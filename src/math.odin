#+private
package main

// All sorts of mixed math helper types
Range_F32 :: struct {
	min: f32,
	max: f32,
}

Extents :: struct {
	x_min: f32,
	y_min: f32,
	x_max: f32,
	y_max: f32,
}

Axis :: enum {
	X,
	Y,
}
