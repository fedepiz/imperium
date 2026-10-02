#+private
package game

import "core:math/linalg"

import "../sim"
import "../span"
import "../util"

// Polyline builder (in cells) for ways, coasts and arrows: add points, end a run (smoothed), read runs back.

POLYLINE_POINTS_MAX :: 1 << 16
POLYLINE_RUNS_MAX :: 1 << 13
// Each corner cut doubles the points
POLYLINE_CORNER_ITER_MAX :: 3
POLYLINE_SMOOTHED_MAX :: POLYLINE_POINTS_MAX << POLYLINE_CORNER_ITER_MAX
// Runs this short aren't softened (it would shrink them to specks)
POLYLINE_SHORT :: 8

Polyline :: struct {
	points: [][2]f32,
	closed: bool,
}

@(private = "file")
POLYLINES: struct {
	// Current run
	tracing: [dynamic; POLYLINE_POINTS_MAX][2]f32,
	// Finished runs, smoothed
	points:  [dynamic; POLYLINE_SMOOTHED_MAX][2]f32,
	runs:    [dynamic; POLYLINE_RUNS_MAX]Polyline_Run,
}

@(private = "file")
Polyline_Run :: struct {
	points: span.Span,
	closed: bool,
}

polylines_clear :: proc() {
	lines := &POLYLINES
	clear(&lines.tracing)
	clear(&lines.points)
	clear(&lines.runs)
}

// Ignored when full
polylines_add :: proc(point: [2]f32) {
	lines := &POLYLINES
	if len(lines.tracing) < POLYLINE_POINTS_MAX do append(&lines.tracing, point)
}

// Smooths and stores the current run. Open runs keep their ends. Runs < 2 points, or that don't fit, are dropped.
polylines_end :: proc(closed: bool, smoothing: util.Smoothing) {
	lines := &POLYLINES
	defer clear(&lines.tracing)
	assert(smoothing.cut_iter >= 0 && smoothing.cut_iter <= POLYLINE_CORNER_ITER_MAX, "too many corner cuts")
	n := len(lines.tracing)
	begin := len(lines.points)
	size := n << uint(smoothing.cut_iter)
	if n < 2 || len(lines.runs) == POLYLINE_RUNS_MAX || begin + size > POLYLINE_SMOOTHED_MAX do return

	resize(&lines.points, begin + size)
	p := lines.points[begin:]
	copy(p, lines.tracing[:])
	smoothing := smoothing
	if n <= POLYLINE_SHORT do smoothing.soften_iter = 0
	n = util.smooth_polyline(p, n, closed, smoothing)
	resize(&lines.points, begin + n)
	append(&lines.runs, Polyline_Run{points = {begin, n}, closed = closed})
}

polylines_count :: proc() -> int {
	return len(POLYLINES.runs)
}

polylines_get :: proc(run: int) -> Polyline {
	lines := &POLYLINES
	r := lines.runs[run]
	return {points = lines.points[r.points.begin:][:r.points.len], closed = r.closed}
}

// For cells within reach where this line is nearer than what's stored: nearest = offset from cell centre to the
// line; side (optional) = 1 left of the line's direction, -1 right.
polyline_stamp :: proc(line: Polyline, reach: f32, nearest: [][2]f32, side: []f32) {
	n := len(line.points)
	segments := line.closed ? n : n - 1
	for s in 0 ..< segments {
		a, b := line.points[s], line.points[(s + 1) % n]
		ab := b - a
		length2 := max(linalg.dot(ab, ab), 1e-6)
		covered := util.cell_rect_covering(linalg.min(a, b) - reach, linalg.max(a, b) + reach)
		area := util.cell_rect_clip(covered, sim.WORLD_SIZE)
		for y in area.min.y ..< area.max.y {
			for x in area.min.x ..< area.max.x {
				middle := [2]f32{f32(x), f32(y)} + 0.5
				t := clamp(linalg.dot(middle - a, ab) / length2, 0, 1)
				offset := a + ab * t - middle
				i := util.grid_index({x, y}, sim.WORLD_SIZE)
				if linalg.dot(offset, offset) >= linalg.dot(nearest[i], nearest[i]) do continue
				nearest[i] = offset
				// +y down: left of (dx, dy) is (dy, -dx)
				if side != nil do side[i] = linalg.dot(middle - a, [2]f32{ab.y, -ab.x}) >= 0 ? 1 : -1
			}
		}
	}
}

