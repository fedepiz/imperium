package game

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

import "../gfx"
import "../tweak"
import "../ui"

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
#assert(len(Way_Kind) == gfx.RENDER_WAY_KINDS)
#assert(POLYLINE_SMOOTHED_MAX <= gfx.RENDER_WAY_SEGMENTS_MAX)

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
	// For each way kind, which way is this cell assigned to. (Way_Id = 0 is nil)
	way:       [Way_Kind]Way_Id,
}

// What covers a cell
Surface :: enum u8 {
	Land,
	Lake,
	Sea,
}

// Ways run over land from cell to cell, one cell wide. The rules treat their cells as land; the map draws each as a line.
Way_Kind :: enum u8 {
	River,
	Road,
}

// Which way of its kind runs through a cell. Id 0 is none.
Way_Id :: distinct u16

WATER :: bit_set[Surface]{.Lake, .Sea}

// Defines the world's images, so call this before sprites_load. The terrain comes from a scenario, with world_load.
world_init :: proc() {
	camera_init()
	map_draw_init(&WORLD.map_draw)
	pawns_init(&WORLD.pawns, WORLD.camera)

}

// Loads a scenario's terrain from its folder: one greyscale PNG per property, WORLD_WIDTH by WORLD_HEIGHT.
// surface.png is black for land, grey for lake and white for sea; elevation.png, trees.png and moisture.png run from 0
// to 255 on land. rivers.png and roads.png hold, in 16 bits, the id of the way through each land cell.
// If a layer is missing or the wrong size, the world is left all water, so the failure shows, and false is returned.
world_load :: proc(scenario: string) -> bool {
	terrain := &WORLD.atlas.terrain
	defer WORLD.atlas.revision += 1
	Layer :: enum {
		Surface,
		Elevation,
		Trees,
		Moisture,
		Rivers,
		Roads,
	}
	names := [Layer]string {
		.Surface   = "surface",
		.Elevation = "elevation",
		.Trees     = "trees",
		.Moisture  = "moisture",
		.Rivers    = "rivers",
		.Roads     = "roads",
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
			byte := u8(value >> 8)
			switch layer {
			case .Surface:
				terrain[i].surface = Surface(min((int(byte) + 64) / 128, int(max(Surface))))
			case .Elevation:
				terrain[i].elevation = byte
			case .Trees:
				terrain[i].trees = byte
			case .Moisture:
				terrain[i].moisture = byte
			case .Rivers:
				terrain[i].way[.River] = Way_Id(value)
			case .Roads:
				terrain[i].way[.Road] = Way_Id(value)
			}
		}
	}
	// Water cells carry nothing else.
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	return true
}

// One greyscale layer, WORLD_WIDTH by WORLD_HEIGHT, in 16 bits: an 8-bit image's values are widened, so their high
// byte is the value. The pixels live in the temp allocator.
@(private = "file")
world_load_layer :: proc(path: string) -> (pixels: []u16, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read terrain layer %q: %v", path, err)
		return
	}
	width, height, channels: c.int
	loaded := stbi.load_16_from_memory(
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
	pixels = make([]u16, CELLS_MAX, context.temp_allocator)
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
	// The button that selects went down this frame, over the map
	click:         bool,
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
		type:    string,
		name:    string,
		culture: Culture,
	}
	@(static, rodata)
	TEST_PAWNS := [?]Test_Pawn {
		{{342, 432}, "town_3", "Roma", .Roman},
		{{296, 374}, "town_3", "Mediolanum", .Roman},
		{{345, 389}, "town_2", "Ravenna", .Roman},
		{{367, 369}, "town_2", "Aquileia", .Roman},
		{{367, 449}, "town_2", "Neapolis", .Roman},
		{{360, 441}, "town_0", "Capua", .Roman},
		{{411, 452}, "town_0", "Brundisium", .Roman},
		{{334, 419}, "army", "", .Roman},
		{{353, 455}, "fleet", "", .Roman},
		{{355, 393}, "fleet", "", .Roman},
		{{350, 430}, "bishop", "", .Roman},
		{{306, 382}, "envoy", "", .Roman},
		{{300, 300}, "town_3", "Alamannia", .Germanic},
		{{332, 318}, "town_2", "Castra Regina", .Germanic},
		{{270, 322}, "town_1", "Brisiacum", .Germanic},
		{{285, 285}, "town_0", "", .Germanic},
		{{316, 342}, "army", "", .Germanic},
		{{292, 340}, "envoy", "", .Germanic},
	}
	for test, i in TEST_PAWNS {
		type, found := pawns_type_find(&WORLD.pawns, test.type)
		WORLD.pawns.entries[i + 1] = {
			active  = found,
			pos     = test.pos,
			type    = type,
			culture = test.culture,
			name    = test.name,
		}
	}
	if input.click do WORLD.pawns.selected = pawns_pick(&WORLD.pawns, WORLD.camera, input.viewport, input.cursor)
	pawns_tick(&WORLD.pawns, WORLD.camera, dt)
	pawns_draw(&WORLD.pawns, input.viewport, WORLD.camera, input.pixel_density)

	// Pawns tweaks
	tweak.slider_in_place("Pawns/Medallion Zoom", &WORLD.pawns.picture_to_medallion_zoom, 1.0, 20.)
	// Which test pawn is selected: each choice after None is the test pawn placed at that id
	choices := make([]string, len(TEST_PAWNS) + 1, context.temp_allocator)
	choices[0] = "None"
	for test, i in TEST_PAWNS do choices[i + 1] = test.name != "" ? test.name : fmt.tprintf("%s %d", test.type, i + 1)
	selected := int(WORLD.pawns.selected)
	tweak.choice_in_place("Pawns/Selected", &selected, choices)
	WORLD.pawns.selected = Pawn_Id(selected)
}

// Called between ui.begin() and ui.end(). The selected pawn is described on a card of the map's paper at the bottom
// left of the view: its medallion and name, or its type's when it has none, over what it is.
world_ui :: proc() {
	pawns := &WORLD.pawns
	if pawns.selected == 0 do return
	pawn := pawns.entries[pawns.selected]
	type := &pawns.types[pawn.type]

	ui.style_push(
		{
			font = pawns.font,
			text_color = PAWN_NAME_INK,
			width = ui.text_dim(),
			height = ui.text_dim(),
		},
	)
	defer ui.style_pop()
	if ui.column({width = ui.grow(), height = ui.grow(), padding = PAWN_CARD_MARGIN}) {
		ui.spacer(ui.grow())
		card := ui.Style {
			width      = ui.fit(),
			height     = ui.fit(),
			padding    = [2]f32{16, 12},
			gap        = 6,
			background = PAWN_PAPER,
			border     = PAWN_NAME_INK,
			thickness  = 1.5,
			radius     = 3,
		}
		if ui.panel("selected pawn", card) {
			title := [?]ui.Text {
				{image = type.image[.Medallion][pawn.culture], color = [4]f32{1, 1, 1, 1}},
				{text = " "},
				{text = pawn.name != "" ? pawn.name : type.tag},
			}
			ui.label_text(title[:], {font = pawns.title_font})
			pawn_card_row("Type", type.name)
			pawn_card_row("Culture", fmt.tprintf("%v", pawn.culture))
		}
	}

	// A property on the card: its name, faded, in a column as wide for every row, then its value
	pawn_card_row :: proc(name, value: string) {
		if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
			ui.label(name, {width = ui.em(5), text_color = PAWN_CARD_FADED_INK})
			ui.label(value)
		}
	}
}

// The peoples whose drawings pawns can be in
Culture :: enum u8 {
	Roman,
	Germanic,
}

