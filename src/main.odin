package main

import "core:fmt"
import "core:mem"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

GLOBAL: struct {
	input:       Input,
	render_data: Render_Data,
	render_ctx:  Render_Ctx,
	sprites:     Sprites,
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
	render_ctx := &GLOBAL.render_ctx
	if !render_init(render_ctx) {
		return
	}
	defer render_destroy(render_ctx)

	sprites_font_define(&GLOBAL.sprites, Font_Id(Font_Name.Default), "MeathFLF", 24)
	sprites_font_define(&GLOBAL.sprites, Font_Id(Font_Name.Heading), "MeathFLF", 32)
	sprites_image_define(&GLOBAL.sprites, Image_Id(Image_Name.Logo), "logo")
	sprites_load(&GLOBAL.sprites, render_ctx)
	ui_init(&GLOBAL.sprites)

	if !sdl.GL_SetSwapInterval(1) {
		fmt.eprintf("Enabling VSync failed: %s\n", sdl.GetError())
	}

	demo: Demo
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

		{
			draw: Draw_Ctx
			clip_span := span_from_array(&GLOBAL.render_data.clips)
			span_advance(&clip_span) // Clip zero means unclipped.
			draw_begin(
				&draw,
				&GLOBAL.render_data,
				&GLOBAL.sprites,
				span_from_array(&GLOBAL.render_data.instances),
				clip_span,
			)

			ui_begin({f32(logical_width), f32(logical_height)})
			demo_build(&demo)
			ui_end(GLOBAL.input, &draw, dt)
		}

		render_ctx.view_size = {f32(logical_width), f32(logical_height)}
		render(render_ctx, GLOBAL.render_data)
		sdl.GL_SwapWindow(window)
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

// A small showcase in the colors of ui2's "Midnight" theme.
Demo :: struct {
	presses: int,
	locked:  bool,
}

MIDNIGHT_BACKGROUND :: [4]f32{0.07, 0.09, 0.13, 1}
MIDNIGHT_PANEL :: [4]f32{0.105, 0.125, 0.165, 1}
MIDNIGHT_BUTTON :: [4]f32{0.15, 0.17, 0.21, 1}
MIDNIGHT_TEXT :: [4]f32{0.91, 0.92, 0.94, 1}
MIDNIGHT_BORDER :: [4]f32{0.24, 0.29, 0.36, 1}
MIDNIGHT_HOT :: [4]f32{0.24, 0.32, 0.43, 1}
MIDNIGHT_ACTIVE :: [4]f32{0.29, 0.41, 0.56, 1}
MIDNIGHT_GOLD :: [4]f32{0.9, 0.71, 0.38, 1}
MIDNIGHT_MUTED :: [4]f32{0.55, 0.61, 0.7, 1}
MIDNIGHT_PRIMARY :: [4]f32{0.23, 0.39, 0.61, 1}
MIDNIGHT_DANGER :: [4]f32{0.48, 0.15, 0.19, 1}
// Text drawn on the saturated primary and danger fills
MIDNIGHT_TEXT_ON_FILL :: [4]f32{1, 1, 1, 1}

// Pushed over the whole demo: every box inherits these colors.
MIDNIGHT :: Ui_Style {
	background        = MIDNIGHT_BUTTON,
	hot_background    = MIDNIGHT_HOT,
	active_background = MIDNIGHT_ACTIVE,
	border            = MIDNIGHT_BORDER,
	focus_border      = MIDNIGHT_GOLD,
	text_color        = MIDNIGHT_TEXT,
	radius            = 5,
	thickness         = 1,
}

// Styles holding a Ui_Size are not compile-time constants, so they are globals; treat them as read-only.
MIDNIGHT_PANEL_STYLE := Ui_Style {
	width      = Ui_Size{.Fit, 0, 1},
	height     = Ui_Size{.Fit, 0, 1},
	padding    = [2]f32{16, 14},
	gap        = 8,
	background = MIDNIGHT_PANEL,
}

MIDNIGHT_HEADING := Ui_Style {
	font       = Font_Id(Font_Name.Heading),
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
	ui_style_push(MIDNIGHT)
	defer ui_style_pop()

	if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{24, 20}, gap = 16}) {
		if ui_column({width = ui_fit(), height = ui_fit(), gap = 2}) {
			demo_label("Imperium", MIDNIGHT_HEADING)
			demo_label("Immediate boxes. Fixed tables. No heap.", MIDNIGHT_MUTED_TEXT)
		}

		if ui_row({width = ui_fit(), height = ui_fit(), gap = 16}) {
			if ui_panel("controls", MIDNIGHT_PANEL_STYLE) {
				demo_label("Controls", MIDNIGHT_HEADING)
				demo_label(fmt.tprintf("Button presses: %d", demo.presses))
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					if demo_button("Press me", MIDNIGHT_PRIMARY_BUTTON).pressed {
						demo.presses += 1
					}
					if demo_button("Reset", MIDNIGHT_DANGER_BUTTON).pressed {
						demo.presses = 0
					}
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_checkbox("Locked", &demo.locked)
					demo_button("Guarded", {disabled = demo.locked})
				}
				demo_label("Locked disables the button next to it.", MIDNIGHT_MUTED_TEXT)
			}

			if ui_panel("styles", MIDNIGHT_PANEL_STYLE) {
				demo_label("Styles", MIDNIGHT_HEADING)
				demo_label("Plain values: push them, or pass them.")
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Ordinary")
					demo_button("Primary", MIDNIGHT_PRIMARY_BUTTON)
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Danger", MIDNIGHT_DANGER_BUTTON)
					demo_button("Unavailable", {disabled = true})
				}
				demo_label("Click a button to give it focus.", MIDNIGHT_MUTED_TEXT)
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
