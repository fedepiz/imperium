use crate::map::Map;
use entities::*;
use util::Rng;

/// A point on the sim's clock: how many `AdvanceTime` commands have been
/// accepted. Unitless — what one epoch *means* (a day, a year, a tenth of
/// a day) is game content, expressed by date derivations like
/// [`crate::game::Date`]. ZII: epoch zero is the start of the world.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug, Hash)]
pub struct Epoch(pub u64);

impl Epoch {
    pub fn advance(&mut self) {
        self.0 += 1;
    }
}

/// Epochs store directly in uvar slots; the zero epoch is ZII-honest
/// ("never" / the dawn of the world).
impl Bits64 for Epoch {
    fn to_bits(self) -> u64 {
        self.0
    }

    fn from_bits(bits: u64) -> Epoch {
        Epoch(bits)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum ActivityVerb {
    #[default]
    Idle,
    Rest,
}

/// What an entity is doing: a command extended in time, a superset of the
/// verbs' fields (a `target` arrives with the first verb that wants one).
/// ZII: the zero activity is Idle. `until` is the epoch it resolves at;
/// 0 = open-ended (never resolves — it ends only by being replaced).
#[derive(Clone, Copy, Default)]
pub struct Activity {
    pub verb: ActivityVerb,
    pub start: Epoch,
    pub until: Epoch,
}

/// THE authoritative sim state: every piece of world state is a field here,
/// nothing lives outside. Plain data — `Clone` is save, ZII throughout;
/// game code addresses the stores directly (`world.vars.set(&world.ids, …)`).
/// The only methods are the cross-store coordinators, `spawn` and `sweep`.
#[derive(Clone)]
pub struct World {
    /// The sim's clock. Whatever drives the passage of time lives outside
    /// and speaks only in commands.
    pub epoch: Epoch,
    pub ids: Ids,
    /// The schema, kept queryable by name; no sim-path consumer yet.
    #[allow(dead_code)]
    pub defs: Definitions,
    pub names: Names,
    pub vars: Vars,
    pub uvars: UVars,
    pub relations: Relations,
    pub sets: Sets,
    pub tags: Tags,
    /// Deterministic randomness is world state like any other: same seed +
    /// same command stream = same history.
    pub rng: Rng,
    pub activities: Table<Activity>,
    /// The world's geography: authored cells, ZII (the empty map is all
    /// void). Not per-entity state — spawn/sweep never touch it.
    pub map: Map,
    // Future typed columns go here, and get one reset line in `spawn`.
}

impl World {
    pub fn new(defs: Definitions, seed: u64) -> World {
        World {
            epoch: Epoch::default(),
            ids: Ids::new(),
            names: Names::new(),
            vars: Vars::new(&defs),
            uvars: UVars::new(&defs),
            relations: Relations::new(&defs),
            sets: Sets::new(&defs),
            tags: Tags::default(),
            rng: Rng(seed),
            activities: Table::new(),
            map: Map::default(),
            defs,
        }
    }

    /// Allocate an entity and give it a clean slate in every dense store.
    pub fn spawn(&mut self) -> EntityId {
        let id = self.ids.spawn();
        self.vars.reset(id);
        self.uvars.reset(id);
        self.activities.reset(id);
        id
    }

    /// Despawn every entity marked since the last sweep, purging it from
    /// every store in the same breath. Call once per frame: reads don't
    /// filter for liveness, so "no store holds a dead id" — this function's
    /// invariant — depends on marks not outliving the frame that made them.
    pub fn sweep(&mut self) {
        let dead = self.ids.sweep();
        if dead.is_empty() {
            return;
        }
        self.names.purge(&dead);
        self.relations.purge(&dead);
        self.sets.purge(&dead);
        self.tags.purge(&self.ids);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn world() -> World {
        let mut defs = Definitions::default();
        defs.define_var("x");
        defs.define_relation("married");
        defs.define_set("dummy");
        World::new(defs, 42)
    }

    #[test]
    fn marked_entities_stay_fully_alive_until_sweep_purges_every_store() {
        let mut world = world();
        let doomed = world.spawn();
        let widow = world.spawn();
        world.sets.add(&mut world.ids, SetId(0), doomed);
        world.tags.bind(&world.ids, "emperor", doomed);
        world
            .relations
            .set(&world.ids, doomed, RelationId(0), widow, 1.0);
        let name = world.names.add("Commodus");
        world.names.set(&world.ids, doomed, name);

        world.ids.mark_despawn(doomed);

        // Marked but unswept: visible everywhere, like any live entity.
        assert!(world.ids.is_alive(doomed));
        assert!(world.sets.contains(&world.ids, SetId(0), doomed));
        assert_eq!(world.tags.lookup("emperor"), Some(doomed));
        assert_eq!(world.relations.get_related(doomed).count(), 1);
        assert_eq!(world.names.get(&world.ids, doomed), "Commodus");

        world.sweep();

        // Swept: gone from every store at once.
        assert!(!world.ids.is_alive(doomed));
        assert!(!world.sets.contains(&world.ids, SetId(0), doomed));
        assert_eq!(world.tags.lookup("emperor"), None);
        assert_eq!(world.relations.get_related(doomed).count(), 0);
        assert_eq!(world.relations.get_related_to(widow).count(), 0);
    }

    #[test]
    fn reused_slots_start_with_a_clean_slate() {
        let mut world = world();
        let stale = world.spawn();
        world.vars.set(&world.ids, stale, VarId(0), 1.0);
        world.activities.set(
            &world.ids,
            stale,
            Activity {
                verb: ActivityVerb::Rest,
                ..Default::default()
            },
        );
        let name = world.names.add("Sulla");
        world.names.set(&world.ids, stale, name);
        world.ids.mark_despawn(stale);
        world.sweep();

        let replacement = world.spawn();
        assert!(!world.ids.is_alive(stale));
        assert_eq!(world.vars.get(&world.ids, replacement, VarId(0)), 0.0);
        assert_eq!(world.names.get(&world.ids, replacement), "");
        assert_eq!(
            world.activities.get(&world.ids, replacement).verb,
            ActivityVerb::Idle
        );

        // The stale id can't reach the reused slot.
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                world.vars.get(&world.ids, stale, VarId(0))
            }))
            .is_err()
        );
    }
}
