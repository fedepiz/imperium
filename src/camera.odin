package main

import "core:math/linalg"

CAMERA_ZOOM_STEP :: 1.15
CAMERA_ZOOM_MIN :: 1
CAMERA_ZOOM_MAX :: 40
CAMERA_PAN_SPEED :: 900
CAMERA_MOVE_EASE :: 5
CAMERA_KEY_EASE :: 5
CAMERA_DRAG_EASE :: 20
CAMERA_EASE_MIN :: 1
CAMERA_EASE_MAX :: 40

Camera :: struct {
	view:      Render_View,
	target:    Render_View,
	ease:      f32,
	move_ease: f32,
	key_ease:  f32,
	drag_ease: f32,
}

camera_tick :: proc(camera: ^Camera, dt: f32) {
	camera.target.center = linalg.clamp(camera.target.center, 0, [2]f32{MAP_WIDTH, MAP_HEIGHT})
	follow := ease_step(camera.ease, dt)
	camera.view.center += (camera.target.center - camera.view.center) * follow
	scale := 1 / camera.view.zoom
	scale += (1 / camera.target.zoom - scale) * follow
	camera.view.zoom = 1 / scale
}
