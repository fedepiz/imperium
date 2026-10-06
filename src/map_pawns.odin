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
	// Drawn under the pawn. Empty = none. Characters outside FONT_FIRST..FONT_LAST are skipped
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

// Offset of the label's halo copies, in logical pixels
@(private = "file")
LABEL_HALO :: 1.5

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

// Appends the scene's pawns as a world-space quad pass, then their labels as a screen-space one
map_pawns_frame :: proc(
	pawns: ^Map_Pawns,
	rend: ^Renderer,
	assets: ^Assets,
	scene: []Map_Pawn,
	view: Render_View,
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

	density := renderer_pixel_density(rend)
	visible := renderer_view_extents(rend, view)
	margin := [2]f32{visible.x_max - visible.x_min, visible.y_max - visible.y_min} * VIEW_TOLERANCE

	// Step: Clocks. Medallions when far, moving at a constant rate
	pawns.time += dt
	pulse := 0.5 - 0.5 * math.cos(2 * math.PI * pawns.time / PULSE_PERIOD)
	target: f32 = view.zoom / density < MEDALLION_ZOOM ? 1 : 0
	fade := dt / MEDALLION_FADE
	pawns.medallion_t += clamp(target - pawns.medallion_t, -fade, fade)
	weights := [Pawn_Set]f32 {
		.Picture   = 1 - pawns.medallion_t,
		.Medallion = pawns.medallion_t,
	}

	// Step: Pawns. During the cross-fade both sets are drawn.
	// Label anchor: bottom centre of the pawn in window pixels, 0 weight = pawn not drawn
	anchors := make([][2]f32, len(scene), context.temp_allocator)
	anchor_weights := make([]f32, len(scene), context.temp_allocator)
	{
		begin := len(quads)
		for pawn, index in scene {
			tint := [3]f32{1, 1, 1}
			if pawn.highlighted do tint = style.pawn_highlight
			if pawn.pulsing do tint += (style.pawn_pulse - tint) * pulse

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

				paper := color_of(style.paper * tint, weight)
				ink := color_of(tint, weight)
				append(
					quads,
					Render_Quad {
						rect = {lo.x, lo.y, hi.x, hi.y},
						source = image.fill,
						colors = {paper, paper, paper, paper},
					},
					Render_Quad {
						rect = {lo.x, lo.y, hi.x, hi.y},
						source = image.drawing,
						colors = {ink, ink, ink, ink},
					},
				)
				bottom := [2]f32{pawn.pos.x, hi.y}
				anchors[index] += (bottom - {visible.x_min, visible.y_min}) * view.zoom * weight
				anchor_weights[index] += weight
			}
		}
		append(passes, Render_Quad_Pass{space = .World, begin = begin, len = len(quads) - begin})
	}

	// Step: Labels. Constant size on screen, centred under the pawn. Each is drawn 8 times in paper
	// colour around its place, as a halo, then once in ink
	{
		begin := len(quads)
		font := &assets.fonts[pawns.label_font]
		paper := color_of(style.paper, 1)
		ink := color_of(style.ink, 1)
		for pawn, index in scene {
			if pawn.label == "" || anchor_weights[index] <= 0 do continue
			anchor := anchors[index] / anchor_weights[index]

			width: f32
			for char in pawn.label {
				if char >= FONT_FIRST && char <= FONT_LAST do width += font.glyphs[int(char) - FONT_FIRST].advance
			}
			// Pen on the baseline, on whole pixels
			start := [2]f32{math.round(anchor.x - width / 2), math.round(anchor.y + font.ascent)}

			for copy in 0 ..< 9 {
				// Copies 0..7: the halo, skipping the centre. Copy 8: the ink
				offset: [2]f32
				color := ink
				if copy < 8 {
					at := copy < 4 ? copy : copy + 1
					offset = [2]f32{f32(at % 3 - 1), f32(at / 3 - 1)} * LABEL_HALO * density
					color = paper
				}
				pen := start + offset
				for char in pawn.label {
					if char < FONT_FIRST || char > FONT_LAST do continue
					glyph := font.glyphs[int(char) - FONT_FIRST]
					size := [2]f32 {
						glyph.source.x_max - glyph.source.x_min,
						glyph.source.y_max - glyph.source.y_min,
					}
					if size.x > 0 {
						corner := pen + glyph.offset
						append(
							quads,
							Render_Quad {
								rect = {corner.x, corner.y, corner.x + size.x, corner.y + size.y},
								source = glyph.source,
								colors = {color, color, color, color},
							},
						)
					}
					pen.x += glyph.advance
				}
			}
		}
		append(passes, Render_Quad_Pass{space = .Screen, begin = begin, len = len(quads) - begin})
	}
}
