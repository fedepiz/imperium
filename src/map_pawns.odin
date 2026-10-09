#+private
package main

import "core:fmt"
import "core:math"

// Pawns: the pieces drawn on the map, restated by the scene every frame. Nothing is kept per pawn.
// Near, a pawn is a picture, far a medallion, cross-faded

// Pawns in a scene
MAP_PAWNS_MAX :: 1024

Map_Pawn :: struct {
	// Centre, in cells
	pos:         [2]f32,
	icon:        Map_Icon,
	culture:     Map_Culture,
	// Tinted in Map_Pawn_Style.highlight
	highlighted: bool,
	// Tint swings to Map_Pawn_Style.pulse and back
	pulsing:     bool,
	label:       string,
}

// Colours: straight RGB, 0..1
Map_Pawn_Style :: struct {
	// Silhouettes under the drawings
	paper:     [3]f32,
	// Tints: when highlighted, and at the peak of a pulse
	highlight: [3]f32,
	pulse:     [3]f32,
	ink:       [3]f32,
}

MAP_PAWN_STYLE_DEFAULT :: Map_Pawn_Style {
	highlight = {0.900, 0.350, 0.300},
	pulse     = {1.000, 0.700, 0.350},
}

Map_Icon :: enum {
	Village,
	Town,
	City,
	Large_City,
	Army,
	Fleet,
}

Map_Culture :: enum {
	Roman,
	Germanic,
}

// Pawn state: the scene, refilled every frame, and what is kept between frames
Map_Pawns :: struct {
	// This frame's pawns. Past the capacity, pawns are dropped
	scene:       [dynamic; MAP_PAWNS_MAX]Map_Pawn,
	images:      [Pawn_Set][Map_Culture][Map_Icon]Pawn_Image,
	label_font:  Text_Font_Id,
	// 0: pictures. 1: medallions
	medallion_t: f32,
	// Seconds. Phase of the pulse, shared by all pawns
	time:        f32,
}

// Atlas rects. Empty = missing
@(private = "file")
Pawn_Image :: struct {
	drawing: Extents,
	// Silhouette, drawn under the drawing in paper colour
	fill:    Extents,
}

@(private = "file")
Pawn_Set :: enum {
	Picture,
	Medallion,
}

// Images: <set>/<culture>_<icon>, and <set>/<culture>_<icon>_fill
@(private = "file", rodata)
SET_NAMES := [Pawn_Set]string {
	.Picture   = "pawns",
	.Medallion = "medallions",
}
@(private = "file", rodata)
CULTURE_NAMES := [Map_Culture]string {
	.Roman    = "roman",
	.Germanic = "germanic",
}
@(private = "file", rodata)
ICON_NAMES := [Map_Icon]string {
	.Village    = "town_0",
	.Town       = "town_1",
	.City       = "town_2",
	.Large_City = "town_3",
	.Army       = "army",
	.Fleet      = "fleet",
}

// Size on the map: image pixels * CELLS_PER_PIXEL[set] * ICON_SIZES[icon].
// One scale per set keeps the pen line weight the same across its images
@(private = "file", rodata)
CELLS_PER_PIXEL := [Pawn_Set]f32 {
	.Picture   = 5.0 / 400.0,
	.Medallion = 5.0 / 150.0,
}
@(private = "file", rodata)
ICON_SIZES := [Map_Icon]f32 {
	.Village    = 1.65,
	.Town       = 1.95,
	.City       = 2.1,
	.Large_City = 2.55,
	.Army       = 1.1,
	.Fleet      = 1.0,
}

// Zoom, in logical pixels per cell, under which pawns are medallions. Cross-fade: seconds
@(private = "file")
MEDALLION_ZOOM :: 10
@(private = "file")
MEDALLION_FADE :: 0.25

// Seconds
@(private = "file")
PULSE_PERIOD :: 1.2

// Pawns outside the view by up to this fraction of its size are still drawn
@(private = "file")
VIEW_TOLERANCE :: 0.1

@(private = "file")
LABEL_HALO :: 1.5
@(private = "file", rodata)
LABEL_HALO_SHIFTS := [8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}

map_pawns_image_paths :: proc(paths: ^[dynamic; ASSETS_IMAGES_MAX]string) {
	for set in Pawn_Set do for culture in Map_Culture do for icon in Map_Icon {
		drawing := fmt.tprintf("%s/%s_%s", SET_NAMES[set], CULTURE_NAMES[culture], ICON_NAMES[icon])
		append(paths, drawing, fmt.tprintf("%s_fill", drawing))
	}
}

map_pawns_build :: proc(pawns: ^Map_Pawns, image_rects: []Extents, label_font: Text_Font_Id) {
	pawns.label_font = label_font
	next := 0
	for &cultures in pawns.images do for &icons in cultures do for &image in icons {
		drawing := image_rects[next]
		fill := image_rects[next + 1]
		next += 2
		if drawing.x_max <= drawing.x_min || fill.x_max <= fill.x_min do continue
		image = {drawing, fill}
	}
}

// Empties the scene. Keeps the rest
map_pawns_clear :: proc(pawns: ^Map_Pawns) {
	clear(&pawns.scene)
}

@(private = "file")
sprite_half_size :: proc(image: Pawn_Image, set: Pawn_Set, icon: Map_Icon) -> [2]f32 {
	pixels := [2]f32 {
		image.drawing.x_max - image.drawing.x_min,
		image.drawing.y_max - image.drawing.y_min,
	}
	return pixels * CELLS_PER_PIXEL[set] * ICON_SIZES[icon] / 2
}

map_pawns_pick :: proc(
	pawns: ^Map_Pawns,
	view: Render_View,
	window: [2]f32,
	point: [2]f32,
	skipped: int,
) -> (
	index: int,
	found: bool,
) {
	set: Pawn_Set = pawns.medallion_t < 0.5 ? .Picture : .Medallion
	world := view.center + (point - window / 2) / view.zoom
	for pawn, i in pawns.scene {
		if i == skipped do continue
		half := sprite_half_size(pawns.images[set][pawn.culture][pawn.icon], set, pawn.icon)
		if abs(world.x - pawn.pos.x) > half.x || abs(world.y - pawn.pos.y) > half.y do continue
		index = i
		found = true
	}
	return
}

// Out: data, appended to. In/out: pawns.
// The scene's pawns as world-space quads
map_pawns_quads :: proc(
	pawns: ^Map_Pawns,
	view: Render_View,
	// Size of the window, in logical pixels
	window: [2]f32,
	style: Map_Pawn_Style,
	// Seconds since the last frame
	dt: f32,
	quads_out: ^[dynamic; RENDER_QUADS_MAX]Render_Quad,
	labels_out: ^[dynamic; RENDER_QUADS_MAX]Render_Quad,
) {
	// Straight RGB and alpha, 0..1, to a quad colour
	color_of :: proc(rgb: [3]f32, alpha: f32) -> [4]u8 {
		c := [4]f32{rgb.r, rgb.g, rgb.b, alpha}
		c = {clamp(c.r, 0, 1), clamp(c.g, 0, 1), clamp(c.b, 0, 1), clamp(c.a, 0, 1)}
		return {u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), u8(c.a * 255 + 0.5)}
	}

	// Phase: Visible. The part of the world in the window, in cells
	visible: Extents
	{
		half := window / 2 / view.zoom
		visible = {
			x_min = view.center.x - half.x,
			y_min = view.center.y - half.y,
			x_max = view.center.x + half.x,
			y_max = view.center.y + half.y,
		}
	}

	// Phase: Clocks. The pulse, and the fade between pictures and medallions
	pawns.time += dt
	pulse := 0.5 - 0.5 * math.cos(2 * math.PI * pawns.time / PULSE_PERIOD)
	target: f32 = view.zoom < MEDALLION_ZOOM ? 1 : 0
	fade := dt / MEDALLION_FADE
	pawns.medallion_t += clamp(target - pawns.medallion_t, -fade, fade)
	weights := [Pawn_Set]f32 {
		.Picture   = 1 - pawns.medallion_t,
		.Medallion = pawns.medallion_t,
	}

	// Phase: Tints. One per pawn
	tints := make([][3]f32, len(pawns.scene), context.temp_allocator)
	for pawn, index in pawns.scene {
		tint := [3]f32{1, 1, 1}
		if pawn.highlighted do tint = style.highlight
		if pawn.pulsing do tint += (style.pulse - tint) * pulse
		tints[index] = tint
	}

	// Phase: Sprites. One per pawn and image set shown: both sets during the fade. In cells.
	// Kept if in view, or near it
	Sprite :: struct {
		pawn:   int,
		lo:     [2]f32,
		hi:     [2]f32,
		image:  Pawn_Image,
		// Opacity, 0..1
		weight: f32,
	}
	sprites := make([dynamic]Sprite, 0, len(pawns.scene) * len(Pawn_Set), context.temp_allocator)
	{
		margin :=
			[2]f32{visible.x_max - visible.x_min, visible.y_max - visible.y_min} * VIEW_TOLERANCE
		for pawn, index in pawns.scene {
			for weight, set in weights {
				image := pawns.images[set][pawn.culture][pawn.icon]
				if weight <= 0 || image.drawing.x_max <= image.drawing.x_min do continue
				half := sprite_half_size(image, set, pawn.icon)
				lo := pawn.pos - half
				hi := pawn.pos + half
				if hi.x < visible.x_min - margin.x || lo.x > visible.x_max + margin.x do continue
				if hi.y < visible.y_min - margin.y || lo.y > visible.y_max + margin.y do continue
				append(
					&sprites,
					Sprite{pawn = index, lo = lo, hi = hi, image = image, weight = weight},
				)
			}
		}
	}

	// Phase: Sprite quads. The silhouette in paper colour, then the drawing over it, both tinted
	for sprite in sprites {
		tint := tints[sprite.pawn]
		paper := color_of(style.paper * tint, sprite.weight)
		ink := color_of(tint, sprite.weight)
		rect := Extents{sprite.lo.x, sprite.lo.y, sprite.hi.x, sprite.hi.y}
		append(
			quads_out,
			Render_Quad {
				rect = rect,
				source = sprite.image.fill,
				colors = {paper, paper, paper, paper},
			},
			Render_Quad{rect = rect, source = sprite.image.drawing, colors = {ink, ink, ink, ink}},
		)
	}

	label_anchors := make([][2]f32, len(pawns.scene), context.temp_allocator)
	label_weights := make([]f32, len(pawns.scene), context.temp_allocator)
	for sprite in sprites {
		bottom_middle := [2]f32{(sprite.lo.x + sprite.hi.x) / 2, sprite.hi.y}
		on_screen := (bottom_middle - view.center) * view.zoom + window / 2
		label_anchors[sprite.pawn] += on_screen * sprite.weight
		label_weights[sprite.pawn] += sprite.weight
	}

	Label :: struct {
		ink:     Text_Id,
		halo:    Text_Id,
		top_left: [2]f32,
	}
	labels := make([dynamic]Label, 0, len(pawns.scene), context.temp_allocator)
	for pawn, index in pawns.scene {
		if pawn.label == "" || label_weights[index] <= 0 do continue
		ink_color := [4]f32{style.ink.r, style.ink.g, style.ink.b, 1}
		halo_color := [4]f32{style.paper.r, style.paper.g, style.paper.b, 1}
		ink := text_make({{text = pawn.label, font = pawns.label_font, color = ink_color}})
		halo := text_make({{text = pawn.label, font = pawns.label_font, color = halo_color}})
		anchor := label_anchors[index] / label_weights[index]
		append(&labels, Label{ink, halo, anchor - {text_size(ink).x / 2, 0}})
	}

	for label in labels {
		for shift in LABEL_HALO_SHIFTS {
			text_quads(label.halo, label.top_left + shift * LABEL_HALO, math.INF_F32, true, {}, labels_out)
		}
	}
	for label in labels {
		text_quads(label.ink, label.top_left, math.INF_F32, true, {}, labels_out)
	}
}
