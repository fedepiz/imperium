#+private
package main

import "core:math"

// A value per field cell. Field cell (x, y) covers the SCALE × SCALE map cells from (x, y) × SCALE; how it aggregates
// them is its producer's
Field :: struct($T: typeid, $SCALE: int) where MAP_WIDTH % SCALE == 0 && MAP_HEIGHT % SCALE == 0 {
	values: [(MAP_WIDTH / SCALE) * (MAP_HEIGHT / SCALE)]T,
}

// The field cell holding the map position, clamped to the map
field_sample_nearest :: proc(field: ^Field($T, $SCALE), pos: [2]f32) -> T {
	size := [2]int{MAP_WIDTH, MAP_HEIGHT} / SCALE
	x := clamp(int(math.floor(pos.x)) / SCALE, 0, size.x - 1)
	y := clamp(int(math.floor(pos.y)) / SCALE, 0, size.y - 1)
	return field.values[y * size.x + x]
}

// Blended from the four nearest field-cell centres, clamped to the map. Infinite ones are left out; all infinite:
// infinite
field_sample_bilinear :: proc(field: ^Field($T, $SCALE), pos: [2]f32) -> f32 {
	size := [2]int{MAP_WIDTH, MAP_HEIGHT} / SCALE
	at := pos / f32(SCALE) - 0.5
	base := [2]int{int(math.floor(at.x)), int(math.floor(at.y))}
	t := at - [2]f32{f32(base.x), f32(base.y)}
	sum, weights: f32
	for dy in 0 ..< 2 do for dx in 0 ..< 2 {
		x := clamp(base.x + dx, 0, size.x - 1)
		y := clamp(base.y + dy, 0, size.y - 1)
		value := f32(field.values[y * size.x + x])
		weight := (dx == 0 ? 1 - t.x : t.x) * (dy == 0 ? 1 - t.y : t.y)
		if value == math.INF_F32 || weight == 0 do continue
		sum += value * weight
		weights += weight
	}
	return weights > 0 ? sum / weights : math.INF_F32
}
