use std::collections::HashMap;

use arena::Arena;
use ui::ir;

use crate::date::{DAYS_PER_YEAR, Date, days_between};
use crate::defs::{Relation, Set, UVar, Var, init_world};
use crate::interaction::Interaction;
use crate::map::{CellPos, Map};
use crate::pathfinding::Pathfinding;
use crate::world::{ActivityVerb, Epoch, World};
use entities::*;

/// The sim begins here, centuries after the calendar's dawn, so every
/// starting birth date fits above epoch 0.
const START_EPOCH: Epoch = Epoch(700 * DAYS_PER_YEAR);

pub struct Game {
    pub(crate) world: World,
    /// Derived route memory, not world state: outside the save/clone
    /// unit, rebuilt from nothing.
    pub(crate) pathfinding: Pathfinding,
    /// The open interaction, if any: modal choice state beside the
    /// world, not in it — never saved, replaced or cleared, never
    /// suspended. While one is open, time does not flow.
    pub(crate) interaction: Option<Interaction>,
}

// Derivations: computed from the world on the fly, never stored, never
// methods — plain functions over &World, of which there will be many.

/// Days since birth (births never postdate now, so the distance is it).
fn days_alive(world: &World, id: EntityId) -> u64 {
    let birth: Epoch = world.uvars.get(id, UVar::BirthEpoch);
    days_between(world.epoch, birth)
}

pub(crate) fn age(world: &World, id: EntityId) -> u32 {
    (days_alive(world, id) / DAYS_PER_YEAR) as u32
}

pub(crate) fn is_birthday(world: &World, id: EntityId) -> bool {
    days_alive(world, id) % DAYS_PER_YEAR == 0
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
            interaction: None,
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

        // The interaction window: $INTERACTION is bound only while one
        // is open, which is what shows the panel.
        if let Some(interaction) = &self.interaction {
            data.bind_global("INTERACTION", "yes");
            data.bind_global("INT_TITLE", &interaction.title);
            data.bind_global("INT_TEXT", &interaction.text);
            data.begin_list("choices");
            for (index, choice) in interaction.choices.iter().enumerate() {
                data.begin_row();
                data.bind("INDEX", &index.to_string());
                data.bind(
                    "ENABLED",
                    if choice.disabled.is_empty() {
                        "yes"
                    } else {
                        "no"
                    },
                );
                // Disabled elements sense nothing, so a tooltip can't
                // carry the reason: fold it into the caption.
                let caption = match choice.disabled.is_empty() {
                    true => choice.text.clone(),
                    false => format!("{} — {}", choice.text, choice.disabled),
                };
                data.bind("CHOICE", &caption);
            }
        }

        data.begin_list("people");
        for id in world.sets.iter(Set::People) {
            data.begin_row();
            data.bind("ID", &format!("{}", id));
            data.bind("NAME", world.names.get(id));
            data.bind("AGE", &format!("{}", age(&self.world, id)));
            let activity = world.activities.get(id);
            let doing = match activity.verb {
                ActivityVerb::Idle => String::new(),
                ActivityVerb::Rest => {
                    format!("· resting ({}d)", world.epoch.0 - activity.start.0)
                }
                ActivityVerb::Travel => {
                    // Destinations are cells; a settlement's blob names it.
                    let place = world.map.cell(activity.destination).settlement;
                    match world.ids.is_alive(place) {
                        true => {
                            format!("· travelling to {}", world.names.get(place))
                        }
                        false => "· travelling".to_string(),
                    }
                }
            };
            data.bind("ACTIVITY", &doing);
            // Where they stand, spoken as a settlement name; unbound when
            // they're nowhere or on no one's cells.
            let pos: CellPos = world.uvars.get(id, UVar::Position);
            let place = world.map.cell(pos).settlement;
            if world.ids.is_alive(place) {
                data.bind("PLACE", world.names.get(place));
            }
            if world.vars.get(id, Var::Gender) > 0. {
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
        world.names.set(id, name);
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
        world.names.set(id, name);
        // The data speaks in ages; the sim speaks in birth epochs. Whole
        // ages put every starting birthday on new year's day.
        let age = node.get_number("age").unwrap_or(0.0);
        let birth = Epoch(world.epoch.0 - (age as u64) * DAYS_PER_YEAR);
        world.uvars.set(id, UVar::BirthEpoch, birth);

        let gender = match node.get_text("gender").unwrap_or_default() {
            "female" => 0.0,
            "male" => 1.0,
            _ => 0.0,
        };
        world.vars.set(id, Var::Gender, gender);

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
        if let Some(lord) = node.get_text("sworn") {
            match by_key.get(lord) {
                Some(&target) => {
                    world
                        .relations
                        .set(&world.ids, source_id, Relation::SwornTo, target, 1.0)
                }
                None => eprintln!("data/characters.txt: '{key}' sworn to unknown id '{lord}'"),
            }
        }
        if let Some(place) = node.get_text("rules") {
            match by_key.get(place) {
                Some(&target) => {
                    world
                        .relations
                        .set(&world.ids, source_id, Relation::Rules, target, 1.0)
                }
                None => eprintln!("data/characters.txt: '{key}' rules unknown id '{place}'"),
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
                        .set(source_id, UVar::Position, anchor);
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
    use crate::tick::{Command, tick};

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
            interaction: None,
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
        tick(game, command("rest"));
        for _ in 0..days {
            tick(game, Command::advance_time());
        }
    }

    #[test]
    fn time_flows_only_while_the_player_is_occupied() {
        let mut game = game();

        // Fresh game: the player is idle, so the sim declines time.
        tick(&mut game, Command::advance_time());
        tick(&mut game, Command::advance_time());
        assert_eq!(game.world.epoch, START_EPOCH);

        // Resting occupies the player: days pass.
        tick(&mut game, command("rest"));
        tick(&mut game, Command::advance_time());
        assert_eq!(game.world.epoch, Epoch(START_EPOCH.0 + 1));

        // Stopping goes idle again: declined again.
        tick(&mut game, command("stop"));
        tick(&mut game, Command::advance_time());
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
        tick(&mut game, command("rest"));
        tick(
            &mut game,
            Command {
                remove: player,
                ..Command::default()
            },
        );

        let epoch = game.world.epoch;
        tick(&mut game, Command::advance_time());
        assert_eq!(game.world.epoch, epoch);
        // Commanding the void warns and does nothing.
        tick(&mut game, command("rest"));
        tick(&mut game, Command::advance_time());
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
        tick(&mut game, Command::default());
        tick(&mut game, command("frobnicate 12"));
        tick(&mut game, command("remove not-an-id"));
        assert_eq!(game.world.epoch, START_EPOCH);
        assert_eq!(game.world.sets.iter(Set::People).count(), 3);

        // The exact strings the UI script emits, ids via Display.
        tick(&mut game, command(&format!("remove {player}")));
        assert!(!game.world.ids.is_alive(player));
        assert_eq!(game.world.sets.iter(Set::People).count(), 2);

        // A stale id parses fine and does nothing.
        tick(&mut game, command(&format!("remove {player}")));
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
        tick(&mut game, command(&format!("travel {destination}")));
        assert_eq!(game.world.activities.get(player).verb, ActivityVerb::Travel);

        // One day, one cell: onto the road, out of Wicstow — both halves of
        // place move together.
        tick(&mut game, Command::advance_time());
        let pos: CellPos = game
            .world
            .uvars
            .get(player, UVar::Position);
        assert_eq!(pos, CellPos { x: 2, y: 1 });
        assert_eq!(
            game.world.relations.get(player, Relation::LocatedIn, vicus),
            0.0
        );

        // Two more days reach Hamtun: position on its anchor, LocatedIn
        // mirroring it, the journey resolved back to Idle.
        tick(&mut game, Command::advance_time());
        tick(&mut game, Command::advance_time());
        let pos: CellPos = game
            .world
            .uvars
            .get(player, UVar::Position);
        assert_eq!(pos, destination);
        assert_eq!(
            game.world.relations.get(player, Relation::LocatedIn, wick),
            1.0
        );
        assert_eq!(game.world.activities.get(player).verb, ActivityVerb::Idle);

        // Arrived and idle: the sim declines further time.
        let epoch = game.world.epoch;
        tick(&mut game, Command::advance_time());
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
