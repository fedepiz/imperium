#+private
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../gfx"
import "../span"
import "../tweak"

// What the map is drawn from: everything worked out from the world's terrain for the map pass and the marks over it
Map_Draw :: struct {
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	terrain_revision: u32,
	// What covers each cell, worked out from the terrain whenever it changes
	cover:            [CELLS_MAX]Cover_Cell,
	// The marks scattered over the terrain, top to bottom, so nearer marks overlap farther ones
	marks:            [dynamic; MARKS_MAX]Mark,
	// How the marks are scattered
	placement:        Mark_Placement,
	// Each mark's drawings, defined by map_draw_init: the first mark_variants[mark] of them
	mark_images:      [Terrain_Mark][TERRAIN_MARK_VARIANTS]gfx.Image_Id,
	mark_variants:    [Terrain_Mark]u8,
	// What the map pass draws
	render_terrain:   gfx.Render_Terrain,
	render_list:      gfx.Render_List,
}

// Enough marks for a full world at the densities map_draw_init sets
MARKS_MAX :: 1 << 17

// One drawing on the map: where its middle sits, in cells, and how wide it is, in cells.
Mark :: struct {
	pos:     [2]f32,
	width:   f32,
	mark:    Terrain_Mark,
	variant: u8,
	// Opacity, up to max(u8): sea marks fade with distance from the shore.
	alpha:   u8,
}

// The drawings a mark can be, each with up to TERRAIN_MARK_VARIANTS variants. Where each is placed is up to
// Mark_Placement.
Terrain_Mark :: enum {
	Conifer,
	Broadleaf,
	Cypress,
	Palm,
	Molehill,
	Mountain,
	Sea_Mark,
	// Steppe grass
	Tuft,
	Marsh,
	Dune,
}

// Each mark has up to this many drawings, so the scatter does not look stamped
TERRAIN_MARK_VARIANTS :: 4

// The drawings of each mark, under assets/gfx; the named variants come first, and an empty name is a variant the
// mark does not have.
@(private = "file")
TERRAIN_MARK_IMAGES := [Terrain_Mark][TERRAIN_MARK_VARIANTS]string {
	.Conifer   = {
		"terrain/conifer_0",
		"terrain/conifer_1",
		"terrain/conifer_2",
		"terrain/conifer_3",
	},
	.Broadleaf = {
		"terrain/broadleaf_0",
		"terrain/broadleaf_1",
		"terrain/broadleaf_2",
		"terrain/broadleaf_3",
	},
	.Cypress   = {
		"terrain/cypress_0",
		"terrain/cypress_1",
		"terrain/cypress_2",
		"terrain/cypress_3",
	},
	.Palm      = {"terrain/palm_0", "terrain/palm_1", "terrain/palm_2", "terrain/palm_3"},
	.Molehill  = {"terrain/hill_0", "terrain/hill_1", "terrain/hill_2", "terrain/hill_3"},
	.Mountain  = {
		"terrain/mountain_0",
		"terrain/mountain_1",
		"terrain/mountain_2",
		"terrain/mountain_3",
	},
	.Sea_Mark  = {"terrain/sea_0", "terrain/sea_1", "", ""},
	.Tuft      = {"terrain/tuft_0", "terrain/tuft_1", "terrain/tuft_2", "terrain/tuft_3"},
	.Marsh     = {"terrain/marsh_0", "terrain/marsh_1", "terrain/marsh_2", "terrain/marsh_3"},
	.Dune      = {"terrain/dune_0", "terrain/dune_1", "terrain/dune_2", "terrain/dune_3"},
}

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

// How each cover is drawn
COVER_LOOKS := [Cover]gfx.Render_Layer_Palette {
	.Open = {},
	.Forest = {color = {0.725, 0.784, 0.576, 1}, wash = 0.45},
	.Desert = {color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
	.Steppe = {color = COVER_SAND, wash = 0.25},
	.Fertile = {color = {0.780, 0.820, 0.560, 1}, wash = 0.7},
	.Marsh = {color = {0.616, 0.714, 0.788, 1}, wash = 0.5},
}

Mark_Family :: enum {
	Tree,
	Molehill,
	Mountain,
	Sea_Mark,
	Tuft,
	Marsh,
	Dune,
}

// How marks are scattered. Marks of a family share a jittered lattice, spacing cells apart, its rows row_squash of
// spacing apart and every other row shifted half a step; each point wanders within its step by up to jitter of it
// across and down. Each mark is about width cells wide, varying by up to vary either way, and keeps river_clearance
// of its width clear of rivers. Whether a point keeps its mark is a chance built from ramps.
Mark_Placement :: struct {
	spacing:         [Mark_Family]f32,
	width:           [Mark_Family]f32,
	vary:            [Mark_Family]f32,
	row_squash:      f32,
	jitter:          [2]f32,
	river_clearance: f32,
	// Over the signed distance to the coast, in cells, positive on land
	coast:           [Mark_Family]Ramp,
	// How densely each cover bears each of the COVER_FAMILIES where it is at full strength
	density:         [Cover][Mark_Family]f32,
	tree:            struct {
		// Over elevation: trees thin out where mountains take over
		elevation:      Ramp,
		// How often each kind is drawn where its climate holds fully
		weight:         [Tree_Kind]f32,
		// Conifers grow above a line at elevation conifer_height[0] in the south, falling straight to
		// conifer_height[1] across conifer_north, shading in over conifer_band either side of it.
		conifer_north:  Ramp,
		conifer_height: [2]f32,
		conifer_band:   f32,
		// Over north and moisture: cypresses around the warm, dry south
		cypress_north:  Ramp,
		cypress_wet:    Ramp,
		// Over north and moisture: palms on fertile land in the hot, dry south
		palm_north:     Ramp,
		palm_wet:       Ramp,
	},
	molehill:        struct {
		// Over elevation: hills rise with the land, and give way as mountains take over
		rise: Ramp,
		fall: Ramp,
	},
	mountain:        struct {
		// Over elevation, which also widens mountains by up to grow of their width
		elevation: Ramp,
		grow:      f32,
	},
	sea:             struct {
		// Over the signed distance to the coast: sea marks fade over the open sea, and are dropped below fade_min
		fade:     Ramp,
		fade_min: f32,
	},
	dune:            struct {
		// Over moisture and elevation: dunes only in the deep desert, and not on hills
		wet:       Ramp,
		elevation: Ramp,
	},
}

// A smooth step over a value, 0 at from and 1 at full; full below from makes it fall.
Ramp :: struct {
	from, full: f32,
}

// The families whose marks the cover bears, by Mark_Placement.density; the others go by the lay of the land.
COVER_FAMILIES :: bit_set[Mark_Family]{.Tree, .Tuft, .Marsh, .Dune}

// The drawings a tree can be
Tree_Kind :: enum {
	Conifer,
	Cypress,
	Palm,
	Broadleaf,
}

TREE_MARKS := [Tree_Kind]Terrain_Mark {
	.Conifer   = .Conifer,
	.Cypress   = .Cypress,
	.Palm      = .Palm,
	.Broadleaf = .Broadleaf,
}

// Sets how the map is drawn and defines the marks' images, so call this before sprites_load.
map_draw_init :: proc() {
	for names, mark in TERRAIN_MARK_IMAGES {
		for name, variant in names {
			if name == "" do break
			WORLD.map_draw.mark_images[mark][variant] = gfx.sprites_image_add(name)
			WORLD.map_draw.mark_variants[mark] += 1
		}
	}

	WORLD.map_draw.render_terrain.style = {
		paper              = {0.933, 0.878, 0.753, 1},
		paper_stain        = {0.847, 0.761, 0.588, 1},
		paper_stain_amount = 0.0,
		ink                = {0.231, 0.165, 0.110, 1},
		sea_shallow        = {0.616, 0.714, 0.788, 1},
		sea_deep           = {0.20, 0.49, 0.78, 1},
		sea_depth_from     = 0,
		sea_depth_full     = 80,
		sea_tint           = 0.55,
		coast_width        = 1.6,
		wobble             = 0.3,
		river_width        = 10.,
	}
	WORLD.map_draw.render_terrain.cover.jitter = 0.8

	WORLD.map_draw.placement = {
		spacing = {
			.Tree = 2.1,
			.Molehill = 3.84,
			.Mountain = 8.04,
			.Sea_Mark = 12,
			.Tuft = 3.8,
			.Marsh = 3.2,
			.Dune = 5.5,
		},
		width = {
			.Tree = 1.6,
			.Molehill = 3.29,
			.Mountain = 4.7,
			.Sea_Mark = 3,
			.Tuft = 1.3,
			.Marsh = 2.3,
			.Dune = 3.4,
		},
		vary = #partial{.Tree = 0.15, .Tuft = 0.2, .Marsh = 0.15, .Dune = 0.2},
		row_squash = 0.8,
		jitter = {0.7, 0.6},
		river_clearance = 0.6,
		coast = {
			.Tree = {0.7, 0.8},
			.Molehill = {0.9, 1},
			.Mountain = {0.9, 1},
			.Sea_Mark = {-3, -5},
			.Tuft = {0.7, 0.8},
			.Marsh = {0.7, 0.8},
			.Dune = {1.9, 2},
		},
		density = #partial{
			.Forest = #partial{.Tree = 1},
			.Desert = #partial{.Dune = 1},
			.Steppe = #partial{.Tuft = 1},
			.Fertile = #partial{.Tree = 0.45},
			.Marsh = #partial{.Marsh = 1},
		},
		tree = {
			elevation = {1.0, 0.55},
			weight = {.Conifer = 6, .Cypress = 3, .Palm = 20, .Broadleaf = 1},
			conifer_north = {0.45, 0.9},
			conifer_height = {0.95, 0},
			conifer_band = 0.08,
			cypress_north = {0.67, 0.62},
			cypress_wet = {0.64, 0.54},
			palm_north = {0.62, 0.55},
			palm_wet = {0.56, 0.46},
		},
		molehill = {rise = {0.58, 0.77}, fall = {1.0, 0.55}},
		mountain = {elevation = {0.55, 1.0}, grow = 0.4},
		sea = {fade = {-19, -5}, fade_min = 0.08},
		dune = {wet = {0.36, 0.30}, elevation = {0.77, 0.58}},
	}
}

// Named in the order of gfx.Render_Terrain_Debug
TERRAIN_VIEW_NAMES := []string{"Map", "Surface", "Elevation", "Trees", "Moisture", "Cover"}

// Keeps the map's drawing in step with the world: the terrain when it changes, the marks when their placement does, and
// the marks in view every frame.
map_draw_tick :: proc(viewport: [2]f32) {
	placement_changed: bool

	if tweak.is_open() {
		view := &WORLD.map_draw.render_terrain.debug_mode
		view^ = gfx.Render_Terrain_Debug(
			tweak.choice("Render/Terrain view", int(view^), TERRAIN_VIEW_NAMES),
		)

		{
			style := &WORLD.map_draw.render_terrain.style
			tweak.slider("Render/Paper stain", &style.paper_stain_amount, 0, 2)
			tweak.slider("Render/Sea Colour/Red", &style.sea_deep.r, 0, 1)
			tweak.slider("Render/Sea Colour/Green", &style.sea_deep.g, 0, 1)
			tweak.slider("Render/Sea Colour/Blue", &style.sea_deep.b, 0, 1)
			tweak.slider("Render/Sea Colour/Depth/From", &style.sea_depth_from, 0, 20)
			tweak.slider("Render/Sea Colour/Depth/Full", &style.sea_depth_full, 0, 80)
		}
		placement_changed = tweak_placement()
	}

	update_render_terrain()
	if placement_changed {
		scatter_marks()
	}
	draw_marks(viewport)
}

// Declares a tweak for every value of the mark placement, and says whether one changed it.
@(private = "file")
tweak_placement :: proc() -> (changed: bool) {
	pl := &WORLD.map_draw.placement
	before := pl^
	for family in Mark_Family {
		tweak.slider(fmt.tprintf("Marks/%v/Spacing", family), &pl.spacing[family], 1, 20)
		tweak.slider(fmt.tprintf("Marks/%v/Width", family), &pl.width[family], 0.2, 10)
		tweak.slider(fmt.tprintf("Marks/%v/Vary", family), &pl.vary[family], 0, 1)
		tweak_ramp(fmt.tprintf("Marks/%v/Coast", family), &pl.coast[family], -25, 5)
		if family not_in COVER_FAMILIES do continue
		// Open land has no strength, so its cover bears nothing.
		for cover in Cover {
			if cover == .Open do continue
			tweak.slider(
				fmt.tprintf("Marks/%v/Density/%v", family, cover),
				&pl.density[cover][family],
				0,
				2,
			)
		}
	}
	tweak.slider("Marks/Row squash", &pl.row_squash, 0.3, 1.5)
	tweak.slider("Marks/Jitter across", &pl.jitter.x, 0, 1)
	tweak.slider("Marks/Jitter down", &pl.jitter.y, 0, 1)
	tweak.slider("Marks/River clearance", &pl.river_clearance, 0, 2)

	t := &pl.tree
	tweak_ramp("Marks/Tree/Elevation", &t.elevation, 0, 1)
	for kind in Tree_Kind {
		tweak.slider(fmt.tprintf("Marks/Tree/Weight/%v", kind), &t.weight[kind], 0, 30)
	}
	tweak_ramp("Marks/Tree/Conifer north", &t.conifer_north, 0, 1)
	tweak.slider("Marks/Tree/Conifer height south", &t.conifer_height[0], 0, 1)
	tweak.slider("Marks/Tree/Conifer height north", &t.conifer_height[1], 0, 1)
	tweak.slider("Marks/Tree/Conifer band", &t.conifer_band, 0, 0.5)
	tweak_ramp("Marks/Tree/Cypress north", &t.cypress_north, 0, 1)
	tweak_ramp("Marks/Tree/Cypress moisture", &t.cypress_wet, 0, 1)
	tweak_ramp("Marks/Tree/Palm north", &t.palm_north, 0, 1)
	tweak_ramp("Marks/Tree/Palm moisture", &t.palm_wet, 0, 1)
	tweak_ramp("Marks/Molehill/Rise", &pl.molehill.rise, 0, 1)
	tweak_ramp("Marks/Molehill/Fall", &pl.molehill.fall, 0, 1)
	tweak_ramp("Marks/Mountain/Elevation", &pl.mountain.elevation, 0, 1)
	tweak.slider("Marks/Mountain/Grow", &pl.mountain.grow, 0, 2)
	tweak_ramp("Marks/Sea_Mark/Fade", &pl.sea.fade, -40, 0)
	tweak.slider("Marks/Sea_Mark/Fade min", &pl.sea.fade_min, 0, 1)
	tweak_ramp("Marks/Dune/Moisture", &pl.dune.wet, 0, 1)
	tweak_ramp("Marks/Dune/Elevation", &pl.dune.elevation, 0, 1)
	return pl^ != before
}

// Declares the two ends of a ramp, each between lo and hi.
@(private = "file")
tweak_ramp :: proc(label: string, r: ^Ramp, lo, hi: f32) {
	tweak.slider(fmt.tprintf("%s/From", label), &r.from, lo, hi)
	tweak.slider(fmt.tprintf("%s/Full", label), &r.full, lo, hi)
}

// Keeps the map pass in step with the world: the camera every frame; the cells, coast, rivers, covers and marks when
// the terrain has changed.
@(private = "file")
update_render_terrain :: proc() {
	rt := &WORLD.map_draw.render_terrain
	rt.center = WORLD.camera.center
	rt.zoom = WORLD.camera.zoom
	if rt.revision == WORLD.map_draw.terrain_revision {
		return
	}
	rt.revision = WORLD.map_draw.terrain_revision

	for terrain, i in WORLD.atlas.terrain {
		rt.cells[i] = {
			u8(terrain.surface) * 85,
			terrain.elevation,
			terrain.trees,
			terrain.moisture,
		}
	}

	// Rivers and coasts are traced into lines, smoothed, and stamped around themselves: each cell near a river learns
	// the offset to its nearest point, and each cell near the coast which side of it it lies on.
	lines := &POLYLINES
	polylines_clear(lines)
	trace_rivers(lines)
	rivers := len(lines.runs)
	trace_coasts(lines)
	polylines_smooth(lines)

	for &offset in rt.river do offset = gfx.RENDER_RIVER_FAR
	to_coast := make([][2]f32, CELLS_MAX, context.temp_allocator)
	coast_side := make([]f32, CELLS_MAX, context.temp_allocator)
	for &offset in to_coast do offset = COAST_REACH
	for r in 0 ..< len(lines.runs) {
		points, closed := polylines_smoothed(lines, r), lines.runs[r].closed
		if r < rivers do polyline_stamp(points, closed, gfx.RENDER_RIVER_REACH, rt.river[:], nil)
		else do polyline_stamp(points, closed, COAST_REACH, to_coast, coast_side)
	}

	// Signed distance to the coast, in cells, positive on land: to the smoothed coast near it, and farther out from
	// cell to cell, half a cell at the cells either side of the coast, the two blending over the last cell of reach.
	to_water := make([]f32, CELLS_MAX, context.temp_allocator)
	to_land := make([]f32, CELLS_MAX, context.temp_allocator)
	distance_to(to_water, true)
	distance_to(to_land, false)
	for terrain, i in WORLD.atlas.terrain {
		water := terrain.surface in WATER
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

	land := measure_land()
	classify_cover(&land)
	scatter_marks()
}

// What the terrain does not hold but covers and marks need, worked out whenever it changes, in the temp allocator:
// cells to the nearest river and to the sea, and how much the ground rises and falls within two cells.
Land :: struct {
	to_river, to_sea: []f32,
}

@(private = "file")
measure_land :: proc() -> (land: Land) {
	terrain := &WORLD.atlas.terrain
	is_river := make([]bool, CELLS_MAX, context.temp_allocator)
	is_sea := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		is_river[i] = cell.surface == .River
		is_sea[i] = cell.surface == .Sea
	}
	land.to_river = make([]f32, CELLS_MAX, context.temp_allocator)
	land.to_sea = make([]f32, CELLS_MAX, context.temp_allocator)
	distance_from(land.to_river, is_river)
	distance_from(land.to_sea, is_sea)
	return
}

// 0 at from, 1 at full, smooth between; full below from makes it fall.
@(private = "file")
ramp :: proc {
	ramp_between,
	ramp_over,
}

@(private = "file")
ramp_over :: proc(r: Ramp, value: f32) -> f32 {
	return ramp_between(r.from, r.full, value)
}

@(private = "file")
ramp_between :: proc(from, full, value: f32) -> f32 {
	return(
		full > from ? math.smoothstep(from, full, value) : 1 - math.smoothstep(full, from, value) \
	)
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
@(private = "file")
classify_cover :: proc(land: ^Land) {
	layer := &WORLD.map_draw.render_terrain.cover
	for &cell, i in WORLD.map_draw.cover {
		cell = cover_of(land, i)
		layer.cells[i] = {u8(cell.cover), cell.strength}
	}
	for look, cover in COVER_LOOKS do layer.palette[cover] = look
	layer.revision += 1
}

// Cell i's cover: whichever suits it best, how well being its strength, unless none suits it by at least a sixth.
// Desert and steppe follow the moisture, forest the trees. Dry land along a river is fertile, and low, level ground is
// marsh where it is very wet or where a river meets the sea; both win over the rest.
@(private = "file")
cover_of :: proc(land: ^Land, i: int) -> (best: Cover_Cell) {
	if WORLD.atlas.terrain[i].surface in WATER do return
	p := place_of(i)
	low := ramp(0.22, 0.12, p.elevation)
	delta := ramp(6, 2, land.to_river[i]) * ramp(16, 6, land.to_sea[i])
	suits := [Cover]f32 {
		.Open    = 1.0 / 6,
		.Forest  = ramp(0.05, 0.75, p.trees),
		.Desert  = ramp(0.47, 0.35, p.moisture),
		.Steppe  = ramp(0.40, 0.47, p.moisture) * ramp(0.58, 0.48, p.moisture),
		.Fertile = 1.3 * ramp(0.62, 0.52, p.moisture) * ramp(5, 1.5, land.to_river[i]),
		.Marsh   = 1.5 * low * max(delta, ramp(0.80, 0.88, p.moisture)),
	}
	most: f32
	for s, cover in suits {
		if s > most do best, most = {cover, u8(min(s, 1) * f32(max(u8)) + 0.5)}, s
	}
	if best.cover == .Open do best.strength = 0
	return
}

// How far around the coast its smoothed line decides the distance to it, in cells
COAST_REACH :: f32(3)

// Rivers are smoothed fully; coasts keep more of their shape, losing mostly the steps of the cells.
RIVER_SMOOTHING :: Polyline_Smoothing {
	softness  = 1,
	cut_iter  = 2,
	cut_ratio = 0.25,
}
COAST_SMOOTHING :: Polyline_Smoothing {
	softness  = 0.3,
	cut_iter  = 2,
	cut_ratio = 0.2,
}

// The rivers and coasts, traced and smoothed whenever the terrain changes
@(private = "file")
POLYLINES: Polylines

// Traces the river cells into lines through the middles of their cells. Lines run between ends and forks, so rivers
// meet where they join; what is left over are closed loops.
@(private = "file")
trace_rivers :: proc(lines: ^Polylines) {
	visited := make([]bool, CELLS_MAX, context.temp_allocator)
	for i in 0 ..< CELLS_MAX {
		if WORLD.atlas.terrain[i].surface != .River do continue
		cell := [2]int{i % WORLD_WIDTH, i / WORLD_WIDTH}
		next: [8][2]int
		count := river_next(cell, &next)
		if count == 2 do continue
		// Every line from this end or fork, unless it has been traced from its other end
		for n in next[:count] {
			j := n.y * WORLD_WIDTH + n.x
			if visited[j] do continue
			if river_next(n, &{}) != 2 && j < i do continue
			river_follow(lines, visited, cell, n)
		}
	}
	for i in 0 ..< CELLS_MAX {
		if WORLD.atlas.terrain[i].surface != .River || visited[i] do continue
		cell := [2]int{i % WORLD_WIDTH, i / WORLD_WIDTH}
		next: [8][2]int
		if river_next(cell, &next) != 2 do continue
		visited[i] = true
		river_follow(lines, visited, cell, next[0])
	}
}

// The river cells a river cell leads to: those beside it, and those diagonal to it that are not already reached
// through one beside it, so a river one cell wide has two.
@(private = "file")
river_next :: proc(cell: [2]int, out: ^[8][2]int) -> (count: int) {
	is_river :: proc(x, y: int) -> bool {
		if x < 0 || y < 0 || x >= WORLD_WIDTH || y >= WORLD_HEIGHT do return false
		return WORLD.atlas.terrain[y * WORLD_WIDTH + x].surface == .River
	}
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			if dx == 0 && dy == 0 do continue
			if !is_river(cell.x + dx, cell.y + dy) do continue
			if dx != 0 && dy != 0 && (is_river(cell.x + dx, cell.y) || is_river(cell.x, cell.y + dy)) do continue
			out[count] = cell + {dx, dy}
			count += 1
		}
	}
	return
}

// Walks a river from cell through next until it reaches an end, a fork, or a cell already walked, through the middle
// of every cell on the way. A river that ends by the sea or a lake is carried on to the shore.
@(private = "file")
river_follow :: proc(lines: ^Polylines, visited: []bool, cell, next: [2]int) {
	middle :: proc(cell: [2]int) -> [2]f32 {return {f32(cell.x), f32(cell.y)} + 0.5}
	river_mouth(lines, cell)
	polylines_add(lines, middle(cell))
	prev, cur := cell, next
	for {
		polylines_add(lines, middle(cur))
		i := cur.y * WORLD_WIDTH + cur.x
		ahead: [8][2]int
		if river_next(cur, &ahead) != 2 || visited[i] do break
		visited[i] = true
		prev, cur = cur, ahead[0] == prev ? ahead[1] : ahead[0]
	}
	river_mouth(lines, cur)
	polylines_end(lines, false, RIVER_SMOOTHING)
}

// If the river ends at cell and cell touches water, a point most of the way into the water.
@(private = "file")
river_mouth :: proc(lines: ^Polylines, cell: [2]int) {
	if river_next(cell, &{}) != 1 do return
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			x, y := cell.x + dx, cell.y + dy
			if x < 0 || y < 0 || x >= WORLD_WIDTH || y >= WORLD_HEIGHT do continue
			if WORLD.atlas.terrain[y * WORLD_WIDTH + x].surface in WATER {
				polylines_add(
					lines,
					[2]f32{f32(cell.x), f32(cell.y)} + 0.5 + [2]f32{f32(dx), f32(dy)} * 0.75,
				)
				return
			}
		}
	}
}

// Traces the coasts: the edges between land and water cells, joined corner to corner into lines with the land on
// their left. A coast that runs off the map ends there; the rest close.
@(private = "file")
trace_coasts :: proc(lines: ^Polylines) {
	// Corners are numbered y * (WORLD_WIDTH + 1) + x. From each leave up to two edges, one step east, south, west or
	// north (see COAST_STEPS); two only where land and water meet across a corner.
	CORNERS :: (WORLD_WIDTH + 1) * (WORLD_HEIGHT + 1)
	corner :: proc(x, y: int) -> int {return y * (WORLD_WIDTH + 1) + x}
	leaving := make([][2]u8, CORNERS, context.temp_allocator)
	count := make([]u8, CORNERS, context.temp_allocator)
	arriving := make([]u8, CORNERS, context.temp_allocator)
	edge :: proc(leaving: [][2]u8, count, arriving: []u8, x, y: int, direction: u8) {
		from := corner(x, y)
		leaving[from][count[from]] = direction
		count[from] += 1
		step := COAST_STEPS[direction]
		arriving[corner(x + step.x, y + step.y)] += 1
	}
	is_water :: proc(x, y: int) -> bool {return(
			WORLD.atlas.terrain[y * WORLD_WIDTH + x].surface in
			WATER \
		)}
	for y in 0 ..< WORLD_HEIGHT {
		for x in 0 ..< WORLD_WIDTH {
			if is_water(x, y) do continue
			if y > 0 && is_water(x, y - 1) do edge(leaving, count, arriving, x + 1, y, 2)
			if y < WORLD_HEIGHT - 1 && is_water(x, y + 1) do edge(leaving, count, arriving, x, y + 1, 0)
			if x > 0 && is_water(x - 1, y) do edge(leaving, count, arriving, x, y, 1)
			if x < WORLD_WIDTH - 1 && is_water(x + 1, y) do edge(leaving, count, arriving, x + 1, y + 1, 3)
		}
	}

	// Walks from a corner along edges not yet walked, until it comes back round or runs out of edges at the edge of the
	// map; where two edges leave a corner, it turns left.
	walk :: proc(lines: ^Polylines, leaving: [][2]u8, count: []u8, x, y: int) {
		start := corner(x, y)
		x, y := x, y
		heading := -1
		for {
			c := corner(x, y)
			if heading >= 0 && c == start {
				polylines_end(lines, true, COAST_SMOOTHING)
				return
			}
			if count[c] == 0 {
				polylines_add(lines, [2]f32{f32(x), f32(y)})
				polylines_end(lines, false, COAST_SMOOTHING)
				return
			}
			pick := 0
			if count[c] == 2 && heading >= 0 && int(leaving[c][1]) == (heading + 3) % 4 do pick = 1
			direction := leaving[c][pick]
			leaving[c][pick] = leaving[c][count[c] - 1]
			count[c] -= 1
			polylines_add(lines, [2]f32{f32(x), f32(y)})
			step := COAST_STEPS[direction]
			x, y, heading = x + step.x, y + step.y, int(direction)
		}
	}
	// Coasts that start at the edge of the map first, then the closed ones
	for c in 0 ..< CORNERS {
		for count[c] > arriving[c] do walk(lines, leaving, count, c % (WORLD_WIDTH + 1), c / (WORLD_WIDTH + 1))
	}
	for c in 0 ..< CORNERS {
		for count[c] > 0 do walk(lines, leaving, count, c % (WORLD_WIDTH + 1), c / (WORLD_WIDTH + 1))
	}
}

// The steps along a coast edge: east, south, west and north, turning clockwise with y down the map
@(private = "file", rodata)
COAST_STEPS := [4][2]int{{1, 0}, {0, 1}, {-1, 0}, {0, -1}}

// A repeatable pseudo-random number in [0, 1) for a position and a stream.
@(private = "file")
random :: proc(x, y: int, stream: u32) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263 + stream * 2246822519
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h >> 8) / f32(1 << 24)
}

// Scatters every family's marks over the terrain, each family on its own jittered lattice: see Mark_Placement.
@(private = "file")
scatter_marks :: proc() {
	clear(&WORLD.map_draw.marks)
	pl := &WORLD.map_draw.placement
	scatter: for family in Mark_Family {
		spacing := pl.spacing[family]
		rows := int(f32(WORLD_HEIGHT) / (spacing * pl.row_squash))
		cols := int(f32(WORLD_WIDTH) / spacing)
		stream := u32(family) * 8
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// Every other row is shifted half a step, and every point wanders within its step.
				x :=
					(f32(col) +
						0.5 +
						f32(row % 2) * 0.5 +
						(random(col, row, stream) - 0.5) * pl.jitter.x) *
					spacing
				y :=
					(f32(row) + 0.5 + (random(col, row, stream + 1) - 0.5) * pl.jitter.y) *
					spacing *
					pl.row_squash
				cx, cy := int(x), int(y)
				if cx < 0 || cy < 0 || cx >= WORLD_WIDTH || cy >= WORLD_HEIGHT do continue
				i := cy * WORLD_WIDTH + cx

				mark, chance := mark_at(family, i, random(col, row, stream + 6))
				if random(col, row, stream + 5) >= chance do continue
				mark.pos = {x, y}
				mark.width *=
					pl.width[family] *
					(1 + pl.vary[family] * (2 * random(col, row, stream + 2) - 1))
				// No mark sits on a river, so rivers stay in view.
				if family != .Sea_Mark {
					offset :=
						WORLD.map_draw.render_terrain.river[i] -
						([2]f32{x, y} - [2]f32{f32(cx), f32(cy)} - 0.5)
					if linalg.length(offset) < mark.width * pl.river_clearance do continue
				}
				mark.variant = u8(
					random(col, row, stream + 3) * f32(WORLD.map_draw.mark_variants[mark.mark]),
				)

				// A full table keeps what it has; the marks are still sorted below.
				if len(WORLD.map_draw.marks) == MARKS_MAX do break scatter
				append(&WORLD.map_draw.marks, mark)
			}
		}
	}
	slice.sort_by(WORLD.map_draw.marks[:], proc(a, b: Mark) -> bool {return a.pos.y < b.pos.y})
}

// The chance a lattice point of family at cell i keeps its mark, and the mark: its drawing, how much wider than the
// family's width it is, and its opacity. roll, from 0 to 1, picks between drawings. See Mark_Placement.
@(private = "file")
mark_at :: proc(family: Mark_Family, i: int, roll: f32) -> (mark: Mark, chance: f32) {
	pl := &WORLD.map_draw.placement
	p := place_of(i)
	coast := WORLD.map_draw.render_terrain.coast[i]
	cover := WORLD.map_draw.cover[i]
	mark.width, mark.alpha = 1, max(u8)
	chance = ramp(pl.coast[family], coast)
	if family in COVER_FAMILIES {
		chance *= pl.density[cover.cover][family] * f32(cover.strength) / f32(max(u8))
	}
	switch family {
	case .Tree:
		// The climates shade into each other; broadleaf trees grow everywhere.
		t := &pl.tree
		chance *= ramp(t.elevation, p.elevation)
		span := t.conifer_north.full - t.conifer_north.from
		north := clamp((p.north - t.conifer_north.from) / span, 0, 1)
		conifer_line := math.lerp(t.conifer_height[0], t.conifer_height[1], north)
		conifer := ramp(conifer_line - t.conifer_band, conifer_line + t.conifer_band, p.elevation)
		cypress := ramp(t.cypress_north, p.north) * ramp(t.cypress_wet, p.moisture)
		palm := ramp(t.palm_north, p.north) * ramp(t.palm_wet, p.moisture)
		weights := t.weight
		weights[.Conifer] *= conifer
		weights[.Cypress] *= cypress
		weights[.Palm] *= cover.cover == .Fertile ? palm : 0
		total: f32
		for weight in weights do total += weight
		left := roll * total
		for weight, kind in weights {
			mark.mark = TREE_MARKS[kind]
			left -= weight
			if left < 0 do break
		}
	case .Molehill:
		mark.mark = .Molehill
		chance *= ramp(pl.molehill.rise, p.elevation) * ramp(pl.molehill.fall, p.elevation)
	case .Mountain:
		mark.mark = .Mountain
		height := ramp(pl.mountain.elevation, p.elevation)
		chance *= height
		mark.width = 1 + pl.mountain.grow * height
	case .Sea_Mark:
		// Lakes have none.
		mark.mark = .Sea_Mark
		fade := ramp(pl.sea.fade, coast)
		if WORLD.atlas.terrain[i].surface != .Sea || fade < pl.sea.fade_min {
			chance = 0
			return
		}
		mark.alpha = u8(fade * f32(max(u8)))
	case .Tuft:
		mark.mark = .Tuft
	case .Marsh:
		mark.mark = .Marsh
	case .Dune:
		mark.mark = .Dune
		chance *= ramp(pl.dune.wet, p.moisture) * ramp(pl.dune.elevation, p.elevation)
	}
	return
}
// Fills the world's render list with the marks in view. Marks are fixed in the world and scale with the map; marks
// past the list's room are dropped.
@(private = "file")
draw_marks :: proc(viewport: [2]f32) {
	camera := &WORLD.camera
	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&WORLD.map_draw.render_list,
		span.from_array(&WORLD.map_draw.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		1,
	)
	for mark in WORLD.map_draw.marks[:] {
		image := WORLD.map_draw.mark_images[mark.mark][mark.variant]
		source := gfx.sprite_region(gfx.sprite_of_image(image)).source
		if source.z <= 0 do continue
		// The drawing keeps its proportions and is centred on the mark.
		width := mark.width * camera.zoom
		size := [2]f32{width, width * source.w / source.z}
		center := (mark.pos - camera.center) * camera.zoom + viewport / 2
		rect := [4]f32{center.x - size.x / 2, center.y - size.y / 2, size.x, size.y}
		if rect.x > viewport.x || rect.y > viewport.y || rect.x + rect.z < 0 || rect.y + rect.w < 0 do continue
		gfx.draw_image(&draw, image, rect, {1, 1, 1, f32(mark.alpha) / f32(max(u8))})
	}
}

// Euclidean distance from every cell to the nearest cell whose water matches.
@(private = "file")
distance_to :: proc(out: []f32, water: bool) {
	source := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in WORLD.atlas.terrain do source[i] = (cell.surface in WATER) == water
	distance_from(out, source)
}

// Euclidean distance from every cell to the nearest source cell, by the exact transform of Felzenszwalb and
// Huttenlocher: a pass down each column, then along each row.
@(private = "file")
distance_from :: proc(out: []f32, source: []bool) {
	FAR :: 1e20
	n := max(WORLD_WIDTH, WORLD_HEIGHT)
	line := make([]f32, n, context.temp_allocator)
	result := make([]f32, n, context.temp_allocator)
	parabolas := make([]i32, n, context.temp_allocator)
	bounds := make([]f32, n + 1, context.temp_allocator)
	for x in 0 ..< WORLD_WIDTH {
		for y in 0 ..< WORLD_HEIGHT {
			line[y] = source[y * WORLD_WIDTH + x] ? 0 : FAR
		}
		distance_line(line[:WORLD_HEIGHT], result, parabolas, bounds)
		for y in 0 ..< WORLD_HEIGHT {
			out[y * WORLD_WIDTH + x] = result[y]
		}
	}
	for y in 0 ..< WORLD_HEIGHT {
		row := out[y * WORLD_WIDTH:][:WORLD_WIDTH]
		distance_line(row, result, parabolas, bounds)
		for x in 0 ..< WORLD_WIDTH {
			row[x] = math.sqrt(result[x])
		}
	}
}

// One-dimensional squared distance transform of f into out: the lower envelope of parabolas rooted at each sample.
// parabolas and bounds are scratch, at least as long as f and one longer.
@(private = "file")
distance_line :: proc(f, out: []f32, parabolas: []i32, bounds: []f32) {
	v, z := parabolas, bounds
	intersect :: proc(f: []f32, q, p: int) -> f32 {
		return ((f[q] + f32(q * q)) - (f[p] + f32(p * p))) / f32(2 * q - 2 * p)
	}
	k := 0
	v[0] = 0
	z[0] = -math.F32_MAX
	z[1] = math.F32_MAX
	for q in 1 ..< len(f) {
		s := intersect(f, q, int(v[k]))
		for s <= z[k] {
			k -= 1
			s = intersect(f, q, int(v[k]))
		}
		k += 1
		v[k] = i32(q)
		z[k] = s
		z[k + 1] = math.F32_MAX
	}
	k = 0
	for q in 0 ..< len(f) {
		for z[k + 1] < f32(q) {
			k += 1
		}
		d := f32(q - int(v[k]))
		out[q] = d * d + f[v[k]]
	}
}
