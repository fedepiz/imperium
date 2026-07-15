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

    fn idx(&self, id: EntityId, var: VarId) -> usize {
        assert!((var.0 as usize) < self.stride);
        id.index() * self.stride + var.0 as usize
    }

    pub fn get(&self, id: EntityId, var: impl Into<VarId>) -> f32 {
        self.values[self.idx(id, var.into())]
    }

    pub fn set(&mut self, id: EntityId, var: impl Into<VarId>, value: f32) {
        let idx = self.idx(id, var.into());
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

        assert_eq!(vars.get(id, VarId(0)), 0.0);
        vars.set(id, VarId(0), 1.5);
        vars.set(id, VarId(1), -2.0);
        assert_eq!(vars.get(id, VarId(0)), 1.5);
        assert_eq!(vars.get(id, VarId(1)), -2.0);

        vars.reset(id);
        assert_eq!(vars.get(id, VarId(0)), 0.0);
        assert_eq!(vars.get(id, VarId(1)), 0.0);
    }

    #[test]
    fn undefined_accesses_panic() {
        let mut ids = Ids::new();
        let vars = vars();
        let live = ids.spawn();

        assert!(std::panic::catch_unwind(|| vars.get(live, VarId(2))).is_err());
    }
}
