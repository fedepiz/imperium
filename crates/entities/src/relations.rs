use crate::defs::{Definitions, RelationId};
use crate::id::{EntityId, Ids};

/// One weighted edge, as callers hand changes to [`Relations::rebuild`]
/// and as queries yield rows. ZII: value 0.0 means "no relation" — as a
/// change it is a deletion, suppressing whatever the base carried.
#[derive(Clone, Copy, PartialEq, PartialOrd, Debug)]
pub struct RelationEntry {
    pub source: EntityId,
    pub relation: RelationId,
    pub target: EntityId,
    pub value: f32,
}

/// One stored edge; `other` is the far endpoint (the target in the
/// forward matrix, the source in the transpose).
#[derive(Clone, Copy, Default)]
struct Edge {
    relation: RelationId,
    other: EntityId,
    value: f32,
}

/// Sparse weighted edges between entities, stored as a CSR matrix pair:
/// forward (row per source slot) and its transpose (row per target slot),
/// each row sorted by (relation, other). Never mutated in place — the one
/// write path is [`Relations::rebuild`], which reconstructs both matrices
/// as `merge(carry(old), changes)`: kinds the caller's `carries` policy
/// keeps flow forward from the old matrix, changes land on top (the last
/// write to a key wins, zero deletes), and kinds that don't carry exist
/// only as far as changes re-emit them each rebuild. Between rebuilds the
/// data can go stale (an endpoint dies); queries stay truthful by
/// filtering dead endpoints and by stamping each row with the id it was
/// built for, so a reused slot reads empty rather than its predecessor's
/// edges.
#[derive(Clone)]
pub struct Relations {
    /// Forward rows: slot `s`'s edges are `edges[offsets[s]..offsets[s+1]]`.
    offsets: Vec<u32>,
    edges: Vec<Edge>,
    /// The transpose, for incoming-edge queries.
    rev_offsets: Vec<u32>,
    rev_edges: Vec<Edge>,
    /// The id each slot's rows were built for (both matrices share it).
    owners: Vec<EntityId>,
    /// Number of defined relation kinds, for the definition assert.
    count: u16,
}

impl Relations {
    pub fn new(defs: &Definitions) -> Relations {
        Relations {
            offsets: vec![0; Ids::CAPACITY + 1],
            edges: Vec::new(),
            rev_offsets: vec![0; Ids::CAPACITY + 1],
            rev_edges: Vec::new(),
            owners: vec![EntityId::NULL; Ids::CAPACITY],
            count: defs.iter_relations().len() as u16,
        }
    }

    /// Rebuild both matrices as `merge(carry(old), changes)` — the only
    /// write path. The base of each row is the old matrix's row where the
    /// slot still belongs to the same entity, minus kinds `carries`
    /// rejects and edges whose far endpoint died; `changes` then land on
    /// top: a change beats the base on an equal key, the last change to a
    /// key beats earlier ones, and a zero value is a deletion. An empty
    /// `old` (or one built for other occupants) contributes nothing, so
    /// building from scratch is the same call. `changes` is scratch:
    /// sorted in place, reusable across rebuilds. Nonzero changes assert
    /// a defined kind and live endpoints; zero ones skip the liveness
    /// checks (cleanup never has to establish liveness first).
    pub fn rebuild(
        &mut self,
        old: &Relations,
        ids: &Ids,
        changes: &mut Vec<RelationEntry>,
        carries: impl Fn(RelationId) -> bool,
    ) {
        for entry in changes.iter() {
            assert!(!entry.value.is_nan());
            assert!(entry.relation.0 < self.count);
            if entry.value != 0.0 {
                assert!(ids.is_alive(entry.source));
                assert!(ids.is_alive(entry.target));
            }
        }
        // Stable sort: changes to the same key keep their recording
        // order, so the merge below can honor the last write.
        changes.sort_by_key(|e| (e.source, e.relation, e.target));

        // Forward matrix: one merge-join per slot, in slot order.
        self.edges.clear();
        let mut cursor = 0;
        for slot in 0..Ids::CAPACITY {
            self.offsets[slot] = self.edges.len() as u32;
            let owner = ids.id_at(slot);
            self.owners[slot] = owner;

            // Every change naming this slot, consumed whether it merges
            // or not — one whose source has since died just drops.
            let start = cursor;
            while cursor < changes.len() && changes[cursor].source.index() == slot {
                cursor += 1;
            }
            let slot_changes = &changes[start..cursor];

            // The base: the old row, when the old matrix built it for
            // this same occupant — a reused slot carries nothing.
            let base: &[Edge] = if owner.is_valid() && old.owners[slot] == owner {
                old.forward_row(slot)
            } else {
                &[]
            };
            let mut base = base
                .iter()
                .filter(|e| carries(e.relation) && ids.is_alive(e.other))
                .peekable();

            let mut ci = 0;
            loop {
                // The next effective change: skip stale sources, then
                // collapse a run of writes to one key into its last.
                let mut change: Option<RelationEntry> = None;
                while ci < slot_changes.len() {
                    if slot_changes[ci].source != owner {
                        ci += 1;
                        continue;
                    }
                    let key = (slot_changes[ci].relation, slot_changes[ci].target);
                    while ci + 1 < slot_changes.len()
                        && slot_changes[ci + 1].source == owner
                        && (slot_changes[ci + 1].relation, slot_changes[ci + 1].target) == key
                    {
                        ci += 1;
                    }
                    change = Some(slot_changes[ci]);
                    break;
                }

                match (base.peek(), change) {
                    (None, None) => break,
                    (Some(_), None) => {
                        self.edges.push(*base.next().unwrap());
                    }
                    (Some(b), Some(c)) if (b.relation, b.other) < (c.relation, c.target) => {
                        self.edges.push(*base.next().unwrap());
                    }
                    (b, Some(c)) => {
                        // The change wins; an equal-keyed base edge is
                        // consumed and shadowed. Zero = deletion.
                        if b.is_some_and(|b| (b.relation, b.other) == (c.relation, c.target)) {
                            base.next();
                        }
                        if c.value != 0.0 {
                            self.edges.push(Edge {
                                relation: c.relation,
                                other: c.target,
                                value: c.value,
                            });
                        }
                        ci += 1;
                    }
                }
            }
        }
        self.offsets[Ids::CAPACITY] = self.edges.len() as u32;
        debug_assert!(cursor == changes.len());

        // The transpose, by counting sort over target slots.
        // NOTE: this and the forward merge above are the future threading
        // seam — per-chunk counts, a prefix-sum, then a parallel fill.
        self.rev_offsets.fill(0);
        for edge in &self.edges {
            self.rev_offsets[edge.other.index() + 1] += 1;
        }
        for slot in 0..Ids::CAPACITY {
            self.rev_offsets[slot + 1] += self.rev_offsets[slot];
        }
        self.rev_edges.clear();
        self.rev_edges.resize(self.edges.len(), Edge::default());
        for slot in 0..Ids::CAPACITY {
            let source = self.owners[slot];
            for edge in &self.edges[self.offsets[slot] as usize..self.offsets[slot + 1] as usize] {
                let position = &mut self.rev_offsets[edge.other.index()];
                self.rev_edges[*position as usize] = Edge {
                    relation: edge.relation,
                    other: source,
                    value: edge.value,
                };
                *position += 1;
            }
        }
        // The scatter advanced each row's start to its end: shift back.
        for slot in (1..=Ids::CAPACITY).rev() {
            self.rev_offsets[slot] = self.rev_offsets[slot - 1];
        }
        self.rev_offsets[0] = 0;
        for slot in 0..Ids::CAPACITY {
            self.rev_edges[self.rev_offsets[slot] as usize..self.rev_offsets[slot + 1] as usize]
                .sort_unstable_by_key(|e| (e.relation, e.other));
        }
    }

    /// A slot's forward row, ungated — rebuild's carry reads this.
    fn forward_row(&self, slot: usize) -> &[Edge] {
        &self.edges[self.offsets[slot] as usize..self.offsets[slot + 1] as usize]
    }

    /// A slot's row in one matrix, empty unless `id` is alive and is the
    /// id the row was built for (a reused slot never reads its
    /// predecessor's edges).
    fn row<'a>(&'a self, offsets: &[u32], edges: &'a [Edge], ids: &Ids, id: EntityId) -> &'a [Edge] {
        if !ids.is_alive(id) || self.owners[id.index()] != id {
            return &[];
        }
        &edges[offsets[id.index()] as usize..offsets[id.index() + 1] as usize]
    }

    /// One relation kind's span within a row (rows sort by relation first).
    fn via(row: &[Edge], relation: RelationId) -> &[Edge] {
        let start = row.partition_point(|e| e.relation < relation);
        let end = row.partition_point(|e| e.relation <= relation);
        &row[start..end]
    }

    /// 0.0 means "no relation" — absent entries and zero are the same thing.
    pub fn get(
        &self,
        ids: &Ids,
        source: EntityId,
        relation: impl Into<RelationId>,
        target: EntityId,
    ) -> f32 {
        Self::via(self.row(&self.offsets, &self.edges, ids, source), relation.into())
            .iter()
            .find(|e| e.other == target)
            .filter(|_| ids.is_alive(target))
            .map(|e| e.value)
            .unwrap_or(0.0)
    }

    /// All relations with this source, in (relation, target) order.
    /// Edges whose target has died since the rebuild are filtered out.
    pub fn get_related<'a>(
        &'a self,
        ids: &'a Ids,
        source: EntityId,
    ) -> impl Iterator<Item = RelationEntry> + 'a {
        self.row(&self.offsets, &self.edges, ids, source)
            .iter()
            .filter(move |e| ids.is_alive(e.other))
            .map(move |e| RelationEntry {
                source,
                relation: e.relation,
                target: e.other,
                value: e.value,
            })
    }

    /// Targets of this source's relations of one kind, in target order.
    pub fn get_related_via<'a>(
        &'a self,
        ids: &'a Ids,
        source: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + 'a {
        Self::via(self.row(&self.offsets, &self.edges, ids, source), relation.into())
            .iter()
            .filter(move |e| ids.is_alive(e.other))
            .map(|e| (e.other, e.value))
    }

    /// All relations pointing at this target, in (relation, source) order.
    pub fn get_related_to<'a>(
        &'a self,
        ids: &'a Ids,
        target: EntityId,
    ) -> impl Iterator<Item = RelationEntry> + 'a {
        self.row(&self.rev_offsets, &self.rev_edges, ids, target)
            .iter()
            .filter(move |e| ids.is_alive(e.other))
            .map(move |e| RelationEntry {
                source: e.other,
                relation: e.relation,
                target,
                value: e.value,
            })
    }

    /// Sources with a relation of one kind pointing at this target, in
    /// source order.
    pub fn get_related_to_via<'a>(
        &'a self,
        ids: &'a Ids,
        target: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + 'a {
        Self::via(self.row(&self.rev_offsets, &self.rev_edges, ids, target), relation.into())
            .iter()
            .filter(move |e| ids.is_alive(e.other))
            .map(|e| (e.other, e.value))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (Ids, Relations, Relations) {
        let mut defs = Definitions::default();
        defs.define_relation("married");
        defs.define_relation("located"); // treated as non-carrying in tests
        (Ids::new(), Relations::new(&defs), Relations::new(&defs))
    }

    fn edge(source: EntityId, relation: u16, target: EntityId, value: f32) -> RelationEntry {
        RelationEntry {
            source,
            relation: RelationId(relation),
            target,
            value,
        }
    }

    const ALL: fn(RelationId) -> bool = |_| true;

    #[test]
    fn rebuild_from_empty_then_query_both_directions_in_order() {
        let (mut ids, mut relations, empty) = fixture();
        let first = ids.spawn();
        let second = ids.spawn();
        let target = ids.spawn();

        let mut changes = vec![
            edge(second, 0, target, 2.0),
            edge(first, 0, target, 1.0),
            edge(first, 1, target, 3.0),
            edge(first, 0, second, 4.0),
            edge(first, 1, second, 0.0), // zero = no edge
        ];
        relations.rebuild(&empty, &ids, &mut changes, ALL);

        assert_eq!(relations.get(&ids, first, RelationId(0), target), 1.0);
        assert_eq!(relations.get(&ids, target, RelationId(0), first), 0.0);
        assert_eq!(relations.get(&ids, first, RelationId(1), second), 0.0);

        // Forward: (relation, target) order.
        assert_eq!(relations.get_related(&ids, first).count(), 3);
        assert_eq!(
            relations
                .get_related_via(&ids, first, RelationId(0))
                .collect::<Vec<_>>(),
            [(second, 4.0), (target, 1.0)]
        );

        // Reverse: (relation, source) order.
        assert_eq!(
            relations
                .get_related_to_via(&ids, target, RelationId(0))
                .collect::<Vec<_>>(),
            [(first, 1.0), (second, 2.0)]
        );
        let incoming: Vec<_> = relations.get_related_to(&ids, target).collect();
        assert_eq!(incoming.len(), 3);
        assert!(incoming.iter().all(|e| e.target == target));
    }

    #[test]
    fn carried_kinds_flow_forward_and_changes_land_on_top() {
        let (mut ids, mut a, mut b) = fixture();
        let x = ids.spawn();
        let y = ids.spawn();
        let z = ids.spawn();
        // Kind 0 carries; kind 1 does not (rebuilt-only, like LocatedIn).
        let carries = |r: RelationId| r == RelationId(0);

        a.rebuild(
            &b,
            &ids,
            &mut vec![edge(x, 0, y, 1.0), edge(x, 0, z, 5.0), edge(x, 1, y, 9.0)],
            carries,
        );

        // Rebuild with changes: update one carried edge, delete another,
        // add a third; the non-carried kind vanishes unless re-emitted.
        b.rebuild(
            &a,
            &ids,
            &mut vec![
                edge(x, 0, y, 2.0), // update
                edge(x, 0, z, 0.0), // divorce-shaped deletion
                edge(y, 0, z, 7.0), // addition
            ],
            carries,
        );
        assert_eq!(b.get(&ids, x, RelationId(0), y), 2.0);
        assert_eq!(b.get(&ids, x, RelationId(0), z), 0.0);
        assert_eq!(b.get(&ids, y, RelationId(0), z), 7.0);
        assert_eq!(b.get(&ids, x, RelationId(1), y), 0.0);

        // No changes at all: carried kinds persist untouched.
        a.rebuild(&b, &ids, &mut Vec::new(), carries);
        assert_eq!(a.get(&ids, x, RelationId(0), y), 2.0);
        assert_eq!(a.get(&ids, y, RelationId(0), z), 7.0);
    }

    #[test]
    fn the_last_write_to_a_key_wins() {
        let (mut ids, mut relations, empty) = fixture();
        let x = ids.spawn();
        let y = ids.spawn();

        relations.rebuild(
            &empty,
            &ids,
            &mut vec![edge(x, 0, y, 1.0), edge(x, 0, y, 3.0)],
            ALL,
        );
        assert_eq!(relations.get(&ids, x, RelationId(0), y), 3.0);

        let mut defs = Definitions::default();
        defs.define_relation("married");
        defs.define_relation("located");
        let mut second = Relations::new(&defs);
        second.rebuild(
            &empty,
            &ids,
            &mut vec![edge(x, 0, y, 1.0), edge(x, 0, y, 0.0)],
            ALL,
        );
        assert_eq!(second.get(&ids, x, RelationId(0), y), 0.0);
        assert_eq!(second.get_related(&ids, x).count(), 0);
    }

    #[test]
    fn dead_endpoints_read_as_no_relation_and_the_carry_drops_them() {
        let (mut ids, mut a, mut b) = fixture();
        let source = ids.spawn();
        let doomed = ids.spawn();
        let live = ids.spawn();
        a.rebuild(
            &b,
            &ids,
            &mut vec![
                edge(source, 0, doomed, 1.0),
                edge(source, 0, live, 2.0),
                edge(doomed, 0, live, 3.0),
            ],
            ALL,
        );

        ids.mark_despawn(doomed);
        // Marked but unswept: still alive, still related.
        assert_eq!(a.get(&ids, source, RelationId(0), doomed), 1.0);

        ids.sweep();
        // Stale edges linger in the matrix but every query filters them.
        assert_eq!(a.get(&ids, source, RelationId(0), doomed), 0.0);
        assert_eq!(a.get_related(&ids, source).count(), 1);
        assert_eq!(a.get_related(&ids, doomed).count(), 0);
        assert_eq!(a.get_related_to(&ids, live).count(), 1);

        // The next rebuild's carry drops them physically, no changes needed.
        b.rebuild(&a, &ids, &mut Vec::new(), ALL);
        assert_eq!(b.get_related(&ids, source).count(), 1);
        assert_eq!(b.get_related_to(&ids, live).count(), 1);
    }

    #[test]
    fn reused_slots_read_empty_and_carry_nothing() {
        let (mut ids, mut a, mut b) = fixture();
        let source = ids.spawn();
        let doomed = ids.spawn();
        a.rebuild(
            &b,
            &ids,
            &mut vec![edge(doomed, 0, source, 1.0), edge(source, 0, doomed, 2.0)],
            ALL,
        );

        ids.mark_despawn(doomed);
        ids.sweep();
        let replacement = ids.spawn();
        assert_eq!(replacement.index(), doomed.index());

        // The slot's rows were built for the corpse: the replacement owns
        // none of them, in either direction.
        assert_eq!(a.get_related(&ids, replacement).count(), 0);
        assert_eq!(a.get_related_to(&ids, replacement).count(), 0);

        // And the next rebuild's carry starts the slot from nothing.
        b.rebuild(&a, &ids, &mut Vec::new(), ALL);
        assert_eq!(b.get_related(&ids, replacement).count(), 0);
        assert_eq!(b.get_related(&ids, source).count(), 0);
    }

    #[test]
    fn rebuild_requires_live_endpoints_and_defined_kinds() {
        let (mut ids, mut relations, empty) = fixture();
        let source = ids.spawn();
        let dead = ids.spawn();
        ids.mark_despawn(dead);
        ids.sweep();

        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                relations.rebuild(&empty, &ids, &mut vec![edge(source, 0, dead, 1.0)], ALL)
            }))
            .is_err()
        );
        let live = ids.spawn();
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                relations.rebuild(&empty, &ids, &mut vec![edge(source, 2, live, 1.0)], ALL)
            }))
            .is_err()
        );
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                relations.rebuild(&empty, &ids, &mut vec![edge(source, 0, live, f32::NAN)], ALL)
            }))
            .is_err()
        );
        // A zero change to a dead endpoint is cleanup, not an error.
        relations.rebuild(&empty, &ids, &mut vec![edge(source, 0, dead, 0.0)], ALL);
        assert_eq!(relations.get_related(&ids, source).count(), 0);
    }
}
