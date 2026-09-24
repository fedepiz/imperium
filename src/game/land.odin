package game

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../gfx"

// What covers the land, and the marks drawn on it.

// What covers a cell. Each land cell has one cover, and how strongly it has it; Open land has none.
Cover :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
}

Cover_Cell :: struct {
	cover:    Cover,
	// From 0 to max(u8)
	strength: u8,
}

@(rodata)
COVER_SAND := [4]f32{0.965, 0.878, 0.690, 1}

// How each cover is drawn, and how densely it bears each mark family where it is at full strength
COVERS := [Cover]struct {
	look:  gfx.Render_Category,
	marks: [Mark_Family]f32,
} {
	.Open    = {},
	.Forest  = {{color = {0.725, 0.784, 0.576, 1}, wash = 0.45}, #partial {.Tree = 1}},
	.Desert  = {{color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45}, #partial {.Dune = 1}},
	.Steppe  = {{color = COVER_SAND, wash = 0.25}, #partial {.Tuft = 1}},
	.Fertile = {{color = {0.780, 0.820, 0.560, 1}, wash = 0.7}, #partial {.Tree = 0.45}},
	.Marsh   = {{color = {0.616, 0.714, 0.788, 1}, wash = 0.5}, #partial {.Marsh = 1}},
}

// Marks of a family share a jittered lattice, spacing cells apart; each is about width cells wide, varying by up to
// vary either way.
Mark_Family :: enum {
	Tree,
	Molehill,
	Mountain,
	Sea_Mark,
	Tuft,
	Marsh,
	Dune,
}

MARK_FAMILIES := [Mark_Family]struct {
	spacing, width, vary: f32,
} {
	.Tree     = {2.1, 1.6, 0.15},
	.Molehill = {3.84, 3.29, 0},
	.Mountain = {8.04, 4.7, 0},
	.Sea_Mark = {12, 3, 0},
	.Tuft     = {3.8, 1.3, 0.2},
	.Marsh    = {3.2, 2.3, 0.15},
	.Dune     = {5.5, 3.4, 0.2},
}

// What the terrain does not hold but covers and marks need, worked out whenever it changes, in the temp allocator:
// cells to the nearest river and to the sea, and how much the ground rises and falls within two cells.
Land :: struct {
	to_river, to_sea, unevenness: []f32,
}

land_make :: proc() -> (land: Land) {
	terrain := &WORLD.atlas.terrain
	is_river := make([]bool, CELLS_MAX, context.temp_allocator)
	is_sea := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		is_river[i] = cell.surface == .River
		is_sea[i] = cell.surface == .Sea
	}
	land.to_river = make([]f32, CELLS_MAX, context.temp_allocator)
	land.to_sea = make([]f32, CELLS_MAX, context.temp_allocator)
	world_distance_from(land.to_river, is_river)
	world_distance_from(land.to_sea, is_sea)

	land.unevenness = make([]f32, CELLS_MAX, context.temp_allocator)
	for i in 0 ..< CELLS_MAX {
		x, y := i % WORLD_WIDTH, i / WORLD_WIDTH
		lowest, highest := terrain[i].elevation, terrain[i].elevation
		for dy in -2 ..= 2 {
			for dx in -2 ..= 2 {
				nx, ny := clamp(x + dx, 0, WORLD_WIDTH - 1), clamp(y + dy, 0, WORLD_HEIGHT - 1)
				e := terrain[ny * WORLD_WIDTH + nx].elevation
				lowest, highest = min(lowest, e), max(highest, e)
			}
		}
		land.unevenness[i] = f32(highest - lowest) / f32(max(u8))
	}
	return
}

// 0 at from, 1 at full, smooth between; full below from makes it fall.
@(private = "file")
ramp :: proc(from, full, value: f32) -> f32 {
	return full > from ? math.smoothstep(from, full, value) : 1 - math.smoothstep(full, from, value)
}

// A cell's terrain as fractions from 0 to 1, and how far north it is
@(private = "file")
Place :: struct {
	elevation, trees, moisture, north: f32,
}

@(private = "file")
place_of :: proc(i: int) -> Place {
	cell := WORLD.atlas.terrain[i]
	return {
		elevation = f32(cell.elevation) / f32(max(u8)),
		trees = f32(cell.trees) / f32(max(u8)),
		moisture = f32(cell.moisture) / f32(max(u8)),
		north = 1 - (f32(i / WORLD_WIDTH) + 0.5) / f32(WORLD_HEIGHT),
	}
}

// Gives every cell its cover, and hands the covers to the map to draw.
land_classify :: proc(land: ^Land) {
	layer := &WORLD.render_terrain.cover
	for &cell, i in WORLD.cover {
		cell = land_cover(land, i)
		layer.cells[i] = {u8(cell.cover), cell.strength}
	}
	for def, cover in COVERS do layer.palette[cover] = def.look
	layer.revision += 1
}

// Cell i's cover: whichever suits it best, how well being its strength, unless none suits it by at least a sixth.
// Desert and steppe follow the moisture, forest the trees. Dry land along a river is fertile, and low, level ground is
// marsh where it is very wet or where a river meets the sea; both win over the rest.
@(private = "file")
land_cover :: proc(land: ^Land, i: int) -> (best: Cover_Cell) {
	if WORLD.atlas.terrain[i].surface in WATER do return
	p := place_of(i)
	low_and_level := ramp(0.22, 0.12, p.elevation) * ramp(0.08, 0.03, land.unevenness[i])
	delta := ramp(6, 2, land.to_river[i]) * ramp(16, 6, land.to_sea[i])
	suits := [Cover]f32 {
		.Open    = 1.0 / 6,
		.Forest  = ramp(0.05, 0.75, p.trees),
		.Desert  = ramp(0.47, 0.35, p.moisture),
		.Steppe  = ramp(0.40, 0.47, p.moisture) * ramp(0.58, 0.48, p.moisture),
		.Fertile = 1.3 * ramp(0.62, 0.52, p.moisture) * ramp(5, 1.5, land.to_river[i]),
		.Marsh   = 1.5 * low_and_level * max(delta, ramp(0.80, 0.88, p.moisture)),
	}
	most: f32
	for s, cover in suits {
		if s > most do best, most = {cover, u8(min(s, 1) * f32(max(u8)) + 0.5)}, s
	}
	if best.cover == .Open do best.strength = 0
	return
}

// Scatters every family's marks over the terrain, each family on its own jittered lattice.
land_scatter_marks :: proc(land: ^Land) {
	WORLD.mark_count = 0
	scatter: for def, family in MARK_FAMILIES {
		rows := int(f32(WORLD_HEIGHT) / (def.spacing * 0.8))
		cols := int(f32(WORLD_WIDTH) / def.spacing)
		stream := u32(family) * 8
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// Every other row is shifted half a step, and every point wanders within its step.
				x :=
					(f32(col) + 0.5 + f32(row % 2) * 0.5 + (world_random(col, row, stream) - 0.5) * 0.7) *
					def.spacing
				y := (f32(row) + 0.5 + (world_random(col, row, stream + 1) - 0.5) * 0.6) * def.spacing * 0.8
				cx, cy := int(x), int(y)
				if cx < 0 || cy < 0 || cx >= WORLD_WIDTH || cy >= WORLD_HEIGHT do continue
				i := cy * WORLD_WIDTH + cx

				mark, chance := land_mark(family, i, world_random(col, row, stream + 6))
				if world_random(col, row, stream + 5) >= chance do continue
				mark.pos = {x, y}
				mark.width *= def.width * (1 + def.vary * (2 * world_random(col, row, stream + 2) - 1))
				// No mark sits on a river, so rivers stay in view.
				if family != .Sea_Mark {
					offset := WORLD.render_terrain.river[i] - ([2]f32{x, y} - [2]f32{f32(cx), f32(cy)} - 0.5)
					if linalg.length(offset) < mark.width * 0.6 do continue
				}
				mark.variant = u8(world_random(col, row, stream + 3) * f32(world_mark_variants(mark.mark)))

				// A full table keeps what it has; the marks are still sorted below.
				if WORLD.mark_count == MARKS_MAX do break scatter
				WORLD.marks[WORLD.mark_count] = mark
				WORLD.mark_count += 1
			}
		}
	}
	slice.sort_by(WORLD.marks[:WORLD.mark_count], proc(a, b: Mark) -> bool {return a.pos.y < b.pos.y})
}

// The chance a lattice point of family at cell i keeps its mark, and the mark: its drawing, how much wider than the
// family's width it is, and its opacity. roll, from 0 to 1, picks between drawings.
@(private = "file")
land_mark :: proc(family: Mark_Family, i: int, roll: f32) -> (mark: Mark, chance: f32) {
	p := place_of(i)
	coast := WORLD.render_terrain.coast[i]
	cover := WORLD.cover[i]
	// How densely the cell's cover bears the family
	density := COVERS[cover.cover].marks[family] * f32(cover.strength) / f32(max(u8))
	mark.width, mark.alpha = 1, max(u8)
	switch family {
	case .Tree:
		// Trees thin out where mountains take over. Conifers grow in the north and on high ground, cypresses around the
		// warm, dry south, palms along its rivers, broadleaf trees everywhere else, the climates shading into each other.
		chance = density * ramp(0.7, 0.8, coast) * ramp(1.0, 0.55, p.elevation)
		hot_and_dry := ramp(0.62, 0.55, p.north) * ramp(0.56, 0.46, p.moisture)
		weights := [4]f32 {
			6 * max(ramp(0.78, 0.86, p.north), ramp(0.40, 0.55, p.elevation)),
			3 * ramp(0.67, 0.62, p.north) * ramp(0.64, 0.54, p.moisture),
			cover.cover == .Fertile ? 20 * hot_and_dry : 0,
			1,
		}
		sprites := [4]Terrain_Mark{.Conifer, .Cypress, .Palm, .Broadleaf}
		left := roll * (weights[0] + weights[1] + weights[2] + weights[3])
		for weight, k in weights {
			mark.mark = sprites[k]
			left -= weight
			if left < 0 do break
		}
	case .Molehill:
		// Hills give way as mountains take over.
		mark.mark = .Molehill
		chance = ramp(0.9, 1, coast) * ramp(0.58, 0.77, p.elevation) * ramp(1.0, 0.55, p.elevation)
	case .Mountain:
		mark.mark = .Mountain
		chance = ramp(0.9, 1, coast) * ramp(0.55, 1.0, p.elevation)
		mark.width = 1 + 0.4 * ramp(0.55, 1.0, p.elevation)
	case .Sea_Mark:
		// Out from the shore, then fading over the open sea; lakes have none.
		mark.mark = .Sea_Mark
		if WORLD.atlas.terrain[i].surface != .Sea do return
		fade := ramp(-5, -19, coast)
		if fade < 0.08 do return
		chance = ramp(-3, -5, coast)
		mark.alpha = u8(fade * f32(max(u8)))
	case .Tuft:
		mark.mark = .Tuft
		chance = density * ramp(0.7, 0.8, coast)
	case .Marsh:
		mark.mark = .Marsh
		chance = density * ramp(0.7, 0.8, coast)
	case .Dune:
		// Dunes only in the deep desert, and not on hills
		mark.mark = .Dune
		chance = density * ramp(1.9, 2, coast) * ramp(0.36, 0.30, p.moisture) * ramp(0.77, 0.58, p.elevation)
	}
	return
}
