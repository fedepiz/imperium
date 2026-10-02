#+private
package game

import "../sim"
import "../tweak"
import "../util"
import "core:math"
import "core:math/linalg"

Camera :: struct {
	// center: in cells. zoom: pixels per cell.
	center:    [2]f32,
	zoom:      f32,
	// Keyboard pan velocity, in cells per second
	dv:        [2]f32,
	grabbing:  bool,
	grab_last: [2]f32,
}

// Screen pixels per second, at any zoom
CAMERA_PAN_SPEED :: 900
// Per second, see util.ease_step
CAMERA_PAN_EASE :: 6
CAMERA_ZOOM_STEP :: 1.15
// In pixels per cell
CAMERA_ZOOM_MAX :: 24
CAMERA_ZOOM_MIN :: 2

camera_init :: proc() {
	GAME.camera.center = {sim.WORLD_WIDTH, sim.WORLD_HEIGHT} / 2
	GAME.camera.zoom = CAMERA_ZOOM_MIN
}

camera_tick :: proc(input: Input, dt: f32) {
	camera := &GAME.camera
	world_size := [2]f32{sim.WORLD_WIDTH, sim.WORLD_HEIGHT}
	// Don't zoom out past the world filling the view
	zoom_min := min(input.viewport.x / world_size.x, input.viewport.y / world_size.y)

	// Wheel zoom around the cursor
	if input.wheel != 0 && input.on_map {
		offset := input.cursor - input.viewport / 2
		anchor := camera.center + offset / camera.zoom
		camera.zoom = clamp(
			camera.zoom * math.pow(CAMERA_ZOOM_STEP, input.wheel),
			max(CAMERA_ZOOM_MIN, zoom_min),
			CAMERA_ZOOM_MAX,
		)
		camera.center = anchor - offset / camera.zoom
	}

	// Drag (must start on the map)
	if input.grab && (camera.grabbing || input.on_map) {
		if camera.grabbing {
			camera.center -= (input.cursor - camera.grab_last) / camera.zoom
		}
		camera.grab_last = input.cursor
		camera.grabbing = true
	} else {
		camera.grabbing = false
	}

	// Keyboard pan, eased
	target := input.pan * CAMERA_PAN_SPEED / camera.zoom
	camera.dv += (target - camera.dv) * util.ease_step(CAMERA_PAN_EASE, dt)
	camera.center += camera.dv * dt

	camera.center = linalg.clamp(camera.center, 0, world_size)

	tweak.slider_in_place("Camera/Zoom", &camera.zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
}

camera_world_to_screen :: proc {
	camera_world_to_screen_point,
	camera_world_to_screen_rect,
}

camera_world_to_screen_point :: proc(camera: Camera, viewport: [2]f32, pos: [2]f32) -> [2]f32 {
	return (pos - camera.center) * camera.zoom + viewport / 2
}

// visible: overlaps the view widened by tolerance (fraction of view size) on each side
camera_world_to_screen_rect :: proc(
	camera: Camera,
	viewport: [2]f32,
	rect: [4]f32,
	tolerance: f32 = 0,
) -> (
	screen: [4]f32,
	visible: bool,
) {
	pos := camera_world_to_screen_point(camera, viewport, rect.xy)
	size := rect.zw * camera.zoom
	screen = {pos.x, pos.y, size.x, size.y}
	lo := -viewport * tolerance
	hi := viewport * (1 + tolerance)
	visible = pos.x <= hi.x && pos.y <= hi.y && pos.x + size.x >= lo.x && pos.y + size.y >= lo.y
	return
}

camera_screen_to_world_point :: proc(camera: Camera, viewport: [2]f32, pos: [2]f32) -> [2]f32 {
	return (pos - viewport / 2) / camera.zoom + camera.center
}

