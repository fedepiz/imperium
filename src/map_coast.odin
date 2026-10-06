#+private
package main

import "core:math"
import "core:math/linalg"

// Coast: signed distance from each cell to the smoothed land/water boundary

// Budgets. Raw: cell-corner points of the traced boundary
MAP_COAST_RAW_POINTS_MAX :: 1 << 16
MAP_COAST_RUNS_MAX :: 1 << 12

// Light smoothing: removes cell steps, keeps the shape
@(private = "file")
COAST_SMOOTHING :: Polyline_Smoothing {
	softness      = 0.3,
	soften_iter   = 2,
	// Softening shorter runs shrinks them to specks
	soften_longer = 8,
	cut_iter      = 2,
	cut_ratio     = 0.2,
}

// Within this many cells the distance is measured to the smoothed line, beyond it between cells
@(private = "file")
COAST_REACH :: f32(3)

// coast[i] = signed distance from cell i's centre to the coast, in cells. > 0 on land, < 0 on water.
// Grids are row-major, size.x * size.y cells
map_coast_build :: proc(coast: []f32, water: []bool, size: [2]int) {
	cells := size.x * size.y
	assert(len(coast) == cells && len(water) == cells)

	// Step: Trace. Water 1, land 2: land is on the left of every run
	labels := make([]u16, cells, context.temp_allocator)
	for is_water, i in water do labels[i] = is_water ? 1 : 2
	raw := polylines_over(
		make([][2]f32, MAP_COAST_RAW_POINTS_MAX, context.temp_allocator),
		make([]Polyline_Run, MAP_COAST_RUNS_MAX, context.temp_allocator),
	)
	boundaries_trace(labels, size, &raw)

	// Step: Smooth
	smooth := polylines_over(
		make([][2]f32, MAP_COAST_RAW_POINTS_MAX << uint(COAST_SMOOTHING.cut_iter), context.temp_allocator),
		make([]Polyline_Run, MAP_COAST_RUNS_MAX, context.temp_allocator),
	)
	polylines_smooth(raw, &smooth, COAST_SMOOTHING)

	// Step: Stamp. Offset and side to the smoothed line, for cells within COAST_REACH
	to_coast := make([][2]f32, cells, context.temp_allocator)
	for &offset in to_coast do offset = COAST_REACH
	side := make([]f32, cells, context.temp_allocator)
	polylines_stamp(smooth, COAST_REACH, size, to_coast, side)

	// Step: Cell distances, to the nearest water cell and the nearest land cell
	land := make([]bool, cells, context.temp_allocator)
	for is_water, i in water do land[i] = !is_water
	to_water := make([]f32, cells, context.temp_allocator)
	to_land := make([]f32, cells, context.temp_allocator)
	distance_transform(to_water, water, size)
	distance_transform(to_land, land, size)

	// Step: Blend. Line distance up to COAST_REACH - 1, cell distance from COAST_REACH
	for is_water, i in water {
		far := is_water ? -(to_land[i] - 0.5) : to_water[i] - 0.5
		near := linalg.length(to_coast[i])
		// Too far from the line for its side to be reliable: use the cell's own
		near_side := side[i]
		if near > 1 do near_side = is_water ? -1 : 1
		coast[i] = math.lerp(near_side * near, far, math.smoothstep(COAST_REACH - 1, COAST_REACH, near))
	}
}
