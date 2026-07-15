//! The world map: a flat grid of square cells, authored as plain ASCII.
//!
//! Format (provisional): the file mixes grid rows and legend lines. Any
//! line containing `=` is a legend entry, `<letter> = <data key>`, tying
//! a settlement glyph to the entry that spawned it; every other non-blank
//! line is a row of cells. Glyphs: `a`-`z`/`A`-`Z` = a cell of that
//! settlement's blob, `#` = road, `~` = sea, `.` = impassable wilds.
//!
//! The grid is the authored truth about space; the logical graph of
//! places and roads is derived from it, never stored.

use entities::{Bits64, EntityId};

/// A cell coordinate. Packs into a uvar slot; ZII with a caveat: the zero
/// position is the map's top-left corner, which authored maps keep void,
/// so zero reads as "nowhere" in practice.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default, Debug)]
pub struct CellPos {
    pub x: u32,
    pub y: u32,
}

impl Bits64 for CellPos {
    fn to_bits(self) -> u64 {
        (self.x as u64) << 32 | self.y as u64
    }

    fn from_bits(bits: u64) -> CellPos {
        CellPos {
            x: (bits >> 32) as u32,
            y: bits as u32,
        }
    }
}

/// Formats as the packed bits so positions embed directly in UI action
/// strings, like `EntityId`; [`FromStr`](core::str::FromStr) reverses
/// the trip. The zero position ("nowhere") is "0", both ways.
impl core::fmt::Display for CellPos {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        core::fmt::Display::fmt(&self.to_bits(), f)
    }
}

impl core::str::FromStr for CellPos {
    type Err = core::num::ParseIntError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(CellPos::from_bits(s.parse::<u64>()?))
    }
}

/// What ground a cell is made of. Genuinely non-overlapping kinds, hence
/// an enum; ZII: the zero terrain is the impassable wild.
#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum Terrain {
    #[default]
    Wild,
    Road,
    Sea,
    /// A cell of some settlement's blob; which one is the cell's
    /// `settlement` field, not the terrain's business.
    Settlement,
}

/// One square of the world, ZII: the all-zero cell is the impassable
/// wild, which is also what lies beyond every map edge.
#[derive(Clone, Copy, Default)]
pub struct Cell {
    pub terrain: Terrain,
    /// Price of stepping in; 0 = impassable. Stored per cell — parse
    /// fills it from the terrain today, but that's policy, and movement
    /// only ever reads this number. Sea is 0 for now; water travel may
    /// price it later.
    pub cost: u8,
    /// The settlement whose blob this cell belongs to; null = none.
    pub settlement: EntityId,
}

#[derive(Clone, Default)]
pub struct Map {
    pub width: u32,
    pub height: u32,
    cells: Vec<Cell>,
    /// Each settlement's anchor — the center of its blob, computed at
    /// parse time. Where "located" people are dropped. Blobs are always
    /// odd-sided squares (1x1, 3x3), so the center is an exact cell.
    anchors: Vec<(EntityId, CellPos)>,
}

impl Map {
    /// The cell at `pos`, or the void cell when out of bounds — the map
    /// effectively extends with impassable nothing in every direction.
    pub fn cell(&self, pos: CellPos) -> Cell {
        if pos.x < self.width && pos.y < self.height {
            self.cells[(pos.y * self.width + pos.x) as usize]
        } else {
            Cell::default()
        }
    }

    /// A settlement's anchor cell. Zero pos = it has no blob on the map.
    pub fn anchor(&self, settlement: EntityId) -> CellPos {
        self.anchors
            .iter()
            .find(|(id, _)| *id == settlement)
            .map(|(_, pos)| *pos)
            .unwrap_or_default()
    }

    /// Every settlement with cells on the map, and where its anchor is.
    pub fn anchors(&self) -> &[(EntityId, CellPos)] {
        &self.anchors
    }

    /// Parse the ASCII format. `resolve` turns a legend entry's data key
    /// into the settlement spawned for it, or None if the key is unknown.
    /// Problems are reported as strings; broken cells parse to the void.
    pub fn parse(
        source: &str,
        mut resolve: impl FnMut(&str) -> Option<EntityId>,
    ) -> (Map, Vec<String>) {
        let mut errors = Vec::new();

        // Split the lines once — legend lines carry '=', every other
        // non-blank line is a grid row — then process the two groups in
        // sequence: legend first, so rows can use letters defined below
        // them.
        let (legend_lines, rows): (Vec<&str>, Vec<&str>) = source
            .lines()
            .map(str::trim_end)
            .filter(|line| !line.trim().is_empty())
            .partition(|line| line.contains('='));

        let mut legend = [EntityId::NULL; 52];
        let letter_slot = |letter: char| -> Option<usize> {
            match letter {
                'a'..='z' => Some(letter as usize - 'a' as usize),
                'A'..='Z' => Some(letter as usize - 'A' as usize + 26),
                _ => None,
            }
        };
        for line in legend_lines {
            let (letter, key) = line.split_once('=').unwrap_or_default();
            let (letter, key) = (letter.trim(), key.trim());
            let slot = match letter.chars().next().and_then(letter_slot) {
                Some(slot) if letter.chars().count() == 1 => slot,
                _ => {
                    errors.push(format!("legend glyph '{letter}' is not a letter"));
                    continue;
                }
            };
            match resolve(key) {
                Some(id) => legend[slot] = id,
                None => errors.push(format!("legend '{letter}' names unknown id '{key}'")),
            }
        }

        // Common indentation strips off, so the source can sit indented
        // (in a test string, say) without shifting cells.
        let indent = rows
            .iter()
            .map(|row| row.len() - row.trim_start().len())
            .min()
            .unwrap_or(0);
        let rows: Vec<&str> = rows.iter().map(|row| &row[indent..]).collect();
        let width = rows
            .iter()
            .map(|row| row.chars().count())
            .max()
            .unwrap_or(0) as u32;
        let height = rows.len() as u32;

        let mut cells = vec![Cell::default(); (width * height) as usize];
        // Each settlement's bounding box and cell count, grown as its
        // cells appear; anchors (centers) derive from these afterwards.
        let mut blobs: Vec<(EntityId, CellPos, CellPos, u32)> = Vec::new();
        for (y, row) in rows.iter().enumerate() {
            for (x, glyph) in row.chars().enumerate() {
                let cell = match glyph {
                    '.' => Cell::default(),
                    '~' => Cell {
                        terrain: Terrain::Sea,
                        ..Cell::default()
                    },
                    '#' => Cell {
                        terrain: Terrain::Road,
                        cost: 1,
                        ..Cell::default()
                    },
                    letter => match letter_slot(letter) {
                        Some(slot) if legend[slot] != EntityId::NULL => {
                            let settlement = legend[slot];
                            let pos = CellPos {
                                x: x as u32,
                                y: y as u32,
                            };
                            match blobs.iter_mut().find(|(id, ..)| *id == settlement) {
                                Some((_, min, max, count)) => {
                                    min.x = min.x.min(pos.x);
                                    min.y = min.y.min(pos.y);
                                    max.x = max.x.max(pos.x);
                                    max.y = max.y.max(pos.y);
                                    *count += 1;
                                }
                                None => blobs.push((settlement, pos, pos, 1)),
                            }
                            Cell {
                                terrain: Terrain::Settlement,
                                cost: 1,
                                settlement,
                            }
                        }
                        Some(_) => {
                            errors.push(format!("glyph '{letter}' at {x},{y} has no legend"));
                            Cell::default()
                        }
                        None => {
                            errors.push(format!("unknown glyph '{letter}' at {x},{y}"));
                            Cell::default()
                        }
                    },
                };
                cells[y * width as usize + x] = cell;
            }
        }

        // Anchors: the center of each blob. Blobs must be filled odd-sided
        // squares so the center is an exact cell — an ill-shaped one still
        // anchors at its bounding box's center, but gets reported.
        let anchors = blobs
            .iter()
            .map(|&(id, min, max, count)| {
                let (w, h) = (max.x - min.x + 1, max.y - min.y + 1);
                if w != h || count != w * h || w % 2 == 0 {
                    errors.push(format!(
                        "settlement blob at {},{} is not a filled odd square",
                        min.x, min.y
                    ));
                }
                (
                    id,
                    CellPos {
                        x: min.x + (w - 1) / 2,
                        y: min.y + (h - 1) / 2,
                    },
                )
            })
            .collect();

        (
            Map {
                width,
                height,
                cells,
                anchors,
            },
            errors,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = "
        ~....
        ~aaa#
        ~aaa.
        ~aaa.
        a = home
    ";

    fn home() -> EntityId {
        entities::Ids::new().spawn()
    }

    fn map() -> (Map, Vec<String>) {
        Map::parse(SOURCE, |key| (key == "home").then(home))
    }

    #[test]
    fn parses_grid_legend_and_costs() {
        let (map, errors) = map();
        assert!(errors.is_empty());
        assert_eq!((map.width, map.height), (5, 4));

        // Sea keeps its kind; wilds are the zero cell, as is row padding.
        assert_eq!(map.cell(CellPos { x: 0, y: 0 }).terrain, Terrain::Sea);
        assert_eq!(map.cell(CellPos { x: 1, y: 0 }).terrain, Terrain::Wild);
        assert_eq!(map.cell(CellPos { x: 4, y: 0 }).terrain, Terrain::Wild);
        // Roads are steppable but belong to no one.
        let road = map.cell(CellPos { x: 4, y: 1 });
        assert_eq!(road.terrain, Terrain::Road);
        assert_eq!(road.cost, 1);
        assert_eq!(road.settlement, EntityId::NULL);
        // Settlement cells carry their blob's id; the anchor is the
        // center of the blob's square.
        let town = map.cell(CellPos { x: 1, y: 1 });
        assert_eq!(town.terrain, Terrain::Settlement);
        assert_eq!(town.cost, 1);
        assert_eq!(town.settlement, home());
        assert_eq!(map.anchor(home()), CellPos { x: 2, y: 2 });
        assert_eq!(map.anchor(EntityId::NULL), CellPos::default());
    }

    #[test]
    fn positions_round_trip_through_bits_and_strings() {
        let pos = CellPos { x: 7, y: 3 };
        assert_eq!(CellPos::from_bits(pos.to_bits()), pos);
        assert_eq!(pos.to_string().parse::<CellPos>(), Ok(pos));
        // ZII: nowhere is "0", both ways.
        assert_eq!(CellPos::default().to_bits(), 0);
        assert_eq!("0".parse::<CellPos>(), Ok(CellPos::default()));
    }

    #[test]
    fn out_of_bounds_is_the_void() {
        let (map, _) = map();
        let beyond = map.cell(CellPos { x: 99, y: 0 });
        assert_eq!(beyond.terrain, Terrain::Wild);
        assert_eq!(beyond.cost, 0);
        assert_eq!(beyond.settlement, EntityId::NULL);
    }

    #[test]
    fn single_cell_blobs_anchor_on_themselves() {
        let (map, errors) = Map::parse(".a\na = home", |_| Some(home()));
        assert!(errors.is_empty());
        assert_eq!(map.anchor(home()), CellPos { x: 1, y: 0 });
    }

    #[test]
    fn ill_shaped_blobs_are_an_error() {
        // Even squares and lopsided blobs alike: no exact center cell.
        let (_, errors) = Map::parse("aa\naa\na = home", |_| Some(home()));
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("not a filled odd square"));

        let (map, errors) = Map::parse("aaa\naa.\na = home", |_| Some(home()));
        assert_eq!(errors.len(), 1);
        // The anchor still lands somewhere sensible: the bbox center.
        assert_eq!(map.anchor(home()), CellPos { x: 1, y: 0 });
    }

    #[test]
    fn problems_become_errors_and_void_cells() {
        let (map, errors) = Map::parse("x?\nx = ghost\n1 = home", |_| None);
        // Unknown key, bad legend glyph, then per-cell: legendless 'x',
        // unknown '?'.
        assert_eq!(errors.len(), 4);
        assert_eq!(map.cell(CellPos { x: 0, y: 0 }).terrain, Terrain::Wild);
        assert_eq!(map.cell(CellPos { x: 1, y: 0 }).terrain, Terrain::Wild);
    }
}
