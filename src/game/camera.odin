#+private
package game

import "core:math"
import "core:math/linalg"

Camera :: struct {
	// The cell at the middle of the view, and pixels per cell
	center:    [2]f32,
	zoom:      f32,
	// Keyboard panning velocity, in cells per second
	dv:        [2]f32,
	// A drag is in progress, and where the cursor was last frame
	grabbing:  bool,
	grab_last: [2]f32,
}

// Pixels per second the keyboard pans at, whatever the zoom
CAMERA_PAN_SPEED :: 900
// Zoom factor per wheel notch
CAMERA_ZOOM_STEP :: 1.15
// Closest zoom, in pixels per cell
CAMERA_ZOOM_MAX :: 24
// Farthest zoom, in pixels per cell
CAMERA_ZOOM_MIN :: 2

// The camera starts over the middle of the world, at its farthest zoom.
camera_init :: proc() {
	WORLD.camera.center = {WORLD_WIDTH, WORLD_HEIGHT} / 2
	WORLD.camera.zoom = CAMERA_ZOOM_MIN
}

// Moves the camera by the input: the wheel zooms about the cursor, a drag on the map pulls it along, and the keyboard
// pans it.
camera_tick :: proc(input: Input, dt: f32) {
	camera := &WORLD.camera
	world_size := [2]f32{WORLD_WIDTH, WORLD_HEIGHT}
	// Never so far out that the world is smaller than the view
	zoom_min := min(input.viewport.x / world_size.x, input.viewport.y / world_size.y)

	// Zooming keeps the cell under the cursor in place.
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

	// A drag starts only on the map, and the grabbed point stays under the cursor until the button is released.
	if input.grab && (camera.grabbing || input.on_map) {
		if camera.grabbing {
			camera.center -= (input.cursor - camera.grab_last) / camera.zoom
		}
		camera.grab_last = input.cursor
		camera.grabbing = true
	} else {
		camera.grabbing = false
	}

	// Keyboard panning eases in and out, at a constant speed on screen.
	target := input.pan * CAMERA_PAN_SPEED / camera.zoom
	camera.dv += (target - camera.dv) * (1 - math.exp(-6 * dt))
	camera.center += camera.dv * dt

	camera.center = linalg.clamp(camera.center, 0, world_size)
}

