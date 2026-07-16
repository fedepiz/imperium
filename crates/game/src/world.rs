use crate::map::{CellPos, Map};
use entities::*;

/// A point on the sim's clock: how many `AdvanceTime` commands have been
/// accepted. Unitless — what one epoch *means* (a day, a year, a tenth of
/// a day) is game content, expressed by date derivations like
/// [`crate::game::Date`]. ZII: epoch zero is the start of the world.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug, Hash)]
pub struct Epoch(pub u64);

impl Epoch {
    /// The far end of time: a deadline of MAX is "never".
    pub const MAX: Epoch = Epoch(u64::MAX);

    pub fn advance(&mut self) {
        self.0 += 1;
    }
}

impl std::ops::Add<u64> for Epoch {
    type Output = Epoch;

    fn add(self, rhs: u64) -> Self::Output {
        Epoch(self.0 + rhs)
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
    Travel,
}

/// What an entity is doing: a command extended in time, a superset of the
/// verbs' fields — `target` is Travel's, zero for the verbs that don't
/// want one. ZII: the zero activity is Idle. `until` is the epoch it
/// resolves at; `Epoch::MAX` = open-ended (never resolves — it ends only
/// by being replaced, or, for Travel, by arrival). The zero `until` is
/// always due, which resolves the zero activity to Idle: a no-op.
#[derive(Clone, Copy, Default)]
pub struct Activity {
    pub verb: ActivityVerb,
    pub start: Epoch,
    pub until: Epoch,
    /// Where Travel is headed; the zero cell = no destination.
    pub destination: crate::map::CellPos,
}

/// The double-buffered half of the world: exactly the per-entity state
/// the day pass rewrites. Two instances exist — `World::state`, the
/// current one, and the staging buffer the pass writes into — swapped
/// after each pass. Everything else on [`World`] is a single instance,
/// mutated only in direct mode (outside the pass).
#[derive(Clone)]
pub struct WorldState {
    pub vars: Vars,
    pub uvars: UVars,
    /// The cell each entity stands on — spatial truth, engine-structural
    /// rather than content, hence a typed column and not a uvar. Zero =
    /// nowhere (the map's void corner). Which settlement someone is "in"
    /// is derived from this via the map, never stored.
    pub positions: Table<CellPos>,
    pub activities: Table<Activity>,
    pub relations: Relations,
    // Future typed columns go here, and get one reset line in `spawn`,
    // one copy_chunk_from line in the pass.
}

impl WorldState {
    pub fn new(defs: &Definitions) -> WorldState {
        WorldState {
            vars: Vars::new(defs),
            uvars: UVars::new(defs),
            positions: Table::new(),
            activities: Table::new(),
            relations: Relations::new(defs),
        }
    }
}

/// THE authoritative sim state: every piece of world state is a field
/// here or on [`WorldState`], nothing lives outside. Plain data — `Clone`
/// is save, ZII throughout. Game code goes through the accessors below;
/// the stores under `state` are what the day pass double-buffers, the
/// rest is mutated only in direct mode.
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
    pub tags: Tags,
    /// The root of all randomness: every roll derives its rng from
    /// (seed, turn, n) via [`util::Rng::at`], so draws are reproducible
    /// and independent of each other — same seed + same command stream =
    /// same history, with no rng state to thread through the world.
    pub seed: u64,
    /// The world's geography: authored cells, ZII (the empty map is all
    /// void). Not per-entity state — spawn/sweep never touch it.
    pub map: Map,
    /// The double-buffered per-entity state.
    pub state: WorldState,
}

impl World {
    pub fn new(defs: Definitions, seed: u64) -> World {
        World {
            epoch: Epoch::default(),
            ids: Ids::new(),
            names: Names::new(),
            tags: Tags::default(),
            seed,
            map: Map::default(),
            state: WorldState::new(&defs),
            defs,
        }
    }

    /// Allocate an entity and give it a clean slate in every dense store.
    pub fn spawn(&mut self) -> EntityId {
        let id = self.ids.spawn();
        self.state.vars.reset(id);
        self.state.uvars.reset(id);
        self.state.positions.reset(id);
        self.state.activities.reset(id);
        id
    }

    /// Despawn every entity marked since the last sweep. Names and tags
    /// purge here; dense stores keep their rows (reads gate on liveness,
    /// spawn resets on reuse); relations filter dead endpoints at query
    /// time until the next build drops them physically.
    pub fn sweep(&mut self) {
        let dead = self.ids.sweep();
        if dead.is_empty() {
            return;
        }
        self.names.purge(&dead);
        self.tags.purge(&self.ids);
    }

    // Accessors: the stores under `state` and the relation queries (with
    // `&self.ids` supplied) so call sites stay one layer deep. See the
    // store methods for semantics.

    pub fn get_var(&self, id: EntityId, var: impl Into<VarId>) -> f32 {
        self.state.vars.get(id, var)
    }

    pub fn set_var(&mut self, id: EntityId, var: impl Into<VarId>, value: f32) {
        self.state.vars.set(id, var, value);
    }

    pub fn get_uvar<T: Bits64>(&self, id: EntityId, uvar: impl Into<UVarId>) -> T {
        self.state.uvars.get(id, uvar)
    }

    pub fn set_uvar<T: Bits64>(&mut self, id: EntityId, uvar: impl Into<UVarId>, value: T) {
        self.state.uvars.set(id, uvar, value);
    }

    pub fn position(&self, id: EntityId) -> CellPos {
        *self.state.positions.get(id)
    }

    pub fn set_position(&mut self, id: EntityId, pos: CellPos) {
        self.state.positions.set(id, pos);
    }

    pub fn activity(&self, id: EntityId) -> Activity {
        *self.state.activities.get(id)
    }

    pub fn set_activity(&mut self, id: EntityId, activity: Activity) {
        self.state.activities.set(id, activity);
    }

    pub fn relation(
        &self,
        source: EntityId,
        relation: impl Into<RelationId>,
        target: EntityId,
    ) -> f32 {
        self.state.relations.get(&self.ids, source, relation, target)
    }

    pub fn related(&self, source: EntityId) -> impl Iterator<Item = RelationEntry> + '_ {
        self.state.relations.get_related(&self.ids, source)
    }

    pub fn related_via(
        &self,
        source: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + '_ {
        self.state.relations.get_related_via(&self.ids, source, relation)
    }

    pub fn related_to(&self, target: EntityId) -> impl Iterator<Item = RelationEntry> + '_ {
        self.state.relations.get_related_to(&self.ids, target)
    }

    pub fn related_to_via(
        &self,
        target: EntityId,
        relation: impl Into<RelationId>,
    ) -> impl Iterator<Item = (EntityId, f32)> + '_ {
        self.state
            .relations
            .get_related_to_via(&self.ids, target, relation)
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
        world.ids.join(SetId(0), doomed);
        world.tags.bind(&world.ids, "emperor", doomed);
        let empty = Relations::new(&world.defs);
        world.state.relations.rebuild(
            &empty,
            &world.ids,
            &mut vec![RelationEntry {
                source: doomed,
                relation: RelationId(0),
                target: widow,
                value: 1.0,
            }],
            |_| true,
        );
        let name = world.names.add("Cuthbert");
        world.names.set(doomed, name);

        world.ids.mark_despawn(doomed);

        // Marked but unswept: visible everywhere, like any live entity.
        assert!(world.ids.is_alive(doomed));
        assert!(world.ids.in_set(doomed, SetId(0)));
        assert_eq!(world.tags.lookup("emperor"), Some(doomed));
        assert_eq!(world.related(doomed).count(), 1);
        assert_eq!(world.names.get(doomed), "Cuthbert");

        world.sweep();

        // Swept: gone from every store at once.
        assert!(!world.ids.is_alive(doomed));
        assert!(!world.ids.in_set(doomed, SetId(0)));
        assert_eq!(world.tags.lookup("emperor"), None);
        assert_eq!(world.related(doomed).count(), 0);
        assert_eq!(world.related_to(widow).count(), 0);
    }

    #[test]
    fn reused_slots_start_with_a_clean_slate() {
        let mut world = world();
        let stale = world.spawn();
        world.set_var(stale, VarId(0), 1.0);
        world.set_activity(
            stale,
            Activity {
                verb: ActivityVerb::Rest,
                ..Default::default()
            },
        );
        let name = world.names.add("Sigered");
        world.names.set(stale, name);
        world.ids.mark_despawn(stale);
        world.sweep();

        let replacement = world.spawn();
        assert!(!world.ids.is_alive(stale));
        assert_eq!(world.get_var(replacement, VarId(0)), 0.0);
        assert_eq!(world.names.get(replacement), "");
        assert_eq!(world.activity(replacement).verb, ActivityVerb::Idle);
    }
}
