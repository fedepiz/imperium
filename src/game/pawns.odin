#+private
package game

import "core:fmt"
import "core:math"
import "core:os"

import "../gfx"
import "../span"

@(private = "file")
PAWNS_MAX :: PIECE_MAX

// What a pawn is
Pawn_Type :: enum u8 {
	Village,
	Town,
	City,
	Large_City,
	Army,
	Fleet,
	Priest,
	Envoy,
}

// How a type of pawn is named and drawn: its drawings are made from art/<set> by tools/pawnify, as <culture>_<tag> under
// assets/gfx/<set>, and drawn size times their natural size: see PAWN_CELLS_PER_PIXEL.
@(private = "file")
Pawn_Type_Def :: struct {
	tag:  string,
	name: string,
	size: f32,
}

@(rodata)
PAWN_TYPES := [Pawn_Type]Pawn_Type_Def {
	.Village    = {"town_0", "Village", 1.1},
	.Town       = {"town_1", "Town", 1.3},
	.City       = {"town_2", "City", 1.4},
	.Large_City = {"town_3", "Large City", 1.7},
	.Army       = {"army", "Army", 1.1},
	.Fleet      = {"fleet", "Fleet", 1.0},
	.Priest     = {"bishop", "Priest", 1.1},
	.Envoy      = {"envoy", "Envoy", 1.1},
}

Pawns :: struct {
	entries:        [PAWNS_MAX]Pawn,
	// Each type's drawing in each set and each culture's style, and its silhouette, drawn in paper under it so the map's
	// marks do not show through. A drawing not there yet is the blank image.
	image:          [Pawn_Type][Pawn_Set][Culture]gfx.Image_Id,
	fill:           [Pawn_Type][Pawn_Set][Culture]gfx.Image_Id,
	// The pawn drawn with a pulsing tint, or zero for none
	selected:       Pawn_Id,
	// Seconds the pawns have been ticked for, which the selected pawn's tint pulses by
	selected_time:  f32,
	// Drawn for a drawing that is not there yet: fully clear
	blank:          gfx.Image_Id,
	// What pawns' names are written in, and the selected pawn's name on its card
	font:           gfx.Font_Id,
	title_font:     gfx.Font_Id,
	render_list:    gfx.Render_List,
	// How far pawns have faded from pictures to medallions, from 0 to 1
	medallion_t:    f32,
	// The zoom, in pixels per cell, below which pawns are seen as medallions
	medallion_zoom: f32,
}

// Zero pawn canonically though to be null
Pawn_Id :: distinct u16

@(private = "file")
Pawn :: struct {
	active:  bool,
	// Where the drawing is centred, in cells
	pos:     [2]f32,
	type:    Pawn_Type,
	// Whose style the drawing is in
	culture: Culture,
	// Written under the pawn, unless empty. Set every frame, so it can live in the temp allocator.
	name:    string,
}

// The selected pawn's card: the ink its property names are written in, and its space from the edges of the view
PAWN_CARD_FADED_INK :: [4]f32{MAP_INK.r, MAP_INK.g, MAP_INK.b, 0.6}
PAWN_CARD_MARGIN :: [2]f32{20, 20}

// The tint the selected pawn pulses towards, over its drawing and its paper, and how many seconds it takes to pulse
// there and back
@(private = "file")
PAWN_SELECTED_TINT :: [4]f32{1.000, 0.700, 0.350, 1}
@(private = "file")
PAWN_SELECTED_PULSE :: 1.2

// The two sets of drawings a pawn is seen as: its picture up close, its medallion from afar
@(private = "file")
Pawn_Set :: enum u8 {
	Picture,
	Medallion,
}

// Every drawing in a set is made at the same scale, so drawing each at its set's cells per pixel of its image, times
// its pawn type's size, keeps the pen line the same weight across the set.
@(private = "file")
PAWN_CELLS_PER_PIXEL := [Pawn_Set]f32 {
	.Picture   = 5.0 / 400.0,
	.Medallion = 5.0 / 150.0,
}

// The zoom, in pixels per cell, that pawns turn from pictures to medallions at, and how long the fade takes in seconds
@(private = "file")
PAWN_MEDALLION_ZOOM :: 10
@(private = "file")
PAWN_MEDALLION_FADE :: 0.25

// How far past the view, as a fraction of its size, a pawn is still drawn, so its name hanging below stays in sight
@(private = "file")
PAWN_VIEW_TOLERANCE :: 0.1

// The folder under assets/gfx each set's drawings are in, and each culture's part of their names
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

// Defines the pawns' fonts and images, so call this before sprites_load. Pawns start as whichever set the camera's zoom
// shows.
pawns_init :: proc(pawns: ^Pawns, camera: Camera) {
	pawns.blank = gfx.sprites_image_add("blank")
	pawns.font = gfx.sprites_font_add("forgotten_uncial", 22)
	pawns.title_font = gfx.sprites_font_add("forgotten_uncial", 36)
	pawns.medallion_zoom = PAWN_MEDALLION_ZOOM
	pawns.medallion_t = camera.zoom < pawns.medallion_zoom ? 1 : 0
	for def, type in PAWN_TYPES {
		for set_name, set in PAWN_SET_NAMES {
			for culture_name, culture in CULTURE_NAMES {
				drawing := fmt.tprintf("%s/%s_%s", set_name, culture_name, def.tag)
				pawns.image[type][set][culture] = image_or_blank(pawns, drawing)
				pawns.fill[type][set][culture] = image_or_blank(
					pawns,
					fmt.tprintf("%s_fill", drawing),
				)
			}
		}
	}

	image_or_blank :: proc(pawns: ^Pawns, name: string) -> gfx.Image_Id {
		if !os.exists(fmt.tprintf("assets/gfx/%s.png", name)) do return pawns.blank
		return gfx.sprites_image_add(name)
	}
}

// Update the pawns
pawns_tick :: proc(pawns: ^Pawns, camera: Camera, dt: f32) {
	target: f32 = camera.zoom < pawns.medallion_zoom ? 1 : 0
	step := dt / PAWN_MEDALLION_FADE
	pawns.medallion_t += clamp(target - pawns.medallion_t, -step, step)
	pawns.selected_time = pawns.selected == 0 ? 0 : pawns.selected_time + dt
}

// The rect a pawn's drawing in a set covers, in cells
@(private = "file")
pawn_bounds :: proc(pawns: ^Pawns, pawn: Pawn, set: Pawn_Set) -> [4]f32 {
	source :=
		gfx.sprite_region(gfx.sprite_of_image(pawns.image[pawn.type][set][pawn.culture])).source
	size := source.zw * PAWN_CELLS_PER_PIXEL[set] * PAWN_TYPES[pawn.type].size
	corner := pawn.pos - size / 2
	return {corner.x, corner.y, size.x, size.y}
}

// The first pawn whose drawing, in the set that shows more, covers the point on screen, or zero for none
pawns_pick :: proc(pawns: ^Pawns, camera: Camera, viewport: [2]f32, point: [2]f32) -> Pawn_Id {
	set: Pawn_Set = pawns.medallion_t < 0.5 ? .Picture : .Medallion
	for pawn, index in pawns.entries {
		if !pawn.active do continue
		rect, _ := camera_world_to_screen(camera, viewport, pawn_bounds(pawns, pawn, set))
		if gfx.rect_contains(rect, point) do return Pawn_Id(index)
	}
	return 0
}

// Draws the pawns in two passes: their drawings, then their names, so every name shows over every drawing.
pawns_draw :: proc(pawns: ^Pawns, viewport: [2]f32, camera: Camera, pixel_density: f32) {
	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&pawns.render_list,
		span.from_array(&pawns.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		pixel_density,
	)

	// While the fade is under way, each pawn is drawn in both sets, the one fading in over the one fading out. Its name
	// hangs under the drawings, between their bottoms as they fade.
	weights := [Pawn_Set]f32 {
		.Picture   = 1 - pawns.medallion_t,
		.Medallion = pawns.medallion_t,
	}
	pulse := 0.5 - 0.5 * math.cos(2 * math.PI * pawns.selected_time / PAWN_SELECTED_PULSE)
	name_at: [PAWNS_MAX][2]f32
	name_weight: [PAWNS_MAX]f32
	for pawn, index in pawns.entries {
		if !pawn.active do continue
		selected := pawns.selected != 0 && Pawn_Id(index) == pawns.selected
		tint :=
			selected ? math.lerp([4]f32{1, 1, 1, 1}, PAWN_SELECTED_TINT, pulse) : [4]f32{1, 1, 1, 1}
		for weight, set in weights {
			if weight <= 0 do continue
			rect, visible := camera_world_to_screen(
				camera,
				viewport,
				pawn_bounds(pawns, pawn, set),
				PAWN_VIEW_TOLERANCE,
			)
			if !visible do continue
			paper := MAP_PAPER * tint
			paper.a *= weight
			gfx.draw_image(&draw, pawns.fill[pawn.type][set][pawn.culture], rect, paper)
			gfx.draw_image(
				&draw,
				pawns.image[pawn.type][set][pawn.culture],
				rect,
				tint * {1, 1, 1, weight},
			)
			name_at[index] += [2]f32{rect.x + rect.z / 2, rect.y + rect.w} * weight
			name_weight[index] += weight
		}
	}

	// Each name keeps its size on screen, centred under its drawing, over a halo of paper: the name drawn in the paper's
	// colour a little way off all round.
	HALO :: 1.5
	for pawn, index in pawns.entries {
		if pawn.name == "" || name_weight[index] <= 0 do continue
		text := gfx.text_from_string(pawn.name, pawns.font, MAP_INK)
		halo := gfx.text_from_string(pawn.name, pawns.font, MAP_PAPER)
		at := name_at[index] / name_weight[index] - [2]f32{gfx.text_measure(text).x / 2, 0}
		for dy in -1 ..= 1 {
			for dx in -1 ..= 1 {
				if dx != 0 || dy != 0 do gfx.text_draw(&draw, halo, at + [2]f32{f32(dx), f32(dy)} * HALO)
			}
		}
		gfx.text_draw(&draw, text, at)
	}
}

