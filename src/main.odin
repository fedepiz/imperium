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

	window := sdl.CreateWindow("window", 1600, 900, {.OPENGL, .HIGH_PIXEL_DENSITY})
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
	sprites_image_define(&GLOBAL.sprites, Image_Id(Image_Name.Logo), "logo")
	sprites_load(&GLOBAL.sprites, render_ctx)

	if !sdl.GL_SetSwapInterval(1) {
		fmt.eprintf("Enabling VSync failed: %s\n", sdl.GetError())
	}


	keep_going := true
	for keep_going {
		free_all(context.temp_allocator)

		event: sdl.Event

		GLOBAL.input.keys[.Old] = GLOBAL.input.keys[.New]
		GLOBAL.input.btns[.Old] = GLOBAL.input.btns[.New]

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
			case .MOUSE_BUTTON_UP:
				id := event.button.button
				GLOBAL.input.btns[.New][.Down][id] = false
			case .MOUSE_MOTION:
				GLOBAL.input.pos = {event.motion.x, event.motion.y}
				GLOBAL.input.pos_is_valid = true
			case .WINDOW_MOUSE_LEAVE:
				GLOBAL.input.pos_is_valid = false
			}
		}

		if key_is_pressed(GLOBAL.input, .ESCAPE) {
			keep_going = false
		}

		if !keep_going {
			break
		}

		width, height: i32
		if !sdl.GetWindowSizeInPixels(window, &width, &height) {
			fmt.eprintf("Getting the window pixel size failed: %s\n", sdl.GetError())
			return
		}
		gl.Viewport(0, 0, width, height)
		gl.ClearColor(0.08, 0.10, 0.14, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		logical_width, logical_height: i32
		if !sdl.GetWindowSize(window, &logical_width, &logical_height) {
			fmt.eprintf("Getting the window size failed: %s\n", sdl.GetError())
			return
		}

		render_ctx.view_size = {f32(logical_width), f32(logical_height)}

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

			draw_image(&draw, Image_Id(Image_Name.Logo), {1040, 80, 224, 224}, {1, 1, 1, 1})
			draw_rectangle(&draw, {80, 80, 240, 180}, {0.2, 0.65, 1.0, 1.0})
			draw_rectangle_lines(
				&draw,
				{360, 80, 280, 180},
				{1.0, 0.3, 0.4, 1.0},
				6,
				radius = 40,
				softness = 1,
			)
			draw_rectangle(
				&draw,
				{680, 80, 300, 180},
				{0.75, 0.4, 1.0, 1.0},
				radius = 90,
				softness = 18,
			)

			draw.layer = 2
			draw_rectangle(&draw, {180, 370, 260, 180}, {1.0, 0.3, 0.2, 0.6})
			draw.layer = 1
			draw_rectangle(&draw, {80, 320, 260, 180}, {0.1, 0.6, 0.9, 1.0})
			draw.layer = 0
			draw_rectangle(&draw, {500, 320, 260, 220}, {0.15, 0.2, 0.28, 1.0})
			draw_clip_push(&draw, {500, 320, 260, 220})
			draw_rectangle(&draw, {460, 370, 380, 120}, {0.3, 0.9, 0.55, 1.0})
			draw_clip_pop(&draw)

			draw_text(
				&draw,
				Font_Id(Font_Name.Default),
				"MeathFLF - The quick brown fox",
				{80, 590},
				{1, 1, 1, 1},
			)
			draw_text_wrapped(
				&draw,
				Font_Id(Font_Name.Default),
				"A font is defined by name, loaded once, and drawn from its atlas. This paragraph wraps to the available width.",
				{80, 630},
				420,
				{0.8, 0.85, 0.9, 1},
			)
		}

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
