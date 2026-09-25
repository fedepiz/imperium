package main

import "core:fmt"
import "core:math"
import "core:mem"
import "game"
import "gfx"
import "span"
import "tweak"
import sdl "vendor:sdl3"

GLOBAL: struct {
	input:       Input,
	render_list: gfx.Render_List,
	renderer:    gfx.Renderer,
	fonts:       [Font_Name]gfx.Font_Id,
	images:      [Image_Name]gfx.Image_Id,
}

Font_Name :: enum {
	Default,
	Heading,
	Small,
}

Image_Name :: enum {
	Logo,
}

main :: proc() {
	context.allocator = mem.panic_allocator()

	if !sdl.Init({.VIDEO}) {
		fmt.eprintf("SDL initialization failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.Quit()

	render_flags, render_flags_ok := gfx.render_window_flags()
	if !render_flags_ok {
		return
	}
	window := sdl.CreateWindow(
		"Imperium",
		1600,
		900,
		render_flags + {.HIGH_PIXEL_DENSITY, .RESIZABLE},
	)
	if window == nil {
		fmt.eprintf("Window creation failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	if !sdl.StartTextInput(window) {
		fmt.eprintf("Starting text input failed: %s\n", sdl.GetError())
	}
	renderer := &GLOBAL.renderer
	if !gfx.render_init(renderer, window) {
		return
	}
	defer gfx.render_destroy(renderer)

	pixel_density := sdl.GetWindowPixelDensity(window)
	if pixel_density <= 0 do pixel_density = 1

	font_file := "aniron" //MeathFLF"
	GLOBAL.fonts = {
		.Default = gfx.sprites_font_add(font_file, 26),
		.Heading = gfx.sprites_font_add(font_file, 34),
		.Small   = gfx.sprites_font_add(font_file, 18),
	}
	MIDNIGHT_HEADING.font = GLOBAL.fonts[.Heading]
	GLOBAL.images[.Logo] = gfx.sprites_image_add("logo")
	game.world_init()
	if !game.world_load("assets/scenarios/roman") {
		fmt.eprintln("The scenario did not load; the world is all water.")
	}
	gfx.sprites_load(renderer, pixel_density)
	renderer.pixel_density = pixel_density
	ui_init(GLOBAL.fonts[.Default])

	// Seconds the display shows each frame for, or 0 when unknown
	refresh_period := display_refresh_period(window)

	demo: Demo_Ui
	palette: Palette
	// Frames and time counted toward the next frame rate shown, and the one shown
	fps_frames: int
	fps_time, fps: f32
	frame_previous := sdl.GetTicksNS()
	keep_going := true
	for keep_going {
		free_all(context.temp_allocator)
		frame_now := sdl.GetTicksNS()
		dt := f32(f64(frame_now - frame_previous) / 1e9)
		frame_previous = frame_now

		// With vsync, a frame stays on screen for a whole number of refreshes, whenever the loop happened to wake;
		// stepping by the time shown rather than the time measured keeps motion even.
		if renderer.vsync && refresh_period > 0 {
			dt = max(1, math.round(dt / refresh_period)) * refresh_period
		}
		event: sdl.Event
		GLOBAL.input.keys[.Old] = GLOBAL.input.keys[.New]
		GLOBAL.input.btns[.Old] = GLOBAL.input.btns[.New]
		GLOBAL.input.keys[.New][.Pressed] = {}
		GLOBAL.input.btns[.New][.Pressed] = {}
		GLOBAL.input.wheel = {}
		clear(&GLOBAL.input.events)

		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				keep_going = false
			case .KEY_DOWN:
				id := event.key.scancode
				GLOBAL.input.keys[.New][.Down][id] = true
				GLOBAL.input.keys[.New][.Pressed][id] = !GLOBAL.input.keys[.Old][.Down][id]
				input_event_push(&GLOBAL.input, {kind = .Key, key = id})
			case .TEXT_INPUT:
				for ch in string(event.text.text) {
					input_event_push(&GLOBAL.input, {kind = .Char, char = ch})
				}
			case .KEY_UP:
				id := event.key.scancode
				GLOBAL.input.keys[.New][.Down][id] = false
			case .MOUSE_BUTTON_DOWN:
				id := event.button.button
				GLOBAL.input.btns[.New][.Down][id] = true
				GLOBAL.input.btns[.New][.Pressed][id] = !GLOBAL.input.btns[.Old][.Down][id]
				GLOBAL.input.pos = {event.button.x, event.button.y}
				GLOBAL.input.pos_is_valid = true
			case .MOUSE_BUTTON_UP:
				id := event.button.button
				GLOBAL.input.btns[.New][.Down][id] = false
				GLOBAL.input.pos = {event.button.x, event.button.y}
			case .MOUSE_MOTION:
				GLOBAL.input.pos = {event.motion.x, event.motion.y}
				GLOBAL.input.pos_is_valid = true
			case .MOUSE_WHEEL:
				GLOBAL.input.wheel += {event.wheel.x, event.wheel.y}
				GLOBAL.input.pos = {event.wheel.mouse_x, event.wheel.mouse_y}
				GLOBAL.input.pos_is_valid = true
			case .WINDOW_MOUSE_LEAVE:
				GLOBAL.input.pos_is_valid = false
			case .WINDOW_FOCUS_LOST:
				GLOBAL.input.keys[.New][.Down] = {}
				GLOBAL.input.btns[.New][.Down] = {}
			case .WINDOW_DISPLAY_CHANGED, .DISPLAY_CURRENT_MODE_CHANGED:
				refresh_period = display_refresh_period(window)
			}
		}

		// Escape leaves the game when nothing in the ui is focused; otherwise the ui takes it to drop the focus.
		keep_going &= !(key_is_pressed(GLOBAL.input, .ESCAPE) && !ui_focused_any())
		if !keep_going {
			break
		}

		logical_width, logical_height: i32
		if !sdl.GetWindowSize(window, &logical_width, &logical_height) {
			fmt.eprintf("Getting the window size failed: %s\n", sdl.GetError())
			return
		}

		// Fps calcualtion
		fps_frames += 1
		fps_time += dt
		if fps_time >= FPS_PERIOD {
			fps = f32(fps_frames) / fps_time
			fps_frames, fps_time = 0, 0
		}

		tweak.begin()

		tweak.label("Info/fps", fmt.tprintf("%.0f (%.2f ms)", fps, 1000 / max(fps, 1e-6)))
		if tweak.button("Sys/quit", "Quit") {
			keep_going = false
		}
		demo.enabled = tweak.toggle("Demo.UI", "Shown", demo.enabled)

		// Texts last one frame; the world writes names before the ui builds its texts.
		gfx.text_begin()
		{
			viewport: [2]f32 = {f32(logical_width), f32(logical_height)}
			game.world_tick(game_input(GLOBAL.input, viewport, pixel_density), dt)
		}
		// Tab steps through the map and the raw terrain properties.
		if key_is_pressed(GLOBAL.input, .TAB) && !ui_keyboard_captured() {
			debug := &game.WORLD.map_draw.render_terrain.debug_mode
			debug^ = gfx.Render_Terrain_Debug((int(debug^) + 1) % len(gfx.Render_Terrain_Debug))
		}

		{
			draw: gfx.Draw_Ctx
			gfx.draw_begin(
				&draw,
				&GLOBAL.render_list,
				span.from_array(&GLOBAL.render_list.instances),
				{0, 0, f32(logical_width), f32(logical_height)},
				pixel_density,
			)

			ui_begin({f32(logical_width), f32(logical_height)})
			if demo.enabled do demo_build(&demo)
			palette_build(&palette, GLOBAL.input)
			ui_end(GLOBAL.input, &draw, dt)
		}

		renderer.view_size = {f32(logical_width), f32(logical_height)}
		if gfx.render_frame_begin(
			renderer,
			{MIDNIGHT_BACKGROUND.r, MIDNIGHT_BACKGROUND.g, MIDNIGHT_BACKGROUND.b, 1},
		) {
			gfx.render_terrain(renderer, &game.WORLD.map_draw.render_terrain)
			gfx.render_list(renderer, &game.WORLD.map_draw.render_list)
			gfx.render_list(renderer, &game.WORLD.pawns.render_list)
			gfx.render_list(renderer, &GLOBAL.render_list)
			gfx.render_frame_end(renderer)
		}
	}
}

game_input :: proc(input: Input, viewport: [2]f32, pixel_density: f32) -> game.Input {
	pan: [2]f32
	if !ui_keyboard_captured() {
		if key_is_down(input, .A) || key_is_down(input, .LEFT) do pan.x -= 1
		if key_is_down(input, .D) || key_is_down(input, .RIGHT) do pan.x += 1
		if key_is_down(input, .W) || key_is_down(input, .UP) do pan.y -= 1
		if key_is_down(input, .S) || key_is_down(input, .DOWN) do pan.y += 1
	}
	return {
		viewport = viewport,
		pixel_density = pixel_density,
		cursor = input.pos,
		on_map = bool(input.pos_is_valid) && !ui_hovered_any(),
		grab = button_is_down(input, sdl.BUTTON_LEFT),
		pan = pan,
		wheel = input.wheel.y,
	}
}

// Seconds over which the frame rate is averaged
FPS_PERIOD :: 0.5

// Seconds between refreshes of the display the window is on, or 0 when the display does not say.
display_refresh_period :: proc(window: ^sdl.Window) -> f32 {
	mode := sdl.GetCurrentDisplayMode(sdl.GetDisplayForWindow(window))
	if mode == nil || mode.refresh_rate_numerator <= 0 || mode.refresh_rate_denominator <= 0 {
		return 0
	}
	return f32(mode.refresh_rate_denominator) / f32(mode.refresh_rate_numerator)
}

Old_New :: enum {
	Old,
	New,
}

Button_State :: enum {
	Down,
	Pressed,
}

Input :: struct {
	keys:         [Old_New][Button_State]#sparse[sdl.Scancode]b8,
	btns:         [Old_New][Button_State][max(u8)]b8,
	pos:          [2]f32,
	pos_is_valid: b32,
	// Wheel movement this frame, in notches (fractional on touchpads); positive y is away from the user, positive x to the right
	wheel:        [2]f32,
	// Keys going down, repeats included, and typed characters, in the order they came this frame; the rest are dropped
	events:       [dynamic; INPUT_EVENTS_MAX]Input_Event,
}

INPUT_EVENTS_MAX :: 64

Input_Event_Kind :: enum {
	Key,
	Char,
}

// A key going down, or a character typed
Input_Event :: struct {
	kind: Input_Event_Kind,
	key:  sdl.Scancode,
	char: rune,
}

input_event_push :: proc(input: ^Input, event: Input_Event) {
	if len(input.events) < INPUT_EVENTS_MAX {
		append(&input.events, event)
	}
}

key_is_down :: proc(input: Input, key: sdl.Scancode) -> bool {
	return bool(input.keys[.New][.Down][key])
}

key_is_pressed :: proc(input: Input, key: sdl.Scancode) -> bool {
	return bool(input.keys[.New][.Pressed][key])
}

button_is_down :: proc(input: Input, button: u8) -> bool {
	return bool(input.btns[.New][.Down][button])
}

button_is_pressed :: proc(input: Input, button: u8) -> bool {
	return bool(input.btns[.New][.Pressed][button])
}

// A small showcase of the widgets.
Demo_Ui :: struct {
	enabled:         bool,
	presses:         int,
	locked:          bool,
	difficulty:      int,
	difficulty_open: bool,
	name:            [64]u8,
	name_len:        int,
}

DEMO_DIFFICULTIES := []string{"Easy", "Normal", "Hard"}

// Midnight colors beyond the ui's base style
MIDNIGHT_BACKGROUND :: [4]f32{0.07, 0.09, 0.13, 1}
MIDNIGHT_PANEL :: [4]f32{0.105, 0.125, 0.165, 1}
MIDNIGHT_GOLD :: [4]f32{0.9, 0.71, 0.38, 1}
MIDNIGHT_MUTED :: [4]f32{0.55, 0.61, 0.7, 1}
MIDNIGHT_PRIMARY :: [4]f32{0.23, 0.39, 0.61, 1}
MIDNIGHT_DANGER :: [4]f32{0.48, 0.15, 0.19, 1}
// Text drawn on the saturated primary and danger fills
MIDNIGHT_TEXT_ON_FILL :: [4]f32{1, 1, 1, 1}
// Styles holding a Ui_Size are not compile-time constants, so they are globals; treat them as read-only once main has
// set them up.
MIDNIGHT_PANEL_STYLE := Ui_Style {
	width      = Ui_Size{.Fit, 0, 1},
	height     = Ui_Size{.Fit, 0, 1},
	padding    = [2]f32{16, 14},
	gap        = 8,
	background = MIDNIGHT_PANEL,
}

// Its font is the heading font, set by main once the fonts are defined
MIDNIGHT_HEADING := Ui_Style {
	height     = Ui_Size{.Text, 0, 1},
	text_color = MIDNIGHT_GOLD,
}

MIDNIGHT_MUTED_TEXT :: Ui_Style {
	text_color = MIDNIGHT_MUTED,
}

MIDNIGHT_PRIMARY_BUTTON :: Ui_Style {
	background = MIDNIGHT_PRIMARY,
	text_color = MIDNIGHT_TEXT_ON_FILL,
}

MIDNIGHT_DANGER_BUTTON :: Ui_Style {
	background = MIDNIGHT_DANGER,
	text_color = MIDNIGHT_TEXT_ON_FILL,
}

demo_build :: proc(demo: ^Demo_Ui) {
	if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{24, 20}, gap = 16}) {
		if ui_column({width = ui_fit(), height = ui_fit(), gap = 2}) {
			demo_label("Imperium", MIDNIGHT_HEADING)
			demo_label("Lorem ipsum dolor sit amet.", MIDNIGHT_MUTED_TEXT)
		}

		if ui_row({width = ui_fit(), height = ui_fit(), gap = 16}) {
			if ui_panel("controls", MIDNIGHT_PANEL_STYLE) {
				demo_label("Controls", MIDNIGHT_HEADING)
				demo_label(fmt.tprintf("Button presses: %d", demo.presses))
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					press := demo_button("Press me", MIDNIGHT_PRIMARY_BUTTON)
					if press.pressed {
						demo.presses += 1
					}
					if press.hovered {
						if ui_tooltip(MIDNIGHT_PANEL_STYLE) {
							demo_label("Lorem ipsum dolor sit amet.")
							demo_label(
								"Consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
								{
									width = ui_em(14),
									height = ui_text_dim(),
									text_color = MIDNIGHT_MUTED,
								},
							)
						}
					}
					if demo_button("Reset", MIDNIGHT_DANGER_BUTTON).pressed {
						demo.presses = 0
					}
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_checkbox("Locked", &demo.locked)
					demo_button("Guarded", {disabled = demo.locked})
				}
				ui_label_text(
					{
						{text = "Sed do eiusmod "},
						{text = "tempor", color = MIDNIGHT_GOLD, key = "tempor", underline = true},
						{text = " incididunt."},
					},
					{width = ui_text_dim(), text_color = MIDNIGHT_MUTED},
				)
				if ui_signal("tempor").hovered {
					if ui_tooltip(MIDNIGHT_PANEL_STYLE) {
						demo_label("Lorem ipsum dolor sit amet.")
					}
				}
			}

			if ui_panel("styles", MIDNIGHT_PANEL_STYLE) {
				demo_label("Styles", MIDNIGHT_HEADING)
				ui_label_text(
					{
						{text = "Ut enim "},
						{image = GLOBAL.images[.Logo]},
						{text = " ad minim "},
						{text = "veniam", color = MIDNIGHT_GOLD},
						{text = "."},
					},
					{width = ui_text_dim()},
				)
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Ordinary")
					demo_button("Primary", MIDNIGHT_PRIMARY_BUTTON)
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Danger", MIDNIGHT_DANGER_BUTTON)
					demo_button("Unavailable", {disabled = true})
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_label("Difficulty")
					ui_combo(
						"difficulty",
						&demo.difficulty,
						&demo.difficulty_open,
						DEMO_DIFFICULTIES,
						{width = ui_px(120), padding = [2]f32{10, 0}},
					)
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_label("Name")
					ui_input(
						"name",
						demo.name[:],
						&demo.name_len,
						{width = ui_px(160), padding = [2]f32{10, 0}},
					)
				}
				demo_label("Quis nostrud exercitation.", MIDNIGHT_MUTED_TEXT)
			}

			ui_style_next(MIDNIGHT_PANEL_STYLE)
			if ui_scroll_panel("scrolling", {height = ui_px(180)}) {
				demo_label("Scrolling", MIDNIGHT_HEADING)
				for i in 1 ..= 20 {
					demo_button(fmt.tprintf("Entry %d###entry%d", i, i))
				}
			}
		}
	}
}

// Labels and buttons in the demo hug their text; the style still wins over these.
demo_label :: proc(text: string, style := Ui_Style{}) {
	ui_style_next({width = ui_text_dim()})
	ui_label(text, style)
}

demo_button :: proc(label: string, style := Ui_Style{}) -> Ui_Signal {
	ui_style_next({width = ui_text_dim(), padding = [2]f32{10, 0}})
	return ui_button(label, style)
}

// A checkbox is a row of boxes, so it fits its children rather than a text.
demo_checkbox :: proc(label: string, value: ^bool, style := Ui_Style{}) -> Ui_Signal {
	ui_style_next({width = ui_fit(), padding = [2]f32{10, 0}})
	return ui_checkbox(label, value, style)
}
