package main

import "core:fmt"
import "core:image"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:os"
import "core:strings"

import sdl "vendor:sdl3"

GLOBAL: struct {
	assets:      Assets,
	render_data: Render_Data,
	map_state:   Map,
}

// Asset budgets must fit the renderer's
#assert(ASSETS_IMAGES_MAX <= RENDER_IMAGES_MAX)
#assert(ASSETS_ATLAS_SIZE <= RENDER_ATLAS_SIZE_MAX)
#assert(ASSETS_ATLAS_SPACING % RENDER_ATLAS_SPACING == 0)

main :: proc() {
	context.allocator = mem.panic_allocator()

	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("Failed to initialise SDL", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("Imperium", 1600, 900, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window == nil {
		fmt.eprintln("Failed to construct window")
		return
	}
	defer sdl.DestroyWindow(window)


	// Load assets, pixels live in temporary memory until uploaded
	renderer: Renderer
	{
		loaded := new(Assets_Loaded, context.temp_allocator)
		assets_load(&GLOBAL.assets, loaded)
		renderer = renderer_init(
			window,
			{ASSETS_ATLAS_SIZE, ASSETS_ATLAS_SIZE},
			GLOBAL.assets.image_rects[:],
			loaded.pixels[:],
		)
	}
	defer renderer_deinit(renderer)

	// DEMO begin: load the scenario into a Map_Geography, build the map, make up highlights,
	// centre the camera
	for name, grid in DEMO_GRID_NAMES {
		path := fmt.tprintf("assets/scenarios/roman/%s.png", name)
		data, data_err := os.read_entire_file(path, context.temp_allocator)
		img, img_err := image.load_from_bytes(
			data,
			{.do_not_expand_grayscale},
			context.temp_allocator,
		)
		if data_err != nil || img_err != nil || img.channels != 1 || img.depth != 8 {
			fmt.eprintln("Failed to load", path)
			return
		}
		if img.width != RENDER_GROUND_WIDTH || img.height != RENDER_GROUND_HEIGHT {
			fmt.eprintln("Not the size of the ground", path)
			return
		}
		copy(DEMO.grids[grid][:], img.pixels.buf[:])
	}
	{
		geography: Map_Geography
		geography.elevation = DEMO.grids[.Elevation][:]
		geography.moisture = DEMO.grids[.Moisture][:]

		// Step: Water. surface.png: black land, grey lake, white sea
		geography.water = make([]bool, MAP_CELLS, context.temp_allocator)
		for surface, i in DEMO.grids[.Surface] do geography.water[i] = surface >= 64

		// Step: Ways. `way = { id = N  points = [ [x, y], ... ] }`, one run per way.
		// A line starting with `way` begins a run, lines starting with `[` hold its cells
		way_files := [?]struct {
			name: string,
			out:  ^Polylines,
		}{{"rivers", &geography.rivers}, {"roads", &geography.roads}}
		for file in way_files {
			path := fmt.tprintf("assets/scenarios/roman/%s.txt", file.name)
			data, data_err := os.read_entire_file(path, context.temp_allocator)
			if data_err != nil {
				fmt.eprintln("Failed to load", path)
				return
			}
			raw := polylines_over(
				make([][2]f32, DEMO_WAY_POINTS_MAX, context.temp_allocator),
				make([]Polyline_Run, DEMO_WAYS_MAX, context.temp_allocator),
			)
			text := string(data)
			for line in strings.split_lines_iterator(&text) {
				trimmed := strings.trim_space(line)
				if strings.has_prefix(trimmed, "way") {
					append(&raw.runs, Polyline_Run{begin = len(raw.points)})
				}
				if !strings.has_prefix(trimmed, "[") || len(raw.runs) == 0 do continue
				// Whole numbers in pairs. Cell (x, y) to its centre
				numbers: [2]f32
				count := 0
				for i := 0; i < len(trimmed); i += 1 {
					if trimmed[i] < '0' || trimmed[i] > '9' do continue
					number := 0
					for ; i < len(trimmed) && trimmed[i] >= '0' && trimmed[i] <= '9'; i += 1 {
						number = number * 10 + int(trimmed[i] - '0')
					}
					numbers[count % 2] = f32(number)
					count += 1
					if count % 2 == 0 {
						append(&raw.points, numbers + 0.5)
						raw.runs[len(raw.runs) - 1].len += 1
					}
				}
			}
			file.out^ = raw
		}

		// Step: Cover. Stand-in for the game's terrain classification: per land cell, the
		// best-suited cover and how well it suits. Follows the old sim's rules, without valleys
		// and passes
		size :: [2]int{MAP_WIDTH, MAP_HEIGHT}
		to_river := make([][2]f32, MAP_CELLS, context.temp_allocator)
		for &offset in to_river do offset = DEMO_RIVER_REACH
		polylines_stamp(geography.rivers, DEMO_RIVER_REACH, size, to_river, nil)
		is_sea := make([]bool, MAP_CELLS, context.temp_allocator)
		for surface, i in DEMO.grids[.Surface] do is_sea[i] = surface >= 192
		to_sea := make([]f32, MAP_CELLS, context.temp_allocator)
		distance_transform(is_sea, size, to_sea)

		geography.cover = make([]Map_Cover_Cell, MAP_CELLS, context.temp_allocator)
		for i in 0 ..< MAP_CELLS {
			if geography.water[i] do continue
			elevation := f32(geography.elevation[i]) / 255
			trees := f32(DEMO.grids[.Trees][i]) / 255
			moisture := f32(geography.moisture[i]) / 255
			river := linalg.length(to_river[i])

			if elevation >= 0.85 {
				geography.cover[i] = {.Mountains, 255}
				continue
			}
			low := ramp(0.22, 0.12, elevation)
			delta := ramp(6, 2, river) * ramp(16, 6, to_sea[i])
			dry_river := ramp(0.62, 0.52, moisture) * ramp(5, 1.5, river)
			suits := [Map_Cover]f32 {
				.Open      = 1.0 / 6,
				.Forest    = ramp(0.05, 0.75, trees),
				.Desert    = ramp(0.47, 0.35, moisture),
				.Steppe    = ramp(0.40, 0.47, moisture) * ramp(0.58, 0.48, moisture),
				.Fertile   = 1.3 * dry_river,
				.Marsh     = 1.5 * low * max(delta, ramp(0.80, 0.88, moisture)),
				.Highland  = 1.2 * ramp(0.55, 1.0, elevation),
				.Mountains = 0,
				.Fields    = 0.6 * ramp(0.52, 0.62, moisture) * ramp(0.3, 0.1, trees),
			}
			best := Map_Cover.Open
			for suit, kind in suits do if suit > suits[best] do best = kind
			if best != .Open {
				geography.cover[i] = {best, u8(clamp(suits[best], 0, 1) * 255 + 0.5)}
			}
		}

		// Step: Regions. regions.txt: a `region = { ... colour = [r, g, b] }` line per region, ids from 1
		// in file order. regions.png: each cell painted in its region's colour
		{
			txt_path :: "assets/scenarios/roman/regions.txt"
			png_path :: "assets/scenarios/roman/regions.png"
			txt, txt_err := os.read_entire_file(txt_path, context.temp_allocator)
			png, png_err := os.read_entire_file(png_path, context.temp_allocator)
			img, img_err := image.load_from_bytes(png, {}, context.temp_allocator)
			if txt_err != nil || png_err != nil || img_err != nil || img.channels != 3 || img.depth != 8 {
				fmt.eprintln("Failed to load the regions")
				return
			}
			if img.width != MAP_WIDTH || img.height != MAP_HEIGHT {
				fmt.eprintln("Not the size of the map", png_path)
				return
			}

			text := string(txt)
			for line in strings.split_lines_iterator(&text) {
				trimmed := strings.trim_space(line)
				colour_at := strings.index(trimmed, "colour")
				if !strings.has_prefix(trimmed, "region") || colour_at < 0 do continue
				if DEMO.region_count == RENDER_GROUND_AREAS - 1 do break
				// The three whole numbers after `colour`
				colour: [3]u8
				count := 0
				for i := colour_at; i < len(trimmed) && count < 3; i += 1 {
					if trimmed[i] < '0' || trimmed[i] > '9' do continue
					number := 0
					for ; i < len(trimmed) && trimmed[i] >= '0' && trimmed[i] <= '9'; i += 1 {
						number = number * 10 + int(trimmed[i] - '0')
					}
					colour[count] = u8(number)
					count += 1
				}
				DEMO.region_count += 1
				DEMO.region_colours[DEMO.region_count] = colour
			}

			pixels := img.pixels.buf[:]
			for i in 0 ..< MAP_CELLS {
				pixel := [3]u8{pixels[i * 3], pixels[i * 3 + 1], pixels[i * 3 + 2]}
				for id in 1 ..= DEMO.region_count {
					if DEMO.region_colours[id] != pixel do continue
					DEMO.regions[i] = u8(id)
					break
				}
			}
			geography.regions = DEMO.regions[:]
		}

		map_build(&GLOBAL.map_state, &renderer, &GLOBAL.assets, geography, MAP_STYLE)
	}
	{
		// Made-up highlights. Zone: a disc. Reach: a blob with a 1-cell thread running from it
		for y in 0 ..< DEMO_ZONE_SIZE.y {
			for x in 0 ..< DEMO_ZONE_SIZE.x {
				from_middle := [2]f32{f32(x), f32(y)} + 0.5 - 24
				DEMO.zone_cells[y * DEMO_ZONE_SIZE.x + x] = linalg.length(from_middle) < 18
			}
		}
		for y in 0 ..< DEMO_REACH_SIZE.y {
			for x in 0 ..< DEMO_REACH_SIZE.x {
				from_blob := [2]f32{f32(x), f32(y)} + 0.5 - 10
				DEMO.reach_cells[y * DEMO_REACH_SIZE.x + x] = linalg.length(from_blob) < 5
			}
		}
		at := [2]int{10, 10}
		for step in 0 ..< 60 {
			DEMO.reach_cells[at.y * DEMO_REACH_SIZE.x + at.x] = true
			at[step % 2] += 1
		}
	}
	DEMO.region_display = .Filled_When_Far
	DEMO.frame_ticks = sdl.GetTicksNS()
	DEMO.view = {
		center = [2]f32{RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT} / 2,
		zoom   = 2 * sdl.GetWindowPixelDensity(window),
	}
	// DEMO end

	running := true
	for running {
		free_all(context.temp_allocator)
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}
				// DEMO begin: 1-4 show a scenario grid as the wash (surface, elevation, trees, moisture),
				// 0 none. R cycles the region display. Z, H, A toggle the made-up zone, reach and arrow
				#partial switch event.key.scancode {
				case ._1, ._2, ._3, ._4:
					DEMO.wash = Demo_Grid(int(event.key.scancode) - int(sdl.Scancode._1))
					DEMO.wash_shown = true
				case ._0:
					DEMO.wash_shown = false
				case .R:
					DEMO.region_display = Map_Region_Display((int(DEMO.region_display) + 1) % len(Map_Region_Display))
				case .Z:
					DEMO.zone_hidden = !DEMO.zone_hidden
				case .H:
					DEMO.reach_hidden = !DEMO.reach_hidden
				case .A:
					DEMO.arrow_hidden = !DEMO.arrow_hidden
				}
				// DEMO end
			// DEMO begin: wheel zooms about the cursor, left drag pans
			case .MOUSE_WHEEL:
				size: [2]i32
				sdl.GetWindowSizeInPixels(window, &size.x, &size.y)
				cursor := [2]f32{event.wheel.mouse_x, event.wheel.mouse_y}
				cursor *= sdl.GetWindowPixelDensity(window)
				from_centre := cursor - [2]f32{f32(size.x), f32(size.y)} / 2
				under_cursor := DEMO.view.center + from_centre / DEMO.view.zoom
				DEMO.view.zoom = clamp(DEMO.view.zoom * math.pow(1.15, event.wheel.y), 0.25, 400)
				DEMO.view.center = under_cursor - from_centre / DEMO.view.zoom
			case .MOUSE_MOTION:
				if .LEFT in event.motion.state {
					moved := [2]f32{event.motion.xrel, event.motion.yrel}
					moved *= sdl.GetWindowPixelDensity(window)
					DEMO.view.center -= moved / DEMO.view.zoom
				}
			// DEMO end
			}
		}

		render_data_clear(&GLOBAL.render_data)

		// DEMO begin: a made-up scene drawn by map_frame
		{
			now := sdl.GetTicksNS()
			dt := min(f32(now - DEMO.frame_ticks) / 1e9, 0.1)
			DEMO.frame_ticks = now

			{
				scene := Map_Scene {
					view           = DEMO.view,
					region_display = DEMO.region_display,
				}

				// Regions: colours from regions.txt, the one under the cursor highlighted
				regions: [RENDER_GROUND_AREAS]Map_Region
				{
					size: [2]i32
					sdl.GetWindowSizeInPixels(window, &size.x, &size.y)
					cursor: [2]f32
					_ = sdl.GetMouseState(&cursor.x, &cursor.y)
					cursor *= sdl.GetWindowPixelDensity(window)
					under := DEMO.view.center + (cursor - [2]f32{f32(size.x), f32(size.y)} / 2) / DEMO.view.zoom
					hovered := 0
					if under.x >= 0 && under.y >= 0 && under.x < MAP_WIDTH && under.y < MAP_HEIGHT {
						hovered = int(DEMO.regions[int(under.y) * MAP_WIDTH + int(under.x)])
					}
					for id in 1 ..= DEMO.region_count {
						colour := DEMO.region_colours[id]
						regions[id] = {
							color       = [3]f32{f32(colour.r), f32(colour.g), f32(colour.b)} / 255,
							highlighted = id == hovered,
						}
					}
				}
				scene.regions = regions[:DEMO.region_count + 1]

				// Highlights: a zone with a circle in slot 0, a reach in slot 1
				zone_circles := [?]Map_Circle{{center = {670, 490}, radius = 10}}
				highlights: [2]Map_Highlight
				if !DEMO.zone_hidden {
					highlights[0] = {
						kind    = .Zone,
						corner  = DEMO_ZONE_CORNER,
						size    = DEMO_ZONE_SIZE,
						cells   = DEMO.zone_cells[:],
						circles = zone_circles[:],
					}
				}
				if !DEMO.reach_hidden {
					highlights[1] = {
						kind   = .Reach,
						corner = DEMO_REACH_CORNER,
						size   = DEMO_REACH_SIZE,
						cells  = DEMO.reach_cells[:],
					}
				}
				scene.highlights = highlights[:]

				// Arrow: along the reach's thread
				arrow_points: [7][2]f32
				arrow_runs: [1]Polyline_Run
				scene.arrows = polylines_over(arrow_points[:], arrow_runs[:])
				if !DEMO.arrow_hidden {
					for k in 0 ..< len(arrow_points) {
						at := [2]f32{f32(DEMO_REACH_CORNER.x), f32(DEMO_REACH_CORNER.y)} + 10.5 + f32(k) * 5
						append(&scene.arrows.points, at)
					}
					append(&scene.arrows.runs, Polyline_Run{begin = 0, len = len(arrow_points)})
				}

				// Pawns: towns with their names, two armies. Roma highlighted, Legio I pulsing
				pawns := [?]Map_Pawn {
					{pos = {353, 441}, icon = .Large_City, culture = .Roman, label = "Roma", highlighted = true},
					{pos = {296, 386}, icon = .City, culture = .Roman, label = "Mediolanum"},
					{pos = {357, 381}, icon = .Town, culture = .Roman, label = "Aquileia"},
					{pos = {377, 461}, icon = .Town, culture = .Roman, label = "Neapolis"},
					{pos = {386, 540}, icon = .Village, culture = .Roman, label = "Syracusae"},
					{pos = {323, 341}, icon = .Town, culture = .Germanic, label = "Augusta Vindelicorum"},
					{pos = {346, 428}, icon = .Army, culture = .Roman, label = "Legio I", pulsing = true},
					{pos = {350, 330}, icon = .Army, culture = .Germanic, label = "Alamanni"},
				}
				scene.pawns = pawns[:]

				// Wash: a scenario grid standing in for a map mode
				if DEMO.wash_shown do scene.wash = DEMO.grids[DEMO.wash][:]

				map_frame(
					&GLOBAL.map_state,
					&renderer,
					&GLOBAL.assets,
					scene,
					MAP_STYLE,
					dt,
					&GLOBAL.render_data.quads,
					&GLOBAL.render_data.passes,
				)
			}
		}
		// DEMO end

		// DEMO: view from the demo camera
		view := DEMO.view
		if !renderer_draw(
			&renderer,
			view,
			GLOBAL.render_data.quads[:],
			GLOBAL.render_data.passes[:],
		) {
			sdl.Delay(16)
		}
	}
}

// DEMO begin
@(private = "file")
DEMO: struct {
	// Camera
	view:           Render_View,
	// SDL nanosecond ticks at the last frame
	frame_ticks:    u64,
	// Scenario grids, 1 byte per cell
	grids:          [Demo_Grid][RENDER_GROUND_WIDTH * RENDER_GROUND_HEIGHT]u8,
	// Scenario grid shown as the scene's wash, if any
	wash_shown:     bool,
	wash:           Demo_Grid,
	// Region per cell, 0 = none. Ids from 1, in regions.txt order
	regions:        [RENDER_GROUND_WIDTH * RENDER_GROUND_HEIGHT]u8,
	region_colours: [RENDER_GROUND_AREAS][3]u8,
	region_count:   int,
	region_display: Map_Region_Display,
	// Made-up scene content
	zone_cells:     [DEMO_ZONE_SIZE.x * DEMO_ZONE_SIZE.y]bool,
	reach_cells:    [DEMO_REACH_SIZE.x * DEMO_REACH_SIZE.y]bool,
	zone_hidden:    bool,
	reach_hidden:   bool,
	arrow_hidden:   bool,
}

// Rects of the made-up highlights, in cells. Zone: Anatolia. Reach: the Balkans
@(private = "file")
DEMO_ZONE_CORNER :: [2]int{626, 466}
@(private = "file")
DEMO_ZONE_SIZE :: [2]int{48, 48}
@(private = "file")
DEMO_REACH_CORNER :: [2]int{430, 330}
@(private = "file")
DEMO_REACH_SIZE :: [2]int{80, 80}

// Farthest a river affects the cover, in cells
@(private = "file")
DEMO_RIVER_REACH :: f32(12)

// Budgets of one ways file
@(private = "file")
DEMO_WAY_POINTS_MAX :: 1 << 13
@(private = "file")
DEMO_WAYS_MAX :: 1 << 8

@(private = "file")
Demo_Grid :: enum {
	Surface,
	Elevation,
	Trees,
	Moisture,
}

@(private = "file")
DEMO_GRID_NAMES :: [Demo_Grid]string {
	.Surface   = "surface",
	.Elevation = "elevation",
	.Trees     = "trees",
	.Moisture  = "moisture",
}
// DEMO end

@(private = "file")
Render_Data :: struct {
	quads:  [dynamic; RENDER_QUADS_MAX]Render_Quad,
	passes: [dynamic; RENDER_PASS_MAX]Render_Pass,
}

@(private = "file")
render_data_clear :: proc(data: ^Render_Data) {
	clear(&data.quads)
	clear(&data.passes)
}

@(private = "file")
render_data_quad_pass :: proc(
	data: ^Render_Data,
	space: Render_Space,
	quads: []Render_Quad,
) {
	// Budgets are enforced by the fixed capacities
	if len(data.passes) >= RENDER_PASS_MAX do return
	base := len(data.quads)
	count := append(&data.quads, ..quads)
	if count == 0 do return

	pass := Render_Quad_Pass {
		space = space,
		begin = base,
		len   = count,
	}
	append(&data.passes, pass)
}
