use std::collections::BTreeSet;

use crate::defs::{Definitions, SetId};
use crate::id::{EntityId, Ids};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SetKey {
    set: SetId,
    entity: EntityId,
}

/// Sparse set memberships. Absence = not a member (ZII); a dead entity's
/// memberships are purged, so iteration never filters. Membership is
/// stored twice, in lockstep: the ordered keys here (for iteration) and
/// each entity's inline bits in `Ids` (for the O(1) `contains`) — which
/// is why the mutators take `&mut Ids`.
#[derive(Clone)]
pub struct Sets {
    keys: BTreeSet<SetKey>,
    /// Number of defined sets, for the definition assert and for purge.
    count: u16,
}

impl Sets {
    pub fn new(defs: &Definitions) -> Sets {
        let count = defs.iter_sets().len() as u16;
        // One bit per set in the entities' inline BitSet. Plenty for now;
        // if it ever transpires, widen the BitSet.
        assert!(count as usize <= 64);
        Sets {
            keys: BTreeSet::default(),
            count,
        }
    }

    pub fn add(&mut self, ids: &mut Ids, set: impl Into<SetId>, entity: EntityId) -> bool {
        let set = set.into();
        assert!(set.0 < self.count);
        assert!(ids.is_alive(entity));
        ids.set_membership(entity, set, true);
        self.keys.insert(SetKey { set, entity })
    }

    pub fn remove(&mut self, ids: &mut Ids, set: impl Into<SetId>, entity: EntityId) -> bool {
        let set = set.into();
        let removed = self.keys.remove(&SetKey { set, entity });
        if removed {
            ids.set_membership(entity, set, false);
        }
        removed
    }

    pub fn contains(&self, ids: &Ids, set: impl Into<SetId>, entity: EntityId) -> bool {
        ids.in_set(entity, set)
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

        assert!(sets.add(&mut ids, SetId(0), first));
        assert!(!sets.add(&mut ids, SetId(0), first));
        assert!(sets.add(&mut ids, SetId(0), second));
        assert!(sets.contains(&ids, SetId(0), first));
        assert_eq!(sets.iter(SetId(0)).collect::<Vec<_>>(), [first, second]);
        assert!(sets.remove(&mut ids, SetId(0), first));
        assert!(!sets.remove(&mut ids, SetId(0), first));
        assert!(!sets.contains(&ids, SetId(0), first));
    }

    #[test]
    fn purge_removes_memberships_of_dead_entities() {
        let (mut ids, mut sets) = fixture();
        let dead = ids.spawn();
        sets.add(&mut ids, SetId(0), dead);
        ids.mark_despawn(dead);

        // Marked but not yet swept: still a member.
        assert!(sets.contains(&ids, SetId(0), dead));

        let swept = ids.sweep();
        sets.purge(&swept);
        assert!(!sets.contains(&ids, SetId(0), dead));
        assert_eq!(sets.iter(SetId(0)).count(), 0);
        assert!(sets.keys.is_empty());

        // The reused slot's inline bits start clean.
        let replacement = ids.spawn();
        assert!(!sets.contains(&ids, SetId(0), replacement));
    }

    #[test]
    fn sets_require_defined_ids_and_live_entities() {
        let (mut ids, mut sets) = fixture();
        let dead = ids.spawn();
        ids.mark_despawn(dead);
        ids.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sets.add(&mut ids, SetId(0), dead)
            }))
            .is_err()
        );

        let live = ids.spawn();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                sets.add(&mut ids, SetId(1), live)
            }))
            .is_err()
        );
    }
}
