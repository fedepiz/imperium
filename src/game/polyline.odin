package game

import "core:math/linalg"

import "../span"

// Lines through the world, in cells: rivers and coasts, and later borders or roads. They are traced from the cells into
// runs of points, stepping from cell to cell, smoothed all together by polylines_smooth, then read out run by run.

POLYLINE_POINTS_MAX :: 1 << 16
POLYLINE_RUNS_MAX :: 1 << 13
// The most times a run's corners can be cut. Each cut doubles its points, so this sizes the smoothed points.
POLYLINE_CORNER_ITER_MAX :: 3
POLYLINE_SMOOTHED_MAX :: POLYLINE_POINTS_MAX << POLYLINE_CORNER_ITER_MAX
// Runs of up to this many points are not softened, which would shrink them to specks.
POLYLINE_SHORT :: 8

// How a run is smoothed. Softening moves each point toward the average of its neighbours, twice, by softness from 0
// to 1: it rounds whole stretches of line, drawing in capes and filling bays. Then every corner is cut cut_iter times,
// Chaikin's way: each segment becomes two points cut_ratio of the way in from its ends, which rounds only the corners.
// A ratio near 0 cuts little, keeping corners crisp; 0.5 cuts the most.
Polyline_Smoothing :: struct {
	softness:  f32,
	cut_iter:  int,
	cut_ratio: f32,
}

// A run: a span of points making a line, whether it closes from its last point back to its first, and how it is
// smoothed.
Polyline_Run :: struct {
	points:    span.Span,
	closed:    bool,
	smoothing: Polyline_Smoothing,
}

Polylines :: struct {
	// The traced points, and the runs of them that make lines
	points:        [POLYLINE_POINTS_MAX][2]f32,
	point_count:   int,
	runs:          [POLYLINE_RUNS_MAX]Polyline_Run,
	run_count:     int,
	// Written by polylines_smooth: each run, smoothed. A run that did not fit is left empty.
	smoothed:      [POLYLINE_SMOOTHED_MAX][2]f32,
	smoothed_runs: [POLYLINE_RUNS_MAX]span.Span,
}

polylines_clear :: proc(lines: ^Polylines) {
	lines.point_count, lines.run_count = 0, 0
}

// Adds a point to the run being traced. A full table takes no more.
polylines_add :: proc(lines: ^Polylines, point: [2]f32) {
	if lines.point_count < POLYLINE_POINTS_MAX {
		lines.points[lines.point_count] = point
		lines.point_count += 1
	}
}

// Ends the run being traced: the points added since the last run ended. Runs of fewer than two points are dropped.
polylines_end :: proc(lines: ^Polylines, closed: bool, smoothing: Polyline_Smoothing) {
	assert(smoothing.softness >= 0 && smoothing.softness <= 1, "softness runs from 0 to 1")
	assert(smoothing.cut_iter >= 0 && smoothing.cut_iter <= POLYLINE_CORNER_ITER_MAX, "too many corner cuts")
	assert(smoothing.cut_ratio > 0 && smoothing.cut_ratio <= 0.5, "cut_ratio runs above 0 up to 0.5")
	begin := 0
	if lines.run_count > 0 {
		last := lines.runs[lines.run_count - 1].points
		begin = last.begin + last.len
	}
	points := span.from_range(begin, lines.point_count)
	if points.len < 2 || lines.run_count == POLYLINE_RUNS_MAX {
		lines.point_count = begin
		return
	}
	lines.runs[lines.run_count] = {points, closed, smoothing}
	lines.run_count += 1
}

// A run's smoothed points.
polylines_smoothed :: proc(lines: ^Polylines, run: int) -> [][2]f32 {
	s := lines.smoothed_runs[run]
	return lines.smoothed[s.begin:][:s.len]
}

// Smooths every run as it asks: see Polyline_Smoothing. Open runs keep their ends where they are.
polylines_smooth :: proc(lines: ^Polylines) {
	out := 0
	for run, r in lines.runs[:lines.run_count] {
		n := run.points.len
		closed, smoothing := run.closed, run.smoothing
		lines.smoothed_runs[r] = {}
		size := n << uint(smoothing.cut_iter)
		if out + size > POLYLINE_SMOOTHED_MAX do continue
		p := lines.smoothed[out:][:size]
		copy(p, lines.points[run.points.begin:][:n])
		for _ in 0 ..< (n > POLYLINE_SHORT ? 2 : 0) {
			first, prev := p[0], closed ? p[n - 1] : p[0]
			for i in 0 ..< n {
				if !closed && (i == 0 || i == n - 1) do continue
				here := p[i]
				average := (prev + 2 * here + (i + 1 < n ? p[i + 1] : first)) / 4
				p[i] = here + (average - here) * smoothing.softness
				prev = here
			}
		}
		for _ in 0 ..< smoothing.cut_iter do n = polyline_cut_corners(p, n, closed, smoothing.cut_ratio)
		lines.smoothed_runs[r] = {out, n}
		out += n
	}
}

// Cuts every corner of the first n points of p, in place, and returns how many points there are now: twice as many.
// Each segment becomes the two points ratio of the way in from its ends; an open line keeps its end points. The points
// are written from the last back, so each is read before anything is written over it.
@(private = "file")
polyline_cut_corners :: proc(p: [][2]f32, n: int, closed: bool, ratio: f32) -> int {
	cut :: proc(a, b: [2]f32, ratio: f32) -> (near_a, near_b: [2]f32) {
		return a + (b - a) * ratio, b + (a - b) * ratio
	}
	if closed {
		for i := n - 1; i >= 0; i -= 1 {
			p[2 * i], p[2 * i + 1] = cut(p[i], p[(i + 1) % n], ratio)
		}
		return 2 * n
	}
	p[2 * n - 1] = p[n - 1]
	for i := n - 2; i >= 0; i -= 1 {
		p[2 * i + 1], p[2 * i + 2] = cut(p[i], p[i + 1], ratio)
	}
	return 2 * n
}

// Records a line as the nearest one of every cell within reach cells of it, where it is nearer than what the cell
// holds: nearest gets the offset from the cell's middle to the nearest point of the line, and side, if given, which
// side of the line the middle lies on, 1 to the left of its direction and -1 to the right.
polyline_stamp :: proc(points: [][2]f32, closed: bool, reach: f32, nearest: [][2]f32, side: []f32) {
	n := len(points)
	segments := closed ? n : n - 1
	for s in 0 ..< segments {
		a, b := points[s], points[(s + 1) % n]
		ab := b - a
		length2 := max(linalg.dot(ab, ab), 1e-6)
		x0 := max(int(min(a.x, b.x) - reach), 0)
		y0 := max(int(min(a.y, b.y) - reach), 0)
		x1 := min(int(max(a.x, b.x) + reach), WORLD_WIDTH - 1)
		y1 := min(int(max(a.y, b.y) + reach), WORLD_HEIGHT - 1)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				middle := [2]f32{f32(x), f32(y)} + 0.5
				t := clamp(linalg.dot(middle - a, ab) / length2, 0, 1)
				offset := a + ab * t - middle
				i := y * WORLD_WIDTH + x
				if linalg.dot(offset, offset) >= linalg.dot(nearest[i], nearest[i]) do continue
				nearest[i] = offset
				// With y down the map, the left of a direction (dx, dy) is (dy, -dx).
				if side != nil do side[i] = linalg.dot(middle - a, [2]f32{ab.y, -ab.x}) >= 0 ? 1 : -1
			}
		}
	}
}
