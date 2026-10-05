package main

import "core:fmt"

import sdl "vendor:sdl3"

GLOBAL: struct {
	render_data: Render_Data,
}

main :: proc() {
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


	// WGPU initialisation

	renderer := renderer_init(window)
	defer renderer_deinit(renderer)

	running := true
	for running {
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
		render_data_quad_pass(
			&GLOBAL.render_data,
			0,
			{
				// Corner gradient: red TL, green TR, blue BR, yellow BL
				{
					rect = {100, 100, 500, 400},
					colors = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 0, 255}},
				},
				// Translucent white overlapping the gradient
				{
					rect = {300, 250, 800, 600},
					colors = {
						{255, 255, 255, 128},
						{255, 255, 255, 128},
						{255, 255, 255, 128},
						{255, 255, 255, 128},
					},
				},
				// Opaque flat orange
				{
					rect = {900, 150, 1200, 350},
					colors = {{230, 120, 30, 255}, {230, 120, 30, 255}, {230, 120, 30, 255}, {230, 120, 30, 255}},
				},
				// Vertical fade to transparent
				{
					rect = {900, 450, 1200, 750},
					colors = {{240, 230, 200, 255}, {240, 230, 200, 255}, {240, 230, 200, 0}, {240, 230, 200, 0}},
				},
			},
		)


		if !renderer_draw(&renderer, GLOBAL.render_data.quads[:], GLOBAL.render_data.passes[:]) {
			sdl.Delay(16)
		}
	}
}

@(private = "file")
Render_Data :: struct {
	quads:  [dynamic; RENDER_QUADS_MAX]Render_Quad,
	passes: [dynamic; RENDER_PASS_MAX]Render_Pass,
}

@(private = "file")
render_data_clear :: proc(data: ^Render_Data) {
	clear(&data.quads)
	clear(&data.passes)
}

@(private = "file")
render_data_quad_pass :: proc(data: ^Render_Data, texture: Texture_Id, quads: []Render_Quad) {
	// Budgets are enforced by the fixed capacities
	if len(data.passes) >= RENDER_PASS_MAX do return
	base := len(data.quads)
	count := append(&data.quads, ..quads)
	if count == 0 do return

	pass := Render_Quad_Pass {
		texture = texture,
		begin   = base,
		len     = count,
	}
	append(&data.passes, pass)
}
