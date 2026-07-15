use util::span::Span;

use crate::id::{EntityId, Ids};

/// A name handle: a span into the name store's shared buffer (see
/// [`Names::add`]). The buffer is append-only and never moves, so a symbol
/// is valid for the lifetime of the store and any number of entities can
/// share one. ZII: the zero symbol is the empty name.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Symbol(Span);

/// Per-entity names: one symbol per slot, all spanning one shared buffer.
#[derive(Clone)]
pub struct Names {
    /// Per-slot name symbols; the zero symbol = unnamed.
    symbols: Vec<Symbol>,
    /// The name vocabulary: every name ever added, append-only. It never
    /// moves, so symbols stay valid forever. A replaced name's bytes
    /// leak — rare (custom/generated names only) and accepted.
    buf: String,
}

impl Default for Names {
    fn default() -> Self {
        Names::new()
    }
}

impl Names {
    pub fn new() -> Names {
        Names {
            symbols: vec![Symbol::default(); Ids::CAPACITY],
            buf: String::new(),
        }
    }

    /// Adds a name to the vocabulary, returning the symbol that names
    /// entities with it. Adding the same text twice stores it twice —
    /// name banks dedup by construction; don't churn this.
    pub fn add(&mut self, name: &str) -> Symbol {
        Symbol(Span::push_str(&mut self.buf, name))
    }

    pub fn get(&self, id: EntityId) -> &str {
        self.symbols[id.index()].0.str(&self.buf)
    }

    pub fn set(&mut self, id: EntityId, name: Symbol) {
        self.symbols[id.index()] = name;
    }

    /// Forget the dead's names; their vocabulary entries stay for reuse.
    pub fn purge(&mut self, dead: &[EntityId]) {
        for &id in dead {
            self.symbols[id.index()] = Symbol::default();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_stored_by_slot_and_cleared_by_purge() {
        let mut ids = Ids::new();
        let mut names = Names::new();
        let first = ids.spawn();
        let cicero = names.add("Marcus Tullius Cicero");
        names.set(first, cicero);
        assert_eq!(names.get(first), "Marcus Tullius Cicero");

        ids.mark_despawn(first);
        let dead = ids.sweep();
        names.purge(&dead);
        let replacement = ids.spawn();

        assert_eq!(names.get(replacement), "");
        let caesar = names.add("Gaius Julius Caesar");
        names.set(replacement, caesar);
        assert_eq!(names.get(replacement), "Gaius Julius Caesar");
    }

    #[test]
    fn one_symbol_names_many_entities_and_outlives_them() {
        let mut ids = Ids::new();
        let mut names = Names::new();
        let gaius = names.add("Gaius");
        let a = ids.spawn();
        let b = ids.spawn();
        names.set(a, gaius);
        names.set(b, gaius);
        assert_eq!(names.get(a), "Gaius");
        assert_eq!(names.get(b), "Gaius");
        // One vocabulary entry serves both.
        assert_eq!(names.buf.len(), "Gaius".len());

        ids.mark_despawn(a);
        let dead = ids.sweep();
        names.purge(&dead);
        let c = ids.spawn();
        names.set(c, gaius);
        assert_eq!(names.get(c), "Gaius");
    }
}
