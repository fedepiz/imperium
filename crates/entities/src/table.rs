use crate::id::{EntityId, Ids};

/// A dense per-entity column of typed POD rows, indexed by entity slot —
/// the home for structured state every entity has and the sim touches every
/// step (where name-addressed `Vars` would be the wrong shape). Each row
/// carries its owner's id, so stale access is caught right here with no
/// look into `Ids`. Rows hold `T::default()` until set (ZII); like `Vars`,
/// slot hygiene comes from the spawner calling [`Table::reset`] on each
/// column, which claims the slot for the fresh id with a zero row.
#[derive(Clone)]
pub struct Table<T> {
    rows: Vec<(EntityId, T)>,
}

impl<T: Copy + Default> Default for Table<T> {
    fn default() -> Self {
        Table::new()
    }
}

impl<T: Copy + Default> Table<T> {
    pub fn new() -> Table<T> {
        Table {
            rows: vec![Default::default(); Ids::CAPACITY],
        }
    }

    pub fn get(&self, id: EntityId) -> &T {
        let entry = &self.rows[id.index()];
        assert!(entry.0 == id);
        &entry.1
    }

    pub fn get_mut(&mut self, id: EntityId) -> &mut T {
        let entry = &mut self.rows[id.index()];
        assert!(entry.0 == id);
        &mut entry.1
    }

    pub fn set(&mut self, id: EntityId, row: T) {
        self.rows[id.index()] = (id, row);
    }

    /// Claim a slot for a fresh id with the zero row. Called on spawn, so
    /// reused slots start clean and the old occupant's id stops matching.
    pub fn reset(&mut self, id: EntityId) {
        self.rows[id.index()] = (id, Default::default());
    }

    /// Copy a range of slots' rows wholesale from another store — the
    /// double buffer's carry-forward, called chunk by chunk by the day
    /// pass before per-entity updates overwrite their own rows.
    pub fn copy_chunk_from(&mut self, src: &Table<T>, slots: core::ops::Range<usize>) {
        self.rows[slots.clone()].copy_from_slice(&src.rows[slots]);
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
        table.reset(id);

        assert_eq!(*table.get(id), Row::default());
        table.set(
            id,
            Row {
                kind: 3,
                target: other,
            },
        );
        assert_eq!(table.get(id).kind, 3);
        assert_eq!(table.get(id).target, other);

        table.reset(id);
        assert_eq!(*table.get(id), Row::default());
    }

    #[test]
    fn reused_slot_reads_default_after_reset_and_stale_access_panics() {
        let mut ids = Ids::new();
        let mut table: Table<Row> = Table::new();
        let stale = ids.spawn();
        table.reset(stale);
        table.set(
            stale,
            Row {
                kind: 7,
                ..Default::default()
            },
        );
        ids.mark_despawn(stale);
        ids.sweep();

        let replacement = ids.spawn();
        table.reset(replacement);
        assert_eq!(*table.get(replacement), Row::default());

        // The reused slot carries the replacement's id, so the stale id
        // fails the row's own id check — no `Ids` needed.
        assert!(std::panic::catch_unwind(|| table.get(stale)).is_err());
    }
}
