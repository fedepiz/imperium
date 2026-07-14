use std::collections::BTreeMap;

use crate::id::{EntityId, Ids};

/// Unique string handles onto single entities ("player", "capital").
/// A tag holds at most one id; binding over an existing tag replaces it.
#[derive(Clone, Default)]
pub struct Tags {
    map: BTreeMap<String, EntityId>,
}

impl Tags {
    pub fn lookup(&self, tag: &str) -> Option<EntityId> {
        self.map.get(tag).copied()
    }

    pub fn bind(&mut self, ids: &Ids, tag: impl Into<String>, id: EntityId) -> Option<EntityId> {
        assert!(ids.is_alive(id));
        self.map.insert(tag.into(), id)
    }

    pub fn unbind(&mut self, tag: &str) -> Option<EntityId> {
        self.map.remove(tag)
    }

    /// Drop tags whose entity died. String-keyed, so this is a full scan —
    /// tags are few.
    pub fn purge(&mut self, ids: &Ids) {
        self.map.retain(|_, id| ids.is_alive(*id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tags_can_be_bound_replaced_and_unbound() {
        let mut ids = Ids::new();
        let mut tags = Tags::default();
        let first = ids.spawn();
        let second = ids.spawn();

        assert_eq!(tags.bind(&ids, "consul", first), None);
        assert_eq!(tags.lookup("consul"), Some(first));
        assert_eq!(tags.bind(&ids, "consul", second), Some(first));
        assert_eq!(tags.lookup("consul"), Some(second));
        assert_eq!(tags.unbind("consul"), Some(second));
        assert_eq!(tags.unbind("consul"), None);
        assert_eq!(tags.lookup("consul"), None);
    }

    #[test]
    fn purge_drops_tags_of_dead_entities() {
        let mut ids = Ids::new();
        let mut tags = Tags::default();
        let dead = ids.spawn();
        tags.bind(&ids, "emperor", dead);
        ids.mark_despawn(dead);

        // Marked but not yet swept: the tag still resolves.
        assert_eq!(tags.lookup("emperor"), Some(dead));

        ids.sweep();
        tags.purge(&ids);
        assert_eq!(tags.lookup("emperor"), None);
        assert!(tags.map.is_empty());

        let replacement = ids.spawn();
        assert_eq!(dead.to_bits() & 0xffff, replacement.to_bits() & 0xffff);
        assert_eq!(tags.lookup("emperor"), None);
    }

    #[test]
    fn tags_require_live_entities() {
        let mut ids = Ids::new();
        let mut tags = Tags::default();
        let dead = ids.spawn();
        ids.mark_despawn(dead);
        ids.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                tags.bind(&ids, "dead", dead)
            }))
            .is_err()
        );
        assert!(tags.map.is_empty());
    }
}
