mod entities;

use arena::Arena;
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

impl Into<VarId> for Var {
    fn into(self) -> VarId {
        VarId(self as usize)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, EnumCount, EnumIter)]
enum Relation {
    Married,
}

impl Relation {
    fn name(&self) -> &'static str {
        match self {
            Relation::Married => "Married",
        }
    }
}

impl Into<RelationId> for Relation {
    fn into(self) -> RelationId {
        RelationId(self as usize)
    }
}

fn main() {
    let arena = Arena::new();
    let source = std::fs::read_to_string("data.txt").unwrap();
    let result = tabula::parse(&arena, &source);
    for node in result.roots {
        println!("{} -> {}", node.key, node.value);
    }

    let mut entities = Entities::new(Definitions {
        num_vars: Var::COUNT,
    });

    let id1 = entities.spawn();
    let id2 = entities.spawn();

    entities.set_var(id1, Var::X, 4.);
    entities.set_var(id1, Var::Y, 3.);

    for id in [id1, id2] {
        for var in Var::iter() {
            println!("{} -> {}", var.name(), entities.get_var(id, var));
        }

        for rel_id in Relation::iter() {
            for (tgt, _) in entities.get_related_via(id, rel_id) {
                println!("{id:?} -> {tgt:?} (via {})", rel_id.name());
            }
        }
    }
}
