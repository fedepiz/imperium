package game

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

import "../gfx"

WORLD: struct {
	camera:     Camera,
	atlas:      Atlas,
	// The first of the image ids given to the world; its own images are numbered from here
	image_base: gfx.Image_Id,
	// What the map is drawn from, kept up to date by world_tick
	map_draw:   Map_Draw,
}

// The drawings a mark can be, each with up to TERRAIN_MARK_VARIANTS variants. Where each is placed is up to
// Mark_Placement.
Terrain_Mark :: enum {
	Conifer,
	Broadleaf,
	Cypress,
	Palm,
	Molehill,
	Mountain,
	Sea_Mark,
	// Steppe grass
	Tuft,
	Marsh,
	Dune,
}

// Each mark has up to this many drawings, so the scatter does not look stamped
TERRAIN_MARK_VARIANTS :: 4

// The drawings of each mark, under assets/gfx; an empty name is a variant the mark does not have.
@(private = "file")
TERRAIN_MARK_IMAGES := [Terrain_Mark][TERRAIN_MARK_VARIANTS]string {
	.Conifer   = {
		"terrain/conifer_0",
		"terrain/conifer_1",
		"terrain/conifer_2",
		"terrain/conifer_3",
	},
	.Broadleaf = {
		"terrain/broadleaf_0",
		"terrain/broadleaf_1",
		"terrain/broadleaf_2",
		"terrain/broadleaf_3",
	},
	.Cypress   = {
		"terrain/cypress_0",
		"terrain/cypress_1",
		"terrain/cypress_2",
		"terrain/cypress_3",
	},
	.Palm      = {"terrain/palm_0", "terrain/palm_1", "terrain/palm_2", "terrain/palm_3"},
	.Molehill  = {"terrain/hill_0", "terrain/hill_1", "terrain/hill_2", "terrain/hill_3"},
	.Mountain  = {
		"terrain/mountain_0",
		"terrain/mountain_1",
		"terrain/mountain_2",
		"terrain/mountain_3",
	},
	.Sea_Mark  = {"terrain/sea_0", "terrain/sea_1", "", ""},
	.Tuft      = {"terrain/tuft_0", "terrain/tuft_1", "terrain/tuft_2", "terrain/tuft_3"},
	.Marsh     = {"terrain/marsh_0", "terrain/marsh_1", "terrain/marsh_2", "terrain/marsh_3"},
	.Dune      = {"terrain/dune_0", "terrain/dune_1", "terrain/dune_2", "terrain/dune_3"},
}

// The world's images, numbered from its image base
WORLD_IMAGES_MAX :: len(Terrain_Mark) * TERRAIN_MARK_VARIANTS

// How many variants a mark has: its leading named drawings.
world_mark_variants :: proc(mark: Terrain_Mark) -> int {
	count := 0
	for name in TERRAIN_MARK_IMAGES[mark] {
		if name == "" do break
		count += 1
	}
	return count
}

// The image of a mark's variant.
world_mark_image :: proc(mark: Terrain_Mark, variant: int) -> gfx.Image_Id {
	return WORLD.image_base + gfx.Image_Id(int(mark) * TERRAIN_MARK_VARIANTS + variant)
}

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT

#assert(gfx.RENDER_TERRAIN_WIDTH == WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == WORLD_HEIGHT)

Atlas :: struct {
	terrain: [CELLS_MAX]Terrain,
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

// The world's images are defined from img_base_index up to WORLD_IMAGES_MAX more, so call this before sprites_load.
// The terrain comes from a scenario, with world_load.
world_init :: proc(img_base_index: gfx.Image_Id) {
	camera_init()

	WORLD.image_base = img_base_index
	for variants, mark in TERRAIN_MARK_IMAGES {
		for name, variant in variants {
			if name == "" do continue
			gfx.sprites_image_define(world_mark_image(mark, variant), name)
		}
	}
	map_draw_init()
}

// Loads a scenario's terrain from its folder: one greyscale PNG per property, WORLD_WIDTH by WORLD_HEIGHT.
// surface.png is black for land, then darker to lighter grey for river, lake and sea; elevation.png, trees.png and
// moisture.png run from 0 to 255 on land.
// If a layer is missing or the wrong size, the world is left all water, so the failure shows, and false is returned.
world_load :: proc(scenario: string) -> bool {
	terrain := &WORLD.atlas.terrain
	defer WORLD.map_draw.terrain_revision += 1
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
	viewport: [2]f32,
	cursor:   [2]f32,
	// The cursor is over the map, not over the ui or outside the window
	on_map:   bool,
	// The button that drags the map is held
	grab:     bool,
	// Keyboard panning along each axis, from -1 to 1; positive y is down the map
	pan:      [2]f32,
	// Wheel movement this frame, in notches; positive zooms in
	wheel:    f32,
}

// Called every frame
world_tick :: proc(input: Input, dt: f32) {
	camera_tick(input, dt)
	map_draw_tick(input.viewport)
}

