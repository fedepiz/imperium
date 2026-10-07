#+private
package main

import "core:math"
import "core:math/linalg"

// Terrain coast: signed distance from each cell to the smoothed land/water boundary

// Budgets. Raw: cell-corner points of the traced boundary
@(private = "file")
RAW_POINTS_MAX :: 1 << 16
@(private = "file")
RUNS_MAX :: 1 << 12

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

// Out: coast.
// coast[i] = signed distance from cell i's centre to the coast, in cells. > 0 on land, < 0 on water.
// Grids are row-major, size.x * size.y cells
terrain_coast_build :: proc(water: []bool, size: [2]int, coast: []f32) {
	cells := size.x * size.y
	assert(len(coast) == cells && len(water) == cells)

	// Step: Trace. Water 1, land 2: land is on the left of every run
	labels := make([]u16, cells, context.temp_allocator)
	for is_water, i in water do labels[i] = is_water ? 1 : 2
	raw := new(Polylines(RAW_POINTS_MAX, RUNS_MAX), context.temp_allocator)
	boundaries_trace(labels, size, raw)

	// Step: Smooth
	smooth := new(
		Polylines(RAW_POINTS_MAX << uint(COAST_SMOOTHING.cut_iter), RUNS_MAX),
		context.temp_allocator,
	)
	polylines_smooth(raw, COAST_SMOOTHING, smooth)

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
	distance_transform(water, size, to_water)
	distance_transform(land, size, to_land)

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

// Out: out, appended to.
// Traces the edges between cells of different labels as polylines along cell corners.
// Label 0 = no cell: edges against it are not traced. The larger label is on the left of each run (+y down).
// Runs are open between corners where 1, 3 or 4 edges meet, closed loops elsewhere. Unsmoothed
@(private = "file")
boundaries_trace :: proc(labels: []u16, size: [2]int, out: ^Polylines($P, $R)) {
	assert(len(labels) == size.x * size.y)

	// Clockwise, +y down
	Step :: enum {
		East,
		South,
		West,
		North,
	}
	@(rodata, static)
	STEPS := [Step][2]int {
		.East  = {1, 0},
		.South = {0, 1},
		.West  = {-1, 0},
		.North = {0, -1},
	}

	// Per corner: unwalked outgoing edges, and how many edges meet there
	corners := size + 1
	outgoing := make([]bit_set[Step], corners.x * corners.y, context.temp_allocator)
	meeting := make([]u8, len(outgoing), context.temp_allocator)

	// Step: Edges. Directed so the larger label is on the left
	edge :: proc(outgoing: []bit_set[Step], meeting: []u8, corners, from: [2]int, step: Step) {
		to := from + STEPS[step]
		outgoing[from.y * corners.x + from.x] += {step}
		meeting[from.y * corners.x + from.x] += 1
		meeting[to.y * corners.x + to.x] += 1
	}
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			here := labels[y * size.x + x]
			if here == 0 do continue
			if y > 0 {
				above := labels[(y - 1) * size.x + x]
				if above != 0 && above != here {
					if here > above do edge(outgoing, meeting, corners, {x + 1, y}, .West)
					else do edge(outgoing, meeting, corners, {x, y}, .East)
				}
			}
			if x > 0 {
				left := labels[y * size.x + x - 1]
				if left != 0 && left != here {
					if here > left do edge(outgoing, meeting, corners, {x, y}, .South)
					else do edge(outgoing, meeting, corners, {x, y + 1}, .North)
				}
			}
		}
	}

	// Step: Walk. Follows edges from start until a junction, a dead end, or back at start
	walk :: proc(
		outgoing: []bit_set[Step],
		meeting: []u8,
		corners, start: [2]int,
		step: Step,
		out: ^Polylines($P, $R),
	) {
		begin := len(out.points)
		closed := false
		at := start
		heading := step
		append(&out.points, [2]f32{f32(at.x), f32(at.y)})
		for {
			outgoing[at.y * corners.x + at.x] -= {heading}
			at += STEPS[heading]
			c := at.y * corners.x + at.x
			if at == start && meeting[c] == 2 {
				closed = true
				break
			}
			append(&out.points, [2]f32{f32(at.x), f32(at.y)})
			if meeting[c] != 2 || outgoing[c] == {} do break
			for s in Step do if s in outgoing[c] {
				heading = s
				break
			}
		}

		// Runs under 2 points, or past the run capacity, are dropped
		count := len(out.points) - begin
		if count < 2 || len(out.runs) == cap(out.runs) {
			resize(&out.points, begin)
			return
		}
		append(&out.runs, Polyline_Run{begin = begin, len = count, closed = closed})
	}
	// Open runs first, then closed loops
	for c in 0 ..< len(outgoing) {
		if meeting[c] == 2 do continue
		for s in Step do if s in outgoing[c] {
			walk(outgoing, meeting, corners, {c % corners.x, c / corners.x}, s, out)
		}
	}
	for c in 0 ..< len(outgoing) {
		for s in Step do if s in outgoing[c] {
			walk(outgoing, meeting, corners, {c % corners.x, c / corners.x}, s, out)
		}
	}
}
