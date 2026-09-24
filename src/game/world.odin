package game

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:slice"
import stbi "vendor:stb/image"

import "../gfx"
import "../span"

WORLD: struct {
	camera:           Camera,
	atlas:            Atlas,
	// The first of the image ids given to the world; its own images are numbered from here
	image_base:       gfx.Image_Id,
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	terrain_revision: u32,
	// What the map pass draws, kept up to date by world_tick
	render_terrain:   gfx.Render_Terrain,
	render_list:      gfx.Render_List,
	// What covers each cell, worked out from the terrain whenever it changes
	cover:            [CELLS_MAX]Cover_Cell,
	// The marks scattered over the terrain, top to bottom, so nearer marks overlap farther ones
	marks:            [MARKS_MAX]Mark,
	mark_count:       int,
}

// Enough marks for a full world at the densities below
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
	look:  gfx.Render_Layer_Palette,
	marks: [Mark_Family]f32,
} {
	.Open    = {},
	.Forest  = {{color = {0.725, 0.784, 0.576, 1}, wash = 0.45}, #partial{.Tree = 1}},
	.Desert  = {
		{color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
		#partial{.Dune = 1},
	},
	.Steppe  = {{color = COVER_SAND, wash = 0.25}, #partial{.Tuft = 1}},
	.Fertile = {{color = {0.780, 0.820, 0.560, 1}, wash = 0.7}, #partial{.Tree = 0.45}},
	.Marsh   = {{color = {0.616, 0.714, 0.788, 1}, wash = 0.5}, #partial{.Marsh = 1}},
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

// The drawings a mark can be, each with up to TERRAIN_MARK_VARIANTS variants. Where each is placed is up to
// MARK_FAMILIES.
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

// The drawings of each mark, under assets/gfx; an empty name is a variant the mark does not have.
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

// The world's images, numbered from its image base
WORLD_IMAGES_MAX :: len(Terrain_Mark) * TERRAIN_MARK_VARIANTS

// How many variants a mark has: its leading named drawings.
world_mark_variants :: proc(mark: Terrain_Mark) -> int {
	count := 0
	for name in TERRAIN_MARK_IMAGES[mark] {
		if name == "" do break
		count += 1
	}
	return count
}

// The image of a mark's variant.
world_mark_image :: proc(mark: Terrain_Mark, variant: int) -> gfx.Image_Id {
	return WORLD.image_base + gfx.Image_Id(int(mark) * TERRAIN_MARK_VARIANTS + variant)
}

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT

#assert(gfx.RENDER_TERRAIN_WIDTH == WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == WORLD_HEIGHT)

Atlas :: struct {
	terrain: [CELLS_MAX]Terrain,
}

Terrain :: struct {
	surface:   Surface,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
}

// What covers a cell. A river is land it runs across: the rules treat it as land, the map draws it as a line.
Surface :: enum u8 {
	Land,
	River,
	Lake,
	Sea,
}

WATER :: bit_set[Surface]{.Lake, .Sea}

Camera :: struct {
	// The cell at the middle of the view, and pixels per cell
	center:    [2]f32,
	zoom:      f32,
	// Keyboard panning velocity, in cells per second
	dv:        [2]f32,
	// A drag is in progress, and where the cursor was last frame
	grabbing:  bool,
	grab_last: [2]f32,
}

// The world's images are defined from img_base_index up to WORLD_IMAGES_MAX more, so call this before sprites_load.
// The terrain comes from a scenario, with world_load.
world_init :: proc(img_base_index: gfx.Image_Id) {
	// The camera starts over the middle of the world, at its farthest zoom.
	WORLD.camera.center = {WORLD_WIDTH, WORLD_HEIGHT} / 2
	WORLD.camera.zoom = CAMERA_ZOOM_MIN

	WORLD.image_base = img_base_index
	for variants, mark in TERRAIN_MARK_IMAGES {
		for name, variant in variants {
			if name == "" do continue
			gfx.sprites_image_define(world_mark_image(mark, variant), name)
		}
	}

	WORLD.render_terrain.style = {
		paper       = {0.933, 0.878, 0.753, 1},
		paper_stain = {0.847, 0.761, 0.588, 1},
		ink         = {0.231, 0.165, 0.110, 1},
		sea_color   = {0.616, 0.714, 0.788, 1},
		sea_tint    = 0.55,
		coast_width = 1.6,
		wobble      = 0.3,
		river_width = 10.,
	}
	WORLD.render_terrain.cover.jitter = 0.8
}

// Loads a scenario's terrain from its folder: one greyscale PNG per property, WORLD_WIDTH by WORLD_HEIGHT.
// surface.png is black for land, then darker to lighter grey for river, lake and sea; elevation.png, trees.png and
// moisture.png run from 0 to 255 on land.
// If a layer is missing or the wrong size, the world is left all water, so the failure shows, and false is returned.
world_load :: proc(scenario: string) -> bool {
	terrain := &WORLD.atlas.terrain
	defer WORLD.terrain_revision += 1
	Layer :: enum {
		Surface,
		Elevation,
		Trees,
		Moisture,
	}
	names := [Layer]string {
		.Surface   = "surface",
		.Elevation = "elevation",
		.Trees     = "trees",
		.Moisture  = "moisture",
	}
	for name, layer in names {
		path := fmt.tprintf("%s/%s.png", scenario, name)
		pixels, ok := world_load_layer(path)
		if !ok {
			for &cell in terrain do cell = {
				surface = .Sea,
			}
			return false
		}
		for value, i in pixels {
			switch layer {
			case .Surface:
				terrain[i].surface = Surface(min((int(value) + 42) / 85, int(max(Surface))))
			case .Elevation:
				terrain[i].elevation = value
			case .Trees:
				terrain[i].trees = value
			case .Moisture:
				terrain[i].moisture = value
			}
		}
	}
	// Water cells carry nothing else.
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	return true
}

// One greyscale layer, WORLD_WIDTH by WORLD_HEIGHT; the pixels live in the temp allocator.
@(private = "file")
world_load_layer :: proc(path: string) -> (pixels: []u8, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read terrain layer %q: %v", path, err)
		return
	}
	width, height, channels: c.int
	loaded := stbi.load_from_memory(
		raw_data(data),
		c.int(len(data)),
		&width,
		&height,
		&channels,
		1,
	)
	if loaded == nil {
		fmt.eprintfln("Could not decode terrain layer %q: %s", path, stbi.failure_reason())
		return
	}
	defer stbi.image_free(loaded)
	if width != WORLD_WIDTH || height != WORLD_HEIGHT {
		fmt.eprintfln(
			"Terrain layer %q is %dx%d; it should be %dx%d",
			path,
			width,
			height,
			WORLD_WIDTH,
			WORLD_HEIGHT,
		)
		return
	}
	pixels = make([]u8, CELLS_MAX, context.temp_allocator)
	copy(pixels, loaded[:CELLS_MAX])
	return pixels, true
}

// Inputs used by the game module, in logical pixels unless stated
Input :: struct {
	// Size of the view the map fills
	viewport: [2]f32,
	cursor:   [2]f32,
	// The cursor is over the map, not over the ui or outside the window
	on_map:   bool,
	// The button that drags the map is held
	grab:     bool,
	// Keyboard panning along each axis, from -1 to 1; positive y is down the map
	pan:      [2]f32,
	// Wheel movement this frame, in notches; positive zooms in
	wheel:    f32,
}

// Pixels per second the keyboard pans at, whatever the zoom
CAMERA_PAN_SPEED :: 900
// Zoom factor per wheel notch
CAMERA_ZOOM_STEP :: 1.15
// Closest zoom, in pixels per cell
CAMERA_ZOOM_MAX :: 24
// Farthest zoom, in pixels per cell
CAMERA_ZOOM_MIN :: 2

// Called every frame
world_tick :: proc(input: Input, dt: f32) {
	world_pan_camera(input, dt)
	world_update_render_terrain()
	world_draw_marks(input.viewport)
}

@(private = "file")
world_pan_camera :: proc(input: Input, dt: f32) {
	camera := &WORLD.camera
	world_size := [2]f32{WORLD_WIDTH, WORLD_HEIGHT}
	// Never so far out that the world is smaller than the view
	zoom_min := min(input.viewport.x / world_size.x, input.viewport.y / world_size.y)

	// Zooming keeps the cell under the cursor in place.
	if input.wheel != 0 && input.on_map {
		offset := input.cursor - input.viewport / 2
		anchor := camera.center + offset / camera.zoom
		camera.zoom = clamp(
			camera.zoom * math.pow(CAMERA_ZOOM_STEP, input.wheel),
			max(CAMERA_ZOOM_MIN, zoom_min),
			CAMERA_ZOOM_MAX,
		)
		camera.center = anchor - offset / camera.zoom
	}

	// A drag starts only on the map, and the grabbed point stays under the cursor until the button is released.
	if input.grab && (camera.grabbing || input.on_map) {
		if camera.grabbing {
			camera.center -= (input.cursor - camera.grab_last) / camera.zoom
		}
		camera.grab_last = input.cursor
		camera.grabbing = true
	} else {
		camera.grabbing = false
	}

	// Keyboard panning eases in and out, at a constant speed on screen.
	target := input.pan * CAMERA_PAN_SPEED / camera.zoom
	camera.dv += (target - camera.dv) * (1 - math.exp(-6 * dt))
	camera.center += camera.dv * dt

	camera.center = linalg.clamp(camera.center, 0, world_size)
}

// Keeps the map pass in step with the world: the camera every frame; the cells, coast, rivers, covers and marks when
// the terrain has changed.
@(private = "file")
world_update_render_terrain :: proc() {
	rt := &WORLD.render_terrain
	rt.center = WORLD.camera.center
	rt.zoom = WORLD.camera.zoom
	if rt.revision == WORLD.terrain_revision {
		return
	}
	rt.revision = WORLD.terrain_revision

	for terrain, i in WORLD.atlas.terrain {
		rt.cells[i] = {
			u8(terrain.surface) * 85,
			terrain.elevation,
			terrain.trees,
			terrain.moisture,
		}
	}

	// Signed distance to the coast, in cells: half a cell at the cells either side of it, positive on land.
	to_water := make([]f32, CELLS_MAX, context.temp_allocator)
	to_land := make([]f32, CELLS_MAX, context.temp_allocator)
	world_distance_to(to_water, true)
	world_distance_to(to_land, false)
	for terrain, i in WORLD.atlas.terrain {
		coast := terrain.surface in WATER ? -(to_land[i] - 0.5) : to_water[i] - 0.5
		rt.coast[i] = coast
	}

	world_trace_rivers()
	land := world_land()
	world_classify_cover(&land)
	world_scatter_marks(&land)
}

// What the terrain does not hold but covers and marks need, worked out whenever it changes, in the temp allocator:
// cells to the nearest river and to the sea, and how much the ground rises and falls within two cells.
Land :: struct {
	to_river, to_sea, unevenness: []f32,
}

@(private = "file")
world_land :: proc() -> (land: Land) {
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
world_classify_cover :: proc(land: ^Land) {
	layer := &WORLD.render_terrain.cover
	for &cell, i in WORLD.cover {
		cell = world_cover(land, i)
		layer.cells[i] = {u8(cell.cover), cell.strength}
	}
	for def, cover in COVERS do layer.palette[cover] = def.look
	layer.revision += 1
}

// Cell i's cover: whichever suits it best, how well being its strength, unless none suits it by at least a sixth.
// Desert and steppe follow the moisture, forest the trees. Dry land along a river is fertile, and low, level ground is
// marsh where it is very wet or where a river meets the sea; both win over the rest.
@(private = "file")
world_cover :: proc(land: ^Land, i: int) -> (best: Cover_Cell) {
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

// Traces the river cells into lines and smooths them, then gives every cell near a river the offset from its middle to
// the nearest point of a line. Lines run between ends and forks, so rivers meet where they join.
@(private = "file")
world_trace_rivers :: proc() {
	river := &WORLD.render_terrain.river
	for &offset in river do offset = gfx.RENDER_RIVER_FAR
	visited := make([]bool, CELLS_MAX, context.temp_allocator)
	points := make([dynamic][2]f32, 0, 1024, context.temp_allocator)
	for i in 0 ..< CELLS_MAX {
		if WORLD.atlas.terrain[i].surface != .River do continue
		cell := [2]int{i % WORLD_WIDTH, i / WORLD_WIDTH}
		next: [8][2]int
		count := world_river_next(cell, &next)
		if count == 2 do continue
		// Every line from this end or fork, unless it has been traced from its other end
		for n in next[:count] {
			j := n.y * WORLD_WIDTH + n.x
			if visited[j] do continue
			if world_river_next(n, &{}) != 2 && j < i do continue
			clear(&points)
			world_river_follow(&points, visited, cell, n)
			world_river_stamp(points[:])
		}
	}
	// What is left are closed loops.
	for i in 0 ..< CELLS_MAX {
		if WORLD.atlas.terrain[i].surface != .River || visited[i] do continue
		cell := [2]int{i % WORLD_WIDTH, i / WORLD_WIDTH}
		next: [8][2]int
		if world_river_next(cell, &next) != 2 do continue
		visited[i] = true
		clear(&points)
		world_river_follow(&points, visited, cell, next[0])
		world_river_stamp(points[:])
	}
}

// The river cells a river cell leads to: those beside it, and those diagonal to it that are not already reached
// through one beside it, so a river one cell wide has two.
@(private = "file")
world_river_next :: proc(cell: [2]int, out: ^[8][2]int) -> (count: int) {
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

// Walks a river from cell through next until it reaches an end, a fork, or a cell already walked, putting the middle
// of every cell on the way into points. A river that ends by the sea or a lake is carried on to the shore.
@(private = "file")
world_river_follow :: proc(points: ^[dynamic][2]f32, visited: []bool, cell, next: [2]int) {
	middle :: proc(cell: [2]int) -> [2]f32 {return {f32(cell.x), f32(cell.y)} + 0.5}
	world_river_mouth(points, cell)
	append(points, middle(cell))
	prev, cur := cell, next
	for {
		append(points, middle(cur))
		i := cur.y * WORLD_WIDTH + cur.x
		ahead: [8][2]int
		if world_river_next(cur, &ahead) != 2 || visited[i] do break
		visited[i] = true
		prev, cur = cur, ahead[0] == prev ? ahead[1] : ahead[0]
	}
	world_river_mouth(points, cur)
}

// If the river ends at cell and cell touches water, a point most of the way into the water.
@(private = "file")
world_river_mouth :: proc(points: ^[dynamic][2]f32, cell: [2]int) {
	if world_river_next(cell, &{}) != 1 do return
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			x, y := cell.x + dx, cell.y + dy
			if x < 0 || y < 0 || x >= WORLD_WIDTH || y >= WORLD_HEIGHT do continue
			if WORLD.atlas.terrain[y * WORLD_WIDTH + x].surface in WATER {
				append(
					points,
					[2]f32{f32(cell.x), f32(cell.y)} + 0.5 + [2]f32{f32(dx), f32(dy)} * 0.75,
				)
				return
			}
		}
	}
}

// Smooths a traced line, keeping its ends, and records it as the nearest river of the cells around it.
@(private = "file")
world_river_stamp :: proc(traced: [][2]f32) {
	if len(traced) < 2 do return
	// Cell to cell steps are softened first, then the corners are cut twice, Chaikin's way.
	line := slice.clone(traced, context.temp_allocator)
	for _ in 0 ..< 2 {
		prev := line[0]
		for i in 1 ..< len(line) - 1 {
			here := line[i]
			line[i] = (prev + 2 * here + line[i + 1]) / 4
			prev = here
		}
	}
	for _ in 0 ..< 2 {
		cut := make([dynamic][2]f32, 0, 2 * len(line), context.temp_allocator)
		append(&cut, line[0])
		for i in 0 ..< len(line) - 1 {
			a, b := line[i], line[i + 1]
			append(&cut, a * 0.75 + b * 0.25, a * 0.25 + b * 0.75)
		}
		append(&cut, line[len(line) - 1])
		line = cut[:]
	}

	river := &WORLD.render_terrain.river
	reach := f32(gfx.RENDER_RIVER_REACH)
	for i in 0 ..< len(line) - 1 {
		a, b := line[i], line[i + 1]
		ab := b - a
		length2 := max(linalg.dot(ab, ab), 1e-6)
		x0 := max(int(min(a.x, b.x) - reach), 0)
		y0 := max(int(min(a.y, b.y) - reach), 0)
		x1 := min(int(max(a.x, b.x) + reach), WORLD_WIDTH - 1)
		y1 := min(int(max(a.y, b.y) + reach), WORLD_HEIGHT - 1)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				middle := [2]f32{f32(x), f32(y)} + 0.5
				t := clamp(linalg.dot(middle - a, ab) / length2, 0, 1)
				offset := a + ab * t - middle
				cell := &river[y * WORLD_WIDTH + x]
				if linalg.dot(offset, offset) < linalg.dot(cell^, cell^) do cell^ = offset
			}
		}
	}
}

// A repeatable pseudo-random number in [0, 1) for a position and a stream.
@(private = "file")
world_random :: proc(x, y: int, stream: u32) -> f32 {
	h := u32(x) * 374761393 + u32(y) * 668265263 + stream * 2246822519
	h = (h ~ (h >> 13)) * 1274126177
	h ~= h >> 16
	return f32(h >> 8) / f32(1 << 24)
}

// Scatters every family's marks over the terrain, each family on its own jittered lattice.
@(private = "file")
world_scatter_marks :: proc(land: ^Land) {
	WORLD.mark_count = 0
	scatter: for def, family in MARK_FAMILIES {
		rows := int(f32(WORLD_HEIGHT) / (def.spacing * 0.8))
		cols := int(f32(WORLD_WIDTH) / def.spacing)
		stream := u32(family) * 8
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// Every other row is shifted half a step, and every point wanders within its step.
				x :=
					(f32(col) +
						0.5 +
						f32(row % 2) * 0.5 +
						(world_random(col, row, stream) - 0.5) * 0.7) *
					def.spacing
				y :=
					(f32(row) + 0.5 + (world_random(col, row, stream + 1) - 0.5) * 0.6) *
					def.spacing *
					0.8
				cx, cy := int(x), int(y)
				if cx < 0 || cy < 0 || cx >= WORLD_WIDTH || cy >= WORLD_HEIGHT do continue
				i := cy * WORLD_WIDTH + cx

				mark, chance := world_mark(family, i, world_random(col, row, stream + 6))
				if world_random(col, row, stream + 5) >= chance do continue
				mark.pos = {x, y}
				mark.width *=
					def.width * (1 + def.vary * (2 * world_random(col, row, stream + 2) - 1))
				// No mark sits on a river, so rivers stay in view.
				if family != .Sea_Mark {
					offset :=
						WORLD.render_terrain.river[i] -
						([2]f32{x, y} - [2]f32{f32(cx), f32(cy)} - 0.5)
					if linalg.length(offset) < mark.width * 0.6 do continue
				}
				mark.variant = u8(
					world_random(col, row, stream + 3) * f32(world_mark_variants(mark.mark)),
				)

				// A full table keeps what it has; the marks are still sorted below.
				if WORLD.mark_count == MARKS_MAX do break scatter
				WORLD.marks[WORLD.mark_count] = mark
				WORLD.mark_count += 1
			}
		}
	}
	slice.sort_by(
		WORLD.marks[:WORLD.mark_count],
		proc(a, b: Mark) -> bool {return a.pos.y < b.pos.y},
	)
}

// The chance a lattice point of family at cell i keeps its mark, and the mark: its drawing, how much wider than the
// family's width it is, and its opacity. roll, from 0 to 1, picks between drawings.
@(private = "file")
world_mark :: proc(family: Mark_Family, i: int, roll: f32) -> (mark: Mark, chance: f32) {
	p := place_of(i)
	coast := WORLD.render_terrain.coast[i]
	cover := WORLD.cover[i]
	// How densely the cell's cover bears the family
	density := COVERS[cover.cover].marks[family] * f32(cover.strength) / f32(max(u8))
	mark.width, mark.alpha = 1, max(u8)
	switch family {
	case .Tree:
		// Trees thin out where mountains take over. Conifers grow above a line that runs high in the south and falls to
		// the ground in the far north, cypresses around the warm, dry south, palms along its rivers, broadleaf trees
		// everywhere else, the climates shading into each other.
		chance = density * ramp(0.7, 0.8, coast) * ramp(1.0, 0.55, p.elevation)
		conifer_line := math.lerp(f32(0.95), 0, clamp((p.north - 0.45) / 0.45, 0, 1))
		hot_and_dry := ramp(0.62, 0.55, p.north) * ramp(0.56, 0.46, p.moisture)
		weights := [4]f32 {
			6 * ramp(conifer_line - 0.08, conifer_line + 0.08, p.elevation),
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
		chance =
			density *
			ramp(1.9, 2, coast) *
			ramp(0.36, 0.30, p.moisture) *
			ramp(0.77, 0.58, p.elevation)
	}
	return
}
// Fills the world's render list with the marks in view. Marks are fixed in the world and scale with the map; marks
// past the list's room are dropped.
@(private = "file")
world_draw_marks :: proc(viewport: [2]f32) {
	camera := &WORLD.camera
	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&WORLD.render_list,
		span.from_array(&WORLD.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		1,
	)
	for mark in WORLD.marks[:WORLD.mark_count] {
		image := world_mark_image(mark.mark, int(mark.variant))
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
world_distance_to :: proc(out: []f32, water: bool) {
	source := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in WORLD.atlas.terrain do source[i] = (cell.surface in WATER) == water
	world_distance_from(out, source)
}

// Euclidean distance from every cell to the nearest source cell, by the exact transform of Felzenszwalb and
// Huttenlocher: a pass down each column, then along each row.
@(private = "file")
world_distance_from :: proc(out: []f32, source: []bool) {
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
		world_distance_line(line[:WORLD_HEIGHT], result, parabolas, bounds)
		for y in 0 ..< WORLD_HEIGHT {
			out[y * WORLD_WIDTH + x] = result[y]
		}
	}
	for y in 0 ..< WORLD_HEIGHT {
		row := out[y * WORLD_WIDTH:][:WORLD_WIDTH]
		world_distance_line(row, result, parabolas, bounds)
		for x in 0 ..< WORLD_WIDTH {
			row[x] = math.sqrt(result[x])
		}
	}
}

// One-dimensional squared distance transform of f into out: the lower envelope of parabolas rooted at each sample.
// parabolas and bounds are scratch, at least as long as f and one longer.
@(private = "file")
world_distance_line :: proc(f, out: []f32, parabolas: []i32, bounds: []f32) {
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

