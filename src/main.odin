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
#assert(
	WAY_MAX_STEPS_PER_TYPE << uint(RIVER_SMOOTHING.cut_iter) <= RENDER_TERRAIN_COURSE_POINTS_MAX,
)

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
		fonts := [?]Text_Source{{"aniron", 24}, {"forgotten_uncial", 26}}

		init := new(Render_Init, context.temp_allocator)
		render_init_reset(init)
		assets_load(&GLOBAL.assets, init)
		text_load(fonts[:], sdl.GetWindowPixelDensity(window), init)
		renderer = renderer_init(window, init)
	}
	defer renderer_deinit(renderer)

	// UI: font 0 is its base font. Typed characters arrive as text input events
	ui_init(0)
	_ = sdl.StartTextInput(window)

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

	// DEMO begin: the UI demo's state
	demo: Demo_Ui
	// DEMO end

	// A left drag that started on the map, not on the UI, pans the camera
	map_drag := false

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

		// Input: the UI's, and the camera's where the UI is not under the mouse
		input: UI_Input
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE do input.escape = true
				if event.key.scancode == .SPACE do demo.visible = !demo.visible
				if len(input.events) < UI_EVENTS_MAX {
					append(&input.events, UI_Event{kind = .Key, key = event.key.scancode})
				}
			case .TEXT_INPUT:
				for char in string(event.text.text) {
					if len(input.events) < UI_EVENTS_MAX {
						append(&input.events, UI_Event{kind = .Char, char = char})
					}
				}
			case .MOUSE_BUTTON_DOWN:
				if event.button.button == sdl.BUTTON_LEFT {
					input.press = true
					map_drag = !ui_hovered_any()
				}
			case .MOUSE_BUTTON_UP:
				if event.button.button == sdl.BUTTON_LEFT do map_drag = false
			// Camera: the wheel zooms about the cursor, a left drag pans
			case .MOUSE_WHEEL:
				input.wheel += {event.wheel.x, event.wheel.y}
				if ui_hovered_any() do continue
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
				if map_drag {
					camera := &GLOBAL.render_data.view
					camera.center -= [2]f32{event.motion.xrel, event.motion.yrel} / camera.zoom
				}
			}
		}

		{
			cursor: [2]f32
			buttons := sdl.GetMouseState(&cursor.x, &cursor.y)
			input.cursor = cursor
			input.cursor_valid = sdl.GetMouseFocus() == window
			input.press_down = .LEFT in buttons
		}
		// Escape drops the UI's focus first, and quits when nothing is focused
		if input.escape && !ui_focused_any() do running = false

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
				if !ui_hovered_any() &&
				   cell.x >= 0 &&
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

		// UI, over everything
		ui_begin(window_size)
		// DEMO begin: the UI demo
		demo_ui(&demo)
		// DEMO end
		ui_end(input, dt, &GLOBAL.render_data.quads[.Screen])

		if !renderer_draw(&renderer, &GLOBAL.render_data) {
			sdl.Delay(16)
		}
	}
}
