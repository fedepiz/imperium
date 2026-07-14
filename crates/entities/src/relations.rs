use std::collections::BTreeMap;

use crate::defs::{Definitions, RelationId};
use crate::id::{EntityId, Ids};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct RelationKey {
    source: EntityId,
    relation: RelationId,
    target: EntityId,
}

/// Same edges as [`RelationKey`], sorted by (target, relation, source) so
/// incoming-edge queries are one range scan too.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct ReverseKey {
    target: EntityId,
    relation: RelationId,
    source: EntityId,
}

impl ReverseKey {
    fn of(key: RelationKey) -> Self {
        ReverseKey {
            target: key.target,
            relation: key.relation,
            source: key.source,
        }
    }
}

#[derive(Clone, Copy, PartialEq, PartialOrd)]
pub struct RelationEntry {
    pub source: EntityId,
    pub relation: RelationId,
    pub target: EntityId,
    pub value: f32,
}

/// Sparse weighted edges between entities. Absent and 0.0 are the same
/// thing (ZII); a dead endpoint's edges are purged, so reads never filter.
#[derive(Clone)]
pub struct Relations {
    forward: BTreeMap<RelationKey, f32>,
    /// Mirror of `forward` keyed for incoming-edge scans. Kept in sync by
    /// `set` and `purge`, the only two mutation points.
    reverse: BTreeMap<ReverseKey, f32>,
    /// Number of defined relation kinds, for the definition assert.
    count: u16,
}

impl Relations {
    pub fn new(defs: &Definitions) -> Relations {
        Relations {
            forward: BTreeMap::default(),
            reverse: BTreeMap::default(),
            count: defs.iter_relations().len() as u16,
        }
    }

    // If value == 0, remove entry. Otherwise, ensure entry exists and has the given value.
    // Removal deliberately skips every check so cleanup never has to
    // establish liveness first; only insertion demands live endpoints.
    pub fn set(
        &mut self,
        ids: &Ids,
        source: EntityId,
        relation: impl Into<RelationId>,
        target: EntityId,
        value: f32,
    ) {
        let key = RelationKey {
            source,
            relation: relation.into(),
            target,
        };
        if value == 0.0 {
            self.forward.remove(&key);
            self.reverse.remove(&ReverseKey::of(key));
        } else {
            assert!(!value.is_nan());
            assert!(key.relation.0 < self.count);
            assert!(ids.is_alive(source));
            assert!(ids.is_alive(target));
            self.forward.insert(key, value);
            self.reverse.insert(ReverseKey::of(key), value);
        }
    }

    /// 0.0 means "no relation" — absent entries and zero are the same thing.
    pub fn get(
        &self,
        source: EntityId,
        relation: impl Into<RelationId>,
        target: EntityId,
    ) -> f32 {
        let key = RelationKey {
            source,
            relation: relation.into(),
            target,
        };
        self.forward.get(&key).copied().unwrap_or(0.0)
    }

    /// All relations with this source, in (relation, target) order.
    /// Keys sort by (source, relation, target), so this is one range scan.
    /// A dead source has no entries left, so the scan is naturally empty.
    pub fn get_related(&self, source: EntityId) -> impl Iterator<Item = RelationEntry> + '_ {
        let min = RelationKey {
            source,
            relation: RelationId(0),
            target: EntityId::default(),
        };
        let max = RelationKey {
            source,
            relation: RelationId(u16::MAX),
            target: EntityId::MAX,
        };
        self.forward
            .range(min..=max)
            .map(|(key, value)| RelationEntry {
                source: key.source,
                relation: key.relation,
                target: key.target,
                value: *value,
            })
    }

    /// Targets of this source's relations of one kind, in target order.
    /// One range scan over the (source, relation) prefix.
    pub fn get_related_via(
        &self,
        source: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + '_ {
        let relation = relation.into();
        let min = RelationKey {
            source,
            relation,
            target: EntityId::default(),
        };
        let max = RelationKey {
            source,
            relation,
            target: EntityId::MAX,
        };
        self.forward
            .range(min..=max)
            .map(|(key, value)| (key.target, *value))
    }

    /// All relations pointing at this target, in (relation, source)
    /// order. One range scan over the reverse index.
    pub fn get_related_to(&self, target: EntityId) -> impl Iterator<Item = RelationEntry> + '_ {
        let min = ReverseKey {
            target,
            relation: RelationId(0),
            source: EntityId::default(),
        };
        let max = ReverseKey {
            target,
            relation: RelationId(u16::MAX),
            source: EntityId::MAX,
        };
        self.reverse
            .range(min..=max)
            .map(|(key, value)| RelationEntry {
                source: key.source,
                relation: key.relation,
                target: key.target,
                value: *value,
            })
    }

    /// Sources with a relation of one kind pointing at this target, in
    /// source order. One range scan over the reverse index's
    /// (target, relation) prefix.
    pub fn get_related_to_via(
        &self,
        target: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + '_ {
        let relation = relation.into();
        let min = ReverseKey {
            target,
            relation,
            source: EntityId::default(),
        };
        let max = ReverseKey {
            target,
            relation,
            source: EntityId::MAX,
        };
        self.reverse
            .range(min..=max)
            .map(|(key, value)| (key.source, *value))
    }

    /// Remove every edge touching a dead id, from both indexes. Targeted
    /// lookups: each dead id contributes two range scans, not a full walk.
    pub fn purge(&mut self, dead: &[EntityId]) {
        let mut doomed: Vec<RelationKey> = Vec::new();
        for &id in dead {
            doomed.extend(self.get_related(id).map(|entry| RelationKey {
                source: entry.source,
                relation: entry.relation,
                target: entry.target,
            }));
            doomed.extend(self.get_related_to(id).map(|entry| RelationKey {
                source: entry.source,
                relation: entry.relation,
                target: entry.target,
            }));
        }
        for key in doomed {
            self.forward.remove(&key);
            self.reverse.remove(&ReverseKey::of(key));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Ids, Relations) {
        let mut defs = Definitions::default();
        defs.define_relation("married");
        (Ids::new(), Relations::new(&defs))
    }

    #[test]
    fn relations_require_live_endpoints_and_defined_ids() {
        let (mut ids, mut relations) = fixture();
        let source = ids.spawn();
        let target = ids.spawn();
        ids.mark_despawn(target);
        ids.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                relations.set(&ids, source, RelationId(0), target, 1.0)
            }))
            .is_err()
        );
        let live = ids.spawn();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                relations.set(&ids, source, RelationId(1), live, 1.0)
            }))
            .is_err()
        );
        assert!(relations.forward.is_empty());
        assert!(relations.reverse.is_empty());
    }

    #[test]
    fn purge_removes_edges_of_dead_entities() {
        let (mut ids, mut relations) = fixture();
        let source = ids.spawn();
        let target = ids.spawn();
        relations.set(&ids, source, RelationId(0), target, 1.0);
        ids.mark_despawn(target);

        // Marked but not yet swept: the relation is still visible.
        assert_eq!(relations.get(source, RelationId(0), target), 1.0);
        assert_eq!(relations.get_related(source).count(), 1);
        assert_eq!(relations.get_related_to(target).count(), 1);

        let dead = ids.sweep();
        relations.purge(&dead);
        assert_eq!(relations.get(source, RelationId(0), target), 0.0);
        assert_eq!(relations.get_related(source).count(), 0);
        assert_eq!(relations.get_related_to(target).count(), 0);
        assert!(relations.forward.is_empty());
        assert!(relations.reverse.is_empty());
    }

    #[test]
    fn purge_only_removes_edges_of_dead_ids() {
        let (mut ids, mut relations) = fixture();
        let source = ids.spawn();
        let dead = ids.spawn();
        let live = ids.spawn();
        relations.set(&ids, source, RelationId(0), dead, 1.0);
        relations.set(&ids, source, RelationId(0), live, 2.0);
        relations.set(&ids, dead, RelationId(0), live, 3.0);
        ids.mark_despawn(dead);

        let swept = ids.sweep();
        relations.purge(&swept);
        assert_eq!(relations.forward.len(), 1);
        assert_eq!(relations.reverse.len(), 1);
        assert_eq!(relations.get(source, RelationId(0), live), 2.0);

        // The reused slot starts with a clean slate.
        let replacement = ids.spawn();
        assert_eq!(relations.get_related(replacement).count(), 0);
        assert_eq!(relations.get_related_to(replacement).count(), 0);
    }

    #[test]
    fn reverse_queries_find_sources_in_order() {
        let (mut ids, mut relations) = fixture();
        let first = ids.spawn();
        let second = ids.spawn();
        let target = ids.spawn();
        relations.set(&ids, second, RelationId(0), target, 2.0);
        relations.set(&ids, first, RelationId(0), target, 1.0);

        assert_eq!(
            relations
                .get_related_to_via(target, RelationId(0))
                .collect::<Vec<_>>(),
            [(first, 1.0), (second, 2.0)]
        );
        let incoming: Vec<_> = relations.get_related_to(target).collect();
        assert_eq!(incoming.len(), 2);
        assert!(incoming.iter().all(|e| e.target == target));

        relations.set(&ids, first, RelationId(0), target, 0.0);
        assert_eq!(
            relations
                .get_related_to_via(target, RelationId(0))
                .collect::<Vec<_>>(),
            [(second, 2.0)]
        );
    }
}
