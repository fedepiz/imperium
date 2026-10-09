package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"

import sdl "vendor:sdl3"

GLOBAL: struct {
	assets:      Assets,
	game:        Game,
	render_data: Render_Data,
	pawns:       Map_Pawns,
	pawn_pieces: [dynamic; MAP_PAWNS_MAX]Piece_Id,
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
#assert(WALK_POINTS_MAX + 1 <= RENDER_TERRAIN_ARROW_POINTS_MAX)
#assert(PATHFIND_FLOOD_CELLS <= RENDER_TERRAIN_HIGHLIGHT_CELLS_MAX)
#assert(PIECE_MAX <= MAP_PAWNS_MAX)

// Camera: zoom per wheel notch, and the zoom range in logical pixels per cell
CAMERA_ZOOM_STEP :: 1.15
CAMERA_ZOOM_MIN :: 1
CAMERA_ZOOM_MAX :: 40
CAMERA_PAN_SPEED :: 900
CAMERA_PAN_EASE :: 6

CLICK_MOVE_SNAP :: 9

FPS_PERIOD :: 0.5

FONT_TWEAK :: Text_Font_Id(1)
FONT_MAP :: Text_Font_Id(2)
FONT_CARD_TITLE :: Text_Font_Id(3)

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
		fonts := [?]Text_Source {
			{"aniron", 24},
			{"aniron", 18},
			{"forgotten_uncial", 22},
			{"forgotten_uncial", 36},
		}

		init := new(Render_Init, context.temp_allocator)
		render_init_reset(init)
		assets_load(&GLOBAL.assets, init)
		text_load(fonts[:], sdl.GetWindowPixelDensity(window), init)
		renderer = renderer_init(window, init)
	}
	defer renderer_deinit(renderer)

	map_pawns_build(&GLOBAL.pawns, &GLOBAL.assets, FONT_MAP)

	// UI: font 0 is its base font. Typed characters arrive as text input events
	ui_init(0)
	_ = sdl.StartTextInput(window)

	{
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

	// A left drag that started on the map, not on the UI, pans the camera
	map_drag := false
	camera_velocity: [2]f32

	focus: Piece_Id
	map_mode: Map_Mode
	game_input: Game_Input

	fps_frames: int
	fps_time: f32
	fps: f32

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
		select_click := false
		order_click := false
		tweaks_toggled := false
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE do input.escape = true
				if event.key.scancode == .SPACE && !ui_keyboard_captured() do tweaks_toggled = true
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
					select_click = !ui_hovered_any()
				}
				if event.button.button == sdl.BUTTON_RIGHT do order_click = !ui_hovered_any()
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

		{
			pan: [2]f32
			if !ui_keyboard_captured() {
				keys := sdl.GetKeyboardState(nil)
				if keys[sdl.Scancode.A] || keys[sdl.Scancode.LEFT] do pan.x -= 1
				if keys[sdl.Scancode.D] || keys[sdl.Scancode.RIGHT] do pan.x += 1
				if keys[sdl.Scancode.W] || keys[sdl.Scancode.UP] do pan.y -= 1
				if keys[sdl.Scancode.S] || keys[sdl.Scancode.DOWN] do pan.y += 1
			}
			camera := &GLOBAL.render_data.view
			target_velocity := pan * CAMERA_PAN_SPEED / camera.zoom
			camera_velocity += (target_velocity - camera_velocity) * ease_step(CAMERA_PAN_EASE, dt)
			camera.center += camera_velocity * dt
			camera.center = linalg.clamp(
				camera.center,
				0,
				[2]f32{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
			)
		}

		fps_frames += 1
		fps_time += dt
		if fps_time >= FPS_PERIOD {
			fps = f32(fps_frames) / fps_time
			fps_frames = 0
			fps_time = 0
		}

		tweak_begin()
		tweak_label("Info/fps", fmt.tprintf("%.0f (%.2f ms)", fps, 1000 / max(fps, 1e-6)))
		if tweak_button("Sys/quit", "Quit") do running = false
		GLOBAL.render_data.view.zoom = tweak_slider(
			"Camera/Zoom",
			GLOBAL.render_data.view.zoom,
			CAMERA_ZOOM_MIN,
			CAMERA_ZOOM_MAX,
		)

		view := GLOBAL.render_data.view
		cursor_cell := view.center + (input.cursor - window_size / 2) / view.zoom

		if select_click {
			index, found := map_pawns_pick(&GLOBAL.pawns, view, window_size, input.cursor, -1)
			focus = found ? GLOBAL.pawn_pieces[index] : {}
		}
		if order_click && focus != {} {
			focus_index := -1
			for piece, index in GLOBAL.pawn_pieces do if piece == focus do focus_index = index
			order := Game_Order {
				piece       = focus,
				destination = cursor_cell,
				snap        = CLICK_MOVE_SNAP,
			}
			index, found := map_pawns_pick(&GLOBAL.pawns, view, window_size, input.cursor, focus_index)
			if found do order.target = GLOBAL.pawn_pieces[index]
			game_input.order = order
		}

		game_tick(&GLOBAL.game, focus, &game_input, dt)

		render_data_clear(&GLOBAL.render_data)
		text_reset()
		map_pawns_clear(&GLOBAL.pawns)
		clear(&GLOBAL.pawn_pieces)

		// Terrain: every region in its color, the one under the cursor highlighted
		{
			pointer: Maybe([2]f32)
			if !ui_hovered_any() do pointer = cursor_cell
			game_present_map(&GLOBAL.game, focus, pointer, map_mode, &GLOBAL.render_data.terrain)
			GLOBAL.render_data.terrain.dt = dt
		}

		game_present_pawns(&GLOBAL.game, focus, &GLOBAL.pawns, &GLOBAL.pawn_pieces)
		map_pawns_quads(
			&GLOBAL.pawns,
			view,
			window_size,
			MAP_PAWN_STYLE_DEFAULT,
			dt,
			&GLOBAL.render_data.quads[.World],
			&GLOBAL.render_data.quads[.Screen],
		)

		cards := new(Cards, context.temp_allocator)
		game_cards(&GLOBAL.game, focus, cards)

		// UI, over everything
		ui_begin(window_size)
		cards_ui(cards, FONT_MAP, FONT_CARD_TITLE, &map_mode, &game_input)
		tweak_ui(tweaks_toggled, FONT_TWEAK)
		ui_end(input, dt, &GLOBAL.render_data.quads[.Screen])

		if !renderer_draw(&renderer, &GLOBAL.render_data) {
			sdl.Delay(16)
		}
	}
}
