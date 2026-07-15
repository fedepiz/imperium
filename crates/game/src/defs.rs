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
    Gender,
}

impl Var {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
            Self::Gender => "Gender",
        }
    }
}

impl From<Var> for VarId {
    fn from(value: Var) -> Self {
        VarId(value as u16)
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
    /// The cell an entity stands on, as a packed [`crate::map::CellPos`].
    /// Which settlement someone is "in" is derived from this via the map,
    /// never stored. Zero = nowhere (the map's void corner).
    Position,
}

impl UVar {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
            Self::BirthEpoch => "BirthEpoch",
            Self::Position => "Position",
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
    /// *follows* [`UVar::Position`] — whatever moves an entity across a
    /// blob boundary updates both. Weight unused.
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

    #[allow(dead_code)]
    pub fn from_id(id: RelationId) -> Option<Relation> {
        Relation::try_from(id.0).ok()
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn world_defs_record_the_schema_by_name() {
        let world = init_world(0);
        assert_eq!(world.defs.get_var_name(Var::Gender.into()), Some("Gender"));
        assert_eq!(
            world.defs.get_uvar_name(UVar::BirthEpoch.into()),
            Some("BirthEpoch")
        );
        assert_eq!(
            world.defs.get_relation_name(Relation::Married.into()),
            Some("Married")
        );
        assert_eq!(world.defs.get_set_name(Set::People.into()), Some("People"));
    }

}
