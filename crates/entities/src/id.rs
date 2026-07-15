#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct EntityId {
    index: u16,
    generation: u16,
}

impl EntityId {
    /// The zero id: refers to nothing, fails `is_valid`, reads as absent.
    pub const NULL: EntityId = EntityId {
        index: 0,
        generation: 0,
    };

    /// Sorts after every real id — the upper bound for range scans.
    pub(crate) const MAX: EntityId = EntityId {
        index: u16::MAX,
        generation: u16::MAX,
    };

    pub fn is_valid(&self) -> bool {
        self.index != 0 && self.generation % 2 == 1
    }

    /// The slot this id names, for the dense per-slot stores.
    pub(crate) fn index(self) -> usize {
        self.index as usize
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
    /// Inline set memberships, one bit per `SetId`: the fast half of
    /// membership, kept in lockstep with `Sets`' ordered keys (which
    /// exist for iteration). ZII: no bits, no memberships — despawn
    /// clears them, so reused slots start clean.
    sets: util::bitset::BitSet<1>,
}

/// The id allocator: owns liveness, plus the per-entity inline data that
/// wants to sit right next to it (the membership bits). Slot 0 is
/// reserved as the null slot; a slot's id is alive iff its generation is
/// odd, and a held `EntityId` is alive iff the slot still holds that
/// exact id.
#[derive(Clone)]
pub struct Ids {
    entries: Vec<EntityData>,
    free_list: Vec<u16>,
    /// Entities marked by `mark_despawn`, still fully alive until the next
    /// `sweep` despawns them.
    marked: Vec<EntityId>,
}

impl Default for Ids {
    fn default() -> Self {
        Ids::new()
    }
}

impl Ids {
    /// Fixed slot count shared by every dense per-slot store. Sized to the
    /// game's design (a cast of a few thousand, plus generous headroom).
    pub const CAPACITY: usize = 16_384;

    pub fn new() -> Ids {
        let free_list: Vec<_> = (1..Self::CAPACITY).rev().map(|x| x as u16).collect();
        let entries: Vec<_> = (0..Self::CAPACITY)
            .map(|index| EntityData {
                id: EntityId {
                    index: index as u16,
                    generation: 0,
                },
                ..Default::default()
            })
            .collect();
        Ids {
            entries,
            free_list,
            marked: Vec::new(),
        }
    }

    pub fn spawn(&mut self) -> EntityId {
        assert!(!self.free_list.is_empty());
        let index = self.free_list.pop().unwrap();
        let entry = &mut self.entries[index as usize];
        entry.id.generation += 1;
        entry.id
    }

    /// Record that this entity should die at the next `sweep`. Until then
    /// it stays fully alive: visible to every query and writable. Marking
    /// twice, or marking an id that dies before the sweep, is harmless.
    pub fn mark_despawn(&mut self, id: EntityId) {
        assert!(id.is_valid());
        self.marked.push(id);
    }

    /// An id is alive iff its slot still holds the same generation.
    pub fn is_alive(&self, id: EntityId) -> bool {
        id.is_valid()
            && self
                .entries
                .get(id.index as usize)
                .is_some_and(|entry| entry.id == id)
    }

    /// Fast membership check against the inline bits: O(1), the entity's
    /// slot and one bit. Dead and stale ids are in no set; `Sets` is the
    /// writer that keeps the bits true.
    pub fn in_set(&self, id: EntityId, set: impl Into<crate::defs::SetId>) -> bool {
        self.is_alive(id)
            && self.entries[id.index as usize]
                .sets
                .get(set.into().0 as usize)
    }

    /// Flip a live entity's inline membership bit; `Sets::add`/`remove`
    /// call this in lockstep with their ordered keys.
    pub(crate) fn set_membership(&mut self, id: EntityId, set: crate::defs::SetId, member: bool) {
        assert!(self.is_alive(id));
        self.entries[id.index as usize]
            .sets
            .set(set.0 as usize, member);
    }

    /// All live entities, in slot order — a full scan of every slot, by
    /// design: the cost is `CAPACITY` every time, however many entities
    /// exist. Predictable beats adaptive. Marked-but-unswept entities are
    /// still alive and included. Borrows `self`, so game logic that
    /// mutates while walking should collect into a Vec first.
    pub fn iter_alive(&self) -> impl Iterator<Item = EntityId> + '_ {
        self.entries
            .iter()
            .map(|entry| entry.id)
            .filter(EntityId::is_valid)
    }

    /// Despawn every entity marked since the last sweep, returning the
    /// deduplicated dead so the caller can purge its other stores in the
    /// same breath — reads don't filter for liveness, so stores holding
    /// only live ids depends on marks not outliving the frame that made
    /// them.
    ///
    /// Marks are deduplicated implicitly: despawning bumps the slot's
    /// generation, so a duplicate mark fails the aliveness check and is
    /// skipped.
    pub fn sweep(&mut self) -> Vec<EntityId> {
        let marked = std::mem::take(&mut self.marked);
        let mut dead: Vec<EntityId> = Vec::new();
        for id in marked {
            if !self.is_alive(id) {
                continue;
            }
            let entry = &mut self.entries[id.index as usize];
            // The inline data dies with the entity, so reuse starts ZII.
            entry.sets = Default::default();
            if entry.id.generation == u16::MAX {
                // This slot can no longer be reused without resurrecting stale IDs.
                entry.id.generation = 0;
            } else {
                entry.id.generation += 1;
                self.free_list.push(id.index);
            }
            dead.push(id);
        }
        dead
    }

    #[cfg(test)]
    pub(crate) fn force_generation(&mut self, id: EntityId, generation: u16) -> EntityId {
        let entry = &mut self.entries[id.index as usize];
        entry.id.generation = generation;
        entry.id
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_round_trip_through_bits_and_strings() {
        let mut ids = Ids::new();
        let id = ids.spawn();

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
        assert!(!ids.is_alive(overflow));
    }

    #[test]
    fn default_id_is_not_alive() {
        let ids = Ids::new();
        assert!(!ids.is_alive(EntityId::default()));
        assert!(!ids.is_alive(EntityId::NULL));
    }

    #[test]
    fn marked_entities_stay_alive_until_sweep() {
        let mut ids = Ids::new();
        let doomed = ids.spawn();
        ids.mark_despawn(doomed);
        // Double-marking is harmless and dedups: one dead id comes back.
        ids.mark_despawn(doomed);

        assert!(ids.is_alive(doomed));
        assert_eq!(ids.sweep(), [doomed]);
        assert!(!ids.is_alive(doomed));

        // Marking an already-dead id is harmless too.
        ids.mark_despawn(doomed);
        assert_eq!(ids.sweep(), []);
    }

    #[test]
    fn iter_alive_lists_live_entities_in_slot_order() {
        let mut ids = Ids::new();
        assert_eq!(ids.iter_alive().count(), 0);

        let a = ids.spawn();
        let b = ids.spawn();
        let c = ids.spawn();
        ids.mark_despawn(b);

        // Marked but unswept: still alive.
        assert_eq!(ids.iter_alive().collect::<Vec<_>>(), [a, b, c]);

        ids.sweep();
        assert_eq!(ids.iter_alive().collect::<Vec<_>>(), [a, c]);

        let reused = ids.spawn();
        assert_eq!(reused.index, b.index);
        assert_eq!(ids.iter_alive().collect::<Vec<_>>(), [a, reused, c]);
    }

    #[test]
    fn exhausted_generation_retires_slot() {
        let mut ids = Ids::new();
        let first = ids.spawn();
        let exhausted = ids.force_generation(first, u16::MAX);

        ids.mark_despawn(exhausted);
        ids.sweep();
        let next = ids.spawn();

        assert!(!ids.is_alive(exhausted));
        assert_ne!(next.index, exhausted.index);
    }
}
