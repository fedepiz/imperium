#+private
package game

import "core:math"

import "../gfx"
import "../sim"
import "../span"

// Per-piece visual state that persists across frames, indexed by handle index
Piece_Visual :: struct {
	// A different handle in the slot resets the state
	handle:       sim.Piece_Id,
	// Seconds, drives the focus pulse
	focused_time: f32,
}

visuals_tick :: proc(visuals: []Piece_Visual, pawns: []sim.Pawn, dt: f32) {
	for pawn in pawns {
		visual := &visuals[pawn.handle.index]
		if visual.handle != pawn.handle do visual^ = {
			handle = pawn.handle,
		}
		visual.focused_time = .Focused in pawn.flags ? visual.focused_time + dt : 0
	}
}

@(private = "file")
PAWNS: struct {
	// Picture -> medallion fade, 0..1
	medallion_t: f32,
	render_list: gfx.Render_List,
}

// Size multiplier per icon, see PAWN_CELLS_PER_PIXEL
@(private = "file", rodata)
PAWN_SIZES := [sim.Icon]f32 {
	.Village    = 1.1,
	.Town       = 1.3,
	.City       = 1.4,
	.Large_City = 1.7,
	.Army       = 1.1,
	.Fleet      = 1.0,
}

// Focus pulse colour, and period in seconds
@(private = "file")
PAWN_FOCUSED_TINT :: [4]f32{1.000, 0.700, 0.350, 1}
@(private = "file")
PAWN_FOCUSED_PULSE :: 1.2
// Armies in the open engagement
PAWN_ENGAGED_TINT :: [4]f32{0.900, 0.350, 0.300, 1}

// One scale per set keeps pen line weight consistent across the set
@(private = "file")
PAWN_CELLS_PER_PIXEL := [Icon_Set]f32 {
	.Picture   = 5.0 / 400.0,
	.Medallion = 5.0 / 150.0,
}

// Zoom (pixels per cell) below which pawns become medallions, and fade time in seconds
@(private = "file")
PAWN_MEDALLION_ZOOM :: 10
@(private = "file")
PAWN_MEDALLION_FADE :: 0.25

// View margin (fraction of view size) so labels below off-screen pawns still show
@(private = "file")
PAWN_VIEW_TOLERANCE :: 0.1

pawns_init :: proc(camera: Camera) {
	PAWNS.medallion_t = camera.zoom < PAWN_MEDALLION_ZOOM ? 1 : 0
}

// In cells
@(private = "file")
pawn_bounds :: proc(pawn: sim.Pawn, set: Icon_Set) -> [4]f32 {
	picture := pawn.picture
	source :=
		gfx.sprite_region(gfx.sprite_of_image(icon_image(picture.icon, set, picture.culture))).source
	size := source.zw * PAWN_CELLS_PER_PIXEL[set] * PAWN_SIZES[picture.icon]
	corner := pawn.pos - size / 2
	return {corner.x, corner.y, size.x, size.y}
}

// Topmost pawn under the screen point, or nil. Skips ignore. Pass the pawns last drawn.
pawns_pick :: proc(
	pawns: []sim.Pawn,
	camera: Camera,
	viewport: [2]f32,
	point: [2]f32,
	ignored: sim.Piece_Id = {},
) -> sim.Piece_Id {
	found: sim.Piece_Id
	set: Icon_Set = PAWNS.medallion_t < 0.5 ? .Picture : .Medallion
	for pawn in pawns {
		if pawn.handle == ignored do continue
		rect, _ := camera_world_to_screen(camera, viewport, pawn_bounds(pawn, set))
		if gfx.rect_contains(rect, point) do found = pawn.handle
	}
	return found
}

// Two passes: drawings, then names, so names are always on top
pawns_draw :: proc(
	pawns: []sim.Pawn,
	visuals: []Piece_Visual,
	camera: Camera,
	viewport: [2]f32,
	pixel_density: f32,
	dt: f32,
) {
	target: f32 = camera.zoom < PAWN_MEDALLION_ZOOM ? 1 : 0
	step := dt / PAWN_MEDALLION_FADE
	PAWNS.medallion_t += clamp(target - PAWNS.medallion_t, -step, step)

	draw: gfx.Draw_Ctx
	gfx.draw_begin(
		&draw,
		&PAWNS.render_list,
		span.from_array(&PAWNS.render_list.instances),
		{0, 0, viewport.x, viewport.y},
		pixel_density,
	)

	// During the fade both sets are drawn, cross-faded
	weights := [Icon_Set]f32 {
		.Picture   = 1 - PAWNS.medallion_t,
		.Medallion = PAWNS.medallion_t,
	}
	name_at: [sim.PAWNS_MAX][2]f32
	name_weight: [sim.PAWNS_MAX]f32
	for pawn, index in pawns {
		tint := [4]f32{1, 1, 1, 1}
		picture := pawn.picture
		if .Engaged in pawn.flags do tint = PAWN_ENGAGED_TINT
		if .Focused in pawn.flags {
			focused_time := visuals[pawn.handle.index].focused_time
			pulse := 0.5 - 0.5 * math.cos(2 * math.PI * focused_time / PAWN_FOCUSED_PULSE)
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

	// Names: constant screen size, centred below, with a paper-coloured halo
	HALO :: 1.5
	font := font_id(.Text)
	for pawn, index in pawns {
		label := pawn.label
		if label == "" || name_weight[index] <= 0 do continue
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

pawns_render :: proc(renderer: ^gfx.Renderer) {
	gfx.render_list(renderer, &PAWNS.render_list)
}

