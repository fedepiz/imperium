#+private
package game

import "core:math"

import "../gfx"
import "../sim"
import "../span"

// A pawn: how a token is drawn on the map, in the slot of its handle's index. Its label must last until pawns_end.
Pawn :: struct {
	// The token the slot's pawn was last added for; a token of another handle starts the pawn over. A focused token is
	// drawn with a pulsing tint.
	token:        sim.Token,
	// The frame the pawn was last added in; only pawns added this frame are drawn and picked
	frame:        u32,
	// Seconds the pawn has been focused for, which its tint pulses by
	focused_time: f32,
}

@(private = "file")
PAWNS: struct {
	// Each handle slot's pawn, kept from frame to frame
	entries:       [sim.TOKENS_MAX]Pawn,
	// Counts pawns_begin calls
	frame:         u32,
	// Seconds since the frame before
	dt:            f32,
	// How far pawns have faded from pictures to medallions, from 0 to 1
	medallion_t:   f32,
	// The view this frame's pawns are drawn in
	camera:        Camera,
	viewport:      [2]f32,
	pixel_density: f32,
	render_list:   gfx.Render_List,
}

// How large each icon is drawn, times its drawing's natural size: see PAWN_CELLS_PER_PIXEL.
@(private = "file", rodata)
PAWN_SIZES := [sim.Icon]f32 {
	.Village    = 1.1,
	.Town       = 1.3,
	.City       = 1.4,
	.Large_City = 1.7,
	.Army       = 1.1,
	.Fleet      = 1.0,
	.Priest     = 1.1,
	.Envoy      = 1.1,
}

// The tint a focused pawn pulses towards, over its drawing and its paper, and how many seconds it takes to pulse
// there and back
@(private = "file")
PAWN_FOCUSED_TINT :: [4]f32{1.000, 0.700, 0.350, 1}
@(private = "file")
PAWN_FOCUSED_PULSE :: 1.2

// Every drawing in a set is made at the same scale, so drawing each at its set's cells per pixel of its image, times
// its icon's size, keeps the pen line the same weight across the set.
@(private = "file")
PAWN_CELLS_PER_PIXEL := [Icon_Set]f32 {
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

// Pawns start as whichever set the camera's zoom shows.
pawns_init :: proc(camera: Camera) {
	PAWNS.medallion_t = camera.zoom < PAWN_MEDALLION_ZOOM ? 1 : 0
}

// Starts a frame's pawns, drawn in the view of the camera: add them with pawns_add, then draw them with pawns_end.
pawns_begin :: proc(camera: Camera, viewport: [2]f32, pixel_density: f32, dt: f32) {
	target: f32 = camera.zoom < PAWN_MEDALLION_ZOOM ? 1 : 0
	step := dt / PAWN_MEDALLION_FADE
	PAWNS.medallion_t += clamp(target - PAWNS.medallion_t, -step, step)
	PAWNS.camera, PAWNS.viewport, PAWNS.pixel_density = camera, viewport, pixel_density
	PAWNS.frame += 1
	PAWNS.dt = dt
}

// Draws a token this frame
pawns_add :: proc(token: sim.Token) {
	pawn := &PAWNS.entries[token.handle.index]
	if pawn.token.handle != token.handle do pawn^ = {}
	pawn.token = token
	pawn.frame = PAWNS.frame
	pawn.focused_time = .Focused in token.flags ? pawn.focused_time + PAWNS.dt : 0
}

// The rect a pawn's drawing in a set covers, in cells
@(private = "file")
pawn_bounds :: proc(pawn: Pawn, set: Icon_Set) -> [4]f32 {
	picture := pawn.token.picture
	source :=
		gfx.sprite_region(gfx.sprite_of_image(icon_image(picture.icon, set, picture.culture))).source
	size := source.zw * PAWN_CELLS_PER_PIXEL[set] * PAWN_SIZES[picture.icon]
	corner := pawn.token.pos - size / 2
	return {corner.x, corner.y, size.x, size.y}
}

// The handle of the first of the latest frame's pawns whose drawing, in the set that shows more, covers the point on
// screen, or nil for none
pawns_pick :: proc(camera: Camera, viewport: [2]f32, point: [2]f32) -> sim.Piece_Id {
	found: sim.Piece_Id
	set: Icon_Set = PAWNS.medallion_t < 0.5 ? .Picture : .Medallion
	for pawn in PAWNS.entries {
		if pawn.frame != PAWNS.frame do continue
		rect, _ := camera_world_to_screen(camera, viewport, pawn_bounds(pawn, set))
		if gfx.rect_contains(rect, point) do found = pawn.token.handle
	}
	return found
}

// Draws the frame's pawns in two passes: their drawings, then their names, so every name shows over every drawing.
pawns_end :: proc() {
	camera, viewport := PAWNS.camera, PAWNS.viewport
	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&PAWNS.render_list,
		span.from_array(&PAWNS.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		PAWNS.pixel_density,
	)

	// While the fade is under way, each pawn is drawn in both sets, the one fading in over the one fading out. Its name
	// hangs under the drawings, between their bottoms as they fade.
	weights := [Icon_Set]f32 {
		.Picture   = 1 - PAWNS.medallion_t,
		.Medallion = PAWNS.medallion_t,
	}
	name_at: [sim.TOKENS_MAX][2]f32
	name_weight: [sim.TOKENS_MAX]f32
	for pawn, index in PAWNS.entries {
		if pawn.frame != PAWNS.frame do continue
		tint := [4]f32{1, 1, 1, 1}
		picture := pawn.token.picture
		if .Focused in pawn.token.flags {
			pulse := 0.5 - 0.5 * math.cos(2 * math.PI * pawn.focused_time / PAWN_FOCUSED_PULSE)
			tint = math.lerp(tint, PAWN_FOCUSED_TINT, pulse)
		}
		for weight, set in weights {
			if weight <= 0 do continue
			rect, visible := camera_world_to_screen(
				camera,
				viewport,
				pawn_bounds(pawn, set),
				PAWN_VIEW_TOLERANCE,
			)
			if !visible do continue
			paper := MAP_PAPER * tint
			paper.a *= weight
			gfx.draw_image(&draw, icon_fill(picture.icon, set, picture.culture), rect, paper)
			gfx.draw_image(
				&draw,
				icon_image(picture.icon, set, picture.culture),
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
	font := font_id(.Text)
	for pawn, index in PAWNS.entries {
		label := pawn.token.label
		if pawn.frame != PAWNS.frame || label == "" || name_weight[index] <= 0 do continue
		text := gfx.text_from_string(label, font, MAP_INK)
		halo := gfx.text_from_string(label, font, MAP_PAPER)
		at := name_at[index] / name_weight[index] - [2]f32{gfx.text_measure(text).x / 2, 0}
		for dy in -1 ..= 1 {
			for dx in -1 ..= 1 {
				if dx != 0 || dy != 0 do gfx.text_draw(&draw, halo, at + [2]f32{f32(dx), f32(dy)} * HALO)
			}
		}
		gfx.text_draw(&draw, text, at)
	}
}

// Draws what pawns_end made
pawns_render :: proc(renderer: ^gfx.Renderer) {
	gfx.render_list(renderer, &PAWNS.render_list)
}

