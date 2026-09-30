#+private
package game

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../gfx"
import "../sim"
import "../span"

// Map -----------------------------------------------------------------------------------------------------------------
// Map: what the map is drawn from, and how it keeps in step with the world

// The map's paper, and the ink it is drawn in, which pawns and their names are drawn in too
MAP_PAPER :: [4]f32{0.840, 0.772, 0.620, 1}
MAP_INK :: [4]f32{0.150, 0.105, 0.070, 1}

// What the map is drawn from: everything worked out from the scene's ground for the map pass and the marks over it
@(private = "file")
MAP_DRAW: struct {
	// The drawings scattered over the terrain
	marks:          Map_Marks,
	// What the map pass draws
	render_terrain: gfx.Render_Terrain,
	render_list:    gfx.Render_List,
	// The revision of each of the scene's areas its highlight was last taken from
	area_revisions: [sim.AREAS_MAX]u64,
}

// Sets how the map is drawn and defines the marks' images, so call this before sprites_load.
map_draw_init :: proc() {
	marks_init(&MAP_DRAW.marks)

	MAP_DRAW.render_terrain.style = {
		paper              = MAP_PAPER,
		paper_stain        = {0.720, 0.620, 0.460, 1},
		paper_stain_amount = 0.50,
		ink                = MAP_INK,
		sea_shallow        = {0.560, 0.610, 0.620, 1},
		sea_deep           = {0.200, 0.330, 0.480, 1},
		sea_depth_from     = 0,
		sea_depth_full     = 80,
		sea_tint           = 0.55,
		coast_width        = 1.6,
		wobble             = 0.3,
		river_width        = 12.,
		road_width         = 8,
		road_stroke        = 1.1,
		road_fill          = {0.950, 0.840, 0.660, 0.55},
		arrow_width        = 5,
		arrow_fill         = {0.700, 0.250, 0.160, 1},
		head_length        = 7.5,
		head_width         = 6.25,
	}
	MAP_DRAW.render_terrain.cover.jitter = 0.8
}

// Named in the order of gfx.Render_Terrain_Debug
@(private = "file")
TERRAIN_VIEW_NAMES := []string{"Map", "Surface", "Elevation", "Trees", "Moisture", "Cover"}

// Keeps the map's drawing in step with the scene: the camera every frame, everything drawn from the ground when it
// changes, the arrows every frame, the areas when they change, and the marks in view every frame.
map_draw_tick :: proc(scene: ^sim.Scene, camera: Camera, viewport: [2]f32, pixel_density: f32) {
	rt := &MAP_DRAW.render_terrain
	rt.center, rt.zoom = camera.center, camera.zoom
	if rt.revision != scene.ground_revision {
		rt.revision = scene.ground_revision
		map_derive(scene.ground[:])
	}
	map_arrows(scene)
	map_areas(scene)
	marks_draw(&MAP_DRAW.marks, &MAP_DRAW.render_list, camera, viewport, pixel_density)
}

// Draws the map: the terrain, then the marks over it
map_draw_render :: proc(renderer: ^gfx.Renderer) {
	gfx.render_terrain(renderer, &MAP_DRAW.render_terrain)
	gfx.render_list(renderer, &MAP_DRAW.render_list)
}

// Steps the map to its next view: the map itself, then each raw terrain property in turn
map_draw_next_view :: proc() {
	debug := &MAP_DRAW.render_terrain.debug_mode
	debug^ = gfx.Render_Terrain_Debug((int(debug^) + 1) % len(gfx.Render_Terrain_Debug))
}

// Works out everything the map draws from the terrain, stage by stage: its cells, its ways, its coast, the land's
// terrain types, and the marks over it.
@(private = "file")
map_derive :: proc(terrain: []sim.Ground) {
	rt := &MAP_DRAW.render_terrain
	for cell, i in terrain {
		rt.cells[i] = {u8(cell.surface) * 127, cell.elevation, cell.trees, cell.moisture}
	}

	// Each kind of way, drawn as its kind of line, and stamped around its lines so each cell near one learns the offset
	// from its middle to its nearest point: from which it preclaims the ground along it.
	claimed := make([]u8, FOOTPRINT_SIZE.x * FOOTPRINT_SIZE.y, context.temp_allocator)
	to_way := make([][2]f32, sim.CELLS_MAX, context.temp_allocator)
	for look in WAY_LOOKS {
		lines := &rt.lines[look.line]
		clear(&lines.segments)
		lines.revision += 1
	}
	for kind in sim.Way_Kind {
		for &offset in to_way do offset = WAY_REACH
		for way in WAYS.ways {
			if way.kind != kind do continue
			line := way_line(way)
			lines_add(&rt.lines[WAY_LOOKS[kind].line], line, false)
			polyline_stamp(line, WAY_REACH, to_way, nil)
		}
		ways_claim_ground(claimed, to_way, WAY_LOOKS[kind].band)
	}

	// The coasts, the boundaries of the land, traced into smoothed lines, then stamped around themselves: each cell near
	// the coast learns the offset to it, and which side of it it lies on.
	to_coast := make([][2]f32, sim.CELLS_MAX, context.temp_allocator)
	coast_side := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	for &offset in to_coast do offset = COAST_REACH
	is_land := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain do is_land[i] = cell.surface not_in sim.WATER
	polylines_clear()
	trace_boundaries(is_land, COAST_SMOOTHING)
	for r in 0 ..< polylines_count() {
		line := polylines_get(r)
		polyline_stamp(line, COAST_REACH, to_coast, coast_side)
	}

	// Signed distance to the coast, in cells, positive on land: to the smoothed coast near it, and farther out from
	// cell to cell, half a cell at the cells either side of the coast, the two blending over the last cell of reach.
	to_water := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	to_land := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	distance_to(to_water, terrain, true)
	distance_to(to_land, terrain, false)
	for cell, i in terrain {
		water := cell.surface in sim.WATER
		far := water ? -(to_land[i] - 0.5) : to_water[i] - 0.5
		near := linalg.length(to_coast[i])
		// Away from the line, the cell itself says which side it is on.
		if near > 1 do coast_side[i] = water ? -1 : 1
		rt.coast[i] = math.lerp(
			coast_side[i] * near,
			far,
			math.smoothstep(COAST_REACH - 1, COAST_REACH, near),
		)
	}

	// The water near the shore, preclaimed so no mark's drawing spills into it
	preclaim_coast_water(claimed, rt.coast[:], COAST_WATER_BAND)

	// The terrain types, drawn as the cover layer, and the marks over the land
	cover_draw(&rt.cover, terrain)
	marks_place(&MAP_DRAW.marks, terrain, rt.coast[:], claimed)
}

// Adds a line to be drawn among lines, as its segments, ending in a head if head
@(private = "file")
lines_add :: proc(lines: ^gfx.Render_Lines, line: Polyline, head: bool) {
	points := len(line.points)
	segments := line.closed ? points : points - 1
	for s in 0 ..< segments {
		append(
			&lines.segments,
			gfx.Render_Segment {
				start = line.points[s],
				end = line.points[(s + 1) % points],
				head = b32(head && s == segments - 1),
			},
		)
	}
}

// Arrows --------------------------------------------------------------------------------------------------------------
// Arrows: lines over the map along the way something is going, ending in a head where it is going to

// Draws the scene's arrows over the map, each through its points as given, in cells, its head at the last
@(private = "file")
map_arrows :: proc(scene: ^sim.Scene) {
	arrows := &MAP_DRAW.render_terrain.lines[.Arrow]
	clear(&arrows.segments)
	arrows.revision += 1
	for arrow in scene.arrows {
		lines_add(arrows, {points = scene.arrow_points[arrow.begin:][:arrow.len]}, true)
	}
}

// Highlights ----------------------------------------------------------------------------------------------------------
// Highlights: areas of cells washed in color over the map

// How a look of the scene's areas is drawn: its highlight's colour, border, thickness and inside, and how far, in
// cells, the thin parts of its cells are widened: see area_widen. Widening draws cells the area does not hold, so
// areas that must meet others edge to edge, such as provinces, keep it 0 and are drawn as their cells are.
@(private = "file")
Area_Look :: struct {
	color:     [4]f32,
	border:    f32,
	thickness: f32,
	inside:    f32,
	widen:     int,
}

// How each look of the scene's areas is drawn: the numbers are the ones sim's present hands out. A look not set here
// is not seen. Reaches are widened, so a reach along a road reads as a band rather than a thread.
@(private = "file")
AREA_LOOKS := [256]Area_Look {
	1 = {color = {0.300, 0.450, 0.650, 1}, border = 0.6, thickness = 2, inside = 0.2, widen = 1},
	2 = {color = {0.700, 0.250, 0.160, 1}, border = 0.6, thickness = 2, inside = 0.2},
	3 = {color = {0.450, 0.420, 0.380, 1}, border = 0.6, thickness = 2, inside = 0.2, widen = 1},
	4 = {color = {0.850, 0.700, 0.200, 1}, border = 0.6, thickness = 2, inside = 0.2},
}

// Highlights the scene's areas, each slot as the highlight area after it: its look and circles every tick, its cells
// taken up again only when its revision is not the one last taken up
@(private = "file")
map_areas :: proc(scene: ^sim.Scene) {
	#assert(sim.AREAS_MAX < gfx.RENDER_HIGHLIGHT_AREAS)
	#assert(sim.CIRCLES_MAX <= gfx.RENDER_HIGHLIGHT_CIRCLES_MAX)
	highlights := &MAP_DRAW.render_terrain.highlights
	clear(&highlights.circles)
	for &area, slot in scene.areas {
		highlight := u8(slot + 1)
		look := AREA_LOOKS[area.look]
		drawn := &highlights.areas[highlight]
		drawn.color = look.color
		drawn.border = look.border
		drawn.thickness = look.thickness
		drawn.inside = look.inside
		drawn.surface = area.on_water ? .Water : .Land
		for circle in scene.circles[area.circles.begin:][:area.circles.len] {
			append(
				&highlights.circles,
				gfx.Render_Highlight_Circle{circle.center, circle.radius, highlight},
			)
		}
		if MAP_DRAW.area_revisions[slot] == area.revision do continue
		MAP_DRAW.area_revisions[slot] = area.revision
		gfx.render_highlight_clear(highlights, highlight)
		cells := area.cells[:]
		if look.widen > 0 do cells = area_widen(cells, look.widen)
		for inside, i in cells {
			if !inside do continue
			cell := area.corner + {i % sim.AREA_SIZE, i / sim.AREA_SIZE}
			if cell.x < 0 || cell.y < 0 || cell.x >= sim.WORLD_WIDTH || cell.y >= sim.WORLD_HEIGHT do continue
			// A cell only the widening adds is left to any other area it is in.
			owner := highlights.cells[cell.y * sim.WORLD_WIDTH + cell.x]
			if !area.cells[i] && owner != 0 && owner != highlight do continue
			gfx.render_highlight_add(highlights, highlight, cell)
		}
	}
}

// How many cells of an area the disc around a cell must hold for the cell to join its thin parts: as many as a
// straight thread of cells puts in it, however far out along the disc's edge the cell lies
@(private = "file")
WIDEN_SUPPORT :: 3

// An area's cells, AREA_SIZE square, with its thin parts widened, in the temp allocator. Its thin parts are what an
// opening by a disc of radius widen takes away: whatever is narrower than about twice widen plus one cell. A cell joins
// the area where the disc around it touches a thin part and holds at least WIDEN_SUPPORT of the area's cells: beside
// a thin part, so a thread of cells becomes a band, but not past its ends, nor around a lone cell or two, which stay as
// they are. Off the square counts as out of the area.
@(private = "file")
area_widen :: proc(cells: []bool, widen: int) -> []bool {
	// The cells covered by the disc, as offsets from its middle cell
	disc := make([dynamic][2]int, context.temp_allocator)
	for dy in -widen ..= widen {
		for dx in -widen ..= widen {
			if dx * dx + dy * dy <= widen * widen + widen do append(&disc, [2]int{dx, dy})
		}
	}
	// Each cell is in if the disc around it holds at least need cells of from: with 1 from grows, with the whole disc
	// it shrinks.
	morph :: proc(from: []bool, disc: [][2]int, need: int) -> []bool {
		to := make([]bool, len(from), context.temp_allocator)
		for y in 0 ..< sim.AREA_SIZE {
			for x in 0 ..< sim.AREA_SIZE {
				held := 0
				for offset in disc {
					at := [2]int{x, y} + offset
					if at.x < 0 || at.y < 0 || at.x >= sim.AREA_SIZE || at.y >= sim.AREA_SIZE do continue
					if from[at.y * sim.AREA_SIZE + at.x] do held += 1
				}
				to[y * sim.AREA_SIZE + x] = held >= need
			}
		}
		return to
	}
	opened := morph(morph(cells, disc[:], len(disc)), disc[:], 1)
	thin := make([]bool, len(cells), context.temp_allocator)
	for inside, i in cells do thin[i] = inside && !opened[i]
	near_thin := morph(thin, disc[:], 1)
	widened := morph(cells, disc[:], WIDEN_SUPPORT)
	for &inside, i in widened do inside = cells[i] || (inside && near_thin[i])
	return widened
}

// Cover ---------------------------------------------------------------------------------------------------------------
// Cover: each land cell's terrain type, drawn as the cover layer and read by the marks

@(private = "file", rodata)
COVER_SAND := [4]f32{0.900, 0.800, 0.600, 1}

// How each terrain type is drawn
@(private = "file")
COVER_LOOKS := [sim.Terrain_Type]gfx.Render_Layer_Palette {
	.Open = {},
	.Forest = {color = {0.600, 0.640, 0.470, 1}, wash = 0.45},
	.Desert = {color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
	.Steppe = {color = COVER_SAND, wash = 0.25},
	.Fertile = {color = {0.720, 0.740, 0.540, 1}, wash = 0.7},
	.Marsh = {color = {0.580, 0.640, 0.640, 1}, wash = 0.5},
	.Highland = {color = {0.740, 0.620, 0.460, 1}, wash = 0.35},
	.Mountains = {color = {0.700, 0.580, 0.420, 1}, wash = 0.45},
	.Fields = {color = {0.790, 0.770, 0.600, 1}, wash = 0.35},
}

// Hands the terrain types to layer to draw.
@(private = "file")
cover_draw :: proc(layer: ^gfx.Render_Layer, terrain: []sim.Ground) {
	for cell, i in terrain do layer.cells[i] = {u8(cell.type), cell.type_strength}
	for look, type in COVER_LOOKS do layer.palette[type] = look
	layer.revision += 1
}

// Ways ----------------------------------------------------------------------------------------------------------------
// Ways: rivers and roads, drawn from their lines: see Way

// How far around the ways the offset to them is kept, in cells: enough for the ground they claim
@(private = "file")
WAY_REACH :: f32(4)

// How each kind of way is drawn: how far either side of its lines, in cells, it claims ground that no mark's drawing
// may cover, and the kind of line it is drawn as
@(private = "file")
Way_Look :: struct {
	band: f32,
	line: gfx.Render_Line_Kind,
}

@(private = "file", rodata)
WAY_LOOKS := [sim.Way_Kind]Way_Look {
	.River = {band = 1.0, line = .River},
	.Road = {band = 1.2, line = .Road},
}

// Preclaims the ground within band of the ways: each square of claimed ground whose middle lies within band of the
// nearest point of a way. to_way holds, for each cell, the offset from its middle to the nearest point of a way.
@(private = "file")
ways_claim_ground :: proc(claimed: []u8, to_way: [][2]f32, band: f32) {
	for offset, i in to_way {
		if linalg.length(offset) > band + 1 do continue
		cell := [2]int{i % sim.WORLD_WIDTH, i / sim.WORLD_WIDTH}
		way := [2]f32{f32(cell.x), f32(cell.y)} + 0.5 + offset
		for y in 0 ..< FOOTPRINT_RES {
			for x in 0 ..< FOOTPRINT_RES {
				square := cell * FOOTPRINT_RES + {x, y}
				middle := ([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES
				if linalg.length(middle - way) >= band do continue
				claimed[square.y * FOOTPRINT_SIZE.x + square.x] = PRECLAIMED
			}
		}
	}
}

// Coasts --------------------------------------------------------------------------------------------------------------
// Coasts: the boundaries of the land, traced into lines, and the distances across land and water

// How far around the coast its smoothed line decides the distance to it, in cells
@(private = "file")
COAST_REACH :: f32(3)

// Coasts keep more of their shape, losing mostly the steps of the cells.
@(private = "file")
COAST_SMOOTHING :: Polyline_Smoothing {
	softness  = 0.3,
	cut_iter  = 2,
	cut_ratio = 0.2,
}

// Traces the boundaries of the cells inside: the edges between inside and outside cells, joined corner to corner into
// lines with the inside on their left. A boundary that runs off the map ends there; the rest close.
@(private = "file")
trace_boundaries :: proc(inside: []bool, smoothing: Polyline_Smoothing) {
	// Corners are numbered y * ACROSS + x. Each holds the steps its edges leave it by: two only where inside and outside
	// meet across it.
	ACROSS :: sim.WORLD_WIDTH + 1
	out := make([]bit_set[Step], ACROSS * (sim.WORLD_HEIGHT + 1), context.temp_allocator)
	for y in 0 ..< sim.WORLD_HEIGHT {
		for x in 0 ..< sim.WORLD_WIDTH {
			i := y * sim.WORLD_WIDTH + x
			if !inside[i] do continue
			if y > 0 && !inside[i - sim.WORLD_WIDTH] do out[y * ACROSS + x + 1] += {.West}
			if y < sim.WORLD_HEIGHT - 1 && !inside[i + sim.WORLD_WIDTH] do out[(y + 1) * ACROSS + x] += {.East}
			if x > 0 && !inside[i - 1] do out[y * ACROSS + x] += {.South}
			if x < sim.WORLD_WIDTH - 1 && !inside[i + 1] do out[(y + 1) * ACROSS + x + 1] += {.North}
		}
	}

	// Walks from a corner along the edges not yet walked, until it comes back round or runs off the map; where two edges
	// leave a corner, it turns left.
	walk :: proc(out: []bit_set[Step], start: [2]int, smoothing: Polyline_Smoothing) {
		at, heading, moved := start, Step.East, false
		for {
			if moved && at == start {
				polylines_end(true, smoothing)
				return
			}
			edges := &out[at.y * ACROSS + at.x]
			if edges^ == {} {
				polylines_add({f32(at.x), f32(at.y)})
				polylines_end(false, smoothing)
				return
			}
			step := Step((int(heading) + 3) % 4)
			if !moved || step not_in edges^ do for s in Step do if s in edges^ {step = s; break}
			edges^ -= {step}
			polylines_add({f32(at.x), f32(at.y)})
			at += STEPS[step]
			heading, moved = step, true
		}
	}
	// Boundaries that run off the map first, from where they leave its edge, then the closed ones
	for x in 0 ..= sim.WORLD_WIDTH {
		for y in ([2]int{0, sim.WORLD_HEIGHT}) do if out[y * ACROSS + x] != {} do walk(out, {x, y}, smoothing)
	}
	for y in 0 ..= sim.WORLD_HEIGHT {
		for x in ([2]int{0, sim.WORLD_WIDTH}) do if out[y * ACROSS + x] != {} do walk(out, {x, y}, smoothing)
	}
	for c in 0 ..< len(out) {
		for out[c] != {} do walk(out, {c % ACROSS, c / ACROSS}, smoothing)
	}
}

// The steps along the edges between cells, turning clockwise with y down the map
@(private = "file")
Step :: enum {
	East,
	South,
	West,
	North,
}

@(private = "file", rodata)
STEPS := [Step][2]int {
	.East  = {1, 0},
	.South = {0, 1},
	.West  = {-1, 0},
	.North = {0, -1},
}

// Euclidean distance from every cell to the nearest cell whose water matches.
@(private = "file")
distance_to :: proc(out: []f32, terrain: []sim.Ground, water: bool) {
	source := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain do source[i] = (cell.surface in sim.WATER) == water
	distance_from(out, source, sim.WORLD_SIZE)
}

// How far out from the shore, in cells, the water is preclaimed
@(private = "file")
COAST_WATER_BAND :: f32(3)

// Preclaims the water within reach of the shore: each square of claimed ground where coast, the signed distance to the
// coast, blended between cells, is below 0 and above -reach.
@(private = "file")
preclaim_coast_water :: proc(claimed: []u8, coast: []f32, reach: f32) {
	for distance, i in coast {
		// A distance changes by at most as far as its point moves, so only cells this near the strip have squares in it.
		if distance >= 1 || distance <= -reach - 1 do continue
		cell := [2]int{i % sim.WORLD_WIDTH, i / sim.WORLD_WIDTH}
		for y in 0 ..< FOOTPRINT_RES {
			for x in 0 ..< FOOTPRINT_RES {
				square := cell * FOOTPRINT_RES + {x, y}
				at := bilinear(
					coast,
					sim.WORLD_SIZE,
					([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES,
				)
				if at < 0 && at > -reach do claimed[square.y * FOOTPRINT_SIZE.x + square.x] = PRECLAIMED
			}
		}
	}
}

// Marks ---------------------------------------------------------------------------------------------------------------
// The marks: drawings scattered over the map, laid layer by layer, each layer on a jittered grid of points over the
// world. At a point, every marking of the layer scores how densely it grows there, by whether the cell's distance to
// the coast, elevation and temperature are in its ranges, and by its terrain type; the point keeps a mark with the sum
// of the scores as its chance, and the mark is one of the markings, picked in proportion to its score.

// Ground where no mark may stand, kept FOOTPRINT_RES squares to a cell each way, row by row. Each square holds who
// claimed it first: 0 for none, PRECLAIMED for what claims it before any mark is placed, such as the ways, and a
// layer's number plus 2 for its marks. No mark's drawing may cover preclaimed ground.
@(private = "file")
FOOTPRINT_RES :: 4
@(private = "file")
FOOTPRINT_SIZE :: [2]int{sim.WORLD_WIDTH * FOOTPRINT_RES, sim.WORLD_HEIGHT * FOOTPRINT_RES}
@(private = "file")
PRECLAIMED :: 1

// How much of its width, about its middle, a mark's drawing covers, as far as keeping it off preclaimed ground
@(private = "file")
MARK_DRAWN_WIDTH :: 0.7

// The square of claimed ground a point, in cells, lies in
@(private = "file")
footprint_square :: proc(p: [2]f32) -> [2]int {
	return {int(p.x * FOOTPRINT_RES), int(p.y * FOOTPRINT_RES)}
}

@(private = "file")
Map_Marks :: struct {
	// The marks laid, by where they stand, top to bottom, so nearer marks overlap farther ones
	marks:    [dynamic; MARKS_MAX]Mark,
	// Each marking's images, by variant, defined by marks_init: the first variants[marking] of them. Marks name their
	// image by marking and variant, so what ids the images were given does not matter to them.
	images:   [len(MARKINGS)][VARIANTS_MAX]gfx.Image_Id,
	variants: [len(MARKINGS)]u8,
}

// Enough marks for a full world at the densities of MARKINGS
@(private = "file")
MARKS_MAX :: 1 << 17

// One drawing on the map: where its middle sits, in cells, the layer it was laid in, and how wide and tall it is, in
// cells.
@(private = "file")
Mark :: struct {
	pos:     [2]f32,
	layer:   Layer,
	width:   f32,
	// Given by its image's proportions once its width is set
	height:  f32,
	// Its drawing: the marking's variant-th image
	marking: u8,
	variant: u8,
	// Opacity, up to max(u8)
	alpha:   u8,
}

#assert(
	len(MARKINGS) <= 256 && VARIANTS_MAX <= 256,
	"a mark names its marking and variant in a byte each",
)

// The layers of marks, in the order they are laid: each claims its ground from those after it
@(private = "file")
Layer :: enum {
	Mountain,
	Molehill,
	Tree,
	Tuft,
	Marsh,
	Dune,
	Sea,
}

// How a layer lays its marks. Its points are spacing cells apart across and row_squash of that down, every other row
// shifted half a step; each wanders within its step by up to jitter of it, across and down. A mark is width cells wide,
// varying by up to vary of that either way. It claims footprint of ground as it is laid: no mark of a later layer
// stands there, nor, if claims_own, a later mark of its own layer.
@(private = "file")
Layer_Def :: struct {
	spacing:    f32,
	row_squash: f32,
	jitter:     [2]f32,
	width:      f32,
	vary:       f32,
	footprint:  struct {
		width: f32,
		below: f32,
	},
	claims_own: bool,
}

@(private = "file", rodata)
LAYERS := [Layer]Layer_Def {
	// Mountains keep to their rows, so the peak behind always shows clear over the one in front.
	.Mountain = {
		spacing = 8.04,
		row_squash = 0.8,
		jitter = {0.6, 0.15},
		width = 4.7,
		vary = 0.2,
		footprint = {width = 0.5, below = 0.45},
		claims_own = true,
	},
	.Molehill = {
		spacing = 3.84,
		row_squash = 0.8,
		jitter = {0.7, 0.6},
		width = 3.29,
		vary = 0.2,
		footprint = {width = 0.525, below = 0.5},
		claims_own = true,
	},
	.Tree = {
		spacing = 2.1,
		row_squash = 0.8,
		jitter = {0.7, 0.6},
		width = 1.6,
		vary = 0.3,
		footprint = {width = 0.7},
	},
	.Tuft = {spacing = 3.8, row_squash = 0.8, jitter = {0.7, 0.6}, width = 1.3, vary = 0.2},
	.Marsh = {spacing = 3.2, row_squash = 0.8, jitter = {0.7, 0.6}, width = 2.3, vary = 0.15},
	.Dune = {spacing = 5.5, row_squash = 0.8, jitter = {0.7, 0.6}, width = 3.4, vary = 0.2},
	.Sea = {spacing = 12, row_squash = 0.8, jitter = {0.7, 0.6}, width = 3},
}

// A kind of mark: its images, under assets/gfx, the layer it is laid in, and where it grows. Each mark is one of the
// images, the named ones first; an empty name is an image it does not have. It grows where the cell's signed distance
// to the coast, elevation and temperature are in its ranges, as densely as its cover says of the cell's terrain type
// times the type's strength, or fully if it names none. Its width grows by grow times how far up its elevation range the
// cell is, and its opacity follows fade over the signed distance to the coast; an unset fade is opaque.
@(private = "file")
Marking :: struct {
	images:      [VARIANTS_MAX]string,
	layer:       Layer,
	coast:       Range,
	elevation:   Range,
	temperature: Range,
	cover:       [sim.Terrain_Type]f32,
	grow:        f32,
	fade:        Ramp,
}

// From lo up to hi. A range whose ends meet is any value.
@(private = "file")
Range :: struct {
	lo, hi: f32,
}

// On land, a cell or more from the shore, and out at sea, five cells or more
@(private = "file")
ON_LAND :: Range{1, 1000}

@(private = "file")
OFFSHORE :: Range{-1000, -5}

// How far either way, at most, a point's distance to the coast, elevation and temperature are read off, so that
// neighbouring ranges mix at their edges instead of meeting at a line
@(private = "file")
BLUR := [3]f32{1, 0.1, 0.1}

// Each marking has up to this many images, so the scatter does not look stamped
@(private = "file")
VARIANTS_MAX :: 4

// The trees' covers: forests, and fertile land more thinly
@(private = "file")
TREE_COVER :: #partial [sim.Terrain_Type]f32 {
	.Forest  = 1,
	.Fertile = 0.45,
}

@(private = "file", rodata)
MARKINGS := [?]Marking {
	{
		images = {
			"terrain/mountain_0",
			"terrain/mountain_1",
			"terrain/mountain_2",
			"terrain/mountain_3",
		},
		layer = .Mountain,
		coast = ON_LAND,
		elevation = {0.7, 1.1},
		cover = #partial{.Mountains = 1},
		grow = 0.55,
	},
	{
		images = {"terrain/hill_0", "terrain/hill_1", "terrain/hill_2", "terrain/hill_3"},
		layer = .Molehill,
		coast = ON_LAND,
		elevation = {0.6, 0.85},
	},
	{
		images = {
			"terrain/conifer_0",
			"terrain/conifer_1",
			"terrain/conifer_2",
			"terrain/conifer_3",
		},
		layer = .Tree,
		coast = ON_LAND,
		temperature = {-0.08, 0.02},
		cover = TREE_COVER,
	},
	{
		images = {
			"terrain/broadleaf_0",
			"terrain/broadleaf_1",
			"terrain/broadleaf_2",
			"terrain/broadleaf_3",
		},
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.02, 0.34},
		cover = TREE_COVER,
	},
	{
		images = {
			"terrain/cypress_0",
			"terrain/cypress_1",
			"terrain/cypress_2",
			"terrain/cypress_3",
		},
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.34, 0.5},
		cover = TREE_COVER,
	},
	// Palms only on fertile land
	{
		images = {"terrain/palm_0", "terrain/palm_1", "terrain/palm_2", "terrain/palm_3"},
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.5, 10},
		cover = #partial{.Fertile = 0.45},
	},
	{
		images = {"terrain/tuft_0", "terrain/tuft_1", "terrain/tuft_2", "terrain/tuft_3"},
		layer = .Tuft,
		coast = ON_LAND,
		cover = #partial{.Steppe = 1},
	},
	{
		images = {"terrain/marsh_0", "terrain/marsh_1", "terrain/marsh_2", "terrain/marsh_3"},
		layer = .Marsh,
		coast = ON_LAND,
		cover = #partial{.Marsh = 1},
	},
	{
		images = {"terrain/dune_0", "terrain/dune_1", "terrain/dune_2", "terrain/dune_3"},
		layer = .Dune,
		coast = ON_LAND,
		cover = #partial{.Desert = 1},
	},
	// Fading over the open sea
	{
		images = {"terrain/sea_0", "terrain/sea_1", "", ""},
		layer = .Sea,
		coast = OFFSHORE,
		fade = {-19, -5},
	},
}

// Defines the markings' images, so call this before sprites_load.
@(private = "file")
marks_init :: proc(mm: ^Map_Marks) {
	for marking, k in MARKINGS {
		for name, variant in marking.images {
			if name == "" do break
			mm.images[k][variant] = gfx.sprites_image_add(name)
			mm.variants[k] += 1
		}
	}
}

// Lays the marks over the terrain, in three passes: every layer's grid points, scored; a candidate mark at each point
// that keeps one; and, in order, each candidate that fits, stamping its footprint. coast is for every cell: the signed
// distance to the coast. claimed holds the preclaimed ground: see FOOTPRINT_RES. Call after sprites_load: marks take
// their images' proportions.
@(private = "file")
marks_place :: proc(mm: ^Map_Marks, terrain: []sim.Ground, coast: []f32, claimed: []u8) {
	// Each layer has sixteen random streams, one for each use at a point.
	stream :: proc(layer: Layer, use: u32) -> u32 {return u32(layer) * 16 + use}
	// Where a mark stands, in cells down the map: its drawing's bottom edge
	mark_foot :: proc(mark: Mark) -> f32 {return mark.pos.y + mark.height / 2}
	// A point of a layer's grid, col across and row down, where it lies, in cells, the cell it lies in, and how densely
	// each marking grows there, 0 for the markings of other layers
	Point :: struct {
		layer:    Layer,
		col, row: int,
		pos:      [2]f32,
		cell:     int,
		scores:   [len(MARKINGS)]f32,
	}

	// Each marking's variants' height over width, as their images were loaded; 0 where an image is missing. The marks
	// read their images only through this, so they depend on the images' proportions, not on their ids.
	aspects := make([][VARIANTS_MAX]f32, len(MARKINGS), context.temp_allocator)
	for &variants, m in aspects {
		for &aspect, v in variants[:mm.variants[m]] {
			source := gfx.sprite_region(gfx.sprite_of_image(mm.images[m][v])).source
			if source.z > 0 do aspect = source.w / source.z
		}
	}

	// Every layer's grid points that lie in the world, each with every marking's score there
	points := make([dynamic]Point, context.temp_allocator)
	for def, layer in LAYERS {
		step := [2]f32{def.spacing, def.spacing * def.row_squash}
		cols, rows := int(sim.WORLD_WIDTH / step.x), int(sim.WORLD_HEIGHT / step.y)
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// The middle of its step, every other row shifted half a step across, wandering within its step
				wander :=
					[2]f32 {
						random_xy(col, row, stream(layer, 0)),
						random_xy(col, row, stream(layer, 1)),
					} -
					0.5
				shift := [2]f32{f32(row % 2) * 0.5, 0}
				pos := ([2]f32{f32(col), f32(row)} + shift + 0.5 + wander * def.jitter) * step
				if pos.x < 0 || pos.y < 0 || pos.x >= sim.WORLD_WIDTH || pos.y >= sim.WORLD_HEIGHT do continue
				point := Point {
					layer = layer,
					col   = col,
					row   = row,
					pos   = pos,
					cell  = int(pos.y) * sim.WORLD_WIDTH + int(pos.x),
				}
				cell := terrain[point.cell]
				elevation := normalized(cell.elevation)
				moisture := normalized(cell.moisture)
				north := 1 - (f32(point.cell / sim.WORLD_WIDTH) + 0.5) / f32(sim.WORLD_HEIGHT)
				temperature := 1 - north - 0.47 * elevation + 0.5 * (0.6 - moisture)
				values := [3]f32{coast[point.cell], elevation, temperature}
				values += (random_xy(col, row, stream(layer, 2)) - 0.5) * 2 * BLUR
				// Each marking of the layer grows where the values are in its ranges: as densely as its cover says of the
				// cell's terrain type, times the type's strength, or fully if it names none.
				here := terrain[point.cell]
				marking: for m, k in MARKINGS {
					if m.layer != layer do continue
					ranges := [3]Range{m.coast, m.elevation, m.temperature}
					for r, q in ranges do if r.lo != r.hi && (values[q] < r.lo || values[q] >= r.hi) do continue marking
					point.scores[k] = 1
					for density in m.cover do if density != 0 {
						point.scores[k] = m.cover[here.type] * normalized(here.type_strength)
						break
					}
				}
				append(&points, point)
			}
		}
	}

	// A candidate mark at each point that keeps one, with the sum of the scores as its chance: one of the markings,
	// picked in proportion to its score
	candidates := make([dynamic]Mark, context.temp_allocator)
	for &point in points {
		col, row, layer := point.col, point.row, point.layer
		total: f32
		for s in point.scores do total += s
		if random_xy(col, row, stream(layer, 3)) >= total do continue
		k, _ := pick_weighted(point.scores[:], random_xy(col, row, stream(layer, 4)))
		marking, def := MARKINGS[k], LAYERS[layer]

		// Markings that grow with elevation are wider the higher up their range the cell is.
		width :=
			def.width *
			math.lerp(1 - def.vary, 1 + def.vary, random_xy(col, row, stream(layer, 5)))
		if marking.grow != 0 {
			band := marking.elevation
			up := (normalized(terrain[point.cell].elevation) - band.lo) / (band.hi - band.lo)
			up = clamp(up, 0, 1)
			width *= 1 + marking.grow * up
		}
		mark := Mark {
			pos     = point.pos,
			layer   = layer,
			width   = width,
			marking = u8(k),
			variant = u8(random_xy(col, row, stream(layer, 6)) * f32(mm.variants[k])),
			alpha   = max(u8),
		}
		if marking.fade.from != marking.fade.full {
			mark.alpha = u8(ramp(marking.fade, coast[point.cell]) * f32(max(u8)))
		}
		// A mark whose image is missing is never drawn, so it is not kept.
		aspect := aspects[mark.marking][mark.variant]
		if aspect <= 0 do continue
		mark.height = width * aspect
		append(&candidates, mark)
	}

	// In order, each candidate that fits: standing on ground nothing before its layer has claimed, nor its own layer if
	// it claims its own, and with no preclaimed ground under its drawing
	clear(&mm.marks)
	candidate: for mark in candidates {
		def := LAYERS[mark.layer]
		foot := footprint_square({mark.pos.x, mark_foot(mark)})
		if foot.y < FOOTPRINT_SIZE.y {
			by := int(claimed[foot.y * FOOTPRINT_SIZE.x + foot.x])
			if by != 0 && (by - 2 < int(mark.layer) || def.claims_own) do continue
		}
		{
			half := mark.width * MARK_DRAWN_WIDTH / 2
			first := footprint_square({mark.pos.x - half, mark_foot(mark) - mark.height})
			last := footprint_square({mark.pos.x + half, mark_foot(mark)})
			for y in max(first.y, 0) ..= min(last.y, FOOTPRINT_SIZE.y - 1) {
				for x in max(first.x, 0) ..= min(last.x, FOOTPRINT_SIZE.x - 1) {
					if claimed[y * FOOTPRINT_SIZE.x + x] == PRECLAIMED do continue candidate
				}
			}
		}
		assert(len(mm.marks) < MARKS_MAX, "more marks than MARKS_MAX")
		append(&mm.marks, mark)

		// Its footprint: width of the mark wide, from the top of its drawing to below of its height in front of it
		if def.footprint == {} do continue
		half := mark.width * def.footprint.width / 2
		first := footprint_square({mark.pos.x - half, mark_foot(mark) - mark.height})
		last := footprint_square(
			{mark.pos.x + half, mark_foot(mark) + def.footprint.below * mark.height},
		)
		for y in max(first.y, 0) ..= min(last.y, FOOTPRINT_SIZE.y - 1) {
			for x in max(first.x, 0) ..= min(last.x, FOOTPRINT_SIZE.x - 1) {
				square := &claimed[y * FOOTPRINT_SIZE.x + x]
				if square^ == 0 do square^ = u8(mark.layer) + 2
			}
		}
	}
	slice.sort_by(mm.marks[:], proc(a, b: Mark) -> bool {return mark_foot(a) < mark_foot(b)})
}

// Fills list with the marks in view. Marks are fixed in the world and scale with the map; marks past the list's room
// are dropped.
@(private = "file")
marks_draw :: proc(
	mm: ^Map_Marks,
	list: ^gfx.Render_List,
	camera: Camera,
	viewport: [2]f32,
	pixel_density: f32,
) {
	draw: gfx.Draw_Ctx
	rect: [4]f32 = {0, 0, viewport.x, viewport.y}
	gfx.draw_begin(&draw, list, span.from_array(&list.instances), rect, pixel_density)
	for mark in mm.marks[:] {
		// The drawing is centred on the mark.
		size := [2]f32{mark.width, mark.height}
		corner := mark.pos - size / 2
		rect: [4]f32 = {corner.x, corner.y, size.x, size.y}
		proj, visible := camera_world_to_screen(camera, viewport, rect)
		if !visible do continue
		image := mm.images[mark.marking][mark.variant]
		gfx.draw_image(&draw, image, proj, {1, 1, 1, normalized(mark.alpha)})
	}
}
