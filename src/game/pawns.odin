#+private
package game

import "core:math"

import "../gfx"
import "../sim"
import "../span"

// Pawns: how the scene's pawns are drawn on the map, each as its icon's drawing with its name hanging below. What a
// pawn shows comes from the scene; what it keeps from frame to frame is in its piece's visual state.

// How a piece looks beyond what its pawn says, kept from frame to frame in the slot of its handle's index
Piece_Visual :: struct {
	// The piece the state is for; a pawn of another handle in the slot starts it over
	handle:       sim.Piece_Id,
	// Seconds the piece has been focused for, which its tint pulses by
	focused_time: f32,
}

// Keeps the pieces' visual state in step with the frame's pawns, dt seconds after the last frame
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
	// How far pawns have faded from pictures to medallions, from 0 to 1
	medallion_t: f32,
	render_list: gfx.Render_List,
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

// The rect a pawn's drawing in a set covers, in cells
@(private = "file")
pawn_bounds :: proc(pawn: sim.Pawn, set: Icon_Set) -> [4]f32 {
	picture := pawn.picture
	source :=
		gfx.sprite_region(gfx.sprite_of_image(icon_image(picture.icon, set, picture.culture))).source
	size := source.zw * PAWN_CELLS_PER_PIXEL[set] * PAWN_SIZES[picture.icon]
	corner := pawn.pos - size / 2
	return {corner.x, corner.y, size.x, size.y}
}

// The handle of the last of the pawns whose drawing, in the set that shows more, covers the point on screen, or nil
// for none. The pawn with the ignored handle is never picked; nil ignores none. Pass the pawns last drawn, so what is
// picked is what is on screen.
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

// Draws the pawns in the view of the camera, fading between pictures and medallions by the zoom, dt seconds
// after the last frame, in two passes: their drawings, then their names, so every name shows over every drawing.
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

	// While the fade is under way, each pawn is drawn in both sets, the one fading in over the one fading out. Its name
	// hangs under the drawings, between their bottoms as they fade.
	weights := [Icon_Set]f32 {
		.Picture   = 1 - PAWNS.medallion_t,
		.Medallion = PAWNS.medallion_t,
	}
	name_at: [sim.PAWNS_MAX][2]f32
	name_weight: [sim.PAWNS_MAX]f32
	for pawn, index in pawns {
		tint := [4]f32{1, 1, 1, 1}
		picture := pawn.picture
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

	// Each name keeps its size on screen, centred under its drawing, over a halo of paper: the name drawn in the paper's
	// colour a little way off all round.
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

// Draws what pawns_end made
pawns_render :: proc(renderer: ^gfx.Renderer) {
	gfx.render_list(renderer, &PAWNS.render_list)
}

