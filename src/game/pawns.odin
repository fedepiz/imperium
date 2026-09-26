package game

import "core:fmt"
import "core:math"
import "core:os"

import "../gfx"
import "../span"

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

