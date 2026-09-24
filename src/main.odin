package main

import "core:fmt"
import "core:mem"
import "game"
import "gfx"
import "span"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

GLOBAL: struct {
	input:       Input,
	render_list: gfx.Render_List,
	renderer:    gfx.Renderer,
}

Font_Name :: enum {
	Default,
	Heading,
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

	if !sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3) ||
	   !sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3) ||
	   !sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE)) ||
	   !sdl.GL_SetAttribute(.CONTEXT_FLAGS, i32(sdl.GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)) ||
	   !sdl.GL_SetAttribute(.DOUBLEBUFFER, 1) {
		fmt.eprintf("OpenGL attribute setup failed: %s\n", sdl.GetError())
		return
	}

	window := sdl.CreateWindow("Imperium", 1600, 900, {.OPENGL, .HIGH_PIXEL_DENSITY, .RESIZABLE})
	if window == nil {
		fmt.eprintf("Window creation failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintf("OpenGL context creation failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.GL_DestroyContext(gl_context)

	if !sdl.GL_MakeCurrent(window, gl_context) {
		fmt.eprintf("Making the OpenGL context current failed: %s\n", sdl.GetError())
		return
	}
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)
	renderer := &GLOBAL.renderer
	if !gfx.render_init(renderer) {
		return
	}
	defer gfx.render_destroy(renderer)

	pixel_density := sdl.GetWindowPixelDensity(window)
	if pixel_density <= 0 do pixel_density = 1

	font_file := "aniron" //MeathFLF"
	gfx.sprites_font_define(gfx.Font_Id(Font_Name.Default), font_file, 26)
	gfx.sprites_font_define(gfx.Font_Id(Font_Name.Heading), font_file, 34)
	gfx.sprites_image_define(gfx.Image_Id(Image_Name.Logo), "logo")
	// The world's images follow main's own, and must be defined before the atlas loads.
	game.world_init(gfx.Image_Id(len(Image_Name)))
	gfx.sprites_load(renderer, pixel_density)
	renderer.pixel_density = pixel_density
	ui_init()

	if !sdl.GL_SetSwapInterval(1) {
		fmt.eprintf("Enabling VSync failed: %s\n", sdl.GetError())
	}

	// demo: Demo
	pane: Debug_Pane
	frame_previous := sdl.GetTicksNS()
	keep_going := true
	for keep_going {
		free_all(context.temp_allocator)
		frame_now := sdl.GetTicksNS()
		dt := f32(f64(frame_now - frame_previous) / 1e9)
		frame_previous = frame_now
		event: sdl.Event
		GLOBAL.input.keys[.Old] = GLOBAL.input.keys[.New]
		GLOBAL.input.btns[.Old] = GLOBAL.input.btns[.New]
		GLOBAL.input.keys[.New][.Pressed] = {}
		GLOBAL.input.btns[.New][.Pressed] = {}
		GLOBAL.input.wheel = {}

		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				keep_going = false
			case .KEY_DOWN:
				id := event.key.scancode
				GLOBAL.input.keys[.New][.Down][id] = true
				GLOBAL.input.keys[.New][.Pressed][id] = !GLOBAL.input.keys[.Old][.Down][id]
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
			}
		}

		keep_going &= !key_is_pressed(GLOBAL.input, .ESCAPE)
		if !keep_going {
			break
		}

		width, height: i32
		if !sdl.GetWindowSizeInPixels(window, &width, &height) {
			fmt.eprintf("Getting the window pixel size failed: %s\n", sdl.GetError())
			return
		}
		gl.Viewport(0, 0, width, height)
		gl.ClearColor(MIDNIGHT_BACKGROUND.r, MIDNIGHT_BACKGROUND.g, MIDNIGHT_BACKGROUND.b, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		logical_width, logical_height: i32
		if !sdl.GetWindowSize(window, &logical_width, &logical_height) {
			fmt.eprintf("Getting the window size failed: %s\n", sdl.GetError())
			return
		}

		game.world_tick(game_input(GLOBAL.input, {f32(logical_width), f32(logical_height)}), dt)
		// Tab steps through the map and the raw terrain properties.
		if key_is_pressed(GLOBAL.input, .TAB) {
			debug := &game.WORLD.render_terrain.debug_mode
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

			gfx.text_begin()
			ui_begin({f32(logical_width), f32(logical_height)})
			// demo_build(&demo)
			debug_pane_build(&pane)
			ui_end(GLOBAL.input, &draw, dt)
		}

		renderer.view_size = {f32(logical_width), f32(logical_height)}
		gfx.render_terrain(renderer, &game.WORLD.render_terrain)
		gfx.render_list(renderer, &game.WORLD.render_list)
		gfx.render_list(renderer, &GLOBAL.render_list)
		sdl.GL_SwapWindow(window)
	}
}

// A pane in the top-left corner for looking at the terrain.
Debug_Pane :: struct {
	view_open: bool,
}

// Named in the order of gfx.Render_Terrain_Debug
TERRAIN_VIEW_NAMES := []string{"Map", "Water", "Elevation", "Trees", "Moisture"}

debug_pane_build :: proc(pane: ^Debug_Pane) {
	#assert(len(gfx.Render_Terrain_Debug) == 5)
	// The column only places the pane; it takes no mouse, so the map gets it everywhere else.
	if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{16, 16}}) {
		if ui_panel("debug pane", MIDNIGHT_PANEL_STYLE) {
			demo_label("Terrain", MIDNIGHT_HEADING)
			if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
				demo_label("View")
				// The ui reads and writes the world's render terrain directly.
				view := &game.WORLD.render_terrain.debug_mode
				selection := int(view^)
				ui_combo(
					"terrain view",
					&selection,
					&pane.view_open,
					TERRAIN_VIEW_NAMES,
					{width = ui_px(140), padding = [2]f32{10, 0}},
				)
				view^ = gfx.Render_Terrain_Debug(selection)
			}
		}
	}
}

game_input :: proc(input: Input, viewport: [2]f32) -> game.Input {
	pan: [2]f32
	if key_is_down(input, .A) || key_is_down(input, .LEFT) do pan.x -= 1
	if key_is_down(input, .D) || key_is_down(input, .RIGHT) do pan.x += 1
	if key_is_down(input, .W) || key_is_down(input, .UP) do pan.y -= 1
	if key_is_down(input, .S) || key_is_down(input, .DOWN) do pan.y += 1
	return {
		viewport = viewport,
		cursor = input.pos,
		on_map = bool(input.pos_is_valid) && !ui_hovered_any(),
		grab = button_is_down(input, sdl.BUTTON_LEFT),
		pan = pan,
		wheel = input.wheel.y,
	}
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
Demo :: struct {
	presses:         int,
	locked:          bool,
	difficulty:      int,
	difficulty_open: bool,
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
// Styles holding a Ui_Size are not compile-time constants, so they are globals; treat them as read-only.
MIDNIGHT_PANEL_STYLE := Ui_Style {
	width      = Ui_Size{.Fit, 0, 1},
	height     = Ui_Size{.Fit, 0, 1},
	padding    = [2]f32{16, 14},
	gap        = 8,
	background = MIDNIGHT_PANEL,
}

MIDNIGHT_HEADING := Ui_Style {
	font       = gfx.Font_Id(Font_Name.Heading),
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

demo_build :: proc(demo: ^Demo) {
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
						{image = gfx.Image_Id(Image_Name.Logo)},
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
