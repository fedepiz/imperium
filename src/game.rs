use std::collections::HashMap;

use arena::Arena;
use num_enum::TryFromPrimitive;
use strum::{EnumCount, EnumIter, IntoEnumIterator};
use ui::ir;

use entities::*;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, EnumCount, EnumIter)]
enum Var {
    #[default]
    Dummy,
    Age,
    Gender,
}

impl Var {
    fn name(&self) -> &'static str {
        match self {
            Self::Dummy => "Dummy",
            Self::Age => "Age",
            Self::Gender => "Gender",
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

    #[allow(dead_code)]
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

    #[allow(dead_code)]
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

/// Everyone dies on the birthday that takes them past this. Placeholder
/// until real death mechanics exist.
const DEATH_AGE: f32 = 70.0;

pub struct Game {
    entities: Entities,
    pub year: u32,
}

impl Game {
    pub fn new() -> Game {
        let mut entities = init_entities();
        let source = std::fs::read_to_string("data/characters.txt").unwrap_or_default();
        bootstrap(&mut entities, &source);
        Game {
            entities,
            year: 700, // AUC
        }
    }

    /// One turn of the placeholder sim: everyone ages a year, the old die.
    /// Death reactions run between mark and sweep, while the corpse's
    /// relations are still queryable.
    pub fn tick_year(&mut self) {
        self.year += 1;
        let people: Vec<_> = self.entities.iter_set(Set::People).collect();
        for id in people {
            let age = self.entities.get_var(id, Var::Age) + 1.0;
            self.entities.set_var(id, Var::Age, age);
            if age >= DEATH_AGE {
                self.entities.mark_despawn(id);
                self.report_death(id);
            }
        }
        self.entities.sweep();
    }

    /// Placeholder death reaction: console obituary. Runs before the sweep
    /// so it can still read the deceased's name and marriages.
    fn report_death(&self, id: EntityId) {
        let name = self.entities.get_name(id);
        // Marriage is declared one-way in the data; look both directions.
        let spouses: Vec<&str> = self
            .entities
            .get_related_via(id, Relation::Married)
            .map(|(other, _)| other)
            .chain(
                self.entities
                    .get_related_to_via(id, Relation::Married)
                    .map(|(other, _)| other),
            )
            .map(|other| self.entities.get_name(other))
            .collect();
        if spouses.is_empty() {
            println!("Year {}: {name} has died.", self.year);
        } else {
            println!(
                "Year {}: {name} has died, survived by {}.",
                self.year,
                spouses.join(", ")
            );
        }
    }

    /// UI action protocol: `<verb> [args…]`, with entity ids packed via
    /// `EntityId::to_bits` (the `Display`/`FromStr` round trip).
    pub fn handle_action(&mut self, action: &str) {
        let mut parts = action.split_whitespace();
        match parts.next() {
            Some("advance_year") => self.tick_year(),
            Some("remove") => {
                let id = parts.next().and_then(|arg| arg.parse::<EntityId>().ok());
                let Some(id) = id else {
                    eprintln!("malformed ui action: {action}");
                    return;
                };
                // Stale ids parse fine and fail here — a click raced a death.
                if self.entities.is_alive(id) {
                    self.entities.mark_despawn(id);
                    self.report_death(id);
                    self.entities.sweep();
                }
            }
            Some("femalify") => {
                let id = parts.next().and_then(|arg| arg.parse::<EntityId>().ok());
                let Some(id) = id else {
                    eprintln!("malformed ui action: {action}");
                    return;
                };
                self.entities.set_var(id, Var::Gender, 0.0);
            }
            _ => println!("unhandled ui action: {action}"),
        }
    }

    /// The per-frame bridge: dump the sim state the UI script binds to.
    pub fn fill_ui_data(&self, data: &mut ir::UiData) {
        data.begin_list("status");
        data.begin_row();
        let souls = self.entities.iter_set(Set::People).count();
        data.bind("STATUS", &format!("Year {} AUC — {souls} souls", self.year));

        data.begin_list("people");
        for id in self.entities.iter_set(Set::People) {
            data.begin_row();
            data.bind("ID", &format!("{}", id));
            data.bind("NAME", self.entities.get_name(id));
            let age = self.entities.get_var(id, Var::Age) as u32;
            data.bind("AGE", &format!("{}", age));
            if self.entities.get_var(id, Var::Gender) > 0. {
                data.bind("IS_MALE", "yes");
            }
        }
    }
}

/// Spawn the starting cast from `data/characters.txt`. Two passes: all
/// characters first, then relations, so forward references resolve.
fn bootstrap(entities: &mut Entities, source: &str) {
    let arena = Arena::new();
    let result = tabula::parse(&arena, source);
    for error in result.errors {
        eprintln!("data/characters.txt: {error}");
    }

    let characters = || result.roots.iter().filter(|node| node.key == "character");

    let mut by_key: HashMap<&str, EntityId> = HashMap::new();
    for node in characters() {
        let id = entities.spawn();
        let name = entities.add_name(node.get_text("name").unwrap_or("Anonymous"));
        entities.set_name(id, name);
        entities.set_var(id, Var::Age, node.get_number("age").unwrap_or(0.0));

        let gender = match node.get_text("gender").unwrap_or_default() {
            "female" => 0.0,
            "male" => 1.0,
            _ => 0.0,
        };
        entities.set_var(id, Var::Gender, gender);

        entities.add_to_set(Set::People, id);
        if let Some(tag) = node.get_text("tag") {
            entities.bind_to_tag(tag, id);
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
                Some(&target) => entities.set_relation(source_id, Relation::Married, target, 1.0),
                None => eprintln!("data/characters.txt: '{key}' married unknown id '{spouse}'"),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_CAST: &str = r#"
        character = { id = a name = "Aulus" age = 68 tag = player married = b }
        character = { id = b name = "Betua" age = 30 }
        character = { id = c name = "Corvus" age = 69 }
    "#;

    fn game() -> Game {
        let mut entities = init_entities();
        bootstrap(&mut entities, TEST_CAST);
        Game {
            entities,
            year: 700,
        }
    }

    #[test]
    fn bootstrap_spawns_cast_with_vars_tags_and_relations() {
        let game = game();
        let player = game.entities.lookup_by_tag("player").unwrap();
        assert_eq!(game.entities.get_name(player), "Aulus");
        assert_eq!(game.entities.get_var(player, Var::Age), 68.0);
        assert_eq!(game.entities.iter_set(Set::People).count(), 3);

        let spouses: Vec<_> = game
            .entities
            .get_related_via(player, Relation::Married)
            .collect();
        assert_eq!(spouses.len(), 1);
        assert_eq!(game.entities.get_name(spouses[0].0), "Betua");
    }

    #[test]
    fn tick_ages_everyone_and_the_old_die() {
        let mut game = game();

        // Corvus (69) turns 70 and dies; Aulus (68) follows a year later.
        game.tick_year();
        assert_eq!(game.year, 701);
        assert_eq!(game.entities.iter_set(Set::People).count(), 2);

        game.tick_year();
        assert_eq!(game.entities.iter_set(Set::People).count(), 1);
        assert!(game.entities.lookup_by_tag("player").is_none());

        let survivor = game.entities.iter_set(Set::People).next().unwrap();
        assert_eq!(game.entities.get_name(survivor), "Betua");
        assert_eq!(game.entities.get_var(survivor, Var::Age), 32.0);
    }

    #[test]
    fn ui_data_carries_status_and_people_rows() {
        let game = game();
        let mut data = ir::UiData::default();
        game.fill_ui_data(&mut data);

        assert_eq!(data.lists.len(), 2);
        let status_rows = data.rows(data.lists[0]);
        assert_eq!(status_rows.len(), 1);
        let binding = data.bindings(status_rows[0])[0];
        assert_eq!(data.text(binding.key), "STATUS");
        assert_eq!(data.text(binding.value), "Year 700 AUC — 3 souls");

        let people_rows = data.rows(data.lists[1]);
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
        assert_eq!(get("AGE"), "68");
        // The ID binding round-trips back to the live entity.
        let id: EntityId = get("ID").parse().unwrap();
        assert_eq!(Some(id), game.entities.lookup_by_tag("player"));
    }

    #[test]
    fn relation_from_u16() {
        assert!(matches!(Relation::try_from(0), Ok(Relation::Married)));
        assert!(Relation::try_from(1).is_err());
        assert!(Relation::try_from(u16::MAX).is_err());
    }

    #[test]
    fn set_from_u16() {
        assert!(matches!(Set::try_from(0), Ok(Set::People)));
        assert!(Set::try_from(1).is_err());
        assert!(Set::try_from(u16::MAX).is_err());
        assert!(matches!(Set::from_id(SetId(0)), Some(Set::People)));
    }
}
