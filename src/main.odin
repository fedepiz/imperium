package main

import "core:fmt"
import "core:math"
import "core:mem"

import sdl "vendor:sdl3"

GLOBAL: struct {
	assets:      Assets,
	game:        Game,
	render_data: Render_Data,
}

// Asset budgets must fit the renderer's: one write per image
#assert(ASSETS_IMAGES_MAX <= RENDER_ATLAS_WRITES_MAX)

// The map must match the renderer's terrain grid
#assert(MAP_WIDTH == RENDER_TERRAIN_WIDTH)
#assert(MAP_HEIGHT == RENDER_TERRAIN_HEIGHT)
#assert(REGIONS_MAX <= RENDER_TERRAIN_REGIONS_MAX)
#assert(WAY_PER_TYPE_MAX <= RENDER_TERRAIN_COURSE_RUNS_MAX)
#assert(WAY_MAX_STEPS_PER_TYPE << uint(RIVER_SMOOTHING.cut_iter) <= RENDER_TERRAIN_COURSE_POINTS_MAX)

// Camera: zoom per wheel notch, and the zoom range in logical pixels per cell
CAMERA_ZOOM_STEP :: 1.15
CAMERA_ZOOM_MIN :: 1
CAMERA_ZOOM_MAX :: 40

// Images of the terrain's mark drawings: terrain/<name>_<variant>
@(rodata)
MARK_DRAWING_NAMES := [Render_Mark_Drawing]string {
	.Mountain  = "mountain",
	.Hill      = "hill",
	.Conifer   = "conifer",
	.Broadleaf = "broadleaf",
	.Cypress   = "cypress",
	.Palm      = "palm",
	.Tuft      = "tuft",
	.Marsh     = "marsh",
	.Dune      = "dune",
	.Sea       = "sea",
}

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

	// Load images and fonts into the atlases' writes. Pixels live in temporary memory until uploaded
	renderer: Renderer
	{
		// Fonts, by Text_Font_Id: 0 is the default
		fonts := [?]Text_Source{{"aniron", 18}, {"forgotten_uncial", 22}}

		init := new(Render_Init, context.temp_allocator)
		render_init_reset(init)
		assets_load(&GLOBAL.assets, init)
		text_load(fonts[:], sdl.GetWindowPixelDensity(window), init)
		renderer = renderer_init(window, init)
	}
	defer renderer_deinit(renderer)

	{
		game_init(&GLOBAL.game)

		geography := new(Render_Geography, context.temp_allocator)

		if !game_load(&GLOBAL.game, "roman", geography) {
			fmt.eprintln("Failed to load game")
			return
		}

		// The mark drawings, from the assets
		marks: Render_Mark_Images
		for &variants, drawing in marks {
			for &rect, variant in variants {
				name := fmt.tprintf("terrain/%s_%d", MARK_DRAWING_NAMES[drawing], variant)
				index, found := assets_image_find(&GLOBAL.assets, name)
				if found do rect = GLOBAL.assets.image_rects[index]
			}
		}
		renderer_terrain_build(&renderer, geography, RENDER_TERRAIN_STYLE_DEFAULT, marks)
	}

	// Whole world in view
	GLOBAL.render_data.view = {
		center = {RENDER_TERRAIN_WIDTH / 2, RENDER_TERRAIN_HEIGHT / 2},
		zoom   = 2,
	}
	frame_ticks := sdl.GetTicksNS()

	running := true
	for running {
		free_all(context.temp_allocator)

		now := sdl.GetTicksNS()
		dt := min(f32(now - frame_ticks) / 1e9, 0.1)
		frame_ticks = now

		window_size: [2]f32
		{
			size: [2]i32
			sdl.GetWindowSize(window, &size.x, &size.y)
			window_size = {f32(size.x), f32(size.y)}
		}

		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}
			// Camera: the wheel zooms about the cursor, a left drag pans
			case .MOUSE_WHEEL:
				camera := &GLOBAL.render_data.view
				from_centre := [2]f32{event.wheel.mouse_x, event.wheel.mouse_y} - window_size / 2
				under_cursor := camera.center + from_centre / camera.zoom
				camera.zoom = clamp(
					camera.zoom * math.pow(CAMERA_ZOOM_STEP, event.wheel.y),
					CAMERA_ZOOM_MIN,
					CAMERA_ZOOM_MAX,
				)
				camera.center = under_cursor - from_centre / camera.zoom
			case .MOUSE_MOTION:
				if .LEFT in event.motion.state {
					camera := &GLOBAL.render_data.view
					camera.center -= [2]f32{event.motion.xrel, event.motion.yrel} / camera.zoom
				}
			}
		}

		game_tick(&GLOBAL.game)

		render_data_clear(&GLOBAL.render_data)
		text_reset()

		// Terrain: every region in its color, the one under the cursor highlighted
		{
			hovered := 0
			{
				cursor: [2]f32
				_ = sdl.GetMouseState(&cursor.x, &cursor.y)
				cell :=
					GLOBAL.render_data.view.center +
					(cursor - window_size / 2) / GLOBAL.render_data.view.zoom
				if cell.x >= 0 &&
				   cell.y >= 0 &&
				   cell.x < RENDER_TERRAIN_WIDTH &&
				   cell.y < RENDER_TERRAIN_HEIGHT {
					hovered = int(
						GLOBAL.game.terrain.regions[int(cell.y) * RENDER_TERRAIN_WIDTH + int(cell.x)],
					)
				}
			}
			for region, id in GLOBAL.game.regions {
				color := region.color
				GLOBAL.render_data.terrain.regions[id] = {
					color       = [3]f32{f32(color.r), f32(color.g), f32(color.b)} / 255,
					highlighted = id == hovered,
				}
			}
			GLOBAL.render_data.terrain.region_display = .Filled_When_Far
			GLOBAL.render_data.terrain.dt = dt
		}

		// DEMO begin: text. A title, a line with a coloured link, and that line cut short with "..."
		{
			ink := [4]f32{0.18, 0.12, 0.06, 1}
			title := text_make({{text = "Imperium Romanum", font = 1, color = ink}})
			line := text_make(
				{
					{text = "The legion marches north to ", font = 0, color = ink},
					{text = "Mogontiacum", font = 1, color = {0.62, 0.12, 0.06, 1}, tag = 1},
				},
			)
			screen := &GLOBAL.render_data.quads[.Screen]
			pos := [2]f32{40, 40}
			text_quads(title, pos, math.INF_F32, true, {}, screen)
			pos.y += text_size(title).y
			text_quads(line, pos, math.INF_F32, true, {}, screen)
			pos.y += text_size(line).y
			text_quads(line, pos, 230, true, {}, screen)
		}
		// DEMO end

		if !renderer_draw(&renderer, &GLOBAL.render_data) {
			sdl.Delay(16)
		}
	}
}
