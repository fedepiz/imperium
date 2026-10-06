#+private
package main

import "core:fmt"
import "core:math"

// Pawns: the pieces drawn on the map, restated by the scene every frame. Nothing is kept per pawn.
// Near, a pawn is a picture, far a medallion, cross-faded. Its label is drawn under it

Map_Pawn :: struct {
	// Centre, in cells
	pos:         [2]f32,
	icon:        Map_Icon,
	culture:     Map_Culture,
	// Drawn under the pawn. Empty = none. LF starts a new line. Characters the label font lacks
	// are skipped
	label:       string,
	// Tinted in Map_Style.pawn_highlight
	highlighted: bool,
	// Tint swings to Map_Style.pawn_pulse and back
	pulsing:     bool,
}

Map_Icon :: enum {
	Village,
	Town,
	City,
	Large_City,
	Army,
}

Map_Culture :: enum {
	Roman,
	Germanic,
}

// Font of the labels, as listed in assets_load
MAP_LABEL_FONT :: "forgotten_uncial"
MAP_LABEL_SIZE :: 22

// Pawn state kept between frames
Map_Pawns :: struct {
	images:      [Pawn_Set][Map_Culture][Map_Icon]Pawn_Image,
	// Index in Assets.fonts
	label_font:  int,
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
}

// Zoom, in logical pixels per cell, under which pawns are medallions. Cross-fade: seconds
@(private = "file")
MEDALLION_ZOOM :: 10
@(private = "file")
MEDALLION_FADE :: 0.25

// Seconds
@(private = "file")
PULSE_PERIOD :: 1.2

// Pawns outside the view by up to this fraction of its size are still drawn: their labels may show
@(private = "file")
VIEW_TOLERANCE :: 0.1

// A label's halo: copies of it in paper colour, each shifted by one of these times LABEL_HALO
@(private = "file")
HALO_SHIFTS :: [8][2]f32{{-1, -1}, {0, -1}, {1, -1}, {-1, 0}, {1, 0}, {-1, 1}, {0, 1}, {1, 1}}
// Logical pixels
@(private = "file")
LABEL_HALO :: 1.5

// Glyphs of all labels drawn in a frame. Labels past it are cut short or dropped
@(private = "file")
LABEL_GLYPHS_MAX :: 1 << 12

// Room that never wraps or truncates
@(private = "file")
UNBOUNDED :: [2]f32{math.INF_F32, math.INF_F32}

// Out: pawns.
// Finds the pawn images and the label font
map_pawns_build :: proc(pawns: ^Map_Pawns, assets: ^Assets) {
	for &cultures, set in pawns.images {
		for &icons, culture in cultures {
			for &image, icon in icons {
				name := fmt.tprintf("%s/%s_%s", SET_NAMES[set], CULTURE_NAMES[culture], ICON_NAMES[icon])
				drawing, drawing_found := assets_image_find(assets, name)
				fill, fill_found := assets_image_find(assets, fmt.tprintf("%s_fill", name))
				if !drawing_found || !fill_found {
					fmt.eprintln("Pawn image not loaded:", name)
					continue
				}
				image = {assets.image_rects[drawing], assets.image_rects[fill]}
			}
		}
	}

	font, font_found := assets_font_find(assets, MAP_LABEL_FONT, MAP_LABEL_SIZE)
	if !font_found do fmt.eprintln("Label font not loaded:", MAP_LABEL_FONT, MAP_LABEL_SIZE)
	pawns.label_font = font
}

// Out: quads, passes, appended to. In/out: pawns.
// The scene's pawns as a world-space quad pass, then their labels as a screen-space one
map_pawns_frame :: proc(
	pawns: ^Map_Pawns,
	assets: ^Assets,
	scene: []Map_Pawn,
	view: Render_View,
	// The part of the world in the window, in cells
	visible: Extents,
	style: Map_Style,
	// Seconds since the last frame
	dt: f32,
	quads: ^[dynamic; RENDER_QUADS_MAX]Render_Quad,
	passes: ^[dynamic; RENDER_PASS_MAX]Render_Pass,
) {
	// Straight RGB and alpha, 0..1, to a quad colour
	color_of :: proc(rgb: [3]f32, alpha: f32) -> [4]u8 {
		c := [4]f32{rgb.r, rgb.g, rgb.b, alpha}
		c = {clamp(c.r, 0, 1), clamp(c.g, 0, 1), clamp(c.b, 0, 1), clamp(c.a, 0, 1)}
		return {u8(c.r * 255 + 0.5), u8(c.g * 255 + 0.5), u8(c.b * 255 + 0.5), u8(c.a * 255 + 0.5)}
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
	tints := make([][3]f32, len(scene), context.temp_allocator)
	for pawn, index in scene {
		tint := [3]f32{1, 1, 1}
		if pawn.highlighted do tint = style.pawn_highlight
		if pawn.pulsing do tint += (style.pawn_pulse - tint) * pulse
		tints[index] = tint
	}

	// Phase: Sprites. One per pawn and image set shown: both sets during the fade. In cells.
	// Kept if in view, or near it: its label may show
	Sprite :: struct {
		pawn:   int,
		lo:     [2]f32,
		hi:     [2]f32,
		image:  Pawn_Image,
		// Opacity, 0..1
		weight: f32,
	}
	sprites := make([dynamic]Sprite, 0, len(scene) * len(Pawn_Set), context.temp_allocator)
	{
		margin := [2]f32{visible.x_max - visible.x_min, visible.y_max - visible.y_min} * VIEW_TOLERANCE
		for pawn, index in scene {
			for weight, set in weights {
				image := pawns.images[set][pawn.culture][pawn.icon]
				if weight <= 0 || image.drawing.x_max <= image.drawing.x_min do continue
				pixels := [2]f32 {
					image.drawing.x_max - image.drawing.x_min,
					image.drawing.y_max - image.drawing.y_min,
				}
				half := pixels * CELLS_PER_PIXEL[set] * ICON_SIZES[pawn.icon] / 2
				lo := pawn.pos - half
				hi := pawn.pos + half
				if hi.x < visible.x_min - margin.x || lo.x > visible.x_max + margin.x do continue
				if hi.y < visible.y_min - margin.y || lo.y > visible.y_max + margin.y do continue
				append(&sprites, Sprite{pawn = index, lo = lo, hi = hi, image = image, weight = weight})
			}
		}
	}

	// Phase: Sprite quads. The silhouette in paper colour, then the drawing over it, both tinted
	{
		begin := len(quads)
		for sprite in sprites {
			tint := tints[sprite.pawn]
			paper := color_of(style.paper * tint, sprite.weight)
			ink := color_of(tint, sprite.weight)
			rect := Extents{sprite.lo.x, sprite.lo.y, sprite.hi.x, sprite.hi.y}
			append(
				quads,
				Render_Quad{rect = rect, source = sprite.image.fill, colors = {paper, paper, paper, paper}},
				Render_Quad{rect = rect, source = sprite.image.drawing, colors = {ink, ink, ink, ink}},
			)
		}
		append(passes, Render_Quad_Pass{space = .World, begin = begin, len = len(quads) - begin})
	}

	// Phase: Label anchors. Per pawn, the middle of the bottom edge of its sprites, in screen space.
	// During the fade: between the two sets' by their weights. Weight 0: the pawn has no sprite
	anchors := make([][2]f32, len(scene), context.temp_allocator)
	anchor_weights := make([]f32, len(scene), context.temp_allocator)
	{
		for sprite in sprites {
			bottom := [2]f32{(sprite.lo.x + sprite.hi.x) / 2, sprite.hi.y}
			anchors[sprite.pawn] += (bottom - {visible.x_min, visible.y_min}) * view.zoom * sprite.weight
			anchor_weights[sprite.pawn] += sprite.weight
		}
		for &anchor, index in anchors {
			if anchor_weights[index] > 0 do anchor /= anchor_weights[index]
		}
	}

	// Phase: Label layouts. One per pawn with a label and a sprite, centred under its anchor on whole
	// pixels. The glyphs of all labels go in one array
	Label :: struct {
		glyphs_begin: int,
		glyphs_len:   int,
		// Top-left of the text, in screen space
		at:           [2]f32,
	}
	labels := make([dynamic]Label, 0, len(scene), context.temp_allocator)
	glyphs := make([]Text_Glyph, LABEL_GLYPHS_MAX, context.temp_allocator)
	glyph_count := 0
	{
		metrics := assets_text_font(assets, pawns.label_font)
		for pawn, index in scene {
			if pawn.label == "" || anchor_weights[index] <= 0 do continue
			run := Text_Run{text = pawn.label}
			layout := text_layout({run}, {metrics}, UNBOUNDED, glyphs[glyph_count:], nil)
			anchor := anchors[index]
			append(
				&labels,
				Label {
					glyphs_begin = glyph_count,
					glyphs_len = layout.glyph_count,
					at = {math.round(anchor.x - layout.size.x / 2), math.round(anchor.y)},
				},
			)
			glyph_count += layout.glyph_count
		}
	}

	// Phase: Label copies. Every label 8 times in paper colour, shifted around its place: the halos.
	// Then every label once in ink
	Label_Copy :: struct {
		glyphs_begin: int,
		glyphs_len:   int,
		at:           [2]f32,
		color:        [4]u8,
	}
	copies := make([dynamic]Label_Copy, 0, len(labels) * (len(HALO_SHIFTS) + 1), context.temp_allocator)
	{
		paper := color_of(style.paper, 1)
		ink := color_of(style.ink, 1)
		for label in labels {
			for shift in HALO_SHIFTS {
				at := label.at + shift * LABEL_HALO
				append(&copies, Label_Copy{label.glyphs_begin, label.glyphs_len, at, paper})
			}
		}
		for label in labels {
			append(&copies, Label_Copy{label.glyphs_begin, label.glyphs_len, label.at, ink})
		}
	}

	// Phase: Label quads. Each glyph's ink box, moved to its copy's place, with its bitmap from the atlas
	{
		begin := len(quads)
		font := &assets.fonts[pawns.label_font]
		for copy in copies {
			for glyph in glyphs[copy.glyphs_begin:][:copy.glyphs_len] {
				// No bitmap
				if glyph.ink.x_max <= glyph.ink.x_min do continue
				append(
					quads,
					Render_Quad {
						rect = {
							copy.at.x + glyph.ink.x_min,
							copy.at.y + glyph.ink.y_min,
							copy.at.x + glyph.ink.x_max,
							copy.at.y + glyph.ink.y_max,
						},
						source = font.sources[int(glyph.char) - FONT_FIRST],
						colors = {copy.color, copy.color, copy.color, copy.color},
					},
				)
			}
		}
		append(passes, Render_Quad_Pass{space = .Screen, begin = begin, len = len(quads) - begin})
	}
}
