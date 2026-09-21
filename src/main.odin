package odin

import "core:fmt"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

GLOBAL: struct {
	input:       Input,
	render_data: Render_Data,
}

main :: proc() {
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
	render_ctx := new(Render_Ctx)
	defer free(render_ctx)
	if !render_init(render_ctx) {
		return
	}
	defer render_destroy(render_ctx)

	example_texture := populate_render_examples(&GLOBAL.render_data, render_ctx)
	defer gl.DeleteTextures(1, &example_texture)

	if !sdl.GL_SetSwapInterval(1) {
		fmt.eprintf("Enabling VSync failed: %s\n", sdl.GetError())
	}


	keep_going := true
	for keep_going {
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
		render(render_ctx, GLOBAL.render_data)

		sdl.GL_SwapWindow(window)
	}
}

// Returns the example texture, which the caller owns and deletes after rendering.
@(private = "file")
populate_render_examples :: proc(data: ^Render_Data, render_ctx: ^Render_Ctx) -> u32 {
	// Solid rectangle.
	data.instances[0].dst = {80, 80, 240, 180}
	for corner in Corner {
		data.instances[0].color[corner] = {0.2, 0.65, 1.0, 1.0}
	}

	// Bilinear color gradient with a different radius at each corner.
	data.instances[1] = {
		dst = {360, 80, 280, 180},
		color = {
			.Top_Left = {1.0, 0.3, 0.4, 1.0},
			.Top_Right = {1.0, 0.8, 0.2, 1.0},
			.Bot_Right = {0.2, 0.85, 0.5, 1.0},
			.Bot_Left = {0.4, 0.3, 1.0, 1.0},
		},
		radii = {.Top_Left = 8, .Top_Right = 40, .Bot_Right = 70, .Bot_Left = 24},
	}

	// Soft inward edge on a pill-shaped rectangle.
	data.instances[2] = {
		dst = {680, 80, 300, 180},
		radii = {.Top_Left = 90, .Top_Right = 90, .Bot_Right = 90, .Bot_Left = 90},
		softness = 18,
	}
	for corner in Corner {
		data.instances[2].color[corner] = {0.75, 0.4, 1.0, 1.0}
	}

	// Draw the earlier array entry on top using its higher layer.
	data.keys[3] = {
		layer = 2,
	}
	data.instances[3].dst = {180, 370, 260, 180}
	data.keys[4] = {
		layer = 1,
	}
	data.instances[4].dst = {80, 320, 260, 180}
	for corner in Corner {
		data.instances[3].color[corner] = {1.0, 0.3, 0.2, 0.6}
		data.instances[4].color[corner] = {0.1, 0.6, 0.9, 1.0}
	}

	// Dark backing shows the clip bounds; the green quad extends beyond them.
	data.instances[5].dst = {500, 320, 260, 220}
	data.clips[1] = {500, 320, 260, 220}
	data.keys[6] = {
		sequence = 1,
		clip     = 1,
	}
	data.instances[6].dst = {460, 370, 380, 120}
	for corner in Corner {
		data.instances[5].color[corner] = {0.15, 0.2, 0.28, 1.0}
		data.instances[6].color[corner] = {0.3, 0.9, 0.55, 1.0}
	}

	// A tiny texture enlarged with nearest filtering and rounded corners.
	example_texture: u32
	gl.GenTextures(1, &example_texture)
	gl.BindTexture(gl.TEXTURE_2D, example_texture)
	example_pixels := [16]u8 {
		255,
		200,
		60,
		255,
		60,
		160,
		255,
		255,
		240,
		80,
		140,
		255,
		80,
		220,
		160,
		255,
	}
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 2, 2, 0, gl.RGBA, gl.UNSIGNED_BYTE, &example_pixels)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	render_ctx.textures[1] = example_texture
	data.keys[7] = {
		texture = 1,
	}
	data.instances[7] = {
		src = {0, 0, 2, 2},
		dst = {840, 320, 220, 220},
		radii = {.Top_Left = 32, .Top_Right = 32, .Bot_Right = 32, .Bot_Left = 32},
	}
	for corner in Corner {
		data.instances[7].color[corner] = {1, 1, 1, 1}
	}
	return example_texture
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
