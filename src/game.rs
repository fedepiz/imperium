use arena::Arena;
use num_enum::TryFromPrimitive;
use strum::{EnumCount, EnumIter, IntoEnumIterator};

use crate::entities::*;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter)]
enum Var {
    #[default]
    Dummy,
    Age,
    X,
    Y,
}

impl Var {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
            Self::Age => "Age",
            Self::X => "X",
            Self::Y => "Y",
        }
    }
}

impl From<Var> for VarId {
    fn from(value: Var) -> Self {
        VarId(value as u16)
    }
}

#[repr(u16)]
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, EnumCount, EnumIter, TryFromPrimitive)]
enum Relation {
    Married,
}

impl Relation {
    fn name(&self) -> &'static str {
        match self {
            Relation::Married => "Married",
        }
    }

    fn from_id(id: RelationId) -> Option<Relation> {
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
enum Set {
    #[default]
    People,
}

impl Set {
    fn name(&self) -> &'static str {
        match self {
            Set::People => "People",
        }
    }

    fn from_id(id: SetId) -> Option<Set> {
        Set::try_from(id.0).ok()
    }
}

impl From<Set> for SetId {
    fn from(value: Set) -> Self {
        SetId(value as u16)
    }
}

fn init_entities() -> Entities {
    let mut definitions = Definitions::default();
    for var in Var::iter() {
        assert_eq!(definitions.define_var(var.name()), VarId::from(var));
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
    Entities::new(definitions)
}

pub fn test() {
    let arena = Arena::new();
    let source = std::fs::read_to_string("data.txt").unwrap();
    let result = tabula::parse(&arena, &source);
    if !result.is_ok() {
        for error in result.errors {
            eprintln!("{error}");
        }
        std::process::exit(1);
    }
    for node in result.roots {
        println!("{} -> {}", node.key, node.value);
    }

    let mut entities = init_entities();

    let id1 = entities.spawn();
    entities.set_name(id1, "Federico");
    entities.set_var(id1, Var::X, 4.);
    entities.set_var(id1, Var::Y, 3.);
    let id2 = entities.spawn();
    entities.set_name(id2, "Tianqi");

    entities.set_relation(id1, Relation::Married, id2, 1.);
    entities.add_to_set(Set::People, id1);
    entities.add_to_set(Set::People, id2);

    for id in entities.iter_set(Set::People) {
        for var in Var::iter() {
            println!("{} -> {}", var.name(), entities.get_var(id, var));
        }

        for entry in entities.get_related(id1) {
            let relation = entities.get_relation_name(entry.relation).unwrap();
            println!(
                "{} -> {} -> {}",
                entities.get_name(entry.source),
                relation,
                entities.get_name(entry.target),
            )
        }
    }

    entities.bind_to_tag("me", id1);
    if let Some(id) = entities.lookup_by_tag("me") {
        println!("I am {}", entities.get_name(id));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relation_from_usize() {
        assert!(matches!(Relation::try_from(0), Ok(Relation::Married)));
        assert!(Relation::try_from(1).is_err());
        assert!(Relation::try_from(u16::MAX).is_err());
    }

    #[test]
    fn set_from_usize() {
        assert!(matches!(Set::try_from(0), Ok(Set::People)));
        assert!(Set::try_from(1).is_err());
        assert!(Set::try_from(u16::MAX).is_err());
        assert!(matches!(Set::from_id(SetId(0)), Some(Set::People)));
    }
}
