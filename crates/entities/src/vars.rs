use crate::defs::{Definitions, VarId};
use crate::id::{EntityId, Ids};

/// Dense per-entity scalars: one f32 per (slot, defined var). 0.0 is the
/// universal "absent/none" value (ZII).
#[derive(Clone)]
pub struct Vars {
    values: Vec<f32>,
    stride: usize,
}

impl Vars {
    pub fn new(defs: &Definitions) -> Vars {
        let stride = defs.iter_vars().len();
        Vars {
            values: vec![0.0; Ids::CAPACITY * stride],
            stride,
        }
    }

    fn idx(&self, ids: &Ids, id: EntityId, var: VarId) -> usize {
        assert!(ids.is_alive(id));
        assert!((var.0 as usize) < self.stride);
        id.index() * self.stride + var.0 as usize
    }

    pub fn get(&self, ids: &Ids, id: EntityId, var: impl Into<VarId>) -> f32 {
        self.values[self.idx(ids, id, var.into())]
    }

    pub fn set(&mut self, ids: &Ids, id: EntityId, var: impl Into<VarId>, value: f32) {
        let idx = self.idx(ids, id, var.into());
        self.values[idx] = value;
    }

    /// Zero one slot's row. Called on spawn, so reused slots start clean.
    pub fn reset(&mut self, id: EntityId) {
        let begin = id.index() * self.stride;
        self.values[begin..begin + self.stride].fill(0.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars() -> Vars {
        let mut defs = Definitions::default();
        defs.define_var("x");
        defs.define_var("y");
        Vars::new(&defs)
    }

    #[test]
    fn vars_read_zero_until_set_and_reset_clears() {
        let mut ids = Ids::new();
        let mut vars = vars();
        let id = ids.spawn();

        assert_eq!(vars.get(&ids, id, VarId(0)), 0.0);
        vars.set(&ids, id, VarId(0), 1.5);
        vars.set(&ids, id, VarId(1), -2.0);
        assert_eq!(vars.get(&ids, id, VarId(0)), 1.5);
        assert_eq!(vars.get(&ids, id, VarId(1)), -2.0);

        vars.reset(id);
        assert_eq!(vars.get(&ids, id, VarId(0)), 0.0);
        assert_eq!(vars.get(&ids, id, VarId(1)), 0.0);
    }

    #[test]
    fn stale_and_undefined_accesses_panic() {
        let mut ids = Ids::new();
        let mut vars = vars();
        let stale = ids.spawn();
        vars.set(&ids, stale, VarId(0), 1.0);
        ids.mark_despawn(stale);
        ids.sweep();
        let live = ids.spawn();

        assert!(std::panic::catch_unwind(|| vars.get(&ids, stale, VarId(0))).is_err());
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                vars.set(&ids, stale, VarId(0), 2.0)
            }))
            .is_err()
        );
        assert!(std::panic::catch_unwind(|| vars.get(&ids, live, VarId(2))).is_err());
    }
}
