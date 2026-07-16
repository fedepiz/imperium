use crate::defs::{Definitions, UVarId};
use crate::id::{EntityId, Ids};

/// A value that round-trips through a u64 slot losslessly. The contract:
/// `from_bits(to_bits(x)) == x`, and `from_bits(0)` is the type's
/// zero/none value (ZII — a fresh slot must read as a valid "nothing").
pub trait Bits64: Copy {
    fn to_bits(self) -> u64;
    fn from_bits(bits: u64) -> Self;
}

impl Bits64 for u64 {
    fn to_bits(self) -> u64 {
        self
    }

    fn from_bits(bits: u64) -> u64 {
        bits
    }
}

/// An entity id in a uvar is a *weak, one-way* reference: far cheaper than
/// a relation, but nothing purges it on death — read it back and check
/// `is_alive` at the point of use, like any stale id.
impl Bits64 for EntityId {
    fn to_bits(self) -> u64 {
        EntityId::to_bits(self)
    }

    fn from_bits(bits: u64) -> EntityId {
        EntityId::from_bits(bits)
    }
}

/// Dense per-entity u64 slots: one per (slot, defined uvar) — the integral
/// sibling of `Vars`, for what f32 can't hold: epochs, handles, weak
/// entity refs. Access is parametric over [`Bits64`], so callers speak in
/// their own types. 0 is the universal "absent/none" value (ZII).
#[derive(Clone)]
pub struct UVars {
    values: Vec<u64>,
    stride: usize,
}

impl UVars {
    pub fn new(defs: &Definitions) -> UVars {
        let stride = defs.iter_uvars().len();
        UVars {
            values: vec![0; Ids::CAPACITY * stride],
            stride,
        }
    }

    fn idx(&self, id: EntityId, var: UVarId) -> usize {
        assert!((var.0 as usize) < self.stride);
        id.index() * self.stride + var.0 as usize
    }

    pub fn get<T: Bits64>(&self, id: EntityId, var: impl Into<UVarId>) -> T {
        T::from_bits(self.values[self.idx(id, var.into())])
    }

    pub fn set<T: Bits64>(&mut self, id: EntityId, var: impl Into<UVarId>, value: T) {
        let idx = self.idx(id, var.into());
        self.values[idx] = value.to_bits();
    }

    /// Zero one slot's row. Called on spawn, so reused slots start clean.
    pub fn reset(&mut self, id: EntityId) {
        let begin = id.index() * self.stride;
        self.values[begin..begin + self.stride].fill(0);
    }

    /// Copy a range of slots' rows wholesale from another store — the
    /// double buffer's carry-forward, called chunk by chunk by the day
    /// pass before per-entity updates overwrite their own rows.
    pub fn copy_chunk_from(&mut self, src: &UVars, slots: core::ops::Range<usize>) {
        debug_assert!(self.stride == src.stride);
        let range = slots.start * self.stride..slots.end * self.stride;
        self.values[range.clone()].copy_from_slice(&src.values[range]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn uvars() -> UVars {
        let mut defs = Definitions::default();
        defs.define_uvar("handle");
        defs.define_uvar("friend");
        UVars::new(&defs)
    }

    #[test]
    fn uvars_read_zero_until_set_and_reset_clears() {
        let mut ids = Ids::new();
        let mut uvars = uvars();
        let id = ids.spawn();

        assert_eq!(uvars.get::<u64>(id, UVarId(0)), 0);
        uvars.set(id, UVarId(0), 99u64);
        assert_eq!(uvars.get::<u64>(id, UVarId(0)), 99);

        uvars.reset(id);
        assert_eq!(uvars.get::<u64>(id, UVarId(0)), 0);
    }

    #[test]
    fn entity_ids_round_trip_as_weak_refs() {
        let mut ids = Ids::new();
        let mut uvars = uvars();
        let holder = ids.spawn();
        let friend = ids.spawn();

        // ZII: the zero slot reads as the null id.
        assert_eq!(uvars.get::<EntityId>(holder, UVarId(1)), EntityId::NULL);

        uvars.set(holder, UVarId(1), friend);
        assert_eq!(uvars.get::<EntityId>(holder, UVarId(1)), friend);

        // Nothing purges a weak ref on death: it reads back stale and
        // simply fails the caller's is_alive check.
        ids.mark_despawn(friend);
        ids.sweep();
        let stale: EntityId = uvars.get(holder, UVarId(1));
        assert_eq!(stale, friend);
        assert!(!ids.is_alive(stale));

        // And a reused slot can't be aliased by it.
        let replacement = ids.spawn();
        assert!(ids.is_alive(replacement));
        assert!(!ids.is_alive(stale));
    }

    #[test]
    fn undefined_accesses_panic() {
        let mut ids = Ids::new();
        let uvars = uvars();
        let live = ids.spawn();

        assert!(std::panic::catch_unwind(|| uvars.get::<u64>(live, UVarId(2))).is_err());
    }
}
