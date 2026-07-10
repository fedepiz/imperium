use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub(crate) struct EntityId {
    index: u16,
    generation: u16,
}

impl EntityId {
    pub fn is_valid(&self) -> bool {
        self.index != 0 && self.generation % 2 == 1
    }
}

#[derive(Default, Clone, Copy)]
struct EntityData {
    id: EntityId,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct VarId(pub usize);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct RelationId(pub usize);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct SetId(pub usize);

#[derive(Default)]
pub(crate) struct Definitions {
    var_names: Vec<String>,
    relation_names: Vec<String>,
    set_names: Vec<String>,
}

impl Definitions {
    pub fn define_var(&mut self, name: impl Into<String>) -> VarId {
        let id = VarId(self.var_names.len());
        self.var_names.push(name.into());
        id
    }

    pub fn define_relation(&mut self, name: impl Into<String>) -> RelationId {
        let id = RelationId(self.relation_names.len());
        self.relation_names.push(name.into());
        id
    }

    pub fn define_set(&mut self, name: impl Into<String>) -> SetId {
        let id = SetId(self.set_names.len());
        self.set_names.push(name.into());
        id
    }

    pub fn get_var_name(&self, id: VarId) -> Option<&str> {
        self.var_names.get(id.0).map(String::as_str)
    }

    pub fn get_relation_name(&self, id: RelationId) -> Option<&str> {
        self.relation_names.get(id.0).map(String::as_str)
    }

    pub fn get_set_name(&self, id: SetId) -> Option<&str> {
        self.set_names.get(id.0).map(String::as_str)
    }

    pub fn iter_vars(&self) -> impl ExactSizeIterator<Item = VarId> {
        (0..self.var_names.len()).map(VarId)
    }

    pub fn iter_relations(&self) -> impl ExactSizeIterator<Item = RelationId> {
        (0..self.relation_names.len()).map(RelationId)
    }

    pub fn iter_sets(&self) -> impl ExactSizeIterator<Item = SetId> {
        (0..self.set_names.len()).map(SetId)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct RelationKey {
    pub source: EntityId,
    pub relation: RelationId,
    pub target: EntityId,
}

#[derive(Clone, Copy, PartialEq, PartialOrd)]
pub(crate) struct RelationEntry {
    pub source: EntityId,
    pub relation: RelationId,
    pub target: EntityId,
    pub value: f32,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SetKey {
    set: SetId,
    entity: EntityId,
}

pub(crate) struct Entities {
    defs: Definitions,
    entries: Vec<EntityData>,
    free_list: Vec<u16>,
    names: Vec<String>,
    tags: BTreeMap<String, EntityId>,
    vars: Vec<f32>,
    relations: BTreeMap<RelationKey, f32>,
    sets: BTreeSet<SetKey>,
    /// Entities despawned since the last `garbage_collect`. Their relations
    /// stay in the map (reads filter them out lazily) until collected.
    dead_since_gc: Vec<EntityId>,
}

impl Entities {
    const NUM_ENTITIES: usize = 65_000;

    pub fn new(defs: Definitions) -> Self {
        let free_list: Vec<_> = (1..Self::NUM_ENTITIES).rev().map(|x| x as u16).collect();
        let entries: Vec<_> = (0..Self::NUM_ENTITIES)
            .map(|index| EntityData {
                id: EntityId {
                    index: index as u16,
                    generation: 0,
                },
            })
            .collect();

        let vars = (0..Self::NUM_ENTITIES * defs.var_names.len())
            .map(|_| 0.0)
            .collect();
        let names = (0..Self::NUM_ENTITIES).map(|_| String::new()).collect();

        Self {
            defs,
            entries,
            free_list,
            names,
            tags: BTreeMap::default(),
            vars,
            relations: BTreeMap::default(),
            sets: BTreeSet::default(),
            dead_since_gc: Vec::new(),
        }
    }

    fn vars_mut(&mut self, id: EntityId) -> &mut [f32] {
        let begin = id.index as usize * self.defs.var_names.len();
        let end = begin + self.defs.var_names.len();
        &mut self.vars[begin..end]
    }

    fn var_idx(&self, id: EntityId, var: VarId) -> usize {
        assert!(self.is_alive(id));
        assert!(self.defs.get_var_name(var).is_some());
        (id.index as usize * self.defs.var_names.len()) + var.0
    }

    pub fn get_var(&self, id: EntityId, var: impl Into<VarId>) -> f32 {
        self.vars[self.var_idx(id, var.into())]
    }

    pub fn set_var(&mut self, id: EntityId, var: impl Into<VarId>, value: f32) {
        let idx = self.var_idx(id, var.into());
        self.vars[idx] = value;
    }

    pub fn get_name(&self, id: EntityId) -> &str {
        assert!(self.is_alive(id));
        &self.names[id.index as usize]
    }

    pub fn set_name(&mut self, id: EntityId, name: &str) {
        assert!(self.is_alive(id));
        let dst = &mut self.names[id.index as usize];
        dst.clear();
        dst.push_str(name);
    }

    pub fn lookup_by_tag(&self, tag: &str) -> Option<EntityId> {
        self.tags.get(tag).copied().filter(|id| self.is_alive(*id))
    }

    pub fn bind_to_tag(&mut self, tag: impl Into<String>, id: EntityId) -> Option<EntityId> {
        assert!(self.is_alive(id));
        self.tags.insert(tag.into(), id)
    }

    pub fn unbind_tag(&mut self, tag: &str) -> Option<EntityId> {
        self.tags.remove(tag)
    }

    pub fn definitions(&self) -> &Definitions {
        &self.defs
    }

    pub fn get_var_name(&self, id: VarId) -> Option<&str> {
        self.defs.get_var_name(id)
    }

    pub fn get_relation_name(&self, id: RelationId) -> Option<&str> {
        self.defs.get_relation_name(id)
    }

    pub fn get_set_name(&self, id: SetId) -> Option<&str> {
        self.defs.get_set_name(id)
    }

    pub fn iter_vars(&self) -> impl ExactSizeIterator<Item = VarId> {
        self.defs.iter_vars()
    }

    pub fn iter_relations(&self) -> impl ExactSizeIterator<Item = RelationId> {
        self.defs.iter_relations()
    }

    pub fn iter_sets(&self) -> impl ExactSizeIterator<Item = SetId> {
        self.defs.iter_sets()
    }

    // If value == 0, remove entry. Otherwise, ensure entry exists and has the given value
    pub fn set_relation(
        &mut self,
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
            self.relations.remove(&key);
        } else {
            assert!(self.defs.get_relation_name(key.relation).is_some());
            assert!(self.is_alive(source));
            assert!(self.is_alive(target));
            self.relations.insert(key, value);
        }
    }

    /// An id is alive iff its slot still holds the same generation.
    pub fn is_alive(&self, id: EntityId) -> bool {
        id.is_valid()
            && self
                .entries
                .get(id.index as usize)
                .is_some_and(|entry| entry.id == id)
    }

    /// All live relations with this source, in (relation, target) order.
    /// Keys sort by (source, relation, target), so this is one range scan.
    /// Entries whose endpoints have died are filtered out lazily.
    pub fn get_related(&self, source: EntityId) -> impl Iterator<Item = RelationEntry> + '_ {
        let min = RelationKey {
            source,
            relation: RelationId(0),
            target: EntityId::default(),
        };
        let max = RelationKey {
            source,
            relation: RelationId(usize::MAX),
            target: EntityId {
                index: u16::MAX,
                generation: u16::MAX,
            },
        };
        self.relations
            .range(min..=max)
            .filter(move |(key, _)| self.is_alive(key.source) && self.is_alive(key.target))
            .map(|(key, value)| RelationEntry {
                source: key.source,
                relation: key.relation,
                target: key.target,
                value: *value,
            })
    }

    /// Live targets of this source's relations of one kind, in target
    /// order. One range scan over the (source, relation) prefix; entries
    /// whose endpoints have died are filtered out lazily.
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
            target: EntityId {
                index: u16::MAX,
                generation: u16::MAX,
            },
        };
        self.relations
            .range(min..=max)
            .filter(move |(key, _)| self.is_alive(key.source) && self.is_alive(key.target))
            .map(|(key, value)| (key.target, *value))
    }

    pub fn add_to_set(&mut self, set: impl Into<SetId>, entity: EntityId) -> bool {
        let set = set.into();
        assert!(self.defs.get_set_name(set).is_some());
        assert!(self.is_alive(entity));
        self.sets.insert(SetKey { set, entity })
    }

    pub fn remove_from_set(&mut self, set: impl Into<SetId>, entity: EntityId) -> bool {
        self.sets.remove(&SetKey {
            set: set.into(),
            entity,
        })
    }

    pub fn in_set(&self, set: impl Into<SetId>, entity: EntityId) -> bool {
        self.is_alive(entity)
            && self.sets.contains(&SetKey {
                set: set.into(),
                entity,
            })
    }

    pub fn iter_set(&self, set: impl Into<SetId>) -> impl Iterator<Item = EntityId> + '_ {
        let set = set.into();
        let min = SetKey {
            set,
            entity: EntityId::default(),
        };
        let max = SetKey {
            set,
            entity: EntityId {
                index: u16::MAX,
                generation: u16::MAX,
            },
        };
        self.sets
            .range(min..=max)
            .filter(move |key| self.is_alive(key.entity))
            .map(|key| key.entity)
    }

    /// Bulk-remove tags, relations, and set memberships involving entities
    /// that died since the last collect.
    /// Reads are already correct without this (they filter lazily); this
    /// only reclaims memory, so call it whenever convenient.
    pub fn garbage_collect(&mut self) {
        if self.dead_since_gc.is_empty() {
            return;
        }
        let entries = &self.entries;
        self.tags
            .retain(|_, id| entries[id.index as usize].id == *id);
        self.relations.retain(|key, _| {
            entries[key.source.index as usize].id == key.source
                && entries[key.target.index as usize].id == key.target
        });
        self.sets
            .retain(|key| entries[key.entity.index as usize].id == key.entity);
        self.dead_since_gc.clear();
    }

    /// 0.0 means "no relation" — absent entries and zero are the same thing.
    pub fn get_relation(
        &self,
        source: EntityId,
        relation: impl Into<RelationId>,
        target: EntityId,
    ) -> f32 {
        if !self.is_alive(source) || !self.is_alive(target) {
            return 0.0;
        }
        let key = RelationKey {
            source,
            relation: relation.into(),
            target,
        };
        self.relations.get(&key).copied().unwrap_or(0.0)
    }

    pub fn spawn(&mut self) -> EntityId {
        assert!(!self.free_list.is_empty());
        let index = self.free_list.pop().unwrap();
        let id = {
            let entry = &mut self.entries[index as usize];
            entry.id.generation += 1;
            entry.id
        };
        for x in self.vars_mut(id) {
            *x = 0.;
        }
        id
    }

    pub fn despawn(&mut self, id: EntityId) {
        // Id must be valid
        assert!(id.is_valid());
        let entry = &mut self.entries[id.index as usize];
        assert!(entry.id == id);
        if entry.id.generation == u16::MAX {
            // This slot can no longer be reused without resurrecting stale IDs.
            entry.id.generation = 0;
        } else {
            entry.id.generation += 1;
            self.free_list.push(id.index);
        }
        self.names[id.index as usize].clear();
        self.dead_since_gc.push(id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entities() -> Entities {
        let mut defs = Definitions::default();
        defs.define_var("x");
        defs.define_var("y");
        defs.define_relation("married");
        defs.define_set("dummy");
        Entities::new(defs)
    }

    #[test]
    fn definitions_assign_names_and_iterate_ids() {
        let mut defs = Definitions::default();
        let x = defs.define_var("x");
        let age = defs.define_var("age");
        let married = defs.define_relation("married");
        let citizens = defs.define_set("citizens");

        assert_eq!(defs.get_var_name(x), Some("x"));
        assert_eq!(defs.get_var_name(age), Some("age"));
        assert_eq!(defs.get_relation_name(married), Some("married"));
        assert_eq!(defs.get_set_name(citizens), Some("citizens"));
        assert_eq!(defs.get_var_name(VarId(2)), None);
        assert_eq!(defs.iter_vars().collect::<Vec<_>>(), [x, age]);
        assert_eq!(defs.iter_relations().collect::<Vec<_>>(), [married]);
        assert_eq!(defs.iter_sets().collect::<Vec<_>>(), [citizens]);
    }

    #[test]
    fn entities_exposes_definition_names_and_ids() {
        let entities = entities();

        assert_eq!(entities.get_var_name(VarId(0)), Some("x"));
        assert_eq!(entities.get_relation_name(RelationId(0)), Some("married"));
        assert_eq!(entities.get_set_name(SetId(0)), Some("dummy"));
        assert_eq!(
            entities.iter_vars().collect::<Vec<_>>(),
            [VarId(0), VarId(1)]
        );
        assert_eq!(
            entities.iter_relations().collect::<Vec<_>>(),
            [RelationId(0)]
        );
        assert_eq!(entities.iter_sets().collect::<Vec<_>>(), [SetId(0)]);
    }

    #[test]
    fn default_id_is_not_alive() {
        let entities = entities();
        assert!(!entities.is_alive(EntityId::default()));
    }

    #[test]
    fn stale_id_cannot_access_reused_slot() {
        let mut entities = entities();
        let stale = entities.spawn();
        entities.set_var(stale, VarId(0), 1.0);
        entities.despawn(stale);
        let replacement = entities.spawn();

        assert_eq!(stale.index, replacement.index);
        assert!(!entities.is_alive(stale));
        assert!(std::panic::catch_unwind(|| entities.get_var(stale, VarId(0))).is_err());
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.set_var(stale, VarId(0), 2.0)
            }))
            .is_err()
        );
        assert_eq!(entities.get_var(replacement, VarId(0)), 0.0);
    }

    #[test]
    fn names_are_stored_by_slot_and_cleared_on_reuse() {
        let mut entities = entities();
        let first = entities.spawn();
        entities.set_name(first, "Marcus Tullius Cicero");
        assert_eq!(entities.get_name(first), "Marcus Tullius Cicero");

        entities.despawn(first);
        let replacement = entities.spawn();

        assert_eq!(first.index, replacement.index);
        assert_eq!(entities.get_name(replacement), "");
        entities.set_name(replacement, "Gaius Julius Caesar");
        assert_eq!(entities.get_name(replacement), "Gaius Julius Caesar");
        assert!(std::panic::catch_unwind(|| entities.get_name(first)).is_err());
    }

    #[test]
    fn tags_can_be_bound_replaced_and_unbound() {
        let mut entities = entities();
        let first = entities.spawn();
        let second = entities.spawn();

        assert_eq!(entities.bind_to_tag("consul", first), None);
        assert_eq!(entities.lookup_by_tag("consul"), Some(first));
        assert_eq!(entities.bind_to_tag("consul", second), Some(first));
        assert_eq!(entities.lookup_by_tag("consul"), Some(second));
        assert_eq!(entities.unbind_tag("consul"), Some(second));
        assert_eq!(entities.unbind_tag("consul"), None);
        assert_eq!(entities.lookup_by_tag("consul"), None);
    }

    #[test]
    fn dead_tags_are_filtered_and_collected() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.bind_to_tag("emperor", dead);
        entities.despawn(dead);

        assert_eq!(entities.lookup_by_tag("emperor"), None);
        assert_eq!(entities.tags.len(), 1);

        let replacement = entities.spawn();
        assert_eq!(dead.index, replacement.index);
        assert_eq!(entities.lookup_by_tag("emperor"), None);

        entities.garbage_collect();
        assert!(entities.tags.is_empty());
    }

    #[test]
    fn tags_require_live_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.despawn(dead);

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.bind_to_tag("dead", dead)
            }))
            .is_err()
        );
        assert!(entities.tags.is_empty());
    }

    #[test]
    fn exhausted_generation_retires_slot() {
        let mut entities = entities();
        let first = entities.spawn();
        let exhausted = EntityId {
            index: first.index,
            generation: u16::MAX,
        };
        entities.entries[first.index as usize].id = exhausted;

        entities.despawn(exhausted);
        let next = entities.spawn();

        assert!(!entities.is_alive(exhausted));
        assert_ne!(next.index, exhausted.index);
    }

    #[test]
    fn relations_require_live_endpoints() {
        let mut entities = entities();
        let source = entities.spawn();
        let target = entities.spawn();
        entities.despawn(target);
        entities.garbage_collect();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.set_relation(source, RelationId(0), target, 1.0)
            }))
            .is_err()
        );
        assert!(entities.relations.is_empty());
    }

    #[test]
    fn dead_relations_are_filtered_and_collected() {
        let mut entities = entities();
        let source = entities.spawn();
        let target = entities.spawn();
        entities.set_relation(source, RelationId(0), target, 1.0);
        entities.despawn(target);

        assert_eq!(entities.get_relation(source, RelationId(0), target), 0.0);
        assert_eq!(entities.get_related(source).count(), 0);
        assert_eq!(entities.relations.len(), 1);

        entities.garbage_collect();
        assert!(entities.relations.is_empty());
    }

    #[test]
    fn set_membership_is_idempotent_and_removable() {
        let mut entities = entities();
        let first = entities.spawn();
        let second = entities.spawn();

        assert!(entities.add_to_set(SetId(0), first));
        assert!(!entities.add_to_set(SetId(0), first));
        assert!(entities.add_to_set(SetId(0), second));
        assert!(entities.in_set(SetId(0), first));
        assert_eq!(
            entities.iter_set(SetId(0)).collect::<Vec<_>>(),
            [first, second]
        );
        assert!(entities.remove_from_set(SetId(0), first));
        assert!(!entities.remove_from_set(SetId(0), first));
        assert!(!entities.in_set(SetId(0), first));
    }

    #[test]
    fn dead_set_members_are_filtered_and_collected() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.add_to_set(SetId(0), dead);
        entities.despawn(dead);

        assert!(!entities.in_set(SetId(0), dead));
        assert_eq!(entities.iter_set(SetId(0)).count(), 0);
        assert_eq!(entities.sets.len(), 1);

        let replacement = entities.spawn();
        assert_eq!(dead.index, replacement.index);
        assert!(!entities.in_set(SetId(0), replacement));

        entities.garbage_collect();
        assert!(entities.sets.is_empty());
    }

    #[test]
    fn sets_require_defined_ids_and_live_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.despawn(dead);

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.add_to_set(SetId(0), dead)
            }))
            .is_err()
        );

        let live = entities.spawn();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.add_to_set(SetId(1), live)
            }))
            .is_err()
        );
    }
}
