use std::collections::{BTreeMap, BTreeSet};

use util::span::Span;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct EntityId {
    index: u16,
    generation: u16,
}

impl EntityId {
    /// Sorts after every real id — the upper bound for range scans.
    const MAX: EntityId = EntityId {
        index: u16::MAX,
        generation: u16::MAX,
    };

    pub fn is_valid(&self) -> bool {
        self.index != 0 && self.generation % 2 == 1
    }

    /// Packs the id into one integer, for round-tripping through flat
    /// channels like UI action strings. The null id packs to 0.
    pub fn to_bits(self) -> u64 {
        (self.generation as u64) << 16 | self.index as u64
    }

    /// Inverse of [`EntityId::to_bits`]. Out-of-range bits yield the
    /// null id, which — like any stale id — fails `is_alive` and reads
    /// as nothing; garbage can't alias a live entity.
    pub fn from_bits(bits: u64) -> EntityId {
        if bits > u32::MAX as u64 {
            return EntityId::default();
        }
        EntityId {
            index: bits as u16,
            generation: (bits >> 16) as u16,
        }
    }
}

/// Formats as the packed bits so ids embed directly in UI strings;
/// [`FromStr`](core::str::FromStr) reverses the trip.
impl core::fmt::Display for EntityId {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        core::fmt::Display::fmt(&self.to_bits(), f)
    }
}

impl core::str::FromStr for EntityId {
    type Err = core::num::ParseIntError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(EntityId::from_bits(s.parse::<u64>()?))
    }
}

#[derive(Default, Clone, Copy)]
struct EntityData {
    id: EntityId,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct VarId(pub u16);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct RelationId(pub u16);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct SetId(pub u16);

/// A name handle: a span into the entity system's shared name buffer
/// (see [`Entities::add_name`]). The buffer is append-only and never
/// moves, so a symbol is valid for the lifetime of the `Entities` and
/// any number of entities can share one. ZII: the zero symbol is the
/// empty name.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Symbol(Span);

#[derive(Default, Clone)]
pub struct Definitions {
    var_names: Vec<String>,
    relation_names: Vec<String>,
    set_names: Vec<String>,
}

impl Definitions {
    pub fn define_var(&mut self, name: impl Into<String>) -> VarId {
        let id = VarId(u16::try_from(self.var_names.len()).unwrap());
        self.var_names.push(name.into());
        id
    }

    pub fn define_relation(&mut self, name: impl Into<String>) -> RelationId {
        let id = RelationId(u16::try_from(self.relation_names.len()).unwrap());
        self.relation_names.push(name.into());
        id
    }

    pub fn define_set(&mut self, name: impl Into<String>) -> SetId {
        let id = SetId(u16::try_from(self.set_names.len()).unwrap());
        self.set_names.push(name.into());
        id
    }

    pub fn get_var_name(&self, id: VarId) -> Option<&str> {
        self.var_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn get_relation_name(&self, id: RelationId) -> Option<&str> {
        self.relation_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn get_set_name(&self, id: SetId) -> Option<&str> {
        self.set_names.get(id.0 as usize).map(String::as_str)
    }

    pub fn iter_vars(&self) -> impl ExactSizeIterator<Item = VarId> {
        (0..self.var_names.len() as u16).map(VarId)
    }

    pub fn iter_relations(&self) -> impl ExactSizeIterator<Item = RelationId> {
        (0..self.relation_names.len() as u16).map(RelationId)
    }

    pub fn iter_sets(&self) -> impl ExactSizeIterator<Item = SetId> {
        (0..self.set_names.len() as u16).map(SetId)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct RelationKey {
    pub source: EntityId,
    pub relation: RelationId,
    pub target: EntityId,
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

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SetKey {
    set: SetId,
    entity: EntityId,
}

#[derive(Clone)]
pub struct Entities {
    defs: Definitions,
    entries: Vec<EntityData>,
    free_list: Vec<u16>,
    /// Per-slot name symbols; the zero symbol = unnamed.
    names: Vec<Symbol>,
    /// The name vocabulary: every name ever added, append-only. It never
    /// moves, so symbols stay valid forever. A replaced name's bytes
    /// leak — rare (custom/generated names only) and accepted.
    name_buf: String,
    tags: BTreeMap<String, EntityId>,
    vars: Vec<f32>,
    relations: BTreeMap<RelationKey, f32>,
    /// Mirror of `relations` keyed for incoming-edge scans. Kept in sync by
    /// `set_relation` and `sweep`, the only two mutation points.
    relations_rev: BTreeMap<ReverseKey, f32>,
    sets: BTreeSet<SetKey>,
    /// Entities marked by `mark_despawn`, still fully alive until the next
    /// `sweep` despawns them and purges their tags/relations/memberships.
    marked: Vec<EntityId>,
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

        let vars = vec![0.0; Self::NUM_ENTITIES * defs.var_names.len()];
        let names = vec![Symbol::default(); Self::NUM_ENTITIES];

        Self {
            defs,
            entries,
            free_list,
            names,
            name_buf: String::new(),
            tags: BTreeMap::default(),
            vars,
            relations: BTreeMap::default(),
            relations_rev: BTreeMap::default(),
            sets: BTreeSet::default(),
            marked: Vec::new(),
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
        (id.index as usize * self.defs.var_names.len()) + var.0 as usize
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
        self.names[id.index as usize].0.str(&self.name_buf)
    }

    /// Adds a name to the vocabulary, returning the symbol that names
    /// entities with it. Adding the same text twice stores it twice —
    /// name banks dedup by construction; don't churn this.
    pub fn add_name(&mut self, name: &str) -> Symbol {
        Symbol(Span::push_str(&mut self.name_buf, name))
    }

    pub fn set_name(&mut self, id: EntityId, name: Symbol) {
        assert!(self.is_alive(id));
        self.names[id.index as usize] = name;
    }

    pub fn lookup_by_tag(&self, tag: &str) -> Option<EntityId> {
        self.tags.get(tag).copied()
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

    // If value == 0, remove entry. Otherwise, ensure entry exists and has the given value.
    // Removal deliberately skips every check so cleanup never has to
    // establish liveness first; only insertion demands live endpoints.
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
            self.relations_rev.remove(&ReverseKey::of(key));
        } else {
            assert!(!value.is_nan());
            assert!(self.defs.get_relation_name(key.relation).is_some());
            assert!(self.is_alive(source));
            assert!(self.is_alive(target));
            self.relations.insert(key, value);
            self.relations_rev.insert(ReverseKey::of(key), value);
        }
    }

    /// All live entities, in slot order. Marked-but-unswept entities are
    /// still alive and included. Borrows `self`, so game logic that
    /// mutates while walking should collect into a Vec first.
    pub fn iter_alive(&self) -> impl Iterator<Item = EntityId> + '_ {
        self.entries
            .iter()
            .map(|entry| entry.id)
            .filter(EntityId::is_valid)
    }

    /// An id is alive iff its slot still holds the same generation.
    pub fn is_alive(&self, id: EntityId) -> bool {
        id.is_valid()
            && self
                .entries
                .get(id.index as usize)
                .is_some_and(|entry| entry.id == id)
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
        self.relations
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
        self.relations
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
        self.relations_rev
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
        self.relations_rev
            .range(min..=max)
            .map(|(key, value)| (key.source, *value))
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
        self.sets.contains(&SetKey {
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
            entity: EntityId::MAX,
        };
        self.sets.range(min..=max).map(|key| key.entity)
    }

    /// Despawn every entity marked since the last sweep, purging its tags,
    /// relations, and set memberships in the same breath. Call once per
    /// frame: reads don't filter for liveness, so the maps holding only
    /// live ids depends on marks not outliving the frame that made them.
    ///
    /// Marks are deduplicated implicitly: despawning bumps the slot's
    /// generation, so a duplicate mark fails the aliveness check and is
    /// skipped. Relations and sets are removed by targeted lookups on the
    /// dead ids; tags are string-keyed, so they take a full scan.
    pub fn sweep(&mut self) {
        let marked = std::mem::take(&mut self.marked);
        let mut dead: Vec<EntityId> = Vec::new();
        for id in marked {
            if !self.is_alive(id) {
                continue;
            }
            let entry = &mut self.entries[id.index as usize];
            if entry.id.generation == u16::MAX {
                // This slot can no longer be reused without resurrecting stale IDs.
                entry.id.generation = 0;
            } else {
                entry.id.generation += 1;
                self.free_list.push(id.index);
            }
            self.names[id.index as usize] = Symbol::default();
            dead.push(id);
        }
        if dead.is_empty() {
            return;
        }

        let mut doomed: Vec<RelationKey> = Vec::new();
        for &id in &dead {
            let min = RelationKey {
                source: id,
                relation: RelationId(0),
                target: EntityId::default(),
            };
            let max = RelationKey {
                source: id,
                relation: RelationId(u16::MAX),
                target: EntityId::MAX,
            };
            doomed.extend(self.relations.range(min..=max).map(|(key, _)| *key));

            let min = ReverseKey {
                target: id,
                relation: RelationId(0),
                source: EntityId::default(),
            };
            let max = ReverseKey {
                target: id,
                relation: RelationId(u16::MAX),
                source: EntityId::MAX,
            };
            doomed.extend(
                self.relations_rev
                    .range(min..=max)
                    .map(|(key, _)| RelationKey {
                        source: key.source,
                        relation: key.relation,
                        target: key.target,
                    }),
            );
        }
        for key in doomed {
            self.relations.remove(&key);
            self.relations_rev.remove(&ReverseKey::of(key));
        }

        for &id in &dead {
            for set in self.defs.iter_sets() {
                self.sets.remove(&SetKey { set, entity: id });
            }
        }

        let entries = &self.entries;
        self.tags
            .retain(|_, id| entries[id.index as usize].id == *id);
    }

    /// 0.0 means "no relation" — absent entries and zero are the same thing.
    pub fn get_relation(
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

    /// Record that this entity should die at the next `sweep`. Until then
    /// it stays fully alive: visible to every query and writable. Marking
    /// twice, or marking an id that dies before the sweep, is harmless.
    pub fn mark_despawn(&mut self, id: EntityId) {
        assert!(id.is_valid());
        self.marked.push(id);
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
    fn ids_round_trip_through_bits_and_strings() {
        let mut entities = entities();
        let id = entities.spawn();

        assert_eq!(EntityId::from_bits(id.to_bits()), id);
        assert_eq!(id.to_string().parse::<EntityId>(), Ok(id));

        // ZII: the null id is "0", both ways.
        assert_eq!(EntityId::default().to_bits(), 0);
        assert_eq!("0".parse::<EntityId>(), Ok(EntityId::default()));

        // Garbage degrades safely: not-a-number is an error; out-of-range
        // bits pack to the null id, which is never alive.
        assert!("brutus".parse::<EntityId>().is_err());
        let overflow = "99999999999999".parse::<EntityId>().unwrap();
        assert_eq!(overflow, EntityId::default());
        assert!(!entities.is_alive(overflow));
    }

    #[test]
    fn default_id_is_not_alive() {
        let entities = entities();
        assert!(!entities.is_alive(EntityId::default()));
    }

    #[test]
    fn marked_entities_stay_alive_until_sweep() {
        let mut entities = entities();
        let doomed = entities.spawn();
        entities.add_to_set(SetId(0), doomed);
        entities.mark_despawn(doomed);
        // Double-marking is harmless.
        entities.mark_despawn(doomed);

        assert!(entities.is_alive(doomed));
        assert!(entities.in_set(SetId(0), doomed));
        assert_eq!(entities.iter_set(SetId(0)).count(), 1);

        entities.sweep();
        assert!(!entities.is_alive(doomed));
        assert!(!entities.in_set(SetId(0), doomed));
        assert!(entities.sets.is_empty());

        // Marking an already-dead id is harmless too.
        entities.mark_despawn(doomed);
        entities.sweep();
    }

    #[test]
    fn iter_alive_lists_live_entities_in_slot_order() {
        let mut entities = entities();
        assert_eq!(entities.iter_alive().count(), 0);

        let a = entities.spawn();
        let b = entities.spawn();
        let c = entities.spawn();
        entities.mark_despawn(b);

        // Marked but unswept: still alive.
        assert_eq!(entities.iter_alive().collect::<Vec<_>>(), [a, b, c]);

        entities.sweep();
        assert_eq!(entities.iter_alive().collect::<Vec<_>>(), [a, c]);

        let reused = entities.spawn();
        assert_eq!(reused.index, b.index);
        assert_eq!(entities.iter_alive().collect::<Vec<_>>(), [a, reused, c]);
    }

    #[test]
    fn stale_id_cannot_access_reused_slot() {
        let mut entities = entities();
        let stale = entities.spawn();
        entities.set_var(stale, VarId(0), 1.0);
        entities.mark_despawn(stale);
        entities.sweep();
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
        let cicero = entities.add_name("Marcus Tullius Cicero");
        entities.set_name(first, cicero);
        assert_eq!(entities.get_name(first), "Marcus Tullius Cicero");

        entities.mark_despawn(first);
        entities.sweep();
        let replacement = entities.spawn();

        assert_eq!(first.index, replacement.index);
        assert_eq!(entities.get_name(replacement), "");
        let caesar = entities.add_name("Gaius Julius Caesar");
        entities.set_name(replacement, caesar);
        assert_eq!(entities.get_name(replacement), "Gaius Julius Caesar");
        assert!(std::panic::catch_unwind(|| entities.get_name(first)).is_err());
    }

    #[test]
    fn one_symbol_names_many_entities_and_outlives_them() {
        let mut entities = entities();
        let gaius = entities.add_name("Gaius");
        let a = entities.spawn();
        let b = entities.spawn();
        entities.set_name(a, gaius);
        entities.set_name(b, gaius);
        assert_eq!(entities.get_name(a), "Gaius");
        assert_eq!(entities.get_name(b), "Gaius");
        // One vocabulary entry serves both.
        assert_eq!(entities.name_buf.len(), "Gaius".len());

        entities.mark_despawn(a);
        entities.sweep();
        let c = entities.spawn();
        entities.set_name(c, gaius);
        assert_eq!(entities.get_name(c), "Gaius");
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
    fn sweep_purges_tags_of_dead_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.bind_to_tag("emperor", dead);
        entities.mark_despawn(dead);

        // Marked but not yet swept: the tag still resolves.
        assert_eq!(entities.lookup_by_tag("emperor"), Some(dead));

        entities.sweep();
        assert_eq!(entities.lookup_by_tag("emperor"), None);
        assert!(entities.tags.is_empty());

        let replacement = entities.spawn();
        assert_eq!(dead.index, replacement.index);
        assert_eq!(entities.lookup_by_tag("emperor"), None);
    }

    #[test]
    fn tags_require_live_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.mark_despawn(dead);
        entities.sweep();

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

        entities.mark_despawn(exhausted);
        entities.sweep();
        let next = entities.spawn();

        assert!(!entities.is_alive(exhausted));
        assert_ne!(next.index, exhausted.index);
    }

    #[test]
    fn relations_require_live_endpoints() {
        let mut entities = entities();
        let source = entities.spawn();
        let target = entities.spawn();
        entities.mark_despawn(target);
        entities.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                entities.set_relation(source, RelationId(0), target, 1.0)
            }))
            .is_err()
        );
        assert!(entities.relations.is_empty());
        assert!(entities.relations_rev.is_empty());
    }

    #[test]
    fn sweep_purges_relations_of_dead_entities() {
        let mut entities = entities();
        let source = entities.spawn();
        let target = entities.spawn();
        entities.set_relation(source, RelationId(0), target, 1.0);
        entities.mark_despawn(target);

        // Marked but not yet swept: the relation is still visible.
        assert_eq!(entities.get_relation(source, RelationId(0), target), 1.0);
        assert_eq!(entities.get_related(source).count(), 1);
        assert_eq!(entities.get_related_to(target).count(), 1);

        entities.sweep();
        assert_eq!(entities.get_relation(source, RelationId(0), target), 0.0);
        assert_eq!(entities.get_related(source).count(), 0);
        assert_eq!(entities.get_related_to(target).count(), 0);
        assert!(entities.relations.is_empty());
        assert!(entities.relations_rev.is_empty());
    }

    #[test]
    fn reverse_queries_find_sources_in_order() {
        let mut entities = entities();
        let first = entities.spawn();
        let second = entities.spawn();
        let target = entities.spawn();
        entities.set_relation(second, RelationId(0), target, 2.0);
        entities.set_relation(first, RelationId(0), target, 1.0);

        assert_eq!(
            entities
                .get_related_to_via(target, RelationId(0))
                .collect::<Vec<_>>(),
            [(first, 1.0), (second, 2.0)]
        );
        let incoming: Vec<_> = entities.get_related_to(target).collect();
        assert_eq!(incoming.len(), 2);
        assert!(incoming.iter().all(|e| e.target == target));

        entities.set_relation(first, RelationId(0), target, 0.0);
        assert_eq!(
            entities
                .get_related_to_via(target, RelationId(0))
                .collect::<Vec<_>>(),
            [(second, 2.0)]
        );
    }

    #[test]
    fn sweep_only_removes_relations_of_dead_ids() {
        let mut entities = entities();
        let source = entities.spawn();
        let dead = entities.spawn();
        let live = entities.spawn();
        entities.set_relation(source, RelationId(0), dead, 1.0);
        entities.set_relation(source, RelationId(0), live, 2.0);
        entities.set_relation(dead, RelationId(0), live, 3.0);
        entities.mark_despawn(dead);

        entities.sweep();
        assert_eq!(entities.relations.len(), 1);
        assert_eq!(entities.relations_rev.len(), 1);
        assert_eq!(entities.get_relation(source, RelationId(0), live), 2.0);

        // The reused slot starts with a clean slate.
        let replacement = entities.spawn();
        assert_eq!(dead.index, replacement.index);
        assert_eq!(entities.get_related(replacement).count(), 0);
        assert_eq!(entities.get_related_to(replacement).count(), 0);
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
    fn sweep_purges_set_memberships_of_dead_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.add_to_set(SetId(0), dead);
        entities.mark_despawn(dead);

        entities.sweep();
        assert!(!entities.in_set(SetId(0), dead));
        assert_eq!(entities.iter_set(SetId(0)).count(), 0);
        assert!(entities.sets.is_empty());

        let replacement = entities.spawn();
        assert_eq!(dead.index, replacement.index);
        assert!(!entities.in_set(SetId(0), replacement));
    }

    #[test]
    fn sets_require_defined_ids_and_live_entities() {
        let mut entities = entities();
        let dead = entities.spawn();
        entities.mark_despawn(dead);
        entities.sweep();

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
