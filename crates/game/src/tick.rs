//! One step of the sim: `tick` takes a frame's worth of intent and
//! advances the world — the sole entry point that mutates it. The
//! command's shape, the tick's report, and the events the entity pass
//! records all live here.

use crate::date::Date;
use crate::defs::{Relation, Set, UVar, Var};
use crate::game::{Game, age, is_birthday};
use crate::interaction::{self, ChoiceParams};
use crate::map::CellPos;
use crate::world::{Activity, ActivityVerb, Epoch, World};
use entities::*;

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
    /// `subject` died; they are marked but not yet swept, so reactions
    /// can still read them.
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

/// The one mover: sets the spatial truth (`Position`) and keeps its
/// logical mirror (`LocatedIn`) in step across blob boundaries — the
/// contract the bootstrap's `located` handling establishes.
fn move_entity(world: &mut World, id: EntityId, from: CellPos, to: CellPos) {
    world.uvars.set(id, UVar::Position, to);
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

/// Placeholder death reaction: console obituary. Runs before the sweep
/// so it can still read the deceased's name and marriages.
fn report_death(world: &World, id: EntityId) {
    let name = world.names.get(id);
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
            let current = *game.world.activities.get(player);
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
                game.world.activities.set(player, next);
            }
        }

        // Waiting: an idle player rests through the coming day. The
        // horizon sits one day past whatever this tick advances to,
        // so a held wait outlives each day's advance (no expiring and
        // re-arming every day, which read as a one-frame pause) and
        // resolves one day after the waiting stops.
        if command.wait {
            let horizon = game.world.epoch + 1 + command.advance_time as u64;
            let activity = game.world.activities.get_mut(player);
            match activity.verb {
                ActivityVerb::Idle => {
                    *activity = Activity {
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
        game.world.vars.set(command.femalify, Var::Gender, 0.0);
    }

    // Time. A request, not an imperative: declined outright when the
    // player isn't occupying the time that would pass, or has an
    // interaction waiting on them.
    let day_passes =
        command.advance_time && game.interaction.is_none() && time_may_flow(&game.world);
    if day_passes {
        game.world.epoch.advance();
    }

    // Globally observable mutations don't happen mid-traversal: the
    // pass records events, resolved after the loop.
    let mut events: Vec<Event> = Vec::new();

    // The entity pass: one uniform loop over every live entity — no
    // kinds — where each runs every check, GPU-style, written from
    // the entity's point of view. Checks gate themselves, on the day
    // advancing (right now, all of them) or on a set-membership bit,
    // and only where a check genuinely doesn't apply. Death reactions
    // run between mark and sweep, while the corpse's relations are
    // still queryable.
    let entities: Vec<_> = game.world.ids.iter_alive().collect();
    for &this in &entities {
        let is_player = this == player.unwrap_or_default();
        let is_person = game.world.ids.in_set(this, Set::People);

        // Resolve an activity that came due — anything can be doing
        // something, not just people. Completion effects go here as
        // verbs gain them.
        if day_passes {
            let activity = game.world.activities.get(this);
            if activity.until <= game.world.epoch {
                game.world.activities.reset(this);
            }
        }

        // Travel: one cell per day toward the target. Stateless —
        // nobody stores a route; each step re-asks from the current
        // cell, so retargeting and detours cost nothing extra.
        if day_passes {
            let activity = *game.world.activities.get(this);
            if activity.verb == ActivityVerb::Travel {
                let pos: CellPos = game.world.uvars.get(this, UVar::Position);
                let next = game
                    .pathfinding
                    .next_step(&game.world.map, pos, activity.destination);
                if next == CellPos::default() {
                    // Already there, or no way there: the journey ends.
                    game.world.activities.reset(this);
                } else {
                    move_entity(&mut game.world, this, pos, next);
                    if next == activity.destination {
                        game.world.activities.reset(this);
                        let place = game.world.map.cell(next).settlement;
                        if game.world.ids.is_alive(place) {
                            events.push(Event {
                                kind: EventKind::Arrival,
                                subject: this,
                                target: place,
                            });
                        }
                    }
                }
            }
        }

        // People randomly travel if idle. Gated on the day like every
        // other roll: the rng is world state, so drawing from it on
        // dayless ticks would fork histories that share a command
        // stream.
        if day_passes && !is_player && is_person {
            if let Some(decision) = decide_destination(this, &mut game.world) {
                let name = game.world.names.get(this);
                println!("{name}: {}", decision.reason);
                game.world.activities.set(
                    this,
                    Activity {
                        verb: ActivityVerb::Travel,
                        start: game.world.epoch,
                        until: Epoch::MAX, // open-ended, ends on arrival
                        destination: decision.destination,
                    },
                );
            }
        }

        // On birthdays, roll the mortality ramp. Only people age.
        if day_passes && is_person && is_birthday(&game.world, this) {
            let hazard = (age(&game.world, this) as f32 - MORTALITY_AGE) / MORTALITY_SPAN;
            if game.world.rng.chance(hazard) {
                game.world.ids.mark_despawn(this);
                events.push(Event {
                    kind: EventKind::Death,
                    subject: this,
                    target: EntityId::NULL,
                });
            }
        }
    }

    // Resolve the pass's events, one by one in the order recorded —
    // between mark and sweep, so death reactions can still read the
    // corpse. The world moved since an event was recorded, so
    // re-check what it refers to.
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
            EventKind::Death => report_death(&game.world, event.subject),
        }
    }
    game.world.sweep();

    Output {
        forced_paused: game.interaction.is_some() || !time_may_flow(&game.world),
    }
}

struct DecideDestination {
    reason: &'static str,
    destination: CellPos,
}

fn decide_destination(this: EntityId, world: &mut World) -> Option<DecideDestination> {
    // People randomly travel if idle. Gated on the day like every
    // other roll: the rng is world state, so drawing from it on
    // dayless ticks would fork histories that share a command
    // stream.
    if world.activities.get(this).verb == ActivityVerb::Idle && world.rng.chance(0.05) {
        // If I am a ruler of a place, go to that place
        let reason;
        let destination = match world
            .relations
            .get_related_via(this, Relation::Rules)
            .next()
        {
            Some((x, _)) => {
                reason = "to return to the land ruled";
                Some(world.map.anchor(x))
            }
            None => {
                reason = "as random travel";
                let count = world.map.anchors().len();
                let pick = world.rng.next_u64() as usize % count;
                world.map.anchors().get(pick).map(|(_, x)| *x)
            }
        };

        destination
            .map(|destination| DecideDestination {
                reason,
                destination,
            })
            .filter(|decision| {
                let current_position: CellPos = world.uvars.get(this, UVar::Position);
                decision.destination != current_position
            })
    } else {
        None
    }
}
