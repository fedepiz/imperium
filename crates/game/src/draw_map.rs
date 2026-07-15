//! The map's render model: everything the harness needs to draw the map,
//! with every drawing *decision* — colors, what gets a dot — made here,
//! sim-side. The harness just rasterizes rectangles and dots; it never
//! looks at world state.

use crate::defs::{Set, UVar};
use crate::map::{CellPos, Terrain};
use crate::world::World;

/// Plain color, ZII: the zero color is fully transparent, which reads as
/// "nothing to draw" wherever a color is optional.
#[derive(Clone, Copy, Default)]
pub struct Rgba {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

const fn rgb(r: f32, g: f32, b: f32) -> Rgba {
    Rgba { r, g, b, a: 1.0 }
}

// The manuscript palette: vellum land, slate sea, oxblood settlements.
const WILD: Rgba = rgb(0.52, 0.48, 0.38);
const SEA: Rgba = rgb(0.36, 0.44, 0.50);
const ROAD: Rgba = rgb(0.68, 0.58, 0.42);
const SETTLEMENT: Rgba = rgb(0.48, 0.18, 0.15);
const PERSON: Rgba = rgb(0.12, 0.10, 0.09);
const PLAYER: Rgba = rgb(0.85, 0.68, 0.30);

/// One drawable cell, fat and ZII: a fill, plus a dot drawn on top when
/// someone stands here (transparent = no dot).
#[derive(Clone, Copy, Default)]
pub struct DrawCell {
    pub fill: Rgba,
    pub dot: Rgba,
}

/// The whole map, ready to draw: `width * height` cells in row-major
/// order. The default is the empty map — nothing to draw.
#[derive(Clone, Default)]
pub struct DrawMap {
    pub width: u32,
    pub height: u32,
    pub cells: Vec<DrawCell>,
}

/// Derive the render model from the world. Called once per frame by the
/// harness, read-only, like `fill_ui_data`.
pub fn build(world: &World) -> DrawMap {
    let map = &world.map;
    let mut cells = vec![DrawCell::default(); (map.width * map.height) as usize];

    for y in 0..map.height {
        for x in 0..map.width {
            let cell = map.cell(CellPos { x, y });
            cells[(y * map.width + x) as usize].fill = match cell.terrain {
                Terrain::Wild => WILD,
                Terrain::Road => ROAD,
                Terrain::Sea => SEA,
                Terrain::Settlement => SETTLEMENT,
            };
        }
    }

    // People *travelling* become dots — only road cells get one; a
    // settlement is presumed occupied, its fill is marker enough. The
    // player's dot outshines anyone sharing the cell.
    let player = world.tags.lookup("player");
    for id in world.sets.iter(Set::People) {
        let pos: CellPos = world.uvars.get(&world.ids, id, UVar::Position);
        // The zero position is "nowhere", not the corner cell.
        if pos == CellPos::default() || pos.x >= map.width || pos.y >= map.height {
            continue;
        }
        if map.cell(pos).terrain != Terrain::Road {
            continue;
        }
        let dot = &mut cells[(pos.y * map.width + pos.x) as usize].dot;
        if player == Some(id) {
            *dot = PLAYER;
        } else if dot.a == 0.0 {
            *dot = PERSON;
        }
    }

    DrawMap {
        width: map.width,
        height: map.height,
        cells,
    }
}
