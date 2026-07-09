use std::collections::BTreeMap;

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

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct VarId(pub usize);

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct RelationId(pub usize);

#[derive(Default)]
pub(crate) struct Definitions {
    pub num_vars: usize,
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

pub(crate) struct Entities {
    defs: Definitions,
    entries: Vec<EntityData>,
    free_list: Vec<u16>,
    vars: Vec<f32>,
    relations: BTreeMap<RelationKey, f32>,
    /// Entities despawned since the last `garbage_collect`. Their relations
    /// stay in the map (reads filter them out lazily) until collected.
    dead_since_gc: Vec<EntityId>,
}

impl Entities {
    const NUM_ENTITIES: usize = 65_000;

    pub fn new(defs: Definitions) -> Self {
        let free_list: Vec<_> = (1..Self::NUM_ENTITIES).rev().map(|x| x as u16).collect();
        let entries: Vec<_> = (0..Self::NUM_ENTITIES)
            .map(|index| {
                let mut entity = EntityData::default();
                entity.id = EntityId {
                    index: index as u16,
                    generation: 0,
                };
                entity
            })
            .collect();

        let vars = (0..Self::NUM_ENTITIES * defs.num_vars)
            .map(|_| 0.0)
            .collect();

        Self {
            defs,
            entries,
            free_list,
            vars,
            relations: BTreeMap::default(),
            dead_since_gc: Vec::new(),
        }
    }

    fn vars_mut(&mut self, id: EntityId) -> &mut [f32] {
        let begin = id.index as usize * self.defs.num_vars;
        let end = begin + self.defs.num_vars;
        &mut self.vars[begin..end]
    }

    fn var_idx(&self, id: EntityId, var: VarId) -> usize {
        assert!(var.0 < self.defs.num_vars);
        (id.index as usize * self.defs.num_vars) + var.0
    }

    pub fn get_var(&self, id: EntityId, var: impl Into<VarId>) -> f32 {
        self.vars[self.var_idx(id, var.into())]
    }

    pub fn set_var(&mut self, id: EntityId, var: impl Into<VarId>, value: f32) {
        let idx = self.var_idx(id, var.into());
        self.vars[idx] = value;
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
            self.relations.insert(key, value);
        }
    }

    /// An id is alive iff its slot still holds the same generation.
    pub fn is_alive(&self, id: EntityId) -> bool {
        self.entries[id.index as usize].id == id
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

    /// Bulk-remove relations whose endpoints died since the last collect.
    /// Reads are already correct without this (they filter lazily); this
    /// only reclaims memory, so call it whenever convenient.
    pub fn garbage_collect(&mut self) {
        if self.dead_since_gc.is_empty() {
            return;
        }
        let entries = &self.entries;
        self.relations.retain(|key, _| {
            entries[key.source.index as usize].id == key.source
                && entries[key.target.index as usize].id == key.target
        });
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
        self.free_list.push(id.index);
        entry.id.generation += 1;
        self.dead_since_gc.push(id);
    }

    fn get(&self, id: EntityId) -> &EntityData {
        let entry = &self.entries[id.index as usize];
        if entry.id.generation != id.generation {
            &self.entries[0]
        } else {
            entry
        }
    }

    fn get_mut(&mut self, id: EntityId) -> &mut EntityData {
        let mut index = id.index as usize;
        if self.entries[index].id.generation != id.generation {
            index = 0;
        }
        &mut self.entries[index]
    }
}
