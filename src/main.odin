package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"
import "core:time"

import sdl "vendor:sdl3"

GLOBAL: struct {
	// The main thread's
	camera:        Camera,
	render_data:   Render_Data,
	pawns:         Map_Pawns,
	// The game thread's
	game:          Game,
	game_events:   [dynamic; GAME_EVENTS_MAX]Game_Event,
	questions:     Game_Questions,
	// Each held by one thread at a time, handed over by index
	presentations: [3]Presentation,
	// Between the two, under its mutex
	game_thread:   Game_Thread,
}

PRESENTATION_TEXT_BYTES :: 4 << 20

Game_Thread :: struct {
	mutex:   sync.Mutex,
	running: bool,
	inputs:  Game_Inputs,
	// Published and not yet taken
	ready:   int,
	fresh:   bool,
}

// All the game side reads from the main thread
Game_Inputs :: struct {
	focus:    Piece_Id,
	hover:    Move_Order,
	// Nil: over the UI
	pointer:  Maybe([2]f32),
	map_mode: Map_Mode,
	tab:      Card_Tab,
	// Taken by the next step; a new one waits until it is
	order:    Game_Order,
}

// Everything the main thread draws. Nothing in it points into the game
Presentation :: struct {
	terrain:     Render_Terrain_Frame,
	pawns:       [dynamic; MAP_PAWNS_MAX]Map_Pawn,
	pawn_pieces: [dynamic; MAP_PAWNS_MAX]Piece_Id,
	cards:       Cards,
	// The game's when presented, and the orders it had taken
	step:        int,
	orders:      int,
	arena:       mem.Arena,
	text:        [PRESENTATION_TEXT_BYTES]u8,
}

@(private = "file")
present :: proc(game: ^Game, inputs: Game_Inputs, orders: int, presentation: ^Presentation) {
	mem.arena_free_all(&presentation.arena)
	context.temp_allocator = mem.arena_allocator(&presentation.arena)
	presentation.terrain = {}
	clear(&presentation.pawns)
	clear(&presentation.pawn_pieces)
	game_present_map(game, inputs.focus, inputs.pointer, inputs.map_mode, &presentation.terrain)
	game_present_pawns(game, inputs.focus, &presentation.pawns, &presentation.pawn_pieces)
	game_cards(game, inputs.focus, inputs.tab, &presentation.cards)
	presentation.step = game.step
	presentation.orders = orders
}

// Steps on its own clock, presents into the presentation it holds, and publishes it
@(private = "file")
game_thread_run :: proc(logs_rules: bool) {
	context.allocator = mem.panic_allocator()
	shared := &GLOBAL.game_thread
	holding := 1
	orders := 0
	unstepped: f32
	ticks := time.tick_now()
	for {
		free_all(context.temp_allocator)
		now := time.tick_now()
		unstepped = min(unstepped + f32(time.duration_seconds(time.tick_diff(ticks, now))), STEPS_AT_ONCE_MAX * STEP_SECONDS)
		ticks = now
		steps := int(unstepped / STEP_SECONDS)
		if steps == 0 {
			time.sleep(time.Duration(f64(STEP_SECONDS - unstepped) * f64(time.Second)))
			continue
		}
		unstepped -= f32(steps) * STEP_SECONDS

		sync.mutex_lock(&shared.mutex)
		running := shared.running
		inputs := shared.inputs
		shared.inputs.order = nil
		sync.mutex_unlock(&shared.mutex)
		if !running do return
		if inputs.order != nil do orders += 1

		clear(&GLOBAL.questions.moves)
		if inputs.hover.piece != {} do append(&GLOBAL.questions.moves, Move_Question{order = inputs.hover, drawn = true})
		for _ in 0 ..< steps {
			clear(&GLOBAL.game_events)
			game_step(&GLOBAL.game, inputs.focus, inputs.order, &GLOBAL.questions, &GLOBAL.game_events)
			inputs.order = nil
			if logs_rules do rules_log_events(&GLOBAL.game, GLOBAL.game_events[:])
		}
		present(&GLOBAL.game, inputs, orders, &GLOBAL.presentations[holding])

		sync.mutex_lock(&shared.mutex)
		holding, shared.ready = shared.ready, holding
		shared.fresh = true
		sync.mutex_unlock(&shared.mutex)
	}
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
#assert(SEA_LANE_POINTS_MAX <= RENDER_TERRAIN_COURSE_POINTS_MAX)
#assert(SEA_LANES_MAX <= RENDER_TERRAIN_COURSE_RUNS_MAX)
#assert(len(Mover) <= RENDER_TERRAIN_ARROWS_MAX)
#assert(len(Mover) * (WALK_POINTS_MAX + 1) <= RENDER_TERRAIN_ARROW_POINTS_MAX)
#assert(PATHFIND_FLOOD_CELLS <= RENDER_TERRAIN_HIGHLIGHT_CELLS_MAX)
#assert(PIECE_MAX <= MAP_PAWNS_MAX)

CLICK_MOVE_SNAP :: 9

STEPS_AT_ONCE_MAX :: 4

FPS_PERIOD :: 0.5

FONT_TWEAK :: Text_Font_Id(1)
FONT_MAP :: Text_Font_Id(2)
FONT_CARD_TITLE :: Text_Font_Id(3)

// Images of the terrain's mark drawings: terrain/<name>_<variant>
Mark_Drawing_Files :: struct {
	name:     string,
	variants: int,
}

@(rodata)
MARK_DRAWING_FILES := [Render_Mark_Drawing]Mark_Drawing_Files {
	.Mountain  = {"mountain", 4},
	.Hill      = {"hill", 4},
	.Conifer   = {"conifer", 4},
	.Broadleaf = {"broadleaf", 4},
	.Cypress   = {"cypress", 4},
	.Palm      = {"palm", 4},
	.Tuft      = {"tuft", 4},
	.Marsh     = {"marsh", 4},
	.Dune      = {"dune", 4},
	.Sea       = {"sea", 2},
}

Options :: struct {
	headless:  bool,
	commands:  string,
	rules_log: string,
}

main :: proc() {
	context.allocator = mem.panic_allocator()

	options: Options
	{
		args := os.args[1:]
		for i := 0; i < len(args); i += 1 {
			switch args[i] {
			case "--headless":
				options.headless = true
			case "--commands", "--rules-log":
				if i + 1 == len(args) {
					fmt.eprintln(args[i], "needs a path, or - for stdin or stdout")
					return
				}
				if args[i] == "--commands" do options.commands = args[i + 1]
				else do options.rules_log = args[i + 1]
				i += 1
			case:
				fmt.eprintln("Unknown argument", args[i])
				return
			}
		}
		if options.headless && options.commands == "" {
			fmt.eprintln("--headless needs --commands")
			return
		}
	}

	if options.commands != "" && !commands_open(options.commands) do return
	defer commands_close()
	if options.rules_log != "" && !rules_log_open(options.rules_log) do return
	defer if options.rules_log != "" do rules_log_close()

	if options.headless {
		run_headless(options)
	} else {
		run_windowed(options)
	}
}

run_headless :: proc(options: Options) {
	geography := new(Render_Geography, context.temp_allocator)
	if !game_load(&GLOBAL.game, "roman", geography) {
		fmt.eprintln("Failed to load game")
		return
	}
	free_all(context.temp_allocator)
	if options.rules_log != "" do rules_log_begin(&GLOBAL.game)

	presentation := &GLOBAL.presentations[0]
	mem.arena_init(&presentation.arena, presentation.text[:])
	input: Game_Order
	command: Command
	for commands_next(&command) {
		present(&GLOBAL.game, {}, 0, presentation)
		steps := command_apply(presentation, command, &input, &GLOBAL.camera)
		for _ in 0 ..< steps {
			clear(&GLOBAL.game_events)
			game_step(&GLOBAL.game, {}, input, nil, &GLOBAL.game_events)
			input = {}
			if options.rules_log != "" do rules_log_events(&GLOBAL.game, GLOBAL.game_events[:])
			free_all(context.temp_allocator)
		}
	}
}

run_windowed :: proc(options: Options) {
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
	marks: Render_Mark_Images
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

		image_paths: [dynamic; ASSETS_IMAGES_MAX]string
		for files in MARK_DRAWING_FILES {
			for variant in 0 ..< files.variants {
				append(&image_paths, fmt.tprintf("terrain/%s_%d", files.name, variant))
			}
		}
		pawn_images_first := len(image_paths)
		map_pawns_image_paths(&image_paths)

		image_rects := make([]Extents, len(image_paths), context.temp_allocator)
		assets_load(image_paths[:], init, image_rects)

		next_rect := 0
		for files, drawing in MARK_DRAWING_FILES {
			for variant in 0 ..< files.variants {
				marks[drawing][variant] = image_rects[next_rect]
				next_rect += 1
			}
		}
		map_pawns_build(&GLOBAL.pawns, image_rects[pawn_images_first:], FONT_MAP)

		text_load(fonts[:], sdl.GetWindowPixelDensity(window), init)
		renderer = renderer_init(window, init)
	}
	defer renderer_deinit(renderer)

	map_style := RENDER_TERRAIN_STYLE_DEFAULT
	pawn_style := MAP_PAWN_STYLE_DEFAULT
	pawn_style.paper = map_style.paper
	pawn_style.ink = map_style.ink

	// UI: font 0 is its base font. Typed characters arrive as text input events
	ui_init(0)
	_ = sdl.StartTextInput(window)

	{
		geography := new(Render_Geography, context.temp_allocator)

		if !game_load(&GLOBAL.game, "roman", geography) {
			fmt.eprintln("Failed to load game")
			return
		}

		renderer_terrain_build(&renderer, geography, map_style, marks)
	}
	if options.rules_log != "" do rules_log_begin(&GLOBAL.game)

	// Whole world in view
	GLOBAL.camera.view = {
		center = {RENDER_TERRAIN_WIDTH / 2, RENDER_TERRAIN_HEIGHT / 2},
		zoom   = 2,
	}
	GLOBAL.camera.target = GLOBAL.camera.view
	GLOBAL.camera.move_ease = CAMERA_MOVE_EASE
	GLOBAL.camera.key_ease = CAMERA_KEY_EASE
	GLOBAL.camera.drag_ease = CAMERA_DRAG_EASE
	GLOBAL.camera.ease = CAMERA_MOVE_EASE
	frame_ticks := sdl.GetTicksNS()

	// A left drag that started on the map, not on the UI, pans the camera
	map_drag := false

	for &each in GLOBAL.presentations do mem.arena_init(&each.arena, each.text[:])
	reading := 0
	present(&GLOBAL.game, {}, 0, &GLOBAL.presentations[reading])
	GLOBAL.game_thread.running = true
	GLOBAL.game_thread.ready = 2
	if THREAD_ARENA.data == nil do mem.arena_init(&THREAD_ARENA, THREAD_MEMORY[:])
	game_thread: ^thread.Thread
	{
		context.allocator = mem.arena_allocator(&THREAD_ARENA)
		game_thread = thread.create_and_start_with_poly_data(options.rules_log != "", game_thread_run)
	}
	defer {
		sync.mutex_lock(&GLOBAL.game_thread.mutex)
		GLOBAL.game_thread.running = false
		sync.mutex_unlock(&GLOBAL.game_thread.mutex)
		thread.join(game_thread)
		context.allocator = mem.arena_allocator(&THREAD_ARENA)
		thread.destroy(game_thread)
	}

	focus: Piece_Id
	cards_view: Cards_View
	game_input: Game_Order
	orders_given := 0
	commands_active := options.commands != ""
	commands_until := 0

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
				target := &GLOBAL.camera.target
				from_centre := [2]f32{event.wheel.mouse_x, event.wheel.mouse_y} - window_size / 2
				under_cursor := target.center + from_centre / target.zoom
				target.zoom = clamp(
					target.zoom * math.pow(CAMERA_ZOOM_STEP, event.wheel.y),
					CAMERA_ZOOM_MIN,
					CAMERA_ZOOM_MAX,
				)
				target.center = under_cursor - from_centre / target.zoom
				GLOBAL.camera.ease = GLOBAL.camera.move_ease
			case .MOUSE_MOTION:
				if map_drag {
					motion := [2]f32{event.motion.xrel, event.motion.yrel}
					GLOBAL.camera.target.center -= motion / GLOBAL.camera.view.zoom
					GLOBAL.camera.ease = GLOBAL.camera.drag_ease
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
			if pan != {} {
				target := &GLOBAL.camera.target
				target.center += pan * CAMERA_PAN_SPEED / target.zoom * dt
				GLOBAL.camera.ease = GLOBAL.camera.key_ease
			}
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
		{
			camera := &GLOBAL.camera
			zoom := tweak_slider("Camera/Zoom", camera.target.zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
			if zoom != camera.target.zoom {
				camera.target.zoom = zoom
				camera.ease = camera.move_ease
			}
			camera.move_ease = tweak_slider("Camera/Move ease", camera.move_ease, CAMERA_EASE_MIN, CAMERA_EASE_MAX)
			camera.key_ease = tweak_slider("Camera/Key ease", camera.key_ease, CAMERA_EASE_MIN, CAMERA_EASE_MAX)
			camera.drag_ease = tweak_slider("Camera/Drag ease", camera.drag_ease, CAMERA_EASE_MIN, CAMERA_EASE_MAX)
		}

		sync.mutex_lock(&GLOBAL.game_thread.mutex)
		if GLOBAL.game_thread.fresh {
			reading, GLOBAL.game_thread.ready = GLOBAL.game_thread.ready, reading
			GLOBAL.game_thread.fresh = false
		}
		sync.mutex_unlock(&GLOBAL.game_thread.mutex)
		presentation := &GLOBAL.presentations[reading]
		GLOBAL.pawns.scene = presentation.pawns

		// One order at a time: the next command waits until the game has taken and presented the last
		for commands_active && game_input == nil && presentation.orders == orders_given && presentation.step >= commands_until {
			command: Command
			if !commands_next(&command) {
				commands_active = false
				break
			}
			commands_until = presentation.step + command_apply(presentation, command, &game_input, &GLOBAL.camera)
		}

		camera_tick(&GLOBAL.camera, dt)
		view := GLOBAL.camera.view
		cursor_cell := view.center + (input.cursor - window_size / 2) / view.zoom

		if select_click {
			index, found := map_pawns_pick(&GLOBAL.pawns, view, window_size, input.cursor, -1)
			focus = found ? presentation.pawn_pieces[index] : {}
			cards_view.menu = nil
		}
		// The move a right click gives. None over the selected pawn
		hover: Move_Order
		under, over_pawn := map_pawns_pick(&GLOBAL.pawns, view, window_size, input.cursor, -1)
		over_focus := over_pawn && presentation.pawn_pieces[under] == focus
		if focus != {} && !over_focus && input.cursor_valid && !ui_hovered_any() {
			focus_index := -1
			for piece, index in presentation.pawn_pieces do if piece == focus do focus_index = index
			hover = {
				piece       = focus,
				destination = cursor_cell,
				snap        = CLICK_MOVE_SNAP,
			}
			index, found := map_pawns_pick(
				&GLOBAL.pawns,
				view,
				window_size,
				input.cursor,
				focus_index,
			)
			if found do hover.target = presentation.pawn_pieces[index]
		}
		if order_click && hover.piece != {} do game_input = hover

		sync.mutex_lock(&GLOBAL.game_thread.mutex)
		{
			inputs := &GLOBAL.game_thread.inputs
			inputs.focus = focus
			inputs.hover = hover
			inputs.pointer = nil
			if !ui_hovered_any() do inputs.pointer = cursor_cell
			inputs.map_mode = cards_view.map_mode
			inputs.tab = cards_view.tab
			if game_input != nil && inputs.order == nil {
				inputs.order = game_input
				game_input = nil
				orders_given += 1
			}
		}
		sync.mutex_unlock(&GLOBAL.game_thread.mutex)

		// Draw
		render_data_clear(&GLOBAL.render_data)
		GLOBAL.render_data.view = view
		GLOBAL.render_data.terrain = presentation.terrain
		GLOBAL.render_data.terrain.dt = dt
		text_reset()
		map_pawns_quads(
			&GLOBAL.pawns,
			view,
			window_size,
			pawn_style,
			dt,
			&GLOBAL.render_data.quads[.World],
			&GLOBAL.render_data.quads[.Screen],
		)

		// UI, over everything
		ui_begin(window_size)
		cards_ui(
			&presentation.cards,
			FONT_MAP,
			FONT_CARD_TITLE,
			map_style.paper,
			map_style.ink,
			&cards_view,
			&game_input,
		)
		tweak_ui(tweaks_toggled, FONT_TWEAK)
		ui_end(input, dt, &GLOBAL.render_data.quads[.Screen])

		if !renderer_draw(&renderer, &GLOBAL.render_data) {
			sdl.Delay(16)
		}
	}
}
