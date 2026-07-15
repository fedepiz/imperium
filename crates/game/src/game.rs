use std::collections::HashMap;

use arena::Arena;
use ui::ir;

use crate::date::{DAYS_PER_YEAR, Date, days_between};
use crate::defs::{Relation, Set, UVar, Var, init_world};
use crate::map::{CellPos, Map};
use crate::pathfinding::Pathfinding;
use crate::world::{Activity, ActivityVerb, Epoch, World};
use entities::*;

/// The sim begins here, centuries after the calendar's dawn, so every
/// starting birth date fits above epoch 0.
const START_EPOCH: Epoch = Epoch(700 * DAYS_PER_YEAR);

/// Mortality ramp, rolled once a year on each person's birthday: no chance
/// of death up to this age, certain death `MORTALITY_SPAN` years later.
const MORTALITY_AGE: f32 = 60.0;
const MORTALITY_SPAN: f32 = 30.0;

/// One tick's worth of player intent, fat and ZII: not a verb to dispatch
/// on, but a superset of independent fields, each turning one step of the
/// tick on or off — zero everywhere means "leave it alone", so
/// `Command::default()` does nothing. The whole sim history is the seed
/// plus the command stream.
#[derive(Clone, Copy, Default)]
pub struct Command {
    /// Request one day to pass; the sim declines while the player idles.
    pub advance_time: bool,
    /// Order the player into this activity; None = no order given.
    /// Stopping is not its own thing: an order of Idle is the stop.
    pub activity: Option<ActivityVerb>,
    /// Where an ordered Travel goes; zero = nowhere. Only meaningful
    /// alongside `activity = Some(Travel)`.
    pub destination: CellPos,
    /// Despawn this entity; null = nobody.
    pub remove: EntityId,
    /// Set this entity's gender to female; null = nobody.
    pub femalify: EntityId,
}

/// What one tick reports back to the harness, as plain data: a superset of
/// fields with meaningful zeros, so `Output::default()` says nothing
/// notable happened.
#[derive(Clone, Copy, Default)]
pub struct Output {
    /// The sim is declining `AdvanceTime`: the internal half of the pause
    /// story (the player is idle or absent). The harness shows this as
    /// paused and locks its own pause controls.
    pub forced_paused: bool,
}

impl Command {
    /// UI action protocol: `<verb> [args…]`, with entity ids and cells
    /// packed via their `to_bits` (the `Display`/`FromStr` round trip).
    /// Actions fold into an existing command — several per tick merge,
    /// each setting its own fields — and anything malformed warns and
    /// sets nothing.
    pub fn parse(&mut self, action: &str) {
        let mut parts = action.split_whitespace();
        let verb = parts.next().unwrap_or_default();
        let arg = parts.next().unwrap_or_default();
        match verb {
            "advance_time" => self.advance_time = true,
            "rest" => self.activity = Some(ActivityVerb::Rest),
            "stop" => self.activity = Some(ActivityVerb::Idle),
            "travel" => {
                let destination: CellPos = parse_arg(arg, action);
                // Travelling to nowhere isn't an order.
                if destination != CellPos::default() {
                    self.activity = Some(ActivityVerb::Travel);
                    self.destination = destination;
                }
            }
            "remove" => self.remove = parse_arg(arg, action),
            "femalify" => self.femalify = parse_arg(arg, action),
            _ => eprintln!("unhandled ui action: {action}"),
        }
    }

    pub fn advance_time() -> Self {
        let mut this = Self::default();
        this.advance_time = true;
        this
    }
}

/// An action's packed argument (`EntityId`, `CellPos`, …) via the
/// `FromStr` half of the protocol; malformed warns and reads as the zero
/// value ("nobody", "nowhere"), which every consumer treats as absent.
fn parse_arg<T: core::str::FromStr + Default>(arg: &str, action: &str) -> T {
    match arg.parse::<T>() {
        Ok(value) => value,
        Err(_) => {
            eprintln!("malformed ui action: {action}");
            T::default()
        }
    }
}

pub struct Game {
    world: World,
    /// Derived route memory, not world state: outside the save/clone
    /// unit, rebuilt from nothing.
    pathfinding: Pathfinding,
}

// Derivations: computed from the world on the fly, never stored, never
// methods — plain functions over &World, of which there will be many.

/// Days since birth (births never postdate now, so the distance is it).
fn days_alive(world: &World, id: EntityId) -> u64 {
    let birth: Epoch = world.uvars.get(&world.ids, id, UVar::BirthEpoch);
    days_between(world.epoch, birth)
}

fn age(world: &World, id: EntityId) -> u32 {
    (days_alive(world, id) / DAYS_PER_YEAR) as u32
}

fn is_birthday(world: &World, id: EntityId) -> bool {
    days_alive(world, id) % DAYS_PER_YEAR == 0
}

/// The one mover: sets the spatial truth (`Position`) and keeps its
/// logical mirror (`LocatedIn`) in step across blob boundaries — the
/// contract the bootstrap's `located` handling establishes.
fn move_entity(world: &mut World, id: EntityId, from: CellPos, to: CellPos) {
    world.uvars.set(&world.ids, id, UVar::Position, to);
    let old = world.map.cell(from).settlement;
    let new = world.map.cell(to).settlement;
    if old != new {
        // Removal (weight 0) is a no-op when there's no such edge, so a
        // null `old` (stepping off a road) needs no special case.
        world
            .relations
            .set(&world.ids, id, Relation::LocatedIn, old, 0.0);
        if new != EntityId::NULL {
            world
                .relations
                .set(&world.ids, id, Relation::LocatedIn, new, 1.0);
        }
    }
}

/// The internal half of the pause story: the sim declines to step while
/// the player is idle or absent. (The external half — whether
/// `AdvanceTime` gets pumped at all — is the clock's, outside the sim.)
fn time_may_flow(world: &World) -> bool {
    match world.tags.lookup("player") {
        Some(player) => world.activities.get(player).verb != ActivityVerb::Idle,
        None => false,
    }
}

impl Game {
    pub fn new() -> Game {
        let mut world = init_world(7);
        world.epoch = START_EPOCH;
        let characters = std::fs::read_to_string("data/characters.txt").unwrap_or_default();
        let map = std::fs::read_to_string("data/map.txt").unwrap_or_default();
        bootstrap(&mut world, &characters, &map);
        Game {
            world,
            pathfinding: Pathfinding::default(),
        }
    }

    /// The sole entry point that mutates the sim: one command per tick, a
    /// frame's worth of intent. Not a dispatch — one general path whose
    /// steps run in a fixed order, each reading its share of the command,
    /// the ZII fields turning steps on and off (null ids fail the
    /// liveness checks, false bools skip). Rendering never happens in
    /// here.
    pub fn tick(&mut self, command: Command) -> Output {
        // The player's orders: an ordered activity replaces the current
        // one (an order of Idle is the stop); no order, no change. Only
        // a genuinely new activity — different verb or target — starts,
        // so repeating an order doesn't restart its clock, while
        // retargeting an ongoing travel does take effect.
        if let (Some(next_verb), Some(player)) =
            (command.activity, self.world.tags.lookup("player"))
        {
            let current = *self.world.activities.get(player);
            let next = match next_verb {
                ActivityVerb::Idle => Activity::default(),
                verb => Activity {
                    verb,
                    start: self.world.epoch,
                    until: Epoch(0), // open-ended
                    // Zero for the verbs that don't want one.
                    target: command.destination,
                },
            };
            if next.verb != current.verb || next.target != current.target {
                self.world.activities.set(player, next);
            }
        }

        // Removal. Stale ids parse fine and fail the liveness check — a
        // click raced a death.
        if self.world.ids.is_alive(command.remove) {
            self.world.ids.mark_despawn(command.remove);
            self.report_death(command.remove);
            self.world.sweep();
        }

        if self.world.ids.is_alive(command.femalify) {
            self.world
                .vars
                .set(&self.world.ids, command.femalify, Var::Gender, 0.0);
        }

        // Time. A request, not an imperative: declined outright when the
        // player isn't occupying the time that would pass.
        let day_passes = command.advance_time && time_may_flow(&self.world);
        if day_passes {
            self.world.epoch.advance();
        }

        // The entity pass: one uniform loop over every live entity — no
        // kinds — where each runs every check, GPU-style, written from
        // the entity's point of view. Checks gate themselves, on the day
        // advancing (right now, all of them) or on a set-membership bit,
        // and only where a check genuinely doesn't apply. Death reactions
        // run between mark and sweep, while the corpse's relations are
        // still queryable.
        let entities: Vec<_> = self.world.ids.iter_alive().collect();
        for &id in &entities {
            // Resolve an activity that came due — anything can be doing
            // something, not just people. Completion effects go here as
            // verbs gain them.
            if day_passes {
                let activity = self.world.activities.get(id);
                if activity.until != Epoch(0) && activity.until <= self.world.epoch {
                    self.world.activities.reset(id);
                }
            }

            // Travel: one cell per day toward the target. Stateless —
            // nobody stores a route; each step re-asks from the current
            // cell, so retargeting and detours cost nothing extra.
            if day_passes {
                let activity = *self.world.activities.get(id);
                if activity.verb == ActivityVerb::Travel {
                    let pos: CellPos = self.world.uvars.get(&self.world.ids, id, UVar::Position);
                    let next = self.pathfinding.next_step(&self.world.map, pos, activity.target);
                    if next == CellPos::default() {
                        // Already there, or no way there: the journey ends.
                        self.world.activities.reset(id);
                    } else {
                        move_entity(&mut self.world, id, pos, next);
                        if next == activity.target {
                            self.world.activities.reset(id);
                        }
                    }
                }
            }

            // On birthdays, roll the mortality ramp. Only people age.
            if day_passes && self.world.ids.in_set(id, Set::People) && is_birthday(&self.world, id)
            {
                let hazard = (age(&self.world, id) as f32 - MORTALITY_AGE) / MORTALITY_SPAN;
                if self.world.rng.chance(hazard) {
                    self.world.ids.mark_despawn(id);
                    self.report_death(id);
                }
            }
        }
        self.world.sweep();

        Output {
            forced_paused: !time_may_flow(&self.world),
        }
    }

    /// Placeholder death reaction: console obituary. Runs before the sweep
    /// so it can still read the deceased's name and marriages.
    fn report_death(&self, id: EntityId) {
        let world = &self.world;
        let name = world.names.get(&world.ids, id);
        // Marriage is declared one-way in the data; look both directions.
        let spouses: Vec<&str> = world
            .relations
            .get_related_via(id, Relation::Married)
            .map(|(other, _)| other)
            .chain(
                world
                    .relations
                    .get_related_to_via(id, Relation::Married)
                    .map(|(other, _)| other),
            )
            .map(|other| world.names.get(&world.ids, other))
            .collect();
        if spouses.is_empty() {
            println!("{}: {name} has died.", Date::of(self.world.epoch));
        } else {
            println!(
                "{}: {name} has died, survived by {}.",
                Date::of(self.world.epoch),
                spouses.join(", ")
            );
        }
    }

    /// The map's per-frame bridge, `fill_ui_data`'s sibling for the layer
    /// under the UI: read-only, once per render, all drawing decisions
    /// made sim-side.
    pub fn draw_map(&self) -> crate::draw_map::DrawMap {
        crate::draw_map::build(&self.world)
    }

    /// The general board pick: the entity a click on this cell lands on;
    /// null = nothing there. Settlements for now (the cell's blob owner);
    /// when picking people matters, whoever stands on the cell takes
    /// precedence here.
    pub fn entity_at(&self, pos: CellPos) -> EntityId {
        self.world.map.cell(pos).settlement
    }

    /// Where an entity sits on the board; the zero cell = it has no
    /// cells (or there's no such entity).
    pub fn anchor(&self, id: EntityId) -> CellPos {
        self.world.map.anchor(id)
    }

    /// The per-frame bridge: dump the sim state the UI script binds to.
    /// Read-only, called once per render — never from inside `tick`. Binds
    /// only sim-owned globals; the external clock binds its own.
    pub fn fill_ui_data(&self, data: &mut ir::UiData) {
        let world = &self.world;
        let souls = world.sets.iter(Set::People).count();
        data.bind_global("STATUS", &format!("{souls} souls"));
        data.bind_global("DATE", &Date::of(self.world.epoch).to_string());

        // The player's occupation toggle. Unbound when there is no player,
        // which hides anything `visible = "$HAS_PLAYER"`.
        if let Some(player) = world.tags.lookup("player") {
            data.bind_global("HAS_PLAYER", "yes");
            let idle = world.activities.get(player).verb == ActivityVerb::Idle;
            data.bind_global("PLAYER_BUTTON", if idle { "Rest" } else { "Stop" });
            data.bind_global("PLAYER_ACTION", if idle { "rest" } else { "stop" });
        }

        data.begin_list("people");
        for id in world.sets.iter(Set::People) {
            data.begin_row();
            data.bind("ID", &format!("{}", id));
            data.bind("NAME", world.names.get(&world.ids, id));
            data.bind("AGE", &format!("{}", age(&self.world, id)));
            let activity = world.activities.get(id);
            let doing = match activity.verb {
                ActivityVerb::Idle => String::new(),
                ActivityVerb::Rest => {
                    format!("· resting ({}d)", world.epoch.0 - activity.start.0)
                }
                ActivityVerb::Travel => {
                    // Destinations are cells; a settlement's blob names it.
                    let place = world.map.cell(activity.target).settlement;
                    match world.ids.is_alive(place) {
                        true => {
                            format!("· travelling to {}", world.names.get(&world.ids, place))
                        }
                        false => "· travelling".to_string(),
                    }
                }
            };
            data.bind("ACTIVITY", &doing);
            // Where they stand, spoken as a settlement name; unbound when
            // they're nowhere or on no one's cells.
            let pos: CellPos = world.uvars.get(&world.ids, id, UVar::Position);
            let place = world.map.cell(pos).settlement;
            if world.ids.is_alive(place) {
                data.bind("PLACE", world.names.get(&world.ids, place));
            }
            if world.vars.get(&world.ids, id, Var::Gender) > 0. {
                data.bind("IS_MALE", "yes");
            }
        }
    }
}

/// Spawn the starting world from `data/characters.txt` and `data/map.txt`.
/// Settlements first, then the map (its legend references them), then
/// characters and their relations, so forward references resolve.
fn bootstrap(world: &mut World, characters_source: &str, map_source: &str) {
    let arena = Arena::new();
    let result = tabula::parse(&arena, characters_source);
    for error in result.errors {
        eprintln!("data/characters.txt: {error}");
    }

    let characters = || result.roots.iter().filter(|node| node.key == "character");
    let settlements = || result.roots.iter().filter(|node| node.key == "settlement");

    // Settlements first: characters reference them by key. One key namespace
    // for everything spawnable, so collisions are caught wherever they occur.
    let mut by_key: HashMap<&str, EntityId> = HashMap::new();
    for node in settlements() {
        let id = world.spawn();
        let name = world.names.add(node.get_text("name").unwrap_or("Nowhere"));
        world.names.set(&world.ids, id, name);
        world.sets.add(&mut world.ids, Set::Settlements, id);
        if let Some(key) = node.get_text("id") {
            if by_key.insert(key, id).is_some() {
                eprintln!("data/characters.txt: duplicate id '{key}'");
            }
        }
    }

    // The map's legend speaks in the same keys the settlement pass filed.
    let (map, map_errors) = Map::parse(map_source, |key| by_key.get(key).copied());
    for error in map_errors {
        eprintln!("data/map.txt: {error}");
    }
    world.map = map;

    for node in characters() {
        let id = world.spawn();
        let name = world
            .names
            .add(node.get_text("name").unwrap_or("Anonymous"));
        world.names.set(&world.ids, id, name);
        // The data speaks in ages; the sim speaks in birth epochs. Whole
        // ages put every starting birthday on new year's day.
        let age = node.get_number("age").unwrap_or(0.0);
        let birth = Epoch(world.epoch.0 - (age as u64) * DAYS_PER_YEAR);
        world.uvars.set(&world.ids, id, UVar::BirthEpoch, birth);

        let gender = match node.get_text("gender").unwrap_or_default() {
            "female" => 0.0,
            "male" => 1.0,
            _ => 0.0,
        };
        world.vars.set(&world.ids, id, Var::Gender, gender);

        world.sets.add(&mut world.ids, Set::People, id);
        if let Some(tag) = node.get_text("tag") {
            world.tags.bind(&world.ids, tag, id);
        }
        if let Some(key) = node.get_text("id") {
            if by_key.insert(key, id).is_some() {
                eprintln!("data/characters.txt: duplicate id '{key}'");
            }
        }
    }

    for node in characters() {
        let Some(key) = node.get_text("id") else {
            continue;
        };
        let source_id = by_key[key];
        if let Some(spouse) = node.get_text("married") {
            match by_key.get(spouse) {
                Some(&target) => {
                    world
                        .relations
                        .set(&world.ids, source_id, Relation::Married, target, 1.0)
                }
                None => eprintln!("data/characters.txt: '{key}' married unknown id '{spouse}'"),
            }
        }
        // "located" sets both halves of place: the position (spatial
        // truth, the settlement's anchor cell) and the LocatedIn relation
        // (its logical mirror). Movement code must keep doing likewise.
        if let Some(place) = node.get_text("located") {
            match by_key.get(place) {
                Some(&target) => {
                    let anchor = world.map.anchor(target);
                    if anchor == CellPos::default() {
                        eprintln!("data/map.txt: '{place}' has no cells on the map");
                    }
                    world
                        .uvars
                        .set(&world.ids, source_id, UVar::Position, anchor);
                    world
                        .relations
                        .set(&world.ids, source_id, Relation::LocatedIn, target, 1.0);
                }
                None => eprintln!("data/characters.txt: '{key}' located unknown id '{place}'"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_CAST: &str = r#"
        settlement = { id = v name = "Wicstow" }
        settlement = { id = w name = "Hamtun" }
        character = { id = a name = "Alfric" age = 20 tag = player married = b located = v }
        character = { id = b name = "Beorhtgifu" age = 30 located = v }
        character = { id = c name = "Methuselah" age = 95 }
    "#;

    const TEST_MAP: &str = "
        ~....
        ~v##w
        ~....
        v = v
        w = w
    ";

    fn game() -> Game {
        let mut world = init_world(7);
        world.epoch = START_EPOCH;
        bootstrap(&mut world, TEST_CAST, TEST_MAP);
        Game {
            world,
            pathfinding: Pathfinding::default(),
        }
    }

    /// A command built the way the harness builds them: parsed from a UI
    /// action string into the zero command.
    fn command(action: &str) -> Command {
        let mut command = Command::default();
        command.parse(action);
        command
    }

    /// One in-game day, forced through regardless of the player (tests that
    /// exercise the sim, not the decline rule).
    fn rest_and_tick_days(game: &mut Game, days: u64) {
        game.tick(command("rest"));
        for _ in 0..days {
            game.tick(Command::advance_time());
        }
    }

    #[test]
    fn time_flows_only_while_the_player_is_occupied() {
        let mut game = game();

        // Fresh game: the player is idle, so the sim declines time.
        game.tick(Command::advance_time());
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, START_EPOCH);

        // Resting occupies the player: days pass.
        game.tick(command("rest"));
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, Epoch(START_EPOCH.0 + 1));

        // Stopping goes idle again: declined again.
        game.tick(command("stop"));
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, Epoch(START_EPOCH.0 + 1));
    }

    #[test]
    fn the_old_die_on_their_birthdays_and_the_young_do_not() {
        let mut game = game();

        // Methuselah (95) is past certain death; Alfric (20) and Beorhtgifu (30)
        // are below the ramp. One year of days reaches everyone's birthday.
        rest_and_tick_days(&mut game, 360);
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);
        let player = game.world.tags.lookup("player").unwrap();
        assert_eq!(age(&game.world, player), 21);
        assert!(game.world.relations.get_related(player).count() > 0);
    }

    #[test]
    fn dead_player_halts_time_for_good() {
        let mut game = game();
        let player = game.world.tags.lookup("player").unwrap();
        game.tick(command("rest"));
        game.tick(Command {
            remove: player,
            ..Command::default()
        });

        let epoch = game.world.epoch;
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, epoch);
        // Commanding the void warns and does nothing.
        game.tick(command("rest"));
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, epoch);
    }

    #[test]
    fn ui_data_carries_status_date_and_people_rows() {
        let game = game();
        let mut data = ir::UiData::default();
        game.fill_ui_data(&mut data);

        let global = |key: &str| {
            data.globals
                .iter()
                .find(|g| data.text(g.key) == key)
                .map(|g| data.text(g.value))
                .unwrap()
        };
        assert_eq!(global("STATUS"), "3 souls");
        assert_eq!(global("DATE"), "Day 1 of Month 1, 700 AUC");
        assert_eq!(global("HAS_PLAYER"), "yes");
        // Idle player: the occupation toggle offers Rest.
        assert_eq!(global("PLAYER_BUTTON"), "Rest");
        assert_eq!(global("PLAYER_ACTION"), "rest");

        assert_eq!(data.lists.len(), 1);
        let people_rows = data.rows(data.lists[0]);
        assert_eq!(people_rows.len(), 3);
        let bindings = data.bindings(people_rows[0]);
        let get = |key: &str| {
            bindings
                .iter()
                .find(|b| data.text(b.key) == key)
                .map(|b| data.text(b.value))
                .unwrap()
        };
        assert_eq!(get("NAME"), "Alfric");
        assert_eq!(get("AGE"), "20");
        assert_eq!(get("ACTIVITY"), "");
        // The ID binding round-trips back to the live entity.
        let id: EntityId = get("ID").parse().unwrap();
        assert_eq!(Some(id), game.world.tags.lookup("player"));
    }

    #[test]
    fn commands_round_trip_through_the_action_protocol() {
        let mut game = game();
        let player = game.world.tags.lookup("player").unwrap();

        // The zero command and garbage are no-ops; the sim only moves on
        // fields an action actually set.
        game.tick(Command::default());
        game.tick(command("frobnicate 12"));
        game.tick(command("remove not-an-id"));
        assert_eq!(game.world.epoch, START_EPOCH);
        assert_eq!(game.world.sets.iter(Set::People).count(), 3);

        // The exact strings the UI script emits, ids via Display.
        game.tick(command(&format!("remove {player}")));
        assert!(!game.world.ids.is_alive(player));
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);

        // A stale id parses fine and does nothing.
        game.tick(command(&format!("remove {player}")));
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);
    }

    #[test]
    fn travel_walks_the_road_and_arrival_halts_time() {
        let mut game = game();
        let player = game.world.tags.lookup("player").unwrap();
        let vicus = game.entity_at(CellPos { x: 1, y: 1 });
        let wick = game.entity_at(CellPos { x: 4, y: 1 });
        let destination = game.anchor(wick);

        // The exact string a board click produces. The order lands the
        // same tick; walking starts with the days.
        game.tick(command(&format!("travel {destination}")));
        assert_eq!(
            game.world.activities.get(player).verb,
            ActivityVerb::Travel
        );

        // One day, one cell: onto the road, out of Wicstow — both halves of
        // place move together.
        game.tick(Command::advance_time());
        let pos: CellPos = game.world.uvars.get(&game.world.ids, player, UVar::Position);
        assert_eq!(pos, CellPos { x: 2, y: 1 });
        assert_eq!(
            game.world
                .relations
                .get(player, Relation::LocatedIn, vicus),
            0.0
        );

        // Two more days reach Hamtun: position on its anchor, LocatedIn
        // mirroring it, the journey resolved back to Idle.
        game.tick(Command::advance_time());
        game.tick(Command::advance_time());
        let pos: CellPos = game.world.uvars.get(&game.world.ids, player, UVar::Position);
        assert_eq!(pos, destination);
        assert_eq!(
            game.world.relations.get(player, Relation::LocatedIn, wick),
            1.0
        );
        assert_eq!(game.world.activities.get(player).verb, ActivityVerb::Idle);

        // Arrived and idle: the sim declines further time.
        let epoch = game.world.epoch;
        game.tick(Command::advance_time());
        assert_eq!(game.world.epoch, epoch);
    }

    #[test]
    fn travel_orders_parse_and_garbage_does_not() {
        let mut command = Command::default();
        command.parse(&format!("travel {}", CellPos { x: 4, y: 1 }));
        assert_eq!(command.activity, Some(ActivityVerb::Travel));
        assert_eq!(command.destination, CellPos { x: 4, y: 1 });

        // Garbage and "nowhere" alike order nothing.
        let mut command = Command::default();
        command.parse("travel elsewhere");
        command.parse("travel 0");
        command.parse("travel");
        assert_eq!(command.activity, None);
        assert_eq!(command.destination, CellPos::default());
    }
}
