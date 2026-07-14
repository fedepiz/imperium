use crate::id::{EntityId, Ids};

/// A dense per-entity column of typed POD rows, indexed by entity slot —
/// the home for structured state every entity has and the sim touches every
/// step (where name-addressed `Vars` would be the wrong shape). Unused
/// slots hold `T::default()` (ZII); like `Vars`, slot hygiene comes from
/// the spawner calling [`Table::reset`] on each column, so reused slots
/// start clean.
#[derive(Clone)]
pub struct Table<T> {
    rows: Vec<T>,
}

impl<T: Copy + Default> Default for Table<T> {
    fn default() -> Self {
        Table::new()
    }
}

impl<T: Copy + Default> Table<T> {
    pub fn new() -> Table<T> {
        Table {
            rows: vec![T::default(); Ids::CAPACITY],
        }
    }

    pub fn get(&self, ids: &Ids, id: EntityId) -> T {
        assert!(ids.is_alive(id));
        self.rows[id.index()]
    }

    pub fn set(&mut self, ids: &Ids, id: EntityId, row: T) {
        assert!(ids.is_alive(id));
        self.rows[id.index()] = row;
    }

    /// Zero one slot's row. Called on spawn, so reused slots start clean.
    pub fn reset(&mut self, id: EntityId) {
        self.rows[id.index()] = T::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone, Copy, Default, PartialEq, Debug)]
    struct Row {
        kind: u16,
        target: EntityId,
    }

    #[test]
    fn rows_read_default_until_set_and_reset_clears() {
        let mut ids = Ids::new();
        let mut table: Table<Row> = Table::new();
        let id = ids.spawn();
        let other = ids.spawn();

        assert_eq!(table.get(&ids, id), Row::default());
        table.set(
            &ids,
            id,
            Row {
                kind: 3,
                target: other,
            },
        );
        assert_eq!(table.get(&ids, id).kind, 3);
        assert_eq!(table.get(&ids, id).target, other);

        table.reset(id);
        assert_eq!(table.get(&ids, id), Row::default());
    }

    #[test]
    fn reused_slot_reads_default_after_reset_and_stale_access_panics() {
        let mut ids = Ids::new();
        let mut table: Table<Row> = Table::new();
        let stale = ids.spawn();
        table.set(&ids, stale, Row { kind: 7, ..Default::default() });
        ids.mark_despawn(stale);
        ids.sweep();

        let replacement = ids.spawn();
        table.reset(replacement);
        assert_eq!(table.get(&ids, replacement), Row::default());

        assert!(std::panic::catch_unwind(|| table.get(&ids, stale)).is_err());
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                table.set(&ids, stale, Row::default())
            }))
            .is_err()
        );
    }
}
