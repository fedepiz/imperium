//! The schema: which vars, relations and sets exist, as enums bridged onto
//! the entities crate's ids. Definition order is identity — `init_world`
//! asserts the bridge lines up.

use num_enum::TryFromPrimitive;
use strum::{EnumCount, EnumIter, IntoEnumIterator};

use crate::world::World;
use entities::*;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter)]
pub enum Var {
    #[default]
    Dummy,
}

impl Var {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
        }
    }
}

impl From<Var> for VarId {
    fn from(value: Var) -> Self {
        VarId(value as u16)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter)]
pub enum Gender {
    #[default]
    Male,
    Female,
}

impl Bits64 for Gender {
    fn to_bits(self) -> u64 {
        self as u64
    }

    fn from_bits(bits: u64) -> Self {
        match bits {
            0 => Self::Male,
            1 => Self::Female,
            _ => Default::default(),
        }
    }
}

/// The u64 siblings of [`Var`]: epochs, handles, and weak (one-way,
/// unpurged) entity refs, via the `Bits64` round trip.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter)]
pub enum UVar {
    #[default]
    Dummy,
    /// The epoch a person was born at. Age and
    /// birthdays are derived from this, never stored.
    BirthEpoch,
    // Male or Female
    Gender,
}

impl UVar {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
            Self::BirthEpoch => "BirthEpoch",
            Self::Gender => "Gender",
        }
    }
}

impl From<UVar> for UVarId {
    fn from(value: UVar) -> Self {
        UVarId(value as u16)
    }
}

#[repr(u16)]
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, EnumCount, EnumIter, TryFromPrimitive)]
pub enum Relation {
    Married,
    /// Character → settlement, the logical mirror of spatial truth: kept
    /// for relation-side processing (who is here / where is he), but it
    /// *follows* the positions column — whatever moves an entity across
    /// a blob boundary updates both. Weight unused.
    LocatedIn,
    /// Character → character: a personal oath of service. Weight unused.
    SwornTo,
    /// Character → settlement: personal rule over a place. One place per
    /// ruler. Weight unused.
    Rules,
}

impl Relation {
    fn name(&self) -> &'static str {
        match self {
            Relation::Married => "Married",
            Relation::LocatedIn => "LocatedIn",
            Relation::SwornTo => "SwornTo",
            Relation::Rules => "Rules",
        }
    }

    pub fn from_id(id: RelationId) -> Option<Relation> {
        Relation::try_from(id.0).ok()
    }

    /// Derived relations are never written: every rebuild recomputes them
    /// from world state, so they can't drift from what they mirror.
    pub const fn is_derived(self) -> bool {
        matches!(self, Relation::LocatedIn)
    }
}

/// Whether a raw relation id names a derived kind — the rebuild's fold
/// skips these when carrying edges forward, and re-derives them instead.
pub fn is_derived_id(id: RelationId) -> bool {
    Relation::from_id(id).is_some_and(Relation::is_derived)
}

/// The settlement an entity standing at `pos` is in — the live blob
/// owner of the cell, or null: the zero position is nowhere, and cells
/// outside any blob carry no settlement. The LocatedIn relation is this
/// value, re-emitted every rebuild.
pub fn located_at(pos: crate::map::CellPos, map: &crate::map::Map, ids: &Ids) -> EntityId {
    if pos == crate::map::CellPos::default() {
        return EntityId::NULL;
    }
    let place = map.cell(pos).settlement;
    if ids.is_alive(place) { place } else { EntityId::NULL }
}

impl From<Relation> for RelationId {
    fn from(value: Relation) -> Self {
        RelationId(value as u16)
    }
}

#[repr(u16)]
#[derive(
    Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter, TryFromPrimitive,
)]
pub enum Set {
    #[default]
    Dummy,
    People,
    Settlements,
}

impl Set {
    fn name(&self) -> &'static str {
        match self {
            Set::Dummy => "Dummy",
            Set::People => "People",
            Set::Settlements => "Settlements",
        }
    }

    #[allow(dead_code)]
    pub fn from_id(id: SetId) -> Option<Set> {
        Set::try_from(id.0).ok()
    }
}

impl From<Set> for SetId {
    fn from(value: Set) -> Self {
        SetId(value as u16)
    }
}

pub fn init_world(seed: u64) -> World {
    let mut definitions = Definitions::default();
    for var in Var::iter() {
        assert_eq!(definitions.define_var(var.name()), VarId::from(var));
    }
    for uvar in UVar::iter() {
        assert_eq!(definitions.define_uvar(uvar.name()), UVarId::from(uvar));
    }
    for relation in Relation::iter() {
        assert_eq!(
            definitions.define_relation(relation.name()),
            RelationId::from(relation)
        );
    }
    for set in Set::iter() {
        assert_eq!(definitions.define_set(set.name()), SetId::from(set));
    }
    World::new(definitions, seed)
}
