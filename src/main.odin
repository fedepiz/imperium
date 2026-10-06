package main

import "core:fmt"
import "core:image"
import "core:math"
import "core:mem"
import "core:os"

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

	// DEMO begin: load the scenario grids, show elevation, centre the camera
	for name, grid in DEMO_GRID_NAMES {
		path := fmt.tprintf("assets/scenarios/roman/%s.png", name)
		data, data_err := os.read_entire_file(path, context.temp_allocator)
		img, img_err := image.load_from_bytes(
			data,
			{.do_not_expand_grayscale},
			context.temp_allocator,
		)
		if data_err != nil || img_err != nil || img.channels != 1 || img.depth != 8 {
			fmt.eprintln("Failed to load", path)
			return
		}
		if img.width != RENDER_GROUND_WIDTH || img.height != RENDER_GROUND_HEIGHT {
			fmt.eprintln("Not the size of the ground", path)
			return
		}
		copy(DEMO.grids[grid][:], img.pixels.buf[:])
	}
	DEMO.shown = .Elevation
	DEMO.value_shown = true
	renderer_ground_write(&renderer, .Value, DEMO.grids[DEMO.shown][:])
	DEMO.view = {
		center = [2]f32{RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT} / 2,
		zoom   = 2 * sdl.GetWindowPixelDensity(window),
	}
	// DEMO end

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
				// DEMO begin: 1-4 select the value grid, 0 turns the value layer off, D toggles the plain look
				#partial switch event.key.scancode {
				case ._1, ._2, ._3, ._4:
					DEMO.shown = Demo_Grid(int(event.key.scancode) - int(sdl.Scancode._1))
					DEMO.value_shown = true
					renderer_ground_write(&renderer, .Value, DEMO.grids[DEMO.shown][:])
				case ._0:
					DEMO.value_shown = false
				case .D:
					DEMO.plain = !DEMO.plain
				}
				// DEMO end
			// DEMO begin: wheel zooms about the cursor, left drag pans
			case .MOUSE_WHEEL:
				size: [2]i32
				sdl.GetWindowSizeInPixels(window, &size.x, &size.y)
				cursor := [2]f32{event.wheel.mouse_x, event.wheel.mouse_y}
				cursor *= sdl.GetWindowPixelDensity(window)
				from_centre := cursor - [2]f32{f32(size.x), f32(size.y)} / 2
				under_cursor := DEMO.view.center + from_centre / DEMO.view.zoom
				DEMO.view.zoom = clamp(DEMO.view.zoom * math.pow(1.15, event.wheel.y), 0.25, 400)
				DEMO.view.center = under_cursor - from_centre / DEMO.view.zoom
			case .MOUSE_MOTION:
				if .LEFT in event.motion.state {
					moved := [2]f32{event.motion.xrel, event.motion.yrel}
					moved *= sdl.GetWindowPixelDensity(window)
					DEMO.view.center -= moved / DEMO.view.zoom
				}
			// DEMO end
			}
		}

		render_data_clear(&GLOBAL.render_data)

		// DEMO begin: ground pass, then world-space quads
		{
			// Map look: stained vellum base, red-to-green value wash
			ground := Render_Ground {
				base = {
					color = {0.840, 0.772, 0.620},
					stain = {0.720, 0.620, 0.460},
					stain_amount = 0.5,
				},
				value = {low = {0.85, 0.45, 0.35}, high = {0.45, 0.75, 0.40}, strength = 0.8},
			}
			// Plain look: white base, black-to-white value wash. Shows the raw grid as grey
			if DEMO.plain {
				ground = {
					base = {color = {1, 1, 1}},
					value = {low = {0, 0, 0}, high = {1, 1, 1}, strength = 1},
				}
			}
			if !DEMO.value_shown do ground.value.strength = 0
			append(&GLOBAL.render_data.passes, Render_Ground_Pass{ground = ground})

			red := [4]u8{180, 64, 40, 255}
			quads: [dynamic; 32]Render_Quad
			middle := [2]f32{RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT} / 2

			// 12 pills around the grid centre. Pill from a to b, half width w:
			// rect of size (|b - a| + 2w, 2w) centred on the midpoint, radii = w, axis = b - a
			for i in 0 ..< 12 {
				angle := f32(i) * math.TAU / 12
				along := [2]f32{math.cos(angle), math.sin(angle)}
				a := middle + along * 4
				b := middle + along * 14
				w := f32(0.6)
				centre := (a + b) / 2
				half_length := f32(5) + w
				append(
					&quads,
					Render_Quad {
						rect = {
							centre.x - half_length,
							centre.y - w,
							centre.x + half_length,
							centre.y + w,
						},
						colors = {red, red, red, red},
						radii = w,
						axis = b - a,
					},
				)
			}

			// Rotating pill
			seconds := f32(sdl.GetTicks()) / 1000
			append(
				&quads,
				Render_Quad {
					rect = {middle.x + 24, middle.y - 1, middle.x + 36, middle.y + 1},
					colors = {red, red, red, red},
					radii = 1,
					axis = {math.cos(seconds), math.sin(seconds)},
				},
			)

			render_data_quad_pass(&GLOBAL.render_data, .World, quads[:])
		}
		// DEMO end

		render_data_quad_pass(
			&GLOBAL.render_data,
			.Screen,
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
			render_data_quad_pass(&GLOBAL.render_data, .Screen, {logo})
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
			render_data_quad_pass(&GLOBAL.render_data, .Screen, glyph_quads[:len(text)])
		}

		// DEMO: view from the demo camera
		view := DEMO.view
		if !renderer_draw(
			&renderer,
			view,
			GLOBAL.render_data.quads[:],
			GLOBAL.render_data.passes[:],
		) {
			sdl.Delay(16)
		}
	}
}

// DEMO begin
@(private = "file")
DEMO: struct {
	// Camera
	view:        Render_View,
	// Scenario grids, 1 byte per cell
	grids:       [Demo_Grid][RENDER_GROUND_WIDTH * RENDER_GROUND_HEIGHT]u8,
	// Grid currently written to the Value grid, and value layer on/off
	shown:       Demo_Grid,
	value_shown: bool,
	// Plain look instead of the map look
	plain:       bool,
}

@(private = "file")
Demo_Grid :: enum {
	Surface,
	Elevation,
	Trees,
	Moisture,
}

@(private = "file")
DEMO_GRID_NAMES :: [Demo_Grid]string {
	.Surface   = "surface",
	.Elevation = "elevation",
	.Trees     = "trees",
	.Moisture  = "moisture",
}
// DEMO end

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
render_data_quad_pass :: proc(
	data: ^Render_Data,
	space: Render_Space,
	quads: []Render_Quad,
) {
	// Budgets are enforced by the fixed capacities
	if len(data.passes) >= RENDER_PASS_MAX do return
	base := len(data.quads)
	count := append(&data.quads, ..quads)
	if count == 0 do return

	pass := Render_Quad_Pass {
		space = space,
		begin = base,
		len   = count,
	}
	append(&data.passes, pass)
}
