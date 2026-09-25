package game

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import stbi "vendor:stb/image"

import "../gfx"
import "../span"
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
	pawns_init(&WORLD.pawns, WORLD.camera)

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


PAWNS_MAX :: 1024
PAWN_TYPES_MAX :: 64

Pawn_Type_Id :: distinct u8

// What a pawn is, and how it is drawn: its drawing in each set and each culture's style, from <set>/<culture>_<name>
// under assets/gfx. A drawing not there yet is the blank image.
Pawn_Type :: struct {
	// Must outlive the type
	tag:   string,
	// Visible name
	name:  string,
	// How large the drawings are against their natural size: see PAWN_CELLS_PER_PIXEL
	size:  f32,
	image: [Pawn_Set][Culture]gfx.Image_Id,
	// Each drawing's silhouette, drawn in paper under it so the map's marks do not show through
	fill:  [Pawn_Set][Culture]gfx.Image_Id,
}

Pawns :: struct {
	entries:                   [PAWNS_MAX]Pawn,
	// Defined by pawns_type_add
	types:                     [dynamic; PAWN_TYPES_MAX]Pawn_Type,
	// The pawn drawn with a pulsing tint, or zero for none
	selected:                  Pawn_Id,
	// Seconds the pawns have been ticked for, which the selected pawn's tint pulses by
	time:                      f32,
	// Drawn for a drawing that is not there yet: fully clear
	blank:                     gfx.Image_Id,
	// What pawns' names are written in, and the selected pawn's name on its card
	font:                      gfx.Font_Id,
	title_font:                gfx.Font_Id,
	render_list:               gfx.Render_List,
	// Picture-Medallion interpolation progression, from 0 (pictures) to 1 (medallions)
	picture_to_medallion_t:    f32,
	// Zoom level at which the transition occours, in pixels per cell: medallions below it, pictures above
	picture_to_medallion_zoom: f32,
}

// Zero pawn canonically though to be null
Pawn_Id :: distinct u16

Pawn :: struct {
	active:  bool,
	// Where the drawing is centred, in cells
	pos:     [2]f32,
	type:    Pawn_Type_Id,
	// Whose style the drawing is in
	culture: Culture,
	// Written under the pawn, unless empty. Set every frame, so it can live in the temp allocator.
	name:    string,
}

// The ink pawns' names are written in: the map's
PAWN_NAME_INK :: [4]f32{0.150, 0.105, 0.070, 1}

// The map's paper, which pawns' silhouettes and the halos round their names are drawn in
PAWN_PAPER :: [4]f32{0.840, 0.772, 0.620, 1}

// The selected pawn's card: the ink its property names are written in, and its space from the edges of the view
PAWN_CARD_FADED_INK :: [4]f32{0.150, 0.105, 0.070, 0.6}
PAWN_CARD_MARGIN :: [2]f32{20, 20}

// The tint the selected pawn pulses towards, over its drawing and its paper, and how many seconds it takes to pulse
// there and back
PAWN_SELECTED_TINT :: [4]f32{1.000, 0.700, 0.350, 1}
PAWN_SELECTED_PULSE :: 1.2

// The two sets of drawings a pawn is seen as: its picture up close, its medallion from afar
Pawn_Set :: enum u8 {
	Picture,
	Medallion,
}

// The peoples whose drawings pawns can be in
Culture :: enum u8 {
	Roman,
	Germanic,
}

// Every drawing in a set is made at the same scale, so drawing each at its set's cells per pixel of its image, times
// its pawn type's size, keeps the pen line the same weight across the set.
PAWN_CELLS_PER_PIXEL := [Pawn_Set]f32 {
	.Picture   = 5.0 / 400.0,
	.Medallion = 5.0 / 150.0,
}

// The zoom, in pixels per cell, that pawns turn from pictures to medallions at, and how long the fade takes in seconds
PAWN_MEDALLION_ZOOM :: 10
PAWN_MEDALLION_FADE :: 0.25

// How far past the view, as a fraction of its size, a pawn is still drawn, so its name hanging below stays in sight
PAWN_VIEW_TOLERANCE :: 0.1

// The drawings of each pawn type, under assets/gfx/<set>, as <culture>_<name>, made from art/<set> by tools/pawnify
@(private = "file")
PAWN_SET_NAMES := [Pawn_Set]string {
	.Picture   = "pawns",
	.Medallion = "medallions",
}

@(private = "file")
CULTURE_NAMES := [Culture]string {
	.Roman    = "roman",
	.Germanic = "germanic",
}

// Defines the pawns' font and blank image, so call this before sprites_load, and before any pawns_type_add. Pawns start
// as whichever set the camera's zoom shows.
pawns_init :: proc(pawns: ^Pawns, camera: Camera) {
	pawns.blank = gfx.sprites_image_add("blank")
	pawns.font = gfx.sprites_font_add("forgotten_uncial", 22)
	pawns.title_font = gfx.sprites_font_add("forgotten_uncial", 36)
	pawns.picture_to_medallion_zoom = PAWN_MEDALLION_ZOOM
	pawns.picture_to_medallion_t = camera.zoom < pawns.picture_to_medallion_zoom ? 1 : 0

	// Pawn types
	Pawn_Type_Def :: struct {
		name_raw:     string,
		name_display: string,
		size:         f32,
	}
	@(static, rodata)
	PAWN_TYPES := [?]Pawn_Type_Def {
		{"town_0", "Village", 1.1},
		{"town_1", "Town", 1.3},
		{"town_2", "City", 1.4},
		{"town_3", "Large City", 1.7},
		{"army", "Army", 1.1},
		{"fleet", "Fleet", 1.0},
		{"bishop", "Priest", 1.1},
		{"envoy", "Envoy", 1.1},
	}
	for type in PAWN_TYPES do pawns_type_add(&WORLD.pawns, type.name_raw, type.name_display, type.size)
}

// Defines a pawn type and its drawings, so call this before sprites_load.
pawns_type_add :: proc(pawns: ^Pawns, tag: string, name: string, size: f32) -> Pawn_Type_Id {
	assert(len(pawns.types) < PAWN_TYPES_MAX)
	id := Pawn_Type_Id(len(pawns.types))
	append(&pawns.types, Pawn_Type{tag = tag, name = name, size = size})
	type := &pawns.types[id]
	for set_name, set in PAWN_SET_NAMES {
		for culture_name, culture in CULTURE_NAMES {
			drawing := fmt.tprintf("%s/%s_%s", set_name, culture_name, tag)
			fill := fmt.tprintf("%s_fill", drawing)
			type.image[set][culture] = pawns_image_or_blank(pawns, drawing)
			type.fill[set][culture] = pawns_image_or_blank(pawns, fill)
		}
	}
	return id

	pawns_image_or_blank :: proc(pawns: ^Pawns, name: string) -> gfx.Image_Id {
		if !os.exists(fmt.tprintf("assets/gfx/%s.png", name)) do return pawns.blank
		return gfx.sprites_image_add(name)
	}
}

// The pawn type of that name, if there is one.
pawns_type_find :: proc(pawns: ^Pawns, name: string) -> (Pawn_Type_Id, bool) {
	for type, i in pawns.types {
		if type.tag == name do return Pawn_Type_Id(i), true
	}
	return 0, false
}

// Fades pawns towards medallions while the camera is farther out than the transition zoom, and towards pictures while
// it is closer in.
pawns_tick :: proc(pawns: ^Pawns, camera: Camera, dt: f32) {
	target: f32 = camera.zoom < pawns.picture_to_medallion_zoom ? 1 : 0
	step := dt / PAWN_MEDALLION_FADE
	pawns.picture_to_medallion_t += clamp(target - pawns.picture_to_medallion_t, -step, step)
	pawns.time += dt
}

// The rect a pawn's drawing in a set covers, in cells
pawn_bounds :: proc(pawns: ^Pawns, pawn: Pawn, set: Pawn_Set) -> [4]f32 {
	type := &pawns.types[pawn.type]
	source := gfx.sprite_region(gfx.sprite_of_image(type.image[set][pawn.culture])).source
	size := source.zw * PAWN_CELLS_PER_PIXEL[set] * type.size
	corner := pawn.pos - size / 2
	return {corner.x, corner.y, size.x, size.y}
}

// The first pawn whose drawing, in the set that shows more, covers the point on screen, or zero for none
pawns_pick :: proc(pawns: ^Pawns, camera: Camera, viewport: [2]f32, point: [2]f32) -> Pawn_Id {
	set: Pawn_Set = pawns.picture_to_medallion_t < 0.5 ? .Picture : .Medallion
	for pawn, index in pawns.entries {
		if index == 0 || !pawn.active do continue
		rect, _ := camera_world_to_screen(camera, viewport, pawn_bounds(pawns, pawn, set))
		if point.x >= rect.x &&
		   point.y >= rect.y &&
		   point.x < rect.x + rect.z &&
		   point.y < rect.y + rect.w {
			return Pawn_Id(index)
		}
	}
	return 0
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

	// While the fade is under way, each pawn is drawn in both sets, the one fading in over the one fading out.
	t := pawns.picture_to_medallion_t
	weights := [Pawn_Set]f32 {
		.Picture   = 1 - t,
		.Medallion = t,
	}
	pulse := 0.5 - 0.5 * math.cos(2 * math.PI * pawns.time / PAWN_SELECTED_PULSE)
	for pawn, index in pawns.entries {
		if !pawn.active do continue
		type := &pawns.types[pawn.type]
		selected := pawns.selected != 0 && Pawn_Id(index) == pawns.selected
		tint :=
			selected ? math.lerp([4]f32{1, 1, 1, 1}, PAWN_SELECTED_TINT, pulse) : [4]f32{1, 1, 1, 1}
		// The name hangs under the drawings, between their bottoms as they fade.
		name_at: [2]f32
		name_weight: f32
		for set in Pawn_Set {
			weight := weights[set]
			if weight <= 0 do continue
			image := type.image[set][pawn.culture]
			rect, visible := camera_world_to_screen(
				camera,
				viewport,
				pawn_bounds(pawns, pawn, set),
				PAWN_VIEW_TOLERANCE,
			)
			if !visible do continue
			paper := PAWN_PAPER * tint
			paper.a *= weight
			gfx.draw_image(&draw, type.fill[set][pawn.culture], rect, paper)
			gfx.draw_image(&draw, image, rect, tint * {1, 1, 1, weight})
			name_at += [2]f32{rect.x + rect.z / 2, rect.y + rect.w} * weight
			name_weight += weight
		}
		// The name keeps its size on screen, centred under the drawing, over a halo of paper: the name drawn in the
		// paper's colour a little way off all round.
		if pawn.name != "" && name_weight > 0 {
			HALO :: 1.5
			text := gfx.text_from_string(pawn.name, pawns.font, PAWN_NAME_INK)
			halo := gfx.text_from_string(pawn.name, pawns.font, PAWN_PAPER)
			text_size := gfx.text_measure(text)
			at := name_at / name_weight - [2]f32{text_size.x / 2, 0}
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

