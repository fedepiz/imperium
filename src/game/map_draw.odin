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
		road_width         = 12,
		road_halo          = 1.5,
		road_fill          = {0.780, 0.540, 0.250, 1},
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
// covers, and the marks over it.
@(private = "file")
map_derive :: proc(terrain: []sim.Ground) {
	rt := &MAP_DRAW.render_terrain
	for cell, i in terrain {
		rt.cells[i] = {u8(cell.surface) * 127, cell.elevation, cell.trees, cell.moisture}
	}

	// Each kind of way, traced into smoothed lines, then drawn as its kind of line, and stamped around themselves so each
	// cell near one learns the offset from its middle to its nearest point: from which it preclaims the ground along it.
	claimed := make([]u8, FOOTPRINT_SIZE.x * FOOTPRINT_SIZE.y, context.temp_allocator)
	to_way := make([][2]f32, sim.CELLS_MAX, context.temp_allocator)
	for trace in WAY_TRACE {
		lines := &rt.lines[trace.line]
		clear(&lines.segments)
		lines.revision += 1
	}
	for kind in sim.Way_Kind {
		for &offset in to_way do offset = WAY_REACH
		polylines_clear()
		ways_trace(terrain, kind)
		for r in 0 ..< polylines_count() {
			line := polylines_get(r)
			lines_add(&rt.lines[WAY_TRACE[kind].line], line, false)
			polyline_stamp(line, WAY_REACH, to_way, nil)
		}
		ways_claim_ground(claimed, to_way, WAY_TRACE[kind].band)
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

	// What covers each cell, drawn as the cover layer, and the marks over the land
	land := measure_land(terrain)
	cover := make([]Cover_Cell, sim.CELLS_MAX, context.temp_allocator)
	classify_cover(&rt.cover, cover, terrain, &land)
	marks_place(&MAP_DRAW.marks, terrain, rt.coast[:], cover, claimed)
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

// Arrows follow ways found from cell to cell, so they are smoothed fully.
@(private = "file")
ARROW_SMOOTHING :: Polyline_Smoothing {
	softness  = 1,
	cut_iter  = 2,
	cut_ratio = 0.25,
}

// Draws the scene's arrows over the map, each through its points, in cells, its head at the last
@(private = "file")
map_arrows :: proc(scene: ^sim.Scene) {
	arrows := &MAP_DRAW.render_terrain.lines[.Arrow]
	clear(&arrows.segments)
	arrows.revision += 1
	for arrow in scene.arrows {
		polylines_clear()
		for point in scene.arrow_points[arrow.begin:][:arrow.len] do polylines_add(point)
		polylines_end(false, ARROW_SMOOTHING)
		for r in 0 ..< polylines_count() do lines_add(arrows, polylines_get(r), true)
	}
}

// Highlights ----------------------------------------------------------------------------------------------------------
// Highlights: areas of cells washed in color over the map

// How each look of the scene's areas is drawn: the numbers are the ones sim's present hands out. Only the colour,
// border, thickness and inside are taken; a look not set here is not seen.
@(private = "file")
AREA_LOOKS := [256]gfx.Render_Highlight_Area {
	1 = {color = {0.300, 0.450, 0.650, 1}, border = 0.6, thickness = 2, inside = 0.2},
	2 = {color = {0.700, 0.250, 0.160, 1}, border = 0.6, thickness = 2, inside = 0.2},
	3 = {color = {0.450, 0.420, 0.380, 1}, border = 0.6, thickness = 2, inside = 0.2},
	4 = {color = {0.850, 0.700, 0.200, 1}, border = 0.6, thickness = 2, inside = 0.2},
}

// Highlights the scene's areas, each slot as the highlight area after it, in its look. Each is taken up again only
// when its revision is not the one last taken up.
@(private = "file")
map_areas :: proc(scene: ^sim.Scene) {
	#assert(sim.AREAS_MAX < gfx.RENDER_HIGHLIGHT_AREAS)
	highlights := &MAP_DRAW.render_terrain.highlights
	for &area, slot in scene.areas {
		if MAP_DRAW.area_revisions[slot] == area.revision do continue
		MAP_DRAW.area_revisions[slot] = area.revision
		highlight := u8(slot + 1)
		gfx.render_highlight_clear(highlights, highlight)
		look := AREA_LOOKS[area.look]
		drawn := &highlights.areas[highlight]
		drawn.color, drawn.border, drawn.thickness, drawn.inside =
			look.color, look.border, look.thickness, look.inside
		drawn.surface = area.on_water ? .Water : .Land
		for inside, i in area.cells {
			if !inside do continue
			cell := area.corner + {i % sim.AREA_SIZE, i / sim.AREA_SIZE}
			gfx.render_highlight_add(highlights, highlight, cell)
		}
	}
}

// Cover ---------------------------------------------------------------------------------------------------------------
// Cover: what covers each cell of land, drawn as the cover layer and read by the marks

// What covers a cell. Each land cell has one cover, and how strongly it has it; Open land has none.
@(private = "file")
Cover :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
	// Mountain country, where the mountains stand
	Highland,
	// Open, well-watered land: fields and pasture
	Fields,
}

// Over elevation: mountain country, where the mountains stand
@(private = "file")
HIGHLAND_ELEVATION :: Ramp{0.55, 1.0}

@(private = "file")
Cover_Cell :: struct {
	cover:    Cover,
	// From 0 to max(u8)
	strength: u8,
}

@(private = "file", rodata)
COVER_SAND := [4]f32{0.900, 0.800, 0.600, 1}

// How each cover is drawn
@(private = "file")
COVER_LOOKS := [Cover]gfx.Render_Layer_Palette {
	.Open = {},
	.Forest = {color = {0.600, 0.640, 0.470, 1}, wash = 0.45},
	.Desert = {color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
	.Steppe = {color = COVER_SAND, wash = 0.25},
	.Fertile = {color = {0.720, 0.740, 0.540, 1}, wash = 0.7},
	.Marsh = {color = {0.580, 0.640, 0.640, 1}, wash = 0.5},
	.Highland = {color = {0.740, 0.620, 0.460, 1}, wash = 0.35},
	.Fields = {color = {0.790, 0.770, 0.600, 1}, wash = 0.35},
}

// What the terrain does not hold but covers and marks need, worked out whenever it changes, in the temp allocator:
// cells to the nearest river and to the sea, and how far each land cell lies below the land around it.
@(private = "file")
Land :: struct {
	to_river, to_sea: []f32,
	// The mean elevation of the land within BASIN_REACH cells, less the cell's own: above 0 in basins and valleys.
	// Elevation has no fixed sea level, so this, not elevation, tells lowland.
	basin:            []f32,
}

// How far around a cell, in cells either way, the land it is compared with to find basins reaches
@(private = "file")
BASIN_REACH :: 24

@(private = "file")
measure_land :: proc(terrain: []sim.Ground) -> (land: Land) {
	is_river := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	is_sea := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		is_river[i] = .River in cell.ways
		is_sea[i] = cell.surface == .Sea
	}
	land.to_river = make([]f32, sim.CELLS_MAX, context.temp_allocator)
	land.to_sea = make([]f32, sim.CELLS_MAX, context.temp_allocator)
	distance_from(land.to_river, is_river, sim.WORLD_SIZE)
	distance_from(land.to_sea, is_sea, sim.WORLD_SIZE)

	elevation := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	is_land := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		if cell.surface in sim.WATER do continue
		elevation[i] = normalized(cell.elevation)
		is_land[i] = 1
	}
	around := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	count := make([]f32, sim.CELLS_MAX, context.temp_allocator)
	box_sum(around, elevation, sim.WORLD_SIZE, BASIN_REACH)
	box_sum(count, is_land, sim.WORLD_SIZE, BASIN_REACH)
	land.basin = make([]f32, sim.CELLS_MAX, context.temp_allocator)
	for i in 0 ..< sim.CELLS_MAX {
		if is_land[i] > 0 do land.basin[i] = around[i] / count[i] - elevation[i]
	}
	return
}

// Gives every cell its cover, and hands the covers to layer to draw.
@(private = "file")
classify_cover :: proc(
	layer: ^gfx.Render_Layer,
	cover: []Cover_Cell,
	terrain: []sim.Ground,
	land: ^Land,
) {
	for &cell, i in cover {
		cell = cover_of(terrain, land, i)
		layer.cells[i] = {u8(cell.cover), cell.strength}
	}
	for look, kind in COVER_LOOKS do layer.palette[kind] = look
	layer.revision += 1
}

// Cell i's cover: whichever suits it best, how well being its strength, unless none suits it by at least a sixth.
// Desert, steppe and fields follow the moisture, forest the trees. Land along a river is fertile: close along it in dry
// country, and farther out where a wet river valley or basin lies below the land around it. Low, level ground is marsh
// where it is very wet or where a river meets the sea; fertile land and marsh win over the rest. Highland follows the
// mountains, so it lies where they stand, and wins over forest, desert and steppe where they are at their
// fullest.
@(private = "file")
cover_of :: proc(terrain: []sim.Ground, land: ^Land, i: int) -> (best: Cover_Cell) {
	if terrain[i].surface in sim.WATER do return
	cell := terrain[i]
	elevation := normalized(cell.elevation)
	trees := normalized(cell.trees)
	moisture := normalized(cell.moisture)
	low := ramp(0.22, 0.12, elevation)
	delta := ramp(6, 2, land.to_river[i]) * ramp(16, 6, land.to_sea[i])
	dry_river := ramp(0.62, 0.52, moisture) * ramp(5, 1.5, land.to_river[i])
	valley :=
		ramp(0.55, 0.65, moisture) *
		ramp(12, 4, land.to_river[i]) *
		ramp(0.02, 0.07, land.basin[i])
	suits := [Cover]f32 {
		.Open     = 1.0 / 6,
		.Forest   = ramp(0.05, 0.75, trees),
		.Desert   = ramp(0.47, 0.35, moisture),
		.Steppe   = ramp(0.40, 0.47, moisture) * ramp(0.58, 0.48, moisture),
		.Fertile  = 1.3 * max(dry_river, valley),
		.Marsh    = 1.5 * low * max(delta, ramp(0.80, 0.88, moisture)),
		.Highland = 1.2 * ramp(HIGHLAND_ELEVATION, elevation),
		.Fields   = 0.6 * ramp(0.52, 0.62, moisture) * ramp(0.3, 0.1, trees),
	}
	most: f32
	for s, cover in suits {
		if s > most do best, most = {cover, u8(min(s, 1) * f32(max(u8)) + 0.5)}, s
	}
	if best.cover == .Open do best.strength = 0
	return
}

// Ways ----------------------------------------------------------------------------------------------------------------
// Ways: rivers and roads, traced from their cells into lines

// How far around the ways the offset to them is kept, in cells: enough for the ground they claim
@(private = "file")
WAY_REACH :: f32(4)

// How each kind of way is traced: how its lines are smoothed, whether an end by the water is carried on to the shore,
// how far either side of its lines, in cells, it claims ground that no mark's drawing may cover, and the kind of line
// it is drawn as. Rivers are smoothed fully; roads keep more of their course.
@(private = "file")
Way_Trace :: struct {
	smoothing: Polyline_Smoothing,
	to_shore:  bool,
	band:      f32,
	line:      gfx.Render_Line_Kind,
}

@(private = "file", rodata)
WAY_TRACE := [sim.Way_Kind]Way_Trace {
	.River = {
		smoothing = {softness = 1, cut_iter = 2, cut_ratio = 0.25},
		to_shore = true,
		band = 1.0,
		line = .River,
	},
	.Road = {
		smoothing = {softness = 0.5, cut_iter = 2, cut_ratio = 0.25},
		band = 1.2,
		line = .Road,
	},
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

// Traces the cells of a kind of way into lines through the middles of their cells. Lines run between ends and forks,
// so ways meet where they join; what is left over are closed loops.
@(private = "file")
ways_trace :: proc(terrain: []sim.Ground, kind: sim.Way_Kind) {
	visited := make([]bool, sim.CELLS_MAX, context.temp_allocator)
	for i in 0 ..< sim.CELLS_MAX {
		if kind not_in terrain[i].ways do continue
		cell := [2]int{i % sim.WORLD_WIDTH, i / sim.WORLD_WIDTH}
		next: [8][2]int
		count := way_next(terrain, kind, cell, &next)
		if count == 2 do continue
		// Every line from this end or fork, unless it has been traced from its other end
		for n in next[:count] {
			j := n.y * sim.WORLD_WIDTH + n.x
			if visited[j] do continue
			if way_next(terrain, kind, n, &{}) != 2 && j < i do continue
			way_follow(terrain, kind, visited, cell, n)
		}
	}
	for i in 0 ..< sim.CELLS_MAX {
		if kind not_in terrain[i].ways || visited[i] do continue
		cell := [2]int{i % sim.WORLD_WIDTH, i / sim.WORLD_WIDTH}
		next: [8][2]int
		if way_next(terrain, kind, cell, &next) != 2 do continue
		visited[i] = true
		way_follow(terrain, kind, visited, cell, next[0])
	}
}

// The cells of a kind of way that a cell of it leads to: those beside it, and those diagonal to it that are not
// already reached through one beside it, so a way one cell wide has two. Ways of a kind lead into each other where
// they meet.
@(private = "file")
way_next :: proc(
	terrain: []sim.Ground,
	kind: sim.Way_Kind,
	cell: [2]int,
	out: ^[8][2]int,
) -> (
	count: int,
) {
	is_way :: proc(terrain: []sim.Ground, kind: sim.Way_Kind, x, y: int) -> bool {
		if x < 0 || y < 0 || x >= sim.WORLD_WIDTH || y >= sim.WORLD_HEIGHT do return false
		return kind in terrain[y * sim.WORLD_WIDTH + x].ways
	}
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			if dx == 0 && dy == 0 do continue
			if !is_way(terrain, kind, cell.x + dx, cell.y + dy) do continue
			if dx != 0 && dy != 0 && (is_way(terrain, kind, cell.x + dx, cell.y) || is_way(terrain, kind, cell.x, cell.y + dy)) do continue
			out[count] = cell + {dx, dy}
			count += 1
		}
	}
	return
}

// Walks a way from cell through next until it reaches an end, a fork, or a cell already walked, through the middle of
// every cell on the way.
@(private = "file")
way_follow :: proc(terrain: []sim.Ground, kind: sim.Way_Kind, visited: []bool, cell, next: [2]int) {
	middle :: proc(cell: [2]int) -> [2]f32 {return {f32(cell.x), f32(cell.y)} + 0.5}
	way_shore(terrain, kind, cell)
	polylines_add(middle(cell))
	prev, cur := cell, next
	for {
		polylines_add(middle(cur))
		i := cur.y * sim.WORLD_WIDTH + cur.x
		ahead: [8][2]int
		if way_next(terrain, kind, cur, &ahead) != 2 || visited[i] do break
		visited[i] = true
		prev, cur = cur, ahead[0] == prev ? ahead[1] : ahead[0]
	}
	way_shore(terrain, kind, cur)
	polylines_end(false, WAY_TRACE[kind].smoothing)
}

// If ways of the kind are carried to the shore, the way ends at cell, and cell touches water: a point most of the way
// into the water.
@(private = "file")
way_shore :: proc(terrain: []sim.Ground, kind: sim.Way_Kind, cell: [2]int) {
	if !WAY_TRACE[kind].to_shore || way_next(terrain, kind, cell, &{}) != 1 do return
	for dy in -1 ..= 1 {
		for dx in -1 ..= 1 {
			x, y := cell.x + dx, cell.y + dy
			if x < 0 || y < 0 || x >= sim.WORLD_WIDTH || y >= sim.WORLD_HEIGHT do continue
			if terrain[y * sim.WORLD_WIDTH + x].surface in sim.WATER {
				polylines_add(
					[2]f32{f32(cell.x), f32(cell.y)} + 0.5 + [2]f32{f32(dx), f32(dy)} * 0.75,
				)
				return
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
// the coast, elevation and temperature are in its ranges, and by its cover; the point keeps a mark with the sum of the
// scores as its chance, and the mark is one of the markings, picked in proportion to its score.

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
	// Each marking's images, defined by marks_init: the first variants[marking] of them
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
	pos:    [2]f32,
	layer:  Layer,
	width:  f32,
	// Given by its image's proportions once its width is set
	height: f32,
	image:  gfx.Image_Id,
	// Opacity, up to max(u8)
	alpha:  u8,
}

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
// to the coast, elevation and temperature are in its ranges, as densely as its cover says of the cell's cover times the
// cover's strength, or fully if it names no cover. Its width grows by grow times how far up its elevation range the
// cell is, and its opacity follows fade over the signed distance to the coast; an unset fade is opaque.
@(private = "file")
Marking :: struct {
	images:      [VARIANTS_MAX]string,
	layer:       Layer,
	coast:       Range,
	elevation:   Range,
	temperature: Range,
	cover:       [Cover]f32,
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
TREE_COVER :: #partial [Cover]f32 {
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
// that keeps one; and, in order, each candidate that fits, stamping its footprint. coast and cover are for every cell:
// the signed distance to the coast, and the cover. claimed holds the preclaimed ground: see FOOTPRINT_RES.
@(private = "file")
marks_place :: proc(
	mm: ^Map_Marks,
	terrain: []sim.Ground,
	coast: []f32,
	cover: []Cover_Cell,
	claimed: []u8,
) {
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
				// cell's cover, times the cover's strength, or fully if it names no cover.
				here := cover[point.cell]
				marking: for m, k in MARKINGS {
					if m.layer != layer do continue
					ranges := [3]Range{m.coast, m.elevation, m.temperature}
					for r, q in ranges do if r.lo != r.hi && (values[q] < r.lo || values[q] >= r.hi) do continue marking
					point.scores[k] = 1
					for density in m.cover do if density != 0 {
						point.scores[k] = m.cover[here.cover] * normalized(here.strength)
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
			pos   = point.pos,
			layer = layer,
			width = width,
			image = mm.images[k][int(random_xy(col, row, stream(layer, 6)) * f32(mm.variants[k]))],
			alpha = max(u8),
		}
		if marking.fade.from != marking.fade.full {
			mark.alpha = u8(ramp(marking.fade, coast[point.cell]) * f32(max(u8)))
		}
		// A mark whose image is missing is never drawn, so it is not kept.
		source := gfx.sprite_region(gfx.sprite_of_image(mark.image)).source
		if source.z <= 0 do continue
		mark.height = width * source.w / source.z
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
		gfx.draw_image(&draw, mark.image, proj, {1, 1, 1, normalized(mark.alpha)})
	}
}

