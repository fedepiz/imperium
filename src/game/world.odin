package game

import "core:math"
import "core:math/linalg"
import "core:math/noise"

import "../gfx"

WORLD: struct {
	camera:           Camera,
	atlas:            Atlas,
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	terrain_revision: u32,
	// What the map pass draws, kept up to date by world_tick
	render_terrain:   gfx.Render_Terrain,
}

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT

#assert(gfx.RENDER_TERRAIN_WIDTH == WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == WORLD_HEIGHT)

Atlas :: struct {
	terrain: [CELLS_MAX]Terrain,
}

Terrain :: struct {
	is_water:  b8,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
}

Camera :: struct {
	// The cell at the middle of the view, and pixels per cell; zero zoom is set to show the whole world on the first tick
	center:    [2]f32,
	zoom:      f32,
	// Keyboard panning velocity, in cells per second
	dv:        [2]f32,
	// A drag is in progress, and where the cursor was last frame
	grabbing:  bool,
	grab_last: [2]f32,
}

// Stand-in terrain until scenarios load from files: noise shaped into one continent, with no attempt at real geography.
world_init :: proc() {
	SEED :: 435
	SEA_LEVEL :: 0.3
	// The height noise rarely reaches its extremes; this is the height treated as the highest ground.
	PEAK :: 0.72

	for y in 0 ..< WORLD_HEIGHT {
		for x in 0 ..< WORLD_WIDTH {
			p := [2]f64{f64(x), f64(y)} / WORLD_WIDTH

			// Land rises toward the middle of the map, so the edges are sea.
			edge := linalg.length(p - 0.5) * 2
			height := world_fbm(SEED, p * 4, 5) * 0.5 + 0.5 - edge * edge * 0.3
			wet := world_fbm(SEED + 1, p * 3, 3) * 0.5 + 0.5
			growth := world_fbm(SEED + 2, p * 8, 3) * 0.5 + 0.5

			terrain := &WORLD.atlas.terrain[y * WORLD_WIDTH + x]
			if height < SEA_LEVEL {
				terrain^ = {
					is_water = true,
				}
				continue
			}
			above := clamp((height - SEA_LEVEL) / (PEAK - SEA_LEVEL), 0, 1)
			// Low ground collects moisture; trees need some, and thin out on high ground.
			moisture := clamp(wet * 0.8 + (1 - above) * 0.3, 0, 1)
			trees :=
				clamp(growth * 2 - 0.6, 0, 1) * clamp(moisture * 2 - 0.3, 0, 1) * (1 - above * 0.7)
			terrain^ = {
				elevation = u8(above * 255),
				moisture  = u8(moisture * 255),
				trees     = u8(trees * 255),
			}
		}
	}

	WORLD.render_terrain.style = {
		paper        = {0.933, 0.878, 0.753, 1},
		paper_stain  = {0.847, 0.761, 0.588, 1},
		ink          = {0.231, 0.165, 0.110, 1},
		sea_color    = {0.616, 0.714, 0.788, 1},
		forest_color = {0.725, 0.784, 0.576, 1},
		sea_tint     = 0.55,
		forest_tint  = 0.45,
		coast_width  = 1.6,
		wobble       = 0.3,
	}
	WORLD.terrain_revision += 1
}

// Sums octaves of noise at doubling frequency and halving weight; the result stays in [-1, 1].
@(private = "file")
world_fbm :: proc(seed: i64, p: [2]f64, octaves: int) -> f64 {
	sum, total: f64
	weight := 1.0
	p := p
	for i in 0 ..< octaves {
		sum += f64(noise.noise_2d(seed + i64(i), p)) * weight
		total += weight
		p *= 2
		weight *= 0.5
	}
	return sum / total
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
CAMERA_ZOOM_MAX :: 64

// Called every frame
world_tick :: proc(input: Input, dt: f32) {
	world_pan_camera(input, dt)
	world_update_render_terrain()
}

@(private = "file")
world_pan_camera :: proc(input: Input, dt: f32) {
	camera := &WORLD.camera
	world_size := [2]f32{WORLD_WIDTH, WORLD_HEIGHT}
	// The farthest zoom shows the whole world
	zoom_min := min(input.viewport.x / world_size.x, input.viewport.y / world_size.y)
	if camera.zoom == 0 {
		camera.center = world_size / 2
		camera.zoom = zoom_min
	}

	// Zooming keeps the cell under the cursor in place.
	if input.wheel != 0 && input.on_map {
		offset := input.cursor - input.viewport / 2
		anchor := camera.center + offset / camera.zoom
		camera.zoom = clamp(
			camera.zoom * math.pow(CAMERA_ZOOM_STEP, input.wheel),
			zoom_min,
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
	camera.dv += (target - camera.dv) * (1 - math.exp(-12 * dt))
	camera.center += camera.dv * dt

	camera.center = linalg.clamp(camera.center, 0, world_size)
}

// Keeps the map pass in step with the world: the camera every frame, the cells and coast when the terrain has changed.
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
		rt.cells[i] = {u8(terrain.is_water), terrain.elevation, terrain.trees, terrain.moisture}
	}

	// Signed distance to the coast, in cells: half a cell at the cells either side of it, positive on land.
	to_water := make([]f32, CELLS_MAX, context.temp_allocator)
	to_land := make([]f32, CELLS_MAX, context.temp_allocator)
	world_distance_to(to_water, true)
	world_distance_to(to_land, false)
	for terrain, i in WORLD.atlas.terrain {
		coast := terrain.is_water ? -(to_land[i] - 0.5) : to_water[i] - 0.5
		rt.coast[i] = coast
	}
}

// Euclidean distance from every cell to the nearest cell whose water matches, by the exact transform of
// Felzenszwalb and Huttenlocher: a pass down each column, then along each row.
@(private = "file")
world_distance_to :: proc(out: []f32, water: bool) {
	FAR :: 1e20
	n := max(WORLD_WIDTH, WORLD_HEIGHT)
	line := make([]f32, n, context.temp_allocator)
	result := make([]f32, n, context.temp_allocator)
	parabolas := make([]i32, n, context.temp_allocator)
	bounds := make([]f32, n + 1, context.temp_allocator)
	for x in 0 ..< WORLD_WIDTH {
		for y in 0 ..< WORLD_HEIGHT {
			line[y] = bool(WORLD.atlas.terrain[y * WORLD_WIDTH + x].is_water) == water ? 0 : FAR
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
