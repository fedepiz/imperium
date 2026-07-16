//! The spatial map: the cell → entities index, the reverse lookup of the
//! positions column. Derived, never authoritative: a pure function of
//! the world, rebuilt whole at the end of every tick — no carry, no
//! merge, no in-place mutation, and nothing to save. Between rebuilds it
//! is a snapshot: a day pass reading it sees where everyone stood when
//! the day began, simultaneous like every other read of the frozen
//! world. Direct-mode code that moves someone re-derives it (one cheap
//! call) rather than obeying any "don't move people between ticks" rule.

use entities::EntityId;

use crate::map::CellPos;
use crate::world::World;

/// The index: every positioned entity, grouped by cell, CSR-style —
/// per-cell spans into one flat array, no per-cell allocation. ZII: the
/// default (unbuilt) index answers `&[]` everywhere.
#[derive(Default)]
pub struct SpatialMap {
    width: u32,
    height: u32,
    /// Cell `c`'s entities are `entities[offsets[c]..offsets[c + 1]]`.
    offsets: Vec<u32>,
    entities: Vec<EntityId>,
}

impl SpatialMap {
    /// Everyone standing on `pos`, in slot order — a fixed order, so
    /// "the first person here" is deterministic. Out of bounds is the
    /// void (`&[]`), and the zero position is nowhere: nobody is ever
    /// indexed there.
    pub fn at(&self, pos: CellPos) -> &[EntityId] {
        if pos.x >= self.width || pos.y >= self.height {
            return &[];
        }
        let cell = (pos.y * self.width + pos.x) as usize;
        &self.entities[self.offsets[cell] as usize..self.offsets[cell + 1] as usize]
    }

    /// Re-derive the whole index from current positions — the only write
    /// path, a counting sort blasting through the raw positions column:
    /// two dense scans, the same cost every time, cheap enough to run
    /// unconditionally.
    pub fn rebuild(&mut self, world: &World) {
        self.width = world.map.width;
        self.height = world.map.height;
        let cells = (self.width * self.height) as usize;
        self.offsets.clear();
        self.offsets.resize(cells + 1, 0);

        // Where a raw row is indexed; None stays out entirely — the zero
        // position is nowhere, a position off the map (bad data) has no
        // cell to land in, and a dead owner stamp is a corpse's row,
        // kept until slot reuse (liveness gates here, as at every
        // dense-store read).
        let (width, height) = (self.width, self.height);
        let cell_of = |owner: EntityId, pos: CellPos| -> Option<usize> {
            (pos != CellPos::default()
                && pos.x < width
                && pos.y < height
                && world.ids.is_alive(owner))
            .then(|| (pos.y * width + pos.x) as usize)
        };

        // Count each cell's entities one slot ahead, so the running sum
        // turns the counts into row starts.
        for (owner, pos) in world.state.positions.iter() {
            if let Some(cell) = cell_of(owner, pos) {
                self.offsets[cell + 1] += 1;
            }
        }
        for cell in 1..=cells {
            self.offsets[cell] += self.offsets[cell - 1];
        }

        // Scatter, each placement advancing its row's cursor. That
        // spends the starts (each row's cursor ends up one row left of
        // where its start belongs), so shift the array back afterwards.
        self.entities.clear();
        self.entities
            .resize(self.offsets[cells] as usize, EntityId::NULL);
        for (owner, pos) in world.state.positions.iter() {
            if let Some(cell) = cell_of(owner, pos) {
                self.entities[self.offsets[cell] as usize] = owner;
                self.offsets[cell] += 1;
            }
        }
        for cell in (1..=cells).rev() {
            self.offsets[cell] = self.offsets[cell - 1];
        }
        self.offsets[0] = 0;
    }
}
