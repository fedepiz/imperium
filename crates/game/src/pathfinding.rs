//! Route queries over the map: "standing here, headed there — where do I
//! step next?" Derived data, NOT world state: this lives on `Game` beside
//! the world, never inside it (saves don't carry it; it rebuilds from
//! nothing), which also keeps the sim's stores free of it.

use rustc_hash::FxHashMap;

use crate::map::{CellPos, Map};

/// The route oracle. Callers stay stateless — an entity re-asks from its
/// current cell every step and stores nothing; the memo of answered
/// questions is this object's private business. Each entry is exactly one
/// question answered: given this position and that destination, the next
/// position is the value — the zero cell meaning "no move" (unreachable,
/// or already there). One A* seeds every hop of the found route, so the
/// rest of the journey (and anyone else on the same road to the same
/// place) answers from the cache.
///
/// The cache assumes the map never changes — true today, the map is
/// parsed once at bootstrap. If terrain ever mutates, call [`clear`].
///
/// [`clear`]: Pathfinding::clear
#[derive(Default)]
pub struct Pathfinding {
    cache: FxHashMap<(CellPos, CellPos), CellPos>,
}

impl Pathfinding {
    /// Entry cap: a chosen constant, like everything else. When the memo
    /// grows past it, the whole thing clears and rebuilds from use.
    const MAX_ENTRIES: usize = 65_536;

    /// The next cell on the cheapest route from `from` to `to`; the zero
    /// cell = nowhere to go (unreachable, or `from` is `to`).
    pub fn next_step(&mut self, map: &Map, from: CellPos, to: CellPos) -> CellPos {
        if let Some(&next) = self.cache.get(&(from, to)) {
            return next;
        }
        if self.cache.len() >= Self::MAX_ENTRIES {
            self.clear();
        }
        match compute(map, from, to) {
            Some(route) => {
                for pair in route.windows(2) {
                    self.cache.insert((pair[0], to), pair[1]);
                }
                // The destination itself answers "no move", and so does a
                // single-cell route (from == to).
                self.cache.insert((to, to), CellPos::default());
            }
            None => {
                self.cache.insert((from, to), CellPos::default());
            }
        }
        self.cache[&(from, to)]
    }

    /// Forget every answered question. For when the map changes under the
    /// memo; unnecessary today.
    pub fn clear(&mut self) {
        self.cache.clear();
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.cache.len()
    }
}

/// One A* over the grid: 4-connected, a cell is enterable iff its cost is
/// nonzero, and that cost prices the step in. Manhattan distance is
/// admissible because every enterable cell costs at least 1.
fn compute(map: &Map, from: CellPos, to: CellPos) -> Option<Vec<CellPos>> {
    let successors = |pos: &CellPos| {
        let &CellPos { x, y } = pos;
        [
            x.checked_sub(1).map(|x| CellPos { x, y }),
            y.checked_sub(1).map(|y| CellPos { x, y }),
            Some(CellPos { x: x + 1, y }),
            Some(CellPos { x, y: y + 1 }),
        ]
        .into_iter()
        .flatten()
        .filter_map(|next| {
            let cost = map.cell(next).cost;
            (cost != 0).then_some((next, cost as u32))
        })
        .collect::<Vec<_>>()
    };
    let heuristic = |pos: &CellPos| pos.x.abs_diff(to.x) + pos.y.abs_diff(to.y);
    pathfinding::prelude::astar(&from, successors, heuristic, |pos| *pos == to)
        .map(|(route, _cost)| route)
}

#[cfg(test)]
mod tests {
    use super::*;
    use entities::Ids;

    // A road ring around a wild block, a settlement at each end of the
    // top road, and a sea-moated island no road reaches.
    const SOURCE: &str = "
        a###b
        #...#
        #####
        ~~~~~
        ~.c.~
        a = a
        b = b
        c = c
    ";

    fn map() -> Map {
        let mut ids = Ids::new();
        let (a, b, c) = (ids.spawn(), ids.spawn(), ids.spawn());
        let (map, errors) = Map::parse(SOURCE, |key| match key {
            "a" => Some(a),
            "b" => Some(b),
            "c" => Some(c),
            _ => None,
        });
        assert!(errors.is_empty(), "{errors:?}");
        map
    }

    fn at(x: u32, y: u32) -> CellPos {
        CellPos { x, y }
    }

    #[test]
    fn steps_along_the_road_toward_the_goal() {
        let map = map();
        let mut routes = Pathfinding::default();

        // a(0,0) to b(4,0): straight along the top road, one cell east.
        assert_eq!(routes.next_step(&map, at(0, 0), at(4, 0)), at(1, 0));
        assert_eq!(routes.next_step(&map, at(1, 0), at(4, 0)), at(2, 0));
        assert_eq!(routes.next_step(&map, at(3, 0), at(4, 0)), at(4, 0));
    }

    #[test]
    fn routes_around_the_impassable() {
        let map = map();
        let mut routes = Pathfinding::default();

        // The wild block (1..4, 1) can't be crossed; from the middle of
        // the top road the way down runs along a side column.
        let next = routes.next_step(&map, at(2, 0), at(2, 2));
        assert!(next == at(1, 0) || next == at(3, 0));
    }

    #[test]
    fn no_route_means_no_move() {
        let map = map();
        let mut routes = Pathfinding::default();

        // The island settlement is behind sea; nowhere = the zero cell.
        assert_eq!(routes.next_step(&map, at(0, 0), at(2, 4)), CellPos::default());
        // Already there.
        assert_eq!(routes.next_step(&map, at(0, 0), at(0, 0)), CellPos::default());
        // Off the map entirely.
        assert_eq!(routes.next_step(&map, at(0, 0), at(99, 99)), CellPos::default());
    }

    #[test]
    fn one_computation_seeds_the_whole_journey() {
        let map = map();
        let mut routes = Pathfinding::default();

        routes.next_step(&map, at(0, 0), at(4, 0));
        let seeded = routes.len();
        // Every later hop of the same journey answers from the cache.
        routes.next_step(&map, at(1, 0), at(4, 0));
        routes.next_step(&map, at(2, 0), at(4, 0));
        routes.next_step(&map, at(4, 0), at(4, 0));
        assert_eq!(routes.len(), seeded);
    }

    #[test]
    fn clear_forgets_every_answer() {
        let map = map();
        let mut routes = Pathfinding::default();
        routes.next_step(&map, at(0, 0), at(4, 0));
        assert!(routes.len() > 0);
        routes.clear();
        assert_eq!(routes.len(), 0);
    }
}
