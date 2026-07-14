use std::collections::HashMap;

use arena::Arena;
use ui::ir;

use crate::date::{days_between, Date, DAYS_PER_YEAR};
use crate::defs::{init_world, Relation, Set, UVar, Var};
use crate::world::{Activity, ActivityVerb, Epoch, World};
use entities::*;

/// The sim begins here, centuries after the calendar's dawn, so every
/// starting birth date fits above epoch 0.
const START_EPOCH: Epoch = Epoch(700 * DAYS_PER_YEAR);

/// Mortality ramp, rolled once a year on each person's birthday: no chance
/// of death up to this age, certain death `MORTALITY_SPAN` years later.
const MORTALITY_AGE: f32 = 60.0;
const MORTALITY_SPAN: f32 = 30.0;

#[derive(Clone, Copy, PartialEq, Eq, Default)]
pub enum Verb {
    /// The zero command: nothing happened this frame.
    #[default]
    Idle,
    AdvanceTime,
    Rest,
    Stop,
    Remove,
    Femalify,
}

/// One frame's worth of player intent, as plain data: a verb plus a superset
/// of arguments, unused ones left at zero. `Command::default()` is `Idle`.
/// The whole sim history is the seed plus the command stream.
#[derive(Clone, Copy, Default)]
pub struct Command {
    pub verb: Verb,
    pub target: EntityId,
}

impl Command {
    pub const IDLE: Command = Command {
        verb: Verb::Idle,
        target: EntityId::NULL,
    };

    pub const ADVANCE_TIME: Command = Command {
        verb: Verb::AdvanceTime,
        target: EntityId::NULL,
    };

    fn on(verb: Verb, target: EntityId) -> Command {
        Command { verb, target }
    }

    /// UI action protocol: `<verb> [args…]`, with entity ids packed via
    /// `EntityId::to_bits` (the `Display`/`FromStr` round trip). Anything
    /// malformed warns and parses to `Idle`, the do-nothing command.
    pub fn parse(action: &str) -> Command {
        let mut parts = action.split_whitespace();
        let verb = match parts.next() {
            Some("advance_time") => return Command::ADVANCE_TIME,
            Some("rest") => return Command::on(Verb::Rest, EntityId::NULL),
            Some("stop") => return Command::on(Verb::Stop, EntityId::NULL),
            Some("remove") => Verb::Remove,
            Some("femalify") => Verb::Femalify,
            _ => {
                eprintln!("unhandled ui action: {action}");
                return Command::IDLE;
            }
        };
        match parts.next().and_then(|arg| arg.parse::<EntityId>().ok()) {
            Some(target) => Command::on(verb, target),
            None => {
                eprintln!("malformed ui action: {action}");
                Command::IDLE
            }
        }
    }
}

pub struct Game {
    world: World,
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

/// The internal half of the pause story: the sim declines to step while
/// the player is idle or absent. (The external half — whether
/// `AdvanceTime` gets pumped at all — is the clock's, outside the sim.)
fn time_may_flow(world: &World) -> bool {
    match world.tags.lookup("player") {
        Some(player) => world.activities.get(&world.ids, player).verb != ActivityVerb::Idle,
        None => false,
    }
}

impl Game {
    pub fn new() -> Game {
        let mut world = init_world(7);
        world.epoch = START_EPOCH;
        let source = std::fs::read_to_string("data/characters.txt").unwrap_or_default();
        bootstrap(&mut world, &source);
        Game { world }
    }

    /// The sole entry point that mutates the sim. Called every frame with
    /// exactly one command — `Idle` on frames with no input — and possibly
    /// several times per frame; rendering never happens in here.
    pub fn tick(&mut self, command: Command) {
        match command.verb {
            Verb::Idle => {}
            // A request, not an imperative: declined outright when the
            // player isn't occupying the time that would pass.
            Verb::AdvanceTime => {
                if time_may_flow(&self.world) {
                    self.step_day();
                }
            }
            Verb::Rest => self.set_player_activity(ActivityVerb::Rest),
            Verb::Stop => self.set_player_activity(ActivityVerb::Idle),
            Verb::Remove => {
                // Stale ids parse fine and fail here — a click raced a death.
                if self.world.ids.is_alive(command.target) {
                    self.world.ids.mark_despawn(command.target);
                    self.report_death(command.target);
                    self.world.sweep();
                }
            }
            Verb::Femalify => {
                if self.world.ids.is_alive(command.target) {
                    self.world
                        .vars
                        .set(&self.world.ids, command.target, Var::Gender, 0.0);
                }
            }
        }
    }

    /// Giving yourself an order replaces whatever you were doing;
    /// interruption is just overwrite. Idle = the zero activity.
    fn set_player_activity(&mut self, verb: ActivityVerb) {
        let Some(player) = self.world.tags.lookup("player") else {
            eprintln!("no player to command");
            return;
        };
        let activity = match verb {
            ActivityVerb::Idle => Activity::default(),
            verb => Activity {
                verb,
                start: self.world.epoch,
                until: Epoch(0), // open-ended
            },
        };
        self.world.activities.set(&self.world.ids, player, activity);
    }

    /// One day passes. Resolve what came due, then the daily sim content:
    /// on birthdays, roll the mortality ramp. Death reactions run between
    /// mark and sweep, while the corpse's relations are still queryable.
    fn step_day(&mut self) {
        self.world.epoch.advance();
        let people: Vec<_> = self.world.sets.iter(Set::People).collect();

        for &id in &people {
            let activity = self.world.activities.get(&self.world.ids, id);
            if activity.until != Epoch(0) && activity.until <= self.world.epoch {
                // Verb completion effects go here as verbs gain them.
                self.world.activities.reset(id);
            }
        }

        for &id in &people {
            if !is_birthday(&self.world, id) {
                continue;
            }
            let hazard = (age(&self.world, id) as f32 - MORTALITY_AGE) / MORTALITY_SPAN;
            if self.world.rng.chance(hazard) {
                self.world.ids.mark_despawn(id);
                self.report_death(id);
            }
        }

        self.world.sweep();
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
            let idle = world.activities.get(&world.ids, player).verb == ActivityVerb::Idle;
            data.bind_global("PLAYER_BUTTON", if idle { "Rest" } else { "Stop" });
            data.bind_global("PLAYER_ACTION", if idle { "rest" } else { "stop" });
        }

        data.begin_list("people");
        for id in world.sets.iter(Set::People) {
            data.begin_row();
            data.bind("ID", &format!("{}", id));
            data.bind("NAME", world.names.get(&world.ids, id));
            data.bind("AGE", &format!("{}", age(&self.world, id)));
            let activity = world.activities.get(&world.ids, id);
            let doing = match activity.verb {
                ActivityVerb::Idle => String::new(),
                ActivityVerb::Rest => {
                    format!("· resting ({}d)", world.epoch.0 - activity.start.0)
                }
            };
            data.bind("ACTIVITY", &doing);
            if world.vars.get(&world.ids, id, Var::Gender) > 0. {
                data.bind("IS_MALE", "yes");
            }
        }
    }
}

/// Spawn the starting cast from `data/characters.txt`. Two passes: all
/// characters first, then relations, so forward references resolve.
fn bootstrap(world: &mut World, source: &str) {
    let arena = Arena::new();
    let result = tabula::parse(&arena, source);
    for error in result.errors {
        eprintln!("data/characters.txt: {error}");
    }

    let characters = || result.roots.iter().filter(|node| node.key == "character");

    let mut by_key: HashMap<&str, EntityId> = HashMap::new();
    for node in characters() {
        let id = world.spawn();
        let name = world.names.add(node.get_text("name").unwrap_or("Anonymous"));
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

        world.sets.add(&world.ids, Set::People, id);
        if let Some(tag) = node.get_text("tag") {
            world.tags.bind(&world.ids, tag, id);
        }
        if let Some(key) = node.get_text("id") {
            if by_key.insert(key, id).is_some() {
                eprintln!("data/characters.txt: duplicate character id '{key}'");
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
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_CAST: &str = r#"
        character = { id = a name = "Aulus" age = 20 tag = player married = b }
        character = { id = b name = "Betua" age = 30 }
        character = { id = c name = "Methuselah" age = 95 }
    "#;

    fn game() -> Game {
        let mut world = init_world(7);
        world.epoch = START_EPOCH;
        bootstrap(&mut world, TEST_CAST);
        Game { world }
    }

    /// One in-game day, forced through regardless of the player (tests that
    /// exercise the sim, not the decline rule).
    fn rest_and_tick_days(game: &mut Game, days: u64) {
        game.tick(Command::parse("rest"));
        for _ in 0..days {
            game.tick(Command::ADVANCE_TIME);
        }
    }

    #[test]
    fn bootstrap_spawns_cast_with_vars_tags_and_relations() {
        let game = game();
        let world = &game.world;
        let player = world.tags.lookup("player").unwrap();
        assert_eq!(world.names.get(&world.ids, player), "Aulus");
        assert_eq!(
            world.uvars.get::<Epoch>(&world.ids, player, UVar::BirthEpoch),
            Epoch(START_EPOCH.0 - 20 * 360)
        );
        assert_eq!(age(&game.world, player), 20);
        assert_eq!(world.sets.iter(Set::People).count(), 3);

        let spouses: Vec<_> = world
            .relations
            .get_related_via(player, Relation::Married)
            .collect();
        assert_eq!(spouses.len(), 1);
        assert_eq!(world.names.get(&world.ids, spouses[0].0), "Betua");
    }

    #[test]
    fn time_flows_only_while_the_player_is_occupied() {
        let mut game = game();

        // Fresh game: the player is idle, so the sim declines time.
        game.tick(Command::ADVANCE_TIME);
        game.tick(Command::ADVANCE_TIME);
        assert_eq!(game.world.epoch, START_EPOCH);

        // Resting occupies the player: days pass.
        game.tick(Command::parse("rest"));
        game.tick(Command::ADVANCE_TIME);
        assert_eq!(game.world.epoch, Epoch(START_EPOCH.0 + 1));

        // Stopping goes idle again: declined again.
        game.tick(Command::parse("stop"));
        game.tick(Command::ADVANCE_TIME);
        assert_eq!(game.world.epoch, Epoch(START_EPOCH.0 + 1));
    }

    #[test]
    fn the_old_die_on_their_birthdays_and_the_young_do_not() {
        let mut game = game();

        // Methuselah (95) is past certain death; Aulus (20) and Betua (30)
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
        game.tick(Command::parse("rest"));
        game.tick(Command::on(Verb::Remove, player));

        let epoch = game.world.epoch;
        game.tick(Command::ADVANCE_TIME);
        assert_eq!(game.world.epoch, epoch);
        // Commanding the void warns and does nothing.
        game.tick(Command::parse("rest"));
        game.tick(Command::ADVANCE_TIME);
        assert_eq!(game.world.epoch, epoch);
    }

    #[test]
    fn same_seed_and_commands_reproduce_the_same_history() {
        let run = || {
            let mut game = game();
            rest_and_tick_days(&mut game, 40 * 360);
            (
                game.world.epoch,
                game.world.sets.iter(Set::People).count(),
                game.world.tags.lookup("player").is_some(),
            )
        };
        assert_eq!(run(), run());
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
        assert_eq!(get("NAME"), "Aulus");
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

        // Idle and garbage are no-ops; the sim only moves on real verbs.
        game.tick(Command::default());
        game.tick(Command::parse("frobnicate 12"));
        game.tick(Command::parse("remove not-an-id"));
        assert_eq!(game.world.epoch, START_EPOCH);
        assert_eq!(game.world.sets.iter(Set::People).count(), 3);

        // The exact strings the UI script emits, ids via Display.
        game.tick(Command::parse(&format!("remove {player}")));
        assert!(!game.world.ids.is_alive(player));
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);

        // A stale id parses fine and does nothing.
        game.tick(Command::parse(&format!("remove {player}")));
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);
    }

}
