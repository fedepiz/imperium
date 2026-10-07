#+private
package main

import "core:fmt"
import "core:math"

// Pawns: the pieces drawn on the map, restated by the scene every frame. Nothing is kept per pawn.
// Near, a pawn is a picture, far a medallion, cross-faded

Map_Pawn :: struct {
	// Centre, in cells
	pos:         [2]f32,
	icon:        Map_Icon,
	culture:     Map_Culture,
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

// Pawn state kept between frames
Map_Pawns :: struct {
	images:      [Pawn_Set][Map_Culture][Map_Icon]Pawn_Image,
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

// Pawns outside the view by up to this fraction of its size are still drawn
@(private = "file")
VIEW_TOLERANCE :: 0.1

// Out: pawns.
// Finds the pawn images
map_pawns_build :: proc(pawns: ^Map_Pawns, assets: ^Assets) {
	for &cultures, set in pawns.images {
		for &icons, culture in cultures {
			for &image, icon in icons {
				name := fmt.tprintf(
					"%s/%s_%s",
					SET_NAMES[set],
					CULTURE_NAMES[culture],
					ICON_NAMES[icon],
				)
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

}

// Out: quads, passes, appended to. In/out: pawns.
// The scene's pawns as a world-space quad pass
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
	// Kept if in view, or near it
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
		margin :=
			[2]f32{visible.x_max - visible.x_min, visible.y_max - visible.y_min} * VIEW_TOLERANCE
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
				append(
					&sprites,
					Sprite{pawn = index, lo = lo, hi = hi, image = image, weight = weight},
				)
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
				Render_Quad {
					rect = rect,
					source = sprite.image.fill,
					colors = {paper, paper, paper, paper},
				},
				Render_Quad {
					rect = rect,
					source = sprite.image.drawing,
					colors = {ink, ink, ink, ink},
				},
			)
		}
		append(passes, Render_Quad_Pass{space = .World, begin = begin, len = len(quads) - begin})
	}
}

