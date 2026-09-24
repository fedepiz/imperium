package game

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../gfx"

// What the land is, and what is drawn on it. land_cover decides each cell's cover; COVERS says how each cover is drawn
// and what marks it bears; MARK_FAMILIES says where marks go and which drawing each one gets, by rules over the land's
// fields.

// A property of the land that rules read. Most run from 0 to 1.
Field :: enum {
	Elevation,
	Trees,
	Moisture,
	// From 0 at the bottom of the map to 1 at the top
	North,
	// How much the ground rises and falls within two cells
	Unevenness,
	// In cells: to the nearest river, to the sea, and to the coast, signed so it is positive on land
	To_River,
	To_Sea,
	Coast,
	// 1 on the sea, 0 elsewhere
	Is_Sea,
}

// 0 where the field is at from, 1 where it is at full, and smooth between; a full below from makes the ramp fall.
Ramp :: struct {
	field:      Field,
	from, full: f32,
}

// How well a place suits something, from 0 to 1: the best of its alternatives, each the product of its ramps. A rule
// with no alternatives suits everywhere fully; so does an alternative with no ramps.
Rule :: [][]Ramp

// Covers

// What covers a cell. Each land cell has one cover, and how strongly it has it; Open land has none.
Cover :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
}

Cover_Def :: struct {
	// How the cover is drawn on the map
	look:  gfx.Render_Category,
	// How densely each mark family is scattered over the cover, where it is at full strength
	marks: [Mark_Family]f32,
}

@(rodata)
COVER_SAND := [4]f32{0.965, 0.878, 0.690, 1}

COVERS := [Cover]Cover_Def {
	.Open = {},
	.Forest = {
		look = {color = {0.725, 0.784, 0.576, 1}, wash = 0.45},
		marks = #partial [Mark_Family]f32{.Tree = 1},
	},
	.Desert = {
		look = {color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
		marks = #partial [Mark_Family]f32{.Dune = 1},
	},
	.Steppe = {
		look = {color = COVER_SAND, wash = 0.25},
		marks = #partial [Mark_Family]f32{.Tuft = 1},
	},
	.Fertile = {
		look = {color = {0.780, 0.820, 0.560, 1}, wash = 0.7},
		marks = #partial [Mark_Family]f32{.Tree = 0.45},
	},
	.Marsh = {
		look = {color = {0.616, 0.714, 0.788, 1}, wash = 0.5},
		marks = #partial [Mark_Family]f32{.Marsh = 1},
	},
}

// One cell's cover
Cover_Cell :: struct {
	cover:    Cover,
	// From 0 to max(u8)
	strength: u8,
}

// Marks

// A kind of mark: its marks share a lattice, and each is drawn as one of the family's members.
Mark_Family :: enum {
	Tree,
	Molehill,
	Mountain,
	Sea_Mark,
	Tuft,
	Marsh,
	Dune,
}

Mark_Family_Def :: struct {
	// The spacing of the family's lattice, in cells: halving it gives four times as many marks
	spacing:      f32,
	// The typical width of a mark, in cells; single marks vary by up to vary either way, and grow by up to grow times
	// their width as the grow ramp rises.
	width:        f32,
	vary:         f32,
	grow:         f32,
	grow_by:      Ramp,
	// A lattice point keeps its mark with the chance this rule gives, times, for families that covers scatter, the
	// density its cell's cover gives the family and the cover's strength there.
	rule:         Rule,
	from_cover:   bool,
	// Opacity, if the family fades: marks too faint to see are left out.
	fades:        bool,
	fade:         Ramp,
	// No mark sits on a river, so rivers stay in view.
	avoid_rivers: bool,
	// Each mark is drawn as one of these, picked with chances in proportion to how well each suits the place.
	members:      []Mark_Member,
}

Mark_Member :: struct {
	sprite: Terrain_Mark,
	// How well the member suits a place, times weight; with covers, only on cells of those covers.
	rule:   Rule,
	weight: f32,
	covers: bit_set[Cover],
}

@(private = "file")
LAND_COAST :: Ramp{.Coast, 0.7, 0.8}
@(private = "file")
UPLAND_COAST :: Ramp{.Coast, 0.9, 1.0}

MARK_FAMILIES := [Mark_Family]Mark_Family_Def {
	.Tree = {
		spacing = 2.1,
		width = 1.6,
		vary = 0.15,
		// Trees thin out where mountains take over.
		rule = {{LAND_COAST, {.Elevation, 1.0, 0.55}}},
		from_cover = true,
		avoid_rivers = true,
		members = {
			// Conifers in the north and on high ground, cypresses around the warm, dry south, palms along its
			// rivers, broadleaf trees everywhere else, the climates shading into each other
			{sprite = .Conifer, rule = {{{.North, 0.78, 0.86}}, {{.Elevation, 0.40, 0.55}}}, weight = 6},
			{sprite = .Broadleaf, weight = 1},
			{sprite = .Cypress, rule = {{{.North, 0.67, 0.62}, {.Moisture, 0.64, 0.54}}}, weight = 3},
			{
				sprite = .Palm,
				rule = {{{.North, 0.62, 0.55}, {.Moisture, 0.56, 0.46}}},
				weight = 20,
				covers = {.Fertile},
			},
		},
	},
	.Molehill = {
		spacing = 3.84,
		width = 3.29,
		// Hills give way as mountains take over.
		rule = {{UPLAND_COAST, {.Elevation, 0.58, 0.77}, {.Elevation, 1.0, 0.55}}},
		avoid_rivers = true,
		members = {{sprite = .Molehill, weight = 1}},
	},
	.Mountain = {
		spacing = 8.04,
		width = 4.7,
		grow = 0.4,
		grow_by = {.Elevation, 0.55, 1.0},
		rule = {{UPLAND_COAST, {.Elevation, 0.55, 1.0}}},
		avoid_rivers = true,
		members = {{sprite = .Mountain, weight = 1}},
	},
	// Out from the shore, then fading over the open sea; lakes have none.
	.Sea_Mark = {
		spacing = 12.0,
		width = 3.0,
		rule = {{{.Is_Sea, 0.5, 0.51}, {.Coast, -3, -5}}},
		fades = true,
		fade = {.Coast, -5, -19},
		members = {{sprite = .Sea_Mark, weight = 1}},
	},
	.Tuft = {
		spacing = 3.8,
		width = 1.3,
		vary = 0.2,
		rule = {{LAND_COAST}},
		from_cover = true,
		avoid_rivers = true,
		members = {{sprite = .Tuft, weight = 1}},
	},
	.Marsh = {
		spacing = 3.2,
		width = 2.3,
		vary = 0.15,
		rule = {{LAND_COAST}},
		from_cover = true,
		avoid_rivers = true,
		members = {{sprite = .Marsh, weight = 1}},
	},
	// Dunes only in the deep desert, and not on hills
	.Dune = {
		spacing = 5.5,
		width = 3.4,
		vary = 0.2,
		rule = {{{.Coast, 1.9, 2.0}, {.Moisture, 0.36, 0.30}, {.Elevation, 0.77, 0.58}}},
		from_cover = true,
		avoid_rivers = true,
		members = {{sprite = .Dune, weight = 1}},
	},
}

// Applying the tables

// The fields that are not kept with the terrain, worked out once whenever it changes. Slices live in the temp
// allocator.
Land :: struct {
	to_river:   []f32,
	to_sea:     []f32,
	unevenness: []f32,
}

// Works out the fields the terrain does not hold.
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

// A field at cell i.
land_field :: proc(land: ^Land, field: Field, i: int) -> f32 {
	cell := WORLD.atlas.terrain[i]
	switch field {
	case .Elevation:
		return f32(cell.elevation) / f32(max(u8))
	case .Trees:
		return f32(cell.trees) / f32(max(u8))
	case .Moisture:
		return f32(cell.moisture) / f32(max(u8))
	case .North:
		return 1 - (f32(i / WORLD_WIDTH) + 0.5) / f32(WORLD_HEIGHT)
	case .Unevenness:
		return land.unevenness[i]
	case .To_River:
		return land.to_river[i]
	case .To_Sea:
		return land.to_sea[i]
	case .Coast:
		return WORLD.render_terrain.coast[i]
	case .Is_Sea:
		return cell.surface == .Sea ? 1 : 0
	}
	return 0
}

land_ramp :: proc(land: ^Land, ramp: Ramp, i: int) -> f32 {
	value := land_field(land, ramp.field, i)
	if ramp.full == ramp.from do return value >= ramp.from ? 1 : 0
	if ramp.full < ramp.from do return math.smoothstep(ramp.full, ramp.from, value) * -1 + 1
	return math.smoothstep(ramp.from, ramp.full, value)
}

// How well cell i suits a rule.
land_rule :: proc(land: ^Land, rule: Rule, i: int) -> f32 {
	if len(rule) == 0 do return 1
	best: f32
	for alternative in rule {
		suits: f32 = 1
		for ramp in alternative {
			suits *= land_ramp(land, ramp, i)
			if suits == 0 do break
		}
		best = max(best, suits)
	}
	return best
}

// Gives every cell its cover, and hands the covers to the map to draw.
land_classify :: proc(land: ^Land) {
	for &cell, i in WORLD.cover do cell = land_cover(land, i)

	layer := &WORLD.render_terrain.cover
	for cell, i in WORLD.cover do layer.cells[i] = {u8(cell.cover), cell.strength}
	for def, cover in COVERS do layer.palette[cover] = def.look
	layer.revision += 1
}

// Cell i's cover: whichever suits it best, how well being its strength, unless none suits it by at least a sixth.
// Desert and steppe follow the moisture; forest the trees. Dry land along a river is fertile, and low, level ground
// is marsh where it is very wet or where a river meets the sea; both of these win over the rest.
@(private = "file")
land_cover :: proc(land: ^Land, i: int) -> (best: Cover_Cell) {
	if WORLD.atlas.terrain[i].surface in WATER do return
	ramp :: proc(land: ^Land, i: int, field: Field, from, full: f32) -> f32 {
		return land_ramp(land, {field, from, full}, i)
	}
	low_and_level := ramp(land, i, .Elevation, 0.22, 0.12) * ramp(land, i, .Unevenness, 0.08, 0.03)
	delta := ramp(land, i, .To_River, 6, 2) * ramp(land, i, .To_Sea, 16, 6)
	suits := [Cover]f32 {
		.Open    = 1.0 / 6,
		.Forest  = ramp(land, i, .Trees, 0.05, 0.75),
		.Desert  = ramp(land, i, .Moisture, 0.47, 0.35),
		.Steppe  = ramp(land, i, .Moisture, 0.40, 0.47) * ramp(land, i, .Moisture, 0.58, 0.48),
		.Fertile = 1.3 * ramp(land, i, .Moisture, 0.62, 0.52) * ramp(land, i, .To_River, 5, 1.5),
		.Marsh   = 1.5 * low_and_level * max(delta, ramp(land, i, .Moisture, 0.80, 0.88)),
	}
	best_suits: f32
	for s, cover in suits {
		if s > best_suits do best, best_suits = {cover, u8(clamp(s, 0, 1) * f32(max(u8)) + 0.5)}, s
	}
	if best.cover == .Open do best.strength = 0
	return
}

// Scatters every family's marks over the terrain, each family on its own jittered lattice.
land_scatter_marks :: proc(land: ^Land) {
	WORLD.mark_count = 0
	scatter: for def, family in MARK_FAMILIES {
		spacing := max(def.spacing, 0.3)
		rows := int(f32(WORLD_HEIGHT) / (spacing * 0.8))
		cols := int(f32(WORLD_WIDTH) / spacing)
		stream := u32(family) * 8
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// Every other row is shifted half a step, and every point wanders within its step.
				x :=
					(f32(col) + 0.5 + f32(row % 2) * 0.5 + (world_random(col, row, stream) - 0.5) * 0.7) *
					spacing
				y := (f32(row) + 0.5 + (world_random(col, row, stream + 1) - 0.5) * 0.6) * spacing * 0.8
				cx, cy := int(x), int(y)
				if cx < 0 || cy < 0 || cx >= WORLD_WIDTH || cy >= WORLD_HEIGHT do continue
				i := cy * WORLD_WIDTH + cx
				cover := WORLD.cover[i]

				chance := land_rule(land, def.rule, i)
				if def.from_cover {
					chance *= COVERS[cover.cover].marks[family] * f32(cover.strength) / f32(max(u8))
				}
				if chance <= 0 || world_random(col, row, stream + 5) >= chance do continue

				width := def.width * (1 + def.vary * (2 * world_random(col, row, stream + 2) - 1))
				if def.grow != 0 do width *= 1 + def.grow * land_ramp(land, def.grow_by, i)
				if def.avoid_rivers {
					// From the mark to the river nearest its cell
					offset := WORLD.render_terrain.river[i] - ([2]f32{x, y} - [2]f32{f32(cx), f32(cy)} - 0.5)
					if linalg.length(offset) < width * 0.6 do continue
				}
				alpha: f32 = 1
				if def.fades {
					alpha = land_ramp(land, def.fade, i)
					if alpha < 0.08 do continue
				}
				sprite, ok := land_pick_member(land, def.members, cover.cover, i, world_random(col, row, stream + 6))
				if !ok do continue

				// A full table keeps what it has; the marks are still sorted below.
				if WORLD.mark_count == MARKS_MAX do break scatter
				WORLD.marks[WORLD.mark_count] = {
					pos     = {x, y},
					width   = width,
					mark    = sprite,
					variant = u8(world_random(col, row, stream + 3) * f32(world_mark_variants(sprite))),
					alpha   = u8(alpha * f32(max(u8))),
				}
				WORLD.mark_count += 1
			}
		}
	}
	slice.sort_by(WORLD.marks[:WORLD.mark_count], proc(a, b: Mark) -> bool {return a.pos.y < b.pos.y})
}

// One of members for cell i, with chances in proportion to how well each suits it; roll is from 0 to 1.
@(private = "file")
land_pick_member :: proc(
	land: ^Land,
	members: []Mark_Member,
	cover: Cover,
	i: int,
	roll: f32,
) -> (
	sprite: Terrain_Mark,
	ok: bool,
) {
	suits: [8]f32
	assert(len(members) <= len(suits))
	total: f32
	for member, k in members {
		if member.covers != {} && cover not_in member.covers do continue
		suits[k] = land_rule(land, member.rule, i) * member.weight
		total += suits[k]
	}
	if total <= 0 do return
	left := roll * total
	for member, k in members {
		if suits[k] <= 0 do continue
		sprite, ok = member.sprite, true
		left -= suits[k]
		if left < 0 do break
	}
	return
}
