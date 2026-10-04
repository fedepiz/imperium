#+private
package game

import "core:math"
import "core:math/linalg"
import "core:slice"

import "../gfx"
import "../sim"
import "../span"
import "../util"

// Constants -----------------------------------------------------------------------------------------------------------
// Also used for pawns and labels
MAP_PAPER :: [4]f32{0.840, 0.772, 0.620, 1}
MAP_INK :: [4]f32{0.150, 0.105, 0.070, 1}

// In gfx.Render_Terrain_Debug order
@(private = "file")
TERRAIN_VIEW_NAMES := []string{"Map", "Surface", "Elevation", "Trees", "Moisture", "Cover"}

// Indexed by the look ids from sim/present.odin; unset = invisible. Reaches are widened so roads read as bands.
@(private = "file")
AREA_LOOKS := [256]Area_Look {
	// Reach: mostly outline, so zones show through
	1 = {layer = .Reach, color = {0.300, 0.450, 0.650, 1}, border = 0.7, thickness = 1.5, inside = 0.1, widen = 1},
	// Enemy zone
	2 = {layer = .Zones, color = {0.700, 0.250, 0.160, 1}, border = 0.6, thickness = 2, inside = 0.25},
	// Reach of a piece the player doesn't control
	3 = {layer = .Reach, color = {0.450, 0.420, 0.380, 1}, border = 0.7, thickness = 1.5, inside = 0.1, widen = 1},
	// Friendly contact
	4 = {layer = .Contacts, color = {0.850, 0.700, 0.200, 1}, border = 0.6, thickness = 2, inside = 0.2},
}

// Per second, see util.ease_step
@(private = "file")
HIGHLIGHT_EASE :: 10

// Below this zoom (pixels per cell) regions use the Far look
@(private = "file")
REGION_FAR_ZOOM :: 5

@(private = "file")
REGION_LOOKS := [sim.Region_Colouring_Mode][Region_Range]Region_Looks {
	.Owner = {
		.Near = {
			plain = {border = 0.25, thickness = 1.5, inside = 0},
			highlighted = {border = 0.4, thickness = 2.5, inside = 0.02},
		},
		.Far = {
			plain = {border = 0.4, thickness = 3, inside = 0.35},
			highlighted = {border = 0.5, thickness = 3.5, inside = 0.45},
		},
	},
	.Identity = {
		.Near = {
			plain = {border = 0.25, thickness = 1.5, inside = 0},
			highlighted = {border = 0.4, thickness = 2.5, inside = 0.02},
		},
		.Far = {
			plain = {border = 0.25, thickness = 1.5, inside = 0},
			highlighted = {border = 0.4, thickness = 2.5, inside = 0.02},
		},
	},
	.Muted = {
		.Near = {
			plain = {border = 0, thickness = 1, inside = 0},
			highlighted = {border = 0, thickness = 1, inside = 0},
		},
		.Far = {
			plain = {border = 0, thickness = 1, inside = 0},
			highlighted = {border = 0, thickness = 1, inside = 0},
		},
	},
}

AREA_SQUARE :: [2]int{sim.AREA_SIZE, sim.AREA_SIZE}

// Min area cells in the disc for a cell to be added by widening (a straight 1-cell thread gives 3)
@(private = "file")
WIDEN_SUPPORT :: 3

@(private = "file", rodata)
COVER_SAND := [4]f32{0.900, 0.800, 0.600, 1}

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

// Max distance, in cells, for the offset-to-way field
@(private = "file")
WAY_REACH :: f32(4)

@(private = "file", rodata)
WAY_LOOKS := [sim.Way_Kind]Way_Look {
	.River = {band = 1.0, line = .River},
	.Road = {band = 1.2, line = .Road},
}

// Within this many cells, distance comes from the smoothed coast line
@(private = "file")
COAST_REACH :: f32(3)

// Light smoothing: removes cell steps, keeps the shape
@(private = "file")
COAST_SMOOTHING :: util.Smoothing {
	softness    = 0.3,
	soften_iter = 2,
	cut_iter    = 2,
	cut_ratio   = 0.2,
}

// Near-shore water kept free of marks, in cells
@(private = "file")
COAST_WATER_BAND :: f32(3)

// Claim grid: FOOTPRINT_RES squares per cell side. 0 = free, PRECLAIMED = ways/coast (no drawing may cover it),
// layer + 2 = claimed by that layer's marks.
@(private = "file")
FOOTPRINT_RES :: 4

@(private = "file")
FOOTPRINT_SIZE :: [2]int{sim.WORLD_WIDTH * FOOTPRINT_RES, sim.WORLD_HEIGHT * FOOTPRINT_RES}

@(private = "file")
PRECLAIMED :: 1

// Fraction of a mark's width checked against preclaimed ground
@(private = "file")
MARK_DRAWN_WIDTH :: 0.7

// Enough for a full world at MARKINGS densities
@(private = "file")
MARKS_MAX :: 1 << 17

@(private = "file")
VARIANTS_MAX :: 4

// Random offset on coast, elevation, temperature, so neighbouring ranges blend instead of meeting at a line
@(private = "file")
BLUR := [3]f32{1, 0.1, 0.1}

// Coast distance ranges
@(private = "file")
ON_LAND :: Range{1, 1000}

@(private = "file")
OFFSHORE :: Range{-1000, -5}

@(private = "file")
TREE_COVER :: #partial [sim.Terrain_Type]f32 {
	.Forest  = 1,
	.Fertile = 0.45,
}

@(private = "file", rodata)
LAYERS := [Layer]Layer_Def {
	// Low vertical jitter so back peaks stay visible over front ones
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
	{
		images = {"terrain/sea_0", "terrain/sea_1", "", ""},
		layer = .Sea,
		coast = OFFSHORE,
		fade = {-19, -5},
	},
}

// Map -----------------------------------------------------------------------------------------------------------------
@(private = "file")
MAP_DRAW: struct {
	marks:               Map_Marks,
	render_terrain:      gfx.Render_Terrain,
	render_list:         gfx.Render_List,
	// Per scene area: last uploaded revision, and the highlight layer it was last drawn in (if placed)
	area_revisions:      [sim.AREAS_MAX]u64,
	area_layers:         [sim.AREAS_MAX]gfx.Render_Highlight_Layer,
	area_placed:         [sim.AREAS_MAX]bool,
	// Last scene supply_map_revision copied into the overlay
	supply_map_revision: u32,
}

// Call before sprites_load: defines the marks' images.
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
		border_width       = 1.5,
		border_ink         = {0.400, 0.180, 0.120, 0.3},
	}
	MAP_DRAW.render_terrain.cover.jitter = 0.8
}

map_draw_tick :: proc(
	scene: ^sim.Scene,
	region_colouring: sim.Region_Colouring_Mode,
	supply_shown: bool,
	camera: Camera,
	viewport: [2]f32,
	pixel_density: f32,
	dt: f32,
) {
	rt := &MAP_DRAW.render_terrain
	rt.center, rt.zoom = camera.center, camera.zoom
	rt.overlay_shown = supply_shown
	if MAP_DRAW.supply_map_revision != scene.supply_map_revision {
		MAP_DRAW.supply_map_revision = scene.supply_map_revision
		for value, i in scene.supply_map do rt.overlay[i] = util.to_u8(f32(value) / 100)
		rt.overlay_revision += 1
	}
	if rt.revision != scene.ground_revision {
		rt.revision = scene.ground_revision
		map_derive(scene.ground[:])
	}
	map_arrows(scene)
	map_areas(scene, dt)
	map_regions(scene^, region_colouring, camera.zoom, dt)
	marks_draw(&MAP_DRAW.marks, &MAP_DRAW.render_list, camera, viewport, pixel_density)
}

map_draw_render :: proc(renderer: ^gfx.Renderer) {
	gfx.render_terrain(renderer, &MAP_DRAW.render_terrain, &MAP_DRAW.render_list)
}

// Cycles the map view: normal, then each raw terrain layer
map_draw_next_view :: proc() {
	debug := &MAP_DRAW.render_terrain.debug_mode
	debug^ = gfx.Render_Terrain_Debug((int(debug^) + 1) % len(gfx.Render_Terrain_Debug))
}

// Rebuilds everything derived from the ground
@(private = "file")
map_derive :: proc(terrain: []sim.Ground) {
	rt := &MAP_DRAW.render_terrain
	for cell, i in terrain {
		rt.cells[i] = {u8(cell.surface) * 127, cell.elevation, cell.trees, cell.moisture}
	}

	// Ways: lines, and preclaim the ground along them
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

	// Coast lines, and offset + side per nearby cell
	to_coast := make([][2]f32, sim.CELLS_MAX, context.temp_allocator)
	coast_side := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	for &offset in to_coast do offset = COAST_REACH
	// Sea 1, land 2, so land is on the left of the coast
	labels := make([]u16, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain do labels[i] = cell.surface in sim.WATER ? 1 : 2
	polylines_clear()
	trace_boundaries(labels, COAST_SMOOTHING)
	for r in 0 ..< polylines_count() {
		line := polylines_get(r)
		polyline_stamp(line, COAST_REACH, to_coast, coast_side)
	}

	// Signed distance to coast, in cells, + on land. Exact near the smoothed line, cell-based farther out, blended.
	to_water := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	to_land := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	distance_to(to_water, terrain, true)
	distance_to(to_land, terrain, false)
	for cell, i in terrain {
		water := cell.surface in sim.WATER
		far := water ? -(to_land[i] - 0.5) : to_water[i] - 0.5
		near := linalg.length(to_coast[i])
		// Far from the line, use the cell's own surface
		if near > 1 do coast_side[i] = water ? -1 : 1
		rt.coast[i] = math.lerp(
			coast_side[i] * near,
			far,
			math.smoothstep(COAST_REACH - 1, COAST_REACH, near),
		)
	}

	// Region highlight areas (ids past RENDER_HIGHLIGHT_AREAS aren't drawn)
	regions := &rt.highlights[.Regions]
	for area in 1 ..< gfx.RENDER_HIGHLIGHT_AREAS do gfx.render_highlight_clear(regions, u8(area))
	for cell, i in terrain {
		if cell.surface in sim.WATER || cell.region == 0 || int(cell.region) >= gfx.RENDER_HIGHLIGHT_AREAS do continue
		gfx.render_highlight_add(regions, u8(cell.region), util.grid_pos(i, sim.WORLD_SIZE))
	}

	// Preclaim near-shore water so marks don't spill into it
	preclaim_coast_water(claimed, rt.coast[:], COAST_WATER_BAND)

	// Cover layer and marks
	cover_draw(&rt.cover, terrain)
	marks_place(&MAP_DRAW.marks, terrain, rt.coast[:], claimed)
}

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
@(private = "file")
Area_Look :: struct {
	layer:     gfx.Render_Highlight_Layer,
	color:     [4]f32,
	border:    f32,
	thickness: f32,
	inside:    f32,
	// In cells, see area_widen. Keep 0 for areas that must tile edge to edge.
	widen:     int,
}

@(private = "file")
highlight_ease :: proc(drawn: ^gfx.Render_Highlight_Area, color: [4]f32, border, thickness, inside, step: f32) {
	drawn.color += (color - drawn.color) * step
	drawn.border += (border - drawn.border) * step
	drawn.thickness += (thickness - drawn.thickness) * step
	drawn.inside += (inside - drawn.inside) * step
}

// Scene area slot i -> highlight area i+1, in its look's layer. Cells re-uploaded only on revision change, fading in.
@(private = "file")
map_areas :: proc(scene: ^sim.Scene, dt: f32) {
	#assert(sim.AREAS_MAX < gfx.RENDER_HIGHLIGHT_AREAS)
	#assert(sim.CIRCLES_MAX <= gfx.RENDER_HIGHLIGHT_CIRCLES_MAX)
	layers := &MAP_DRAW.render_terrain.highlights
	for layer in ([3]gfx.Render_Highlight_Layer{.Zones, .Contacts, .Reach}) do clear(&layers[layer].circles)
	step := util.ease_step(HIGHLIGHT_EASE, dt)
	for &area, slot in scene.areas {
		highlight := u8(slot + 1)
		look := AREA_LOOKS[area.look]
		changed := MAP_DRAW.area_revisions[slot] != area.revision

		// Moved layer, or no look: clear it from where it was
		if MAP_DRAW.area_placed[slot] && (look == {} || MAP_DRAW.area_layers[slot] != look.layer) {
			gfx.render_highlight_clear(&layers[MAP_DRAW.area_layers[slot]], highlight)
			MAP_DRAW.area_placed[slot] = false
			changed = true
		}
		if look == {} do continue
		MAP_DRAW.area_layers[slot] = look.layer
		MAP_DRAW.area_placed[slot] = true
		highlights := &layers[look.layer]

		drawn := &highlights.areas[highlight]
		if changed {
			drawn.border = 0
			drawn.inside = 0
		}
		highlight_ease(drawn, look.color, look.border, look.thickness, look.inside, step)
		drawn.surface = area.on_water ? .Water : .Land
		for circle in scene.circles[area.circles.begin:][:area.circles.len] {
			append(
				&highlights.circles,
				gfx.Render_Highlight_Circle{circle.center, circle.radius, highlight},
			)
		}
		if !changed do continue
		MAP_DRAW.area_revisions[slot] = area.revision
		gfx.render_highlight_clear(highlights, highlight)
		cells := area.cells[:]
		if look.widen > 0 do cells = area_widen(cells, look.widen)
		for inside, i in cells {
			if !inside do continue
			cell := area.corner + util.grid_pos(i, AREA_SQUARE)
			if !util.grid_contains(cell, sim.WORLD_SIZE) do continue
			// Cells added by widening don't steal from other areas
			owner := highlights.cells[util.grid_index(cell, sim.WORLD_SIZE)]
			if !area.cells[i] && owner != 0 && owner != highlight do continue
			gfx.render_highlight_add(highlights, highlight, cell)
		}
	}
}

// Regions ------------------------------------------------------------------------------------------------------------
@(private = "file")
Region_Look :: struct {
	// Wash strength at the edge
	border:    f32,
	// Edge fade width, in cells
	thickness: f32,
	// Wash strength inside
	inside:    f32,
}

@(private = "file")
Region_Looks :: struct {
	plain:       Region_Look,
	highlighted: Region_Look,
}

@(private = "file")
Region_Range :: enum u8 {
	Near,
	Far,
}

@(private = "file")
map_regions :: proc(scene: sim.Scene, colouring: sim.Region_Colouring_Mode, zoom: f32, dt: f32) {
	regions := &MAP_DRAW.render_terrain.highlights[.Regions]
	step := util.ease_step(HIGHLIGHT_EASE, dt)
	looks := REGION_LOOKS[colouring][zoom < REGION_FAR_ZOOM ? .Far : .Near]
	for &drawn, area in regions.areas {
		if area == 0 || area > len(scene.regions) do continue
		region := scene.regions[area - 1]
		look := region.highlighted ? looks.highlighted : looks.plain
		highlight_ease(&drawn, region.color, look.border, look.thickness, look.inside, step)
		drawn.surface = .Land
	}
}

// Thickens parts thinner than ~2*widen+1 cells (what a morphological opening removes), so threads become bands.
// Doesn't extend past thread ends or grow isolated cells. Result in the temp allocator.
@(private = "file")
area_widen :: proc(cells: []bool, widen: int) -> []bool {
	// Disc offsets
	disc := make([dynamic][2]int, context.temp_allocator)
	for dy in -widen ..= widen {
		for dx in -widen ..= widen {
			if dx * dx + dy * dy <= widen * widen + widen do append(&disc, [2]int{dx, dy})
		}
	}
	// need = 1: dilate. need = len(disc): erode.
	morph :: proc(from: []bool, disc: [][2]int, need: int) -> []bool {
		to := make([]bool, len(from), context.temp_allocator)
		for y in 0 ..< sim.AREA_SIZE {
			for x in 0 ..< sim.AREA_SIZE {
				held := 0
				for offset in disc {
					at := [2]int{x, y} + offset
					if util.grid_contains(at, AREA_SQUARE) && from[util.grid_index(at, AREA_SQUARE)] do held += 1
				}
				to[util.grid_index({x, y}, AREA_SQUARE)] = held >= need
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
@(private = "file")
cover_draw :: proc(layer: ^gfx.Render_Layer, terrain: []sim.Ground) {
	for cell, i in terrain do layer.cells[i] = {u8(cell.type), cell.type_strength}
	for look, type in COVER_LOOKS do layer.palette[type] = look
	layer.revision += 1
}

// Ways ----------------------------------------------------------------------------------------------------------------
@(private = "file")
Way_Look :: struct {
	// Half-width, in cells, kept free of marks
	band: f32,
	line: gfx.Render_Line_Kind,
}

// to_way: per cell, offset from its centre to the nearest way point
@(private = "file")
ways_claim_ground :: proc(claimed: []u8, to_way: [][2]f32, band: f32) {
	for offset, i in to_way {
		if linalg.length(offset) > band + 1 do continue
		cell := util.grid_pos(i, sim.WORLD_SIZE)
		way := [2]f32{f32(cell.x), f32(cell.y)} + 0.5 + offset
		for y in 0 ..< FOOTPRINT_RES {
			for x in 0 ..< FOOTPRINT_RES {
				square := cell * FOOTPRINT_RES + {x, y}
				middle := ([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES
				if linalg.length(middle - way) >= band do continue
				claimed[util.grid_index(square, FOOTPRINT_SIZE)] = PRECLAIMED
			}
		}
	}
}

// Coasts --------------------------------------------------------------------------------------------------------------
// Traces edges between different labels into polylines, larger label on the left. Label 0 is ignored. Lines end
// at corners where 1, 3 or 4 edges meet; the rest are closed loops.
@(private = "file")
trace_boundaries :: proc(labels: []u16, smoothing: util.Smoothing) {
	// Per corner: unwalked outgoing edges, and how many edges meet there
	CORNERS :: [2]int{sim.WORLD_WIDTH + 1, sim.WORLD_HEIGHT + 1}
	out := make([]bit_set[Step], CORNERS.x * CORNERS.y, context.temp_allocator)
	meeting := make([]u8, len(out), context.temp_allocator)
	edge :: proc(out: []bit_set[Step], meeting: []u8, from: [2]int, step: Step) {
		to := from + STEPS[step]
		out[util.grid_index(from, CORNERS)] += {step}
		meeting[util.grid_index(from, CORNERS)] += 1
		meeting[util.grid_index(to, CORNERS)] += 1
	}
	for y in 0 ..< sim.WORLD_HEIGHT {
		for x in 0 ..< sim.WORLD_WIDTH {
			here := labels[util.grid_index({x, y}, sim.WORLD_SIZE)]
			if here == 0 do continue
			// Top and left edges
			if y > 0 {
				above := labels[util.grid_index({x, y - 1}, sim.WORLD_SIZE)]
				if above != 0 && above != here {
					if here > above do edge(out, meeting, {x + 1, y}, .West)
					else do edge(out, meeting, {x, y}, .East)
				}
			}
			if x > 0 {
				left := labels[util.grid_index({x - 1, y}, sim.WORLD_SIZE)]
				if left != 0 && left != here {
					if here > left do edge(out, meeting, {x, y}, .South)
					else do edge(out, meeting, {x, y + 1}, .North)
				}
			}
		}
	}

	// Follows edges until a junction/end corner or back to start
	walk :: proc(
		out: []bit_set[Step],
		meeting: []u8,
		start: [2]int,
		step: Step,
		smoothing: util.Smoothing,
	) {
		at, heading := start, step
		polylines_add({f32(at.x), f32(at.y)})
		for {
			out[util.grid_index(at, CORNERS)] -= {heading}
			at += STEPS[heading]
			c := util.grid_index(at, CORNERS)
			if at == start && meeting[c] == 2 {
				polylines_end(true, smoothing)
				return
			}
			polylines_add({f32(at.x), f32(at.y)})
			if meeting[c] != 2 || out[c] == {} {
				polylines_end(false, smoothing)
				return
			}
			for s in Step do if s in out[c] {heading = s; break}
		}
	}
	// Open lines first, then closed loops
	for c in 0 ..< len(out) {
		if meeting[c] == 2 do continue
		for s in Step do if s in out[c] do walk(out, meeting, util.grid_pos(c, CORNERS), s, smoothing)
	}
	for c in 0 ..< len(out) {
		for s in Step do if s in out[c] do walk(out, meeting, util.grid_pos(c, CORNERS), s, smoothing)
	}
}

// Clockwise, +y down
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

// Distance to the nearest water cell (or land cell if !water)
@(private = "file")
distance_to :: proc(out: []f32, terrain: []sim.Ground, water: bool) {
	source := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain do source[i] = (cell.surface in sim.WATER) == water
	util.distance_from(out, source, sim.WORLD_SIZE)
}

// Preclaims squares where -reach < coast < 0 (bilinear)
@(private = "file")
preclaim_coast_water :: proc(claimed: []u8, coast: []f32, reach: f32) {
	for distance, i in coast {
		// Skip cells too far from the band to have squares in it
		if distance >= 1 || distance <= -reach - 1 do continue
		cell := util.grid_pos(i, sim.WORLD_SIZE)
		for y in 0 ..< FOOTPRINT_RES {
			for x in 0 ..< FOOTPRINT_RES {
				square := cell * FOOTPRINT_RES + {x, y}
				at := util.bilinear(
					coast,
					sim.WORLD_SIZE,
					([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES,
				)
				if at < 0 && at > -reach do claimed[util.grid_index(square, FOOTPRINT_SIZE)] = PRECLAIMED
			}
		}
	}
}

// Marks ---------------------------------------------------------------------------------------------------------------
// Scattered drawings (trees, hills...). Each layer is a jittered grid; at each point every marking of the layer gets
// a score from coast distance, elevation, temperature and terrain. A mark is kept with probability sum(scores), and
// the marking is picked weighted by score.

@(private = "file")
footprint_square :: proc(p: [2]f32) -> [2]int {
	return {int(p.x * FOOTPRINT_RES), int(p.y * FOOTPRINT_RES)}
}

@(private = "file")
Map_Marks :: struct {
	// Sorted by foot, top to bottom, so nearer marks draw over farther ones
	marks:    [dynamic; MARKS_MAX]Mark,
	// [marking][variant]; the first variants[marking] are valid
	images:   [len(MARKINGS)][VARIANTS_MAX]gfx.Image_Id,
	variants: [len(MARKINGS)]u8,
}

@(private = "file")
Mark :: struct {
	// Centre, in cells
	pos:     [2]f32,
	layer:   Layer,
	// In cells
	width:   f32,
	// From the image's aspect ratio
	height:  f32,
	marking: u8,
	variant: u8,
	// 0..255
	alpha:   u8,
}

#assert(
	len(MARKINGS) <= 256 && VARIANTS_MAX <= 256,
	"a mark names its marking and variant in a byte each",
)

// In placement order; earlier layers claim ground from later ones
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

@(private = "file")
Layer_Def :: struct {
	// Grid step in cells; rows are spacing * row_squash apart, odd rows offset half a step
	spacing:    f32,
	row_squash: f32,
	// Fraction of a step
	jitter:     [2]f32,
	// In cells, +-vary as a fraction
	width:      f32,
	vary:       f32,
	// Ground claimed by each mark, as fractions of its size. Zero = claims nothing.
	footprint:  struct {
		width: f32,
		below: f32,
	},
	// Also blocks later marks of the same layer
	claims_own: bool,
}

@(private = "file")
Marking :: struct {
	// Under assets/gfx; empty = no more variants
	images:      [VARIANTS_MAX]string,
	layer:       Layer,
	// Where it grows
	coast:       Range,
	elevation:   Range,
	temperature: Range,
	// Density per terrain type (times type strength). All zero = density 1 everywhere.
	cover:       [sim.Terrain_Type]f32,
	// Width multiplier at the top of the elevation range
	grow:        f32,
	// Opacity over coast distance; unset = opaque
	fade:        util.Ramp,
}

// [lo, hi). lo == hi = any value.
@(private = "file")
Range :: struct {
	lo, hi: f32,
}

// Call before sprites_load
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

// Call after sprites_load (needs image aspect ratios). coast: signed distance per cell. claimed: see FOOTPRINT_RES.
@(private = "file")
marks_place :: proc(mm: ^Map_Marks, terrain: []sim.Ground, coast: []f32, claimed: []u8) {
	// 16 random streams per layer
	stream :: proc(layer: Layer, use: u32) -> u32 {return u32(layer) * 16 + use}
	// Bottom edge y, in cells
	mark_foot :: proc(mark: Mark) -> f32 {return mark.pos.y + mark.height / 2}
	Point :: struct {
		layer:    Layer,
		col, row: int,
		pos:      [2]f32,
		cell:     int,
		scores:   [len(MARKINGS)]f32,
	}

	// Aspect ratios (height / width); 0 = missing image
	aspects := make([][VARIANTS_MAX]f32, len(MARKINGS), context.temp_allocator)
	for &variants, m in aspects {
		for &aspect, v in variants[:mm.variants[m]] {
			source := gfx.sprite_region(gfx.sprite_of_image(mm.images[m][v])).source
			if source.z > 0 do aspect = source.w / source.z
		}
	}

	// Grid points and scores
	points := make([dynamic]Point, context.temp_allocator)
	for def, layer in LAYERS {
		step := [2]f32{def.spacing, def.spacing * def.row_squash}
		cols, rows := int(sim.WORLD_WIDTH / step.x), int(sim.WORLD_HEIGHT / step.y)
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				wander :=
					[2]f32 {
						util.random_xy(col, row, stream(layer, 0)),
						util.random_xy(col, row, stream(layer, 1)),
					} -
					0.5
				shift := [2]f32{f32(row % 2) * 0.5, 0}
				pos := ([2]f32{f32(col), f32(row)} + shift + 0.5 + wander * def.jitter) * step
				if !util.grid_contains(util.cell_of(pos), sim.WORLD_SIZE) do continue
				point := Point {
					layer = layer,
					col   = col,
					row   = row,
					pos   = pos,
					cell  = util.grid_index(util.cell_of(pos), sim.WORLD_SIZE),
				}
				cell := terrain[point.cell]
				elevation := util.normalized(cell.elevation)
				moisture := util.normalized(cell.moisture)
				north := 1 - util.cell_center(util.grid_pos(point.cell, sim.WORLD_SIZE)).y / f32(sim.WORLD_HEIGHT)
				temperature := 1 - north - 0.47 * elevation + 0.5 * (0.6 - moisture)
				values := [3]f32{coast[point.cell], elevation, temperature}
				values += (util.random_xy(col, row, stream(layer, 2)) - 0.5) * 2 * BLUR
				here := terrain[point.cell]
				marking: for m, k in MARKINGS {
					if m.layer != layer do continue
					ranges := [3]Range{m.coast, m.elevation, m.temperature}
					for r, q in ranges do if r.lo != r.hi && (values[q] < r.lo || values[q] >= r.hi) do continue marking
					point.scores[k] = 1
					for density in m.cover do if density != 0 {
						point.scores[k] = m.cover[here.type] * util.normalized(here.type_strength)
						break
					}
				}
				append(&points, point)
			}
		}
	}

	// Candidates
	candidates := make([dynamic]Mark, context.temp_allocator)
	for &point in points {
		col, row, layer := point.col, point.row, point.layer
		total: f32
		for s in point.scores do total += s
		if util.random_xy(col, row, stream(layer, 3)) >= total do continue
		k, _ := util.pick_weighted(point.scores[:], util.random_xy(col, row, stream(layer, 4)))
		marking, def := MARKINGS[k], LAYERS[layer]

		width :=
			def.width *
			math.lerp(1 - def.vary, 1 + def.vary, util.random_xy(col, row, stream(layer, 5)))
		if marking.grow != 0 {
			band := marking.elevation
			up := (util.normalized(terrain[point.cell].elevation) - band.lo) / (band.hi - band.lo)
			up = clamp(up, 0, 1)
			width *= 1 + marking.grow * up
		}
		mark := Mark {
			pos     = point.pos,
			layer   = layer,
			width   = width,
			marking = u8(k),
			variant = u8(util.random_xy(col, row, stream(layer, 6)) * f32(mm.variants[k])),
			alpha   = max(u8),
		}
		if marking.fade.from != marking.fade.full {
			mark.alpha = util.to_u8(util.ramp(marking.fade, coast[point.cell]))
		}
		// Skip missing images
		aspect := aspects[mark.marking][mark.variant]
		if aspect <= 0 do continue
		mark.height = width * aspect
		append(&candidates, mark)
	}

	// Place candidates that fit, then claim their footprint
	clear(&mm.marks)
	candidate: for mark in candidates {
		def := LAYERS[mark.layer]
		foot := footprint_square({mark.pos.x, mark_foot(mark)})
		if foot.y < FOOTPRINT_SIZE.y {
			by := int(claimed[util.grid_index(foot, FOOTPRINT_SIZE)])
			if by != 0 && (by - 2 < int(mark.layer) || def.claims_own) do continue
		}
		{
			half := mark.width * MARK_DRAWN_WIDTH / 2
			first := footprint_square({mark.pos.x - half, mark_foot(mark) - mark.height})
			last := footprint_square({mark.pos.x + half, mark_foot(mark)})
			drawn := util.cell_rect_clip({first, last + 1}, FOOTPRINT_SIZE)
			for y in drawn.min.y ..< drawn.max.y do for x in drawn.min.x ..< drawn.max.x {
				if claimed[util.grid_index({x, y}, FOOTPRINT_SIZE)] == PRECLAIMED do continue candidate
			}
		}
		assert(len(mm.marks) < MARKS_MAX, "more marks than MARKS_MAX")
		append(&mm.marks, mark)

		// Claim footprint
		if def.footprint == {} do continue
		half := mark.width * def.footprint.width / 2
		first := footprint_square({mark.pos.x - half, mark_foot(mark) - mark.height})
		last := footprint_square(
			{mark.pos.x + half, mark_foot(mark) + def.footprint.below * mark.height},
		)
		footprint := util.cell_rect_clip({first, last + 1}, FOOTPRINT_SIZE)
		for y in footprint.min.y ..< footprint.max.y do for x in footprint.min.x ..< footprint.max.x {
			square := &claimed[util.grid_index({x, y}, FOOTPRINT_SIZE)]
			if square^ == 0 do square^ = u8(mark.layer) + 2
		}
	}
	slice.sort_by(mm.marks[:], proc(a, b: Mark) -> bool {return mark_foot(a) < mark_foot(b)})
}

// Marks beyond the list's capacity are dropped
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
	gfx.draw_begin(&draw, list, span.from_array(list.instances), rect, pixel_density)
	for mark in mm.marks[:] {
		size := [2]f32{mark.width, mark.height}
		corner := mark.pos - size / 2
		rect: [4]f32 = {corner.x, corner.y, size.x, size.y}
		proj, visible := camera_world_to_screen(camera, viewport, rect)
		if !visible do continue
		image := mm.images[mark.marking][mark.variant]
		gfx.draw_image(&draw, image, proj, {1, 1, 1, util.normalized(mark.alpha)})
	}
}
