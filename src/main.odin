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
		assets_load(&GLOBAL.assets, loaded)
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
		render_data_quad_pass(
			&GLOBAL.render_data,
			0,
			{
				// Corner gradient: red TL, green TR, blue BR, yellow BL
				{
					rect = {100, 100, 500, 400},
					colors = {
						{255, 0, 0, 255},
						{0, 255, 0, 255},
						{0, 0, 255, 255},
						{255, 255, 0, 255},
					},
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
					colors = {
						{230, 120, 30, 255},
						{230, 120, 30, 255},
						{230, 120, 30, 255},
						{230, 120, 30, 255},
					},
				},
				// Rounded
				{
					rect = {100, 650, 350, 800},
					colors = {
						{200, 60, 50, 255},
						{200, 60, 50, 255},
						{200, 60, 50, 255},
						{200, 60, 50, 255},
					},
					radii = 24,
				},
				// Rounded border
				{
					rect = {400, 650, 650, 800},
					colors = {
						{240, 230, 200, 255},
						{240, 230, 200, 255},
						{240, 230, 200, 255},
						{240, 230, 200, 255},
					},
					radii = 24,
					thickness = 4,
				},
				// Soft shadow-like blob
				{
					rect = {1300, 150, 1500, 350},
					colors = {{0, 0, 0, 200}, {0, 0, 0, 200}, {0, 0, 0, 200}, {0, 0, 0, 200}},
					radii = 16,
					softness = 16,
				},
				// Circle, clipped to its left half
				{
					rect = {1300, 450, 1500, 650},
					clip = {1300, 450, 1400, 650},
					colors = {
						{80, 160, 220, 255},
						{80, 160, 220, 255},
						{80, 160, 220, 255},
						{80, 160, 220, 255},
					},
					radii = 100,
				},
				// Vertical fade to transparent
				{
					rect = {900, 450, 1200, 750},
					colors = {
						{240, 230, 200, 255},
						{240, 230, 200, 255},
						{240, 230, 200, 0},
						{240, 230, 200, 0},
					},
				},
			},
		)


		// Logo at its original size
		{
			logo_size := [2]f32 {
				GLOBAL.assets.image_rects[0].x_max - GLOBAL.assets.image_rects[0].x_min,
				GLOBAL.assets.image_rects[0].y_max - GLOBAL.assets.image_rects[0].y_min,
			}
			white := [4]u8{255, 255, 255, 255}
			logo := Render_Quad {
				rect   = {1300, 700, 1300 + logo_size.x / 2, 700 + logo_size.y / 2},
				source = GLOBAL.assets.image_rects[0],
				colors = {white, white, white, white},
			}
			render_data_quad_pass(&GLOBAL.render_data, 0, {logo})
		}

		// Text, one quad per glyph along the baseline
		{
			font := &GLOBAL.assets.fonts[0]
			text := "Imperium, late antiquity"
			color := [4]u8{240, 230, 200, 255}
			pen := [2]f32{100, 30 + font.ascent}
			glyph_quads: [64]Render_Quad
			for char, i in text {
				glyph := font.glyphs[int(char) - FONT_FIRST]
				size := [2]f32 {
					glyph.source.x_max - glyph.source.x_min,
					glyph.source.y_max - glyph.source.y_min,
				}
				top_left := pen + glyph.offset
				glyph_quads[i] = {
					rect   = {top_left.x, top_left.y, top_left.x + size.x, top_left.y + size.y},
					source = glyph.source,
					colors = {color, color, color, color},
				}
				pen.x += glyph.advance
			}
			render_data_quad_pass(&GLOBAL.render_data, 0, glyph_quads[:len(text)])
		}

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
