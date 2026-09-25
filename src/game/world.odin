package game

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

import "../gfx"
import "../span"

WORLD: struct {
	camera:   Camera,
	atlas:    Atlas,
	pawns:    Pawns,
	// What the map is drawn from, kept up to date by world_tick
	map_draw: Map_Draw,
}

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT

#assert(gfx.RENDER_TERRAIN_WIDTH == WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == WORLD_HEIGHT)

Atlas :: struct {
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	revision: u32,
	terrain:  [CELLS_MAX]Terrain,
}

Terrain :: struct {
	surface:   Surface,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
}

// What covers a cell. A river is land it runs across: the rules treat it as land, the map draws it as a line.
Surface :: enum u8 {
	Land,
	River,
	Lake,
	Sea,
}

WATER :: bit_set[Surface]{.Lake, .Sea}

// Defines the world's images, so call this before sprites_load. The terrain comes from a scenario, with world_load.
world_init :: proc() {
	camera_init()
	map_draw_init(&WORLD.map_draw)
	pawns_init(&WORLD.pawns)
}

// Loads a scenario's terrain from its folder: one greyscale PNG per property, WORLD_WIDTH by WORLD_HEIGHT.
// surface.png is black for land, then darker to lighter grey for river, lake and sea; elevation.png, trees.png and
// moisture.png run from 0 to 255 on land.
// If a layer is missing or the wrong size, the world is left all water, so the failure shows, and false is returned.
world_load :: proc(scenario: string) -> bool {
	terrain := &WORLD.atlas.terrain
	defer WORLD.atlas.revision += 1
	Layer :: enum {
		Surface,
		Elevation,
		Trees,
		Moisture,
	}
	names := [Layer]string {
		.Surface   = "surface",
		.Elevation = "elevation",
		.Trees     = "trees",
		.Moisture  = "moisture",
	}
	for name, layer in names {
		path := fmt.tprintf("%s/%s.png", scenario, name)
		pixels, ok := world_load_layer(path)
		if !ok {
			for &cell in terrain do cell = {
				surface = .Sea,
			}
			return false
		}
		for value, i in pixels {
			switch layer {
			case .Surface:
				terrain[i].surface = Surface(min((int(value) + 42) / 85, int(max(Surface))))
			case .Elevation:
				terrain[i].elevation = value
			case .Trees:
				terrain[i].trees = value
			case .Moisture:
				terrain[i].moisture = value
			}
		}
	}
	// Water cells carry nothing else.
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	return true
}

// One greyscale layer, WORLD_WIDTH by WORLD_HEIGHT; the pixels live in the temp allocator.
@(private = "file")
world_load_layer :: proc(path: string) -> (pixels: []u8, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read terrain layer %q: %v", path, err)
		return
	}
	width, height, channels: c.int
	loaded := stbi.load_from_memory(
		raw_data(data),
		c.int(len(data)),
		&width,
		&height,
		&channels,
		1,
	)
	if loaded == nil {
		fmt.eprintfln("Could not decode terrain layer %q: %s", path, stbi.failure_reason())
		return
	}
	defer stbi.image_free(loaded)
	if width != WORLD_WIDTH || height != WORLD_HEIGHT {
		fmt.eprintfln(
			"Terrain layer %q is %dx%d; it should be %dx%d",
			path,
			width,
			height,
			WORLD_WIDTH,
			WORLD_HEIGHT,
		)
		return
	}
	pixels = make([]u8, CELLS_MAX, context.temp_allocator)
	copy(pixels, loaded[:CELLS_MAX])
	return pixels, true
}

// Inputs used by the game module, in logical pixels unless stated
Input :: struct {
	// Size of the view the map fills
	viewport:      [2]f32,
	pixel_density: f32,
	cursor:        [2]f32,
	// The cursor is over the map, not over the ui or outside the window
	on_map:        bool,
	// The button that drags the map is held
	grab:          bool,
	// Keyboard panning along each axis, from -1 to 1; positive y is down the map
	pan:           [2]f32,
	// Wheel movement this frame, in notches; positive zooms in
	wheel:         f32,
}

// Called every frame
world_tick :: proc(input: Input, dt: f32) {
	camera_tick(input, dt)
	map_draw_tick(&WORLD.map_draw, &WORLD.atlas, WORLD.camera, input.viewport, input.pixel_density)

	// Test pawns in late-Roman Italy and Germanic lands north of the Alps, set every frame until there are pieces
	Test_Pawn :: struct {
		pos:     [2]f32,
		image:   Pawn_Image,
		scale:   f32,
		name:    string,
		culture: Culture,
	}
	@(static, rodata)
	TEST_PAWNS := [?]Test_Pawn {
		{{342, 432}, .Town_3, 1.8, "Roma", .Roman},
		{{296, 374}, .Town_3, 1.5, "Mediolanum", .Roman},
		{{345, 389}, .Town_2, 1.4, "Ravenna", .Roman},
		{{367, 369}, .Town_2, 1.4, "Aquileia", .Roman},
		{{367, 449}, .Town_2, 1.4, "Neapolis", .Roman},
		{{360, 441}, .Town_0, 1.1, "Capua", .Roman},
		{{411, 452}, .Town_0, 1.1, "Brundisium", .Roman},
		{{334, 419}, .Army, 1.1, "", .Roman},
		{{353, 455}, .Fleet, 1.1, "", .Roman},
		{{355, 393}, .Fleet, 1.1, "", .Roman},
		{{350, 430}, .Bishop, 1.2, "", .Roman},
		{{306, 382}, .Envoy, 1.2, "", .Roman},
		{{352, 438}, .Merchant, 1.2, "", .Roman},
		{{373, 375}, .Spy, 1.2, "", .Roman},
		{{300, 300}, .Town_3, 1.5, "Alamannia", .Germanic},
		{{332, 318}, .Town_2, 1.4, "Castra Regina", .Germanic},
		{{270, 322}, .Town_1, 1.4, "Brisiacum", .Germanic},
		{{285, 285}, .Town_0, 1.1, "", .Germanic},
		{{316, 342}, .Army, 1.1, "", .Germanic},
		{{292, 340}, .Envoy, 1.2, "", .Germanic},
		{{350, 330}, .Spy, 1.2, "", .Germanic},
	}
	for test, i in TEST_PAWNS {
		WORLD.pawns.entries[i] = {
			active  = true,
			pos     = test.pos,
			scale   = test.scale,
			image   = test.image,
			culture = test.culture,
			name    = test.name,
		}
	}
	pawns_draw(&WORLD.pawns, input.viewport, WORLD.camera, input.pixel_density)
}

PAWNS_MAX :: 1024

Pawns :: struct {
	entries:     [PAWNS_MAX]Pawn,
	// Each drawing a pawn can be, in each culture's style, defined by pawns_init; a culture may not have them all yet.
	images:      [Culture][Pawn_Image]gfx.Image_Id,
	has_image:   [Culture][Pawn_Image]bool,
	// Each drawing's silhouette, drawn in paper under it so the map's marks do not show through; only drawings with a
	// <name>_fill.png have one
	fills:       [Culture][Pawn_Image]gfx.Image_Id,
	has_fill:    [Culture][Pawn_Image]bool,
	// What pawns' names are written in
	font:        gfx.Font_Id,
	render_list: gfx.Render_List,
}

Pawn :: struct {
	active:  bool,
	// Where the drawing is centred, in cells
	pos:     [2]f32,
	// How large the drawing is against its natural size: see PAWN_CELLS_PER_PIXEL
	scale:   f32,
	image:   Pawn_Image,
	// Whose style the drawing is in
	culture: Culture,
	// Written under the pawn, unless empty. Set every frame, so it can live in the temp allocator.
	name:    string,
}

// The ink pawns' names are written in: the map's
PAWN_NAME_INK :: [4]f32{0.150, 0.105, 0.070, 1}

// The map's paper, which pawns' silhouettes and the halos round their names are drawn in
PAWN_PAPER :: [4]f32{0.840, 0.772, 0.620, 1}

// What a pawn is drawn as; each culture has its own drawing of each.
Pawn_Image :: enum u8 {
	Town_0,
	Town_1,
	Town_2,
	Town_3,
	Army,
	Fleet,
	Bishop,
	Envoy,
	Merchant,
	Spy,
}

// The peoples whose drawings pawns can be in
Culture :: enum u8 {
	Roman,
	Germanic,
}

// Every drawing is made at the same scale, so drawing each at this many cells per pixel of its image, times its pawn's
// scale, keeps the pen line the same weight across them all.
PAWN_CELLS_PER_PIXEL :: f32(7.5 / 400.0)

// The drawings of each pawn image, under assets/gfx/pawns, as <culture>_<name>, made from art/pawns by tools/pawnify
@(private = "file")
CULTURE_NAMES := [Culture]string {
	.Roman    = "roman",
	.Germanic = "germanic",
}

@(private = "file")
PAWN_IMAGE_NAMES := [Pawn_Image]string {
	.Town_0   = "town_0",
	.Town_1   = "town_1",
	.Town_2   = "town_2",
	.Town_3   = "town_3",
	.Army     = "army",
	.Fleet    = "fleet",
	.Bishop   = "bishop",
	.Envoy    = "envoy",
	.Merchant = "merchant",
	.Spy      = "spy",
}

// Defines the pawns' images, so call this before sprites_load.
pawns_init :: proc(pawns: ^Pawns) {
	for culture_name, culture in CULTURE_NAMES {
		for name, image in PAWN_IMAGE_NAMES {
			drawing := fmt.tprintf("pawns/%s_%s", culture_name, name)
			if !os.exists(fmt.tprintf("assets/gfx/%s.png", drawing)) do continue
			pawns.images[culture][image] = gfx.sprites_image_add(drawing)
			pawns.has_image[culture][image] = true
			fill := fmt.tprintf("%s_fill", drawing)
			if os.exists(fmt.tprintf("assets/gfx/%s.png", fill)) {
				pawns.fills[culture][image] = gfx.sprites_image_add(fill)
				pawns.has_fill[culture][image] = true
			}
		}
	}
	pawns.font = gfx.sprites_font_add("forgotten_uncial", 22)
}

pawns_draw :: proc(pawns: ^Pawns, viewport: [2]f32, camera: Camera, pixel_density: f32) {
	// Prepare drawing
	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&pawns.render_list,
		span.from_array(&pawns.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		pixel_density,
	)

	for pawn in pawns.entries {
		if !pawn.active do continue
		if !pawns.has_image[pawn.culture][pawn.image] do continue
		image := pawns.images[pawn.culture][pawn.image]
		source := gfx.sprite_region(gfx.sprite_of_image(image)).source
		if source.z <= 0 do continue
		size := source.zw * PAWN_CELLS_PER_PIXEL * pawn.scale * camera.zoom
		center := (pawn.pos - camera.center) * camera.zoom + viewport / 2
		rect := [4]f32{center.x - size.x / 2, center.y - size.y / 2, size.x, size.y}
		if rect.x > viewport.x || rect.y > viewport.y || rect.x + rect.z < 0 || rect.y + rect.w < 0 do continue
		if pawns.has_fill[pawn.culture][pawn.image] {
			gfx.draw_image(&draw, pawns.fills[pawn.culture][pawn.image], rect, PAWN_PAPER)
		}
		gfx.draw_image(&draw, image, rect, {1, 1, 1, 1})
		// The name keeps its size on screen, centred under the drawing, over a halo of paper: the name drawn in the
		// paper's colour a little way off all round.
		if pawn.name != "" {
			HALO :: 1.5
			text := gfx.text_from_string(pawn.name, pawns.font, PAWN_NAME_INK)
			halo := gfx.text_from_string(pawn.name, pawns.font, PAWN_PAPER)
			text_size := gfx.text_measure(text)
			at := [2]f32{center.x - text_size.x / 2, rect.y + rect.w}
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					if dx == 0 && dy == 0 do continue
					gfx.text_draw(&draw, halo, at + [2]f32{f32(dx), f32(dy)} * HALO)
				}
			}
			gfx.text_draw(&draw, text, at)
		}
	}
}
