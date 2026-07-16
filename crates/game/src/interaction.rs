//! Interactions: the game's modal choice mechanism (see docs/DESIGN.md).
//! An open interaction lives on `Game` beside the world, not in it —
//! never saved, needn't be resolved — and while one is open, time does
//! not flow. Picking a choice runs its effect, which transforms the
//! world and hands back the next interaction, if any.

use crate::defs::Relation;
use crate::world::{Activity, ActivityVerb, Epoch, World};
use entities::EntityId;
use std::fmt::Write as _; // import without risk of name clashing

/// A choice's consequence: mutate the world as needed and hand back the
/// next interaction. Chaining to another screen is just returning it;
/// None returns control to the sim.
pub type Effect = fn(&mut World, ChoiceParams) -> Option<Interaction>;

/// The arguments a choice was authored with, handed to its effect on
/// pick.
#[derive(Clone, Copy, Default)]
pub struct ChoiceParams {
    /// The entity the choice concerns (e.g. the settlement in question).
    pub target: EntityId,
}

pub struct Interaction {
    pub title: String,
    pub text: String,
    pub choices: Vec<Choice>,
}

pub struct Choice {
    /// Button caption.
    pub text: String,
    /// Empty = pickable; nonempty = why it can't be (shown to the player).
    pub disabled: String,
    pub effect: Effect,
    pub params: ChoiceParams,
}

/// The do-nothing effect: close the interaction, change nothing.
pub fn close(_world: &mut World, _params: ChoiceParams) -> Option<Interaction> {
    None
}

/// Everyone but the player located in a settlement, by name.
fn company_names(world: &World, place: EntityId) -> Vec<&str> {
    let player = world.tags.lookup("player");
    world
        .related_to_via(place, Relation::LocatedIn)
        .filter(|&(other, _)| Some(other) != player)
        .map(|(other, _)| world.names.get(other))
        .collect()
}

fn describe_person(out: &mut String, this: EntityId, world: &World) {
    if this == EntityId::NULL {
        out.push_str("no one");
        return;
    }

    let name = world.names.get(this);
    write!(out, "{}", name).unwrap();
    if let Some((master, _)) = world.related_to_via(this, Relation::SwornTo).next() {
        let name = world.names.get(master);
        write!(out, ", who is sworn to {name}").unwrap();
    }
}

/// The screen raised when the player's travel resolves at a settlement.
pub fn arrival(world: &mut World, params: ChoiceParams) -> Option<Interaction> {
    let name = world.names.get(params.target);

    let mut text = format!("You arrive at {name}.");
    let (ruler, _) = world
        .related_to_via(params.target, Relation::Rules)
        .next()
        .unwrap_or_default();

    text.push_str(" The settlement is ruled by ");
    describe_person(&mut text, ruler, world);
    text.push('.');

    let deserted = company_names(world, params.target).is_empty();
    Some(Interaction {
        title: name.to_string(),
        text,
        choices: vec![
            Choice {
                text: "Seek out company".to_string(),
                disabled: match deserted {
                    true => "no one of note is here".to_string(),
                    false => String::new(),
                },
                effect: company,
                params,
            },
            Choice {
                text: "Rest a while".to_string(),
                disabled: String::new(),
                effect: rest_here,
                params,
            },
            Choice {
                text: "Be on your way".to_string(),
                disabled: String::new(),
                effect: close,
                params,
            },
        ],
    })
}

/// Who is present at the settlement; chains back to `arrival`.
fn company(world: &mut World, params: ChoiceParams) -> Option<Interaction> {
    let names = company_names(world, params.target);
    Some(Interaction {
        title: world.names.get(params.target).to_string(),
        text: format!("You find {} here.", names.join(", ")),
        choices: vec![Choice {
            text: "Step back".to_string(),
            disabled: String::new(),
            effect: arrival,
            params,
        }],
    })
}

/// An open-ended rest, same as the Rest button orders.
fn rest_here(world: &mut World, _params: ChoiceParams) -> Option<Interaction> {
    if let Some(player) = world.tags.lookup("player") {
        world.set_activity(
            player,
            Activity {
                verb: ActivityVerb::Rest,
                start: world.epoch,
                until: Epoch::MAX,
                ..Activity::default()
            },
        );
    }
    None
}
