package main

import "core:fmt"
import "core:mem"

import sdl "vendor:sdl3"

GLOBAL: struct {
	assets:      Assets,
	render_data: Render_Data,
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
		assets_load(&GLOBAL.assets, sdl.GetWindowPixelDensity(window), loaded)
		renderer = renderer_init(
			window,
			{ASSETS_ATLAS_SIZE, ASSETS_ATLAS_SIZE},
			GLOBAL.assets.image_rects[:],
			loaded.pixels[:],
		)
	}
	defer renderer_deinit(renderer)

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
			}
		}

		render_data_clear(&GLOBAL.render_data)

		renderer_update(&renderer, GLOBAL.render_data.updates[:])
		if !renderer_draw(
			&renderer,
			{zoom = 1},
			GLOBAL.render_data.quads[:],
			GLOBAL.render_data.passes[:],
		) {
			sdl.Delay(16)
		}
	}
}

@(private = "file")
Render_Data :: struct {
	updates: [dynamic; RENDER_UPDATES_MAX]Render_Update,
	quads:   [dynamic; RENDER_QUADS_MAX]Render_Quad,
	passes:  [dynamic; RENDER_PASS_MAX]Render_Pass,
}

@(private = "file")
render_data_clear :: proc(data: ^Render_Data) {
	clear(&data.updates)
	clear(&data.quads)
	clear(&data.passes)
}
