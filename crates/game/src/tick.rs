//! One step of the sim: `tick` takes a frame's worth of intent and
//! advances the world — the sole entry point that mutates it. The
//! command's shape, the tick's report, and the events the entity pass
//! records all live here.

use crate::date::Date;
use crate::defs::Gender;
use crate::defs::{Relation, Set, UVar, is_derived_id, located_at};
use crate::game::{Game, age, is_birthday};
use crate::interaction::{self, ChoiceParams};
use crate::map::CellPos;
use crate::pathfinding::Pathfinding;
use crate::world::{Activity, ActivityVerb, Epoch, World, WorldState};
use entities::*;
use util::Rng;

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
    /// Let time pass while otherwise unoccupied: an idle player rests
    /// through the coming day, and a waiting rest is extended by it.
    pub wait: bool,
    /// Where an ordered Travel goes; zero = nowhere. Only meaningful
    /// alongside `activity = Some(Travel)`.
    pub destination: CellPos,
    /// Pick this choice (0-based) of the open interaction; None = no pick.
    pub choose: Option<u32>,
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
            // Not `parse_arg`: its malformed-input default would read
            // as picking choice 0.
            "choose" => match arg.parse::<u32>() {
                Ok(index) => self.choose = Some(index),
                Err(_) => eprintln!("malformed ui action: {action}"),
            },
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

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum EventKind {
    /// `subject` completed a journey at settlement `target`.
    Arrival,
    /// `subject` dies today. The pass only records it; the event phase
    /// marks, so reactions read the corpse between mark and sweep.
    Death,
}

/// A notable happening, recorded during the entity pass and resolved
/// one by one after it. The pass itself only observes and appends —
/// what an event *means* (an interaction, a reaction, a chronicle
/// line) is decided post-traversal, per CLAUDE.md's mutation locality
/// rule.
#[derive(Clone, Copy)]
pub struct Event {
    pub kind: EventKind,
    pub subject: EntityId,
    pub target: EntityId,
}

/// The internal half of the pause story: the sim declines to step while
/// the player is idle or absent. (The external half — whether
/// `AdvanceTime` gets pumped at all — is the clock's, outside the sim.)
fn time_may_flow(world: &World) -> bool {
    match world.tags.lookup("player") {
        Some(player) => world.activity(player).verb != ActivityVerb::Idle,
        None => false,
    }
}

/// Placeholder death reaction: console obituary. Runs before the sweep
/// so it can still read the deceased's name and marriages.
fn report_death(world: &World, id: EntityId) {
    let name = world.names.get(id);
    // Marriage is declared one-way in the data; look both directions.
    let spouses: Vec<&str> = world
        .related_via(id, Relation::Married)
        .map(|(other, _)| other)
        .chain(
            world
                .related_to_via(id, Relation::Married)
                .map(|(other, _)| other),
        )
        .map(|other| world.names.get(other))
        .collect();
    if spouses.is_empty() {
        println!("{}: {name} has died.", Date::of(world.epoch));
    } else {
        println!(
            "{}: {name} has died, survived by {}.",
            Date::of(world.epoch),
            spouses.join(", ")
        );
    }
}

/// One command per tick, a frame's worth of intent. Not a dispatch —
/// one general path whose steps run in a fixed order, each reading its
/// share of the command, the ZII fields turning steps on and off (null
/// ids fail the liveness checks, false bools skip). Rendering never
/// happens in here.
pub fn tick(game: &mut Game, command: Command) -> Output {
    // The player's orders: an ordered activity replaces the current
    // one (an order of Idle is the stop); no order, no change. Only
    // a genuinely new activity — different verb or target — starts,
    // so repeating an order doesn't restart its clock, while
    // retargeting an ongoing travel does take effect.
    let player = game.world.tags.lookup("player");

    // A pick resolves the open interaction: the choice's effect
    // transforms the world and hands back the next screen, if any.
    // An invalid or stale pick (nothing open, out of range,
    // disabled) does nothing and leaves the interaction standing.
    if let Some(index) = command.choose {
        let valid = game.interaction.as_ref().is_some_and(|interaction| {
            interaction
                .choices
                .get(index as usize)
                .is_some_and(|choice| choice.disabled.is_empty())
        });
        if valid {
            let interaction = game.interaction.take().unwrap();
            let choice = &interaction.choices[index as usize];
            game.interaction = (choice.effect)(&mut game.world, choice.params);
        }
    }

    // An open interaction is modal: activity orders and waiting are
    // ignored until it's answered (board clicks still emit travel
    // actions; they land here and do nothing).
    if let (Some(player), true) = (player, game.interaction.is_none()) {
        if let Some(next_verb) = command.activity {
            let current = game.world.activity(player);
            let next = match next_verb {
                ActivityVerb::Idle => Activity::default(),
                verb => Activity {
                    verb,
                    start: game.world.epoch,
                    until: Epoch::MAX, // open-ended
                    // Zero for the verbs that don't want one.
                    destination: command.destination,
                },
            };
            if next.verb != current.verb || next.destination != current.destination {
                game.world.set_activity(player, next);
            }
        }

        // Waiting: an idle player rests through the coming day. The
        // horizon sits one day past whatever this tick advances to,
        // so a held wait outlives each day's advance (no expiring and
        // re-arming every day, which read as a one-frame pause) and
        // resolves one day after the waiting stops.
        if command.wait {
            let horizon = game.world.epoch + 1 + command.advance_time as u64;
            let mut activity = game.world.activity(player);
            match activity.verb {
                ActivityVerb::Idle => {
                    activity = Activity {
                        verb: ActivityVerb::Rest,
                        start: game.world.epoch,
                        until: horizon,
                        ..Activity::default()
                    };
                }
                // Extend a finite rest; an open-ended one (until MAX,
                // ordered explicitly) absorbs the max unchanged.
                ActivityVerb::Rest => {
                    activity.until = activity.until.max(horizon);
                }
                _ => {}
            }
            game.world.set_activity(player, activity);
        }
    }

    // Removal. Stale ids parse fine and fail the liveness check — a
    // click raced a death.
    if game.world.ids.is_alive(command.remove) {
        game.world.ids.mark_despawn(command.remove);
        report_death(&game.world, command.remove);
        game.world.sweep();
    }

    if game.world.ids.is_alive(command.femalify) {
        game.world
            .set_uvar(command.femalify, UVar::Gender, Gender::Female);
    }

    // Time. A request, not an imperative: declined outright when the
    // player isn't occupying the time that would pass, or has an
    // interaction waiting on them.
    let day_passes =
        command.advance_time && game.interaction.is_none() && time_may_flow(&game.world);
    if day_passes {
        game.world.epoch.advance();
    }

    // The buffered day pass: read the frozen current world, write the
    // staging buffer, copying as it goes — each chunk's rows are carried
    // forward wholesale, then each live entity's update overwrites its
    // own rows and contributes its relation row. Nothing global mutates
    // mid-pass: whatever the day changes beyond an entity's own slots is
    // recorded as an event and resolved after the swap.
    let mut events: Vec<Event> = Vec::new();
    if day_passes {
        let Game {
            world,
            staging,
            pathfinding,
            ..
        } = game;
        let world = &*world;

        // Relation *changes* land here: what the updates send through the
        // outbox (locations today; oaths and marriages one day) plus, in
        // time, direct-mode decrees taken at the pass boundary. The
        // rebuild below merges them over the carried base — relations are
        // never mutated in place, only reconstructed.
        let mut changes: Vec<RelationEntry> = Vec::new();
        let mut pass = Pass {
            events: &mut events,
            changes: &mut changes,
            pathfinding,
        };

        // NOTE: the future threading seam. One chunk = one task: an
        // update reads only the frozen world and writes only its own
        // entity's slots in `staging`; per-chunk event vecs would then
        // concatenate in chunk order to keep resolution deterministic.
        // The pathfinding memo is the one shared &mut to shard first,
        // and the wander println!s become events.
        const CHUNK_SIZE: usize = 1024;
        for chunk in (0..Ids::CAPACITY).step_by(CHUNK_SIZE) {
            let slots = chunk..(chunk + CHUNK_SIZE).min(Ids::CAPACITY);
            staging
                .vars
                .copy_chunk_from(&world.state.vars, slots.clone());
            staging
                .uvars
                .copy_chunk_from(&world.state.uvars, slots.clone());
            staging
                .positions
                .copy_chunk_from(&world.state.positions, slots.clone());
            staging
                .activities
                .copy_chunk_from(&world.state.activities, slots.clone());
            for slot in slots {
                let this = world.ids.id_at(slot);
                if !this.is_valid() {
                    continue;
                }
                update_entity(this, player, world, staging, &mut pass);
            }
        }
        // Carried kinds flow forward from the old matrix with the changes
        // on top; kinds that don't carry (LocatedIn) exist only as far as
        // the updates re-emitted them above.
        staging.relations.rebuild(
            &world.state.relations,
            &world.ids,
            &mut changes,
            |kind| !is_derived_id(kind),
        );

        // The pass's output becomes the world; the old state lingers as
        // the next pass's scratch, never read meanwhile.
        std::mem::swap(&mut game.world.state, &mut game.staging);
    }

    // Resolve the pass's events, one by one in the order recorded —
    // direct mode on the new current world. The world moved since an
    // event was recorded, so re-check what it refers to.
    for event in events {
        match event.kind {
            EventKind::Arrival => {
                // The player arriving at a settlement is received at
                // its gates. Time doesn't flow while an interaction is
                // open, so an arrival can't find one already standing.
                let player = game.world.tags.lookup("player");
                if Some(event.subject) == player && game.world.ids.is_alive(event.target) {
                    debug_assert!(game.interaction.is_none());
                    let params = ChoiceParams {
                        target: event.target,
                    };
                    game.interaction = interaction::arrival(&mut game.world, params);
                }
            }
            // Death lands here, not in the pass: mark, then react while
            // the corpse is still readable — the sweep below despawns.
            EventKind::Death => {
                game.world.ids.mark_despawn(event.subject);
                report_death(&game.world, event.subject);
            }
        }
    }
    game.world.sweep();

    // Everything that moves or removes people has run; re-derive the
    // cell → entities index from the settled world.
    game.spatial_map.rebuild(&game.world);

    Output {
        forced_paused: game.interaction.is_some() || !time_may_flow(&game.world),
    }
}

/// The day pass's kit, handed to every update: the bridge between one
/// entity's tick and everything that isn't its own rows. Consequences an
/// update can't apply locally go out through the methods here — events
/// resolve serially after the swap, relation changes merge in the
/// rebuild — and the pass's shared scratch (the route memo) rides along.
/// Updates gain new consequences as methods, not signature changes.
/// Under threading, each chunk gets its own, sinks drained in chunk
/// order.
struct Pass<'a> {
    events: &'a mut Vec<Event>,
    changes: &'a mut Vec<RelationEntry>,
    pathfinding: &'a mut Pathfinding,
}

impl Pass<'_> {
    /// `who` stands in `place` at day's end — becomes the LocatedIn
    /// change. A null place is nowhere: no relation at all.
    fn locate(&mut self, who: EntityId, place: EntityId) {
        if place != EntityId::NULL {
            self.changes.push(RelationEntry {
                source: who,
                relation: Relation::LocatedIn.into(),
                target: place,
                value: 1.0,
            });
        }
    }

    /// `who` completed a journey at settlement `place`.
    fn arrive(&mut self, who: EntityId, place: EntityId) {
        self.events.push(Event {
            kind: EventKind::Arrival,
            subject: who,
            target: place,
        });
    }

    /// `who` dies today; the event phase marks the despawn.
    fn die(&mut self, who: EntityId) {
        self.events.push(Event {
            kind: EventKind::Death,
            subject: who,
            target: EntityId::NULL,
        });
    }
}

/// One entity's day, from its own point of view: read the frozen world,
/// write only this entity's rows in `out` (which already carry
/// yesterday's values, copied by the pass). The activity evolves as a
/// local so later checks see earlier effects — a rest that ends today
/// frees today's wander roll — and lands in `out` exactly once. Anything
/// beyond the entity's own rows goes through the pass kit.
fn update_entity(
    this: EntityId,
    player: Option<EntityId>,
    world: &World,
    out: &mut WorldState,
    pass: &mut Pass,
) {
    let is_player = Some(this) == player;
    let is_person = world.ids.in_set(this, Set::People);
    // This entity's rng for the day, derived — not world state — so every
    // entity's rolls are independent of everyone else's, of draw order,
    // and of dayless ticks.
    let mut rng = Rng::at(world.seed, world.epoch.0, this.to_bits());
    let mut activity = world.activity(this);
    let mut pos = world.position(this);

    // Resolve an activity that came due — anything can be doing
    // something, not just people. Completion effects go here as verbs
    // gain them.
    if activity.until <= world.epoch {
        activity = Activity::default();
    }

    // Travel: one cell per day toward the target. Stateless — nobody
    // stores a route; each step re-asks from the current cell, so
    // retargeting and detours cost nothing extra.
    if activity.verb == ActivityVerb::Travel {
        let next = pass.pathfinding.next_step(&world.map, pos, activity.destination);
        if next == CellPos::default() {
            // Already there, or no way there: the journey ends.
            activity = Activity::default();
        } else {
            pos = next;
            out.positions.set(this, next);
            if next == activity.destination {
                activity = Activity::default();
                let place = world.map.cell(next).settlement;
                if world.ids.is_alive(place) {
                    pass.arrive(this, place);
                }
            }
        }
    }

    // People randomly travel if idle.
    if !is_player && is_person && activity.verb == ActivityVerb::Idle {
        if let Some(decision) = decide_destination(this, world, &mut rng) {
            let name = world.names.get(this);
            println!("{name}: {}", decision.reason);
            activity = Activity {
                verb: ActivityVerb::Travel,
                start: world.epoch,
                until: Epoch::MAX, // open-ended, ends on arrival
                destination: decision.destination,
            };
        }
    }

    // On birthdays, roll the mortality ramp. Only people age.
    if is_person && is_birthday(world, this) {
        let hazard = (age(world, this) as f32 - MORTALITY_AGE) / MORTALITY_SPAN;
        if rng.chance(hazard) {
            pass.die(this);
        }
    }

    out.activities.set(this, activity);
    pass.locate(this, located_at(pos, &world.map, &world.ids));
}

struct DecideDestination {
    reason: &'static str,
    destination: CellPos,
}

fn decide_destination(this: EntityId, world: &World, rng: &mut Rng) -> Option<DecideDestination> {
    if !rng.chance(0.05) {
        return None;
    }
    // If I am a ruler of a place, go to that place
    let reason;
    let destination = match world.related_via(this, Relation::Rules).next() {
        Some((x, _)) => {
            reason = "to return to the land ruled";
            Some(world.map.anchor(x))
        }
        None => {
            reason = "as random travel";
            let count = world.map.anchors().len();
            let pick = rng.next_u64() as usize % count;
            world.map.anchors().get(pick).map(|(_, x)| *x)
        }
    };

    destination
        .map(|destination| DecideDestination {
            reason,
            destination,
        })
        .filter(|decision| decision.destination != world.position(this))
}
