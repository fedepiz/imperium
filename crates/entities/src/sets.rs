use std::collections::BTreeSet;

use crate::defs::{Definitions, SetId};
use crate::id::{EntityId, Ids};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SetKey {
    set: SetId,
    entity: EntityId,
}

/// Sparse set memberships. Absence = not a member (ZII); a dead entity's
/// memberships are purged, so iteration never filters.
#[derive(Clone)]
pub struct Sets {
    keys: BTreeSet<SetKey>,
    /// Number of defined sets, for the definition assert and for purge.
    count: u16,
}

impl Sets {
    pub fn new(defs: &Definitions) -> Sets {
        Sets {
            keys: BTreeSet::default(),
            count: defs.iter_sets().len() as u16,
        }
    }

    pub fn add(&mut self, ids: &Ids, set: impl Into<SetId>, entity: EntityId) -> bool {
        let set = set.into();
        assert!(set.0 < self.count);
        assert!(ids.is_alive(entity));
        self.keys.insert(SetKey { set, entity })
    }

    pub fn remove(&mut self, set: impl Into<SetId>, entity: EntityId) -> bool {
        self.keys.remove(&SetKey {
            set: set.into(),
            entity,
        })
    }

    pub fn contains(&self, set: impl Into<SetId>, entity: EntityId) -> bool {
        self.keys.contains(&SetKey {
            set: set.into(),
            entity,
        })
    }

    pub fn iter(&self, set: impl Into<SetId>) -> impl Iterator<Item = EntityId> + '_ {
        let set = set.into();
        let min = SetKey {
            set,
            entity: EntityId::default(),
        };
        let max = SetKey {
            set,
            entity: EntityId::MAX,
        };
        self.keys.range(min..=max).map(|key| key.entity)
    }

    /// Remove the dead from every set: one point removal per (set, dead id).
    pub fn purge(&mut self, dead: &[EntityId]) {
        for &entity in dead {
            for set in 0..self.count {
                self.keys.remove(&SetKey {
                    set: SetId(set),
                    entity,
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Ids, Sets) {
        let mut defs = Definitions::default();
        defs.define_set("dummy");
        (Ids::new(), Sets::new(&defs))
    }

    #[test]
    fn set_membership_is_idempotent_and_removable() {
        let (mut ids, mut sets) = fixture();
        let first = ids.spawn();
        let second = ids.spawn();

        assert!(sets.add(&ids, SetId(0), first));
        assert!(!sets.add(&ids, SetId(0), first));
        assert!(sets.add(&ids, SetId(0), second));
        assert!(sets.contains(SetId(0), first));
        assert_eq!(sets.iter(SetId(0)).collect::<Vec<_>>(), [first, second]);
        assert!(sets.remove(SetId(0), first));
        assert!(!sets.remove(SetId(0), first));
        assert!(!sets.contains(SetId(0), first));
    }

    #[test]
    fn purge_removes_memberships_of_dead_entities() {
        let (mut ids, mut sets) = fixture();
        let dead = ids.spawn();
        sets.add(&ids, SetId(0), dead);
        ids.mark_despawn(dead);

        // Marked but not yet swept: still a member.
        assert!(sets.contains(SetId(0), dead));

        let swept = ids.sweep();
        sets.purge(&swept);
        assert!(!sets.contains(SetId(0), dead));
        assert_eq!(sets.iter(SetId(0)).count(), 0);
        assert!(sets.keys.is_empty());

        let replacement = ids.spawn();
        assert!(!sets.contains(SetId(0), replacement));
    }

    #[test]
    fn sets_require_defined_ids_and_live_entities() {
        let (mut ids, mut sets) = fixture();
        let dead = ids.spawn();
        ids.mark_despawn(dead);
        ids.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sets.add(&ids, SetId(0), dead)
            }))
            .is_err()
        );

        let live = ids.spawn();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sets.add(&ids, SetId(1), live)
            }))
            .is_err()
        );
    }
}
