#+private
package game

import "core:math/linalg"

import "../sim"
import "../span"

// Polyline builder (in cells) for ways, coasts and arrows: add points, end a run (smoothed), read runs back.

POLYLINE_POINTS_MAX :: 1 << 16
POLYLINE_RUNS_MAX :: 1 << 13
// Each corner cut doubles the points
POLYLINE_CORNER_ITER_MAX :: 3
POLYLINE_SMOOTHED_MAX :: POLYLINE_POINTS_MAX << POLYLINE_CORNER_ITER_MAX
// Runs this short aren't softened (it would shrink them to specks)
POLYLINE_SHORT :: 8

// Neighbour averaging (soften), then Chaikin corner cutting
Polyline_Smoothing :: struct {
	// 0..1, pull toward neighbours' average per iteration
	softness:    f32,
	soften_iter: int,
	cut_iter:    int,
	// 0..0.5: near 0 keeps corners crisp, 0.5 cuts most
	cut_ratio:   f32,
	// Max cut distance in cells, 0 = unlimited
	cut_max:     f32,
}

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
polylines_end :: proc(closed: bool, smoothing: Polyline_Smoothing) {
	lines := &POLYLINES
	defer clear(&lines.tracing)
	assert(smoothing.softness >= 0 && smoothing.softness <= 1, "softness runs from 0 to 1")
	assert(smoothing.cut_iter >= 0 && smoothing.cut_iter <= POLYLINE_CORNER_ITER_MAX, "too many corner cuts")
	assert(smoothing.cut_ratio > 0 && smoothing.cut_ratio <= 0.5, "cut_ratio runs above 0 up to 0.5")
	n := len(lines.tracing)
	begin := len(lines.points)
	size := n << uint(smoothing.cut_iter)
	if n < 2 || len(lines.runs) == POLYLINE_RUNS_MAX || begin + size > POLYLINE_SMOOTHED_MAX do return

	resize(&lines.points, begin + size)
	p := lines.points[begin:]
	copy(p, lines.tracing[:])
	for _ in 0 ..< (n > POLYLINE_SHORT ? smoothing.soften_iter : 0) {
		first, prev := p[0], closed ? p[n - 1] : p[0]
		for i in 0 ..< n {
			if !closed && (i == 0 || i == n - 1) do continue
			here := p[i]
			average := (prev + 2 * here + (i + 1 < n ? p[i + 1] : first)) / 4
			p[i] = here + (average - here) * smoothing.softness
			prev = here
		}
	}
	for _ in 0 ..< smoothing.cut_iter do n = polyline_cut_corners(p, n, closed, smoothing.cut_ratio, smoothing.cut_max)
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

// One Chaikin pass in place over the first n points; returns the new count (2n). Open lines keep their ends.
@(private = "file")
polyline_cut_corners :: proc(p: [][2]f32, n: int, closed: bool, ratio, cut_max: f32) -> int {
	cut :: proc(a, b: [2]f32, ratio, cut_max: f32) -> (near_a, near_b: [2]f32) {
		t := ratio
		if cut_max > 0 do t = min(t, cut_max / max(linalg.length(b - a), 1e-6))
		return a + (b - a) * t, b + (a - b) * t
	}
	if closed {
		for i := n - 1; i >= 0; i -= 1 {
			p[2 * i], p[2 * i + 1] = cut(p[i], p[(i + 1) % n], ratio, cut_max)
		}
		return 2 * n
	}
	p[2 * n - 1] = p[n - 1]
	for i := n - 2; i >= 0; i -= 1 {
		p[2 * i + 1], p[2 * i + 2] = cut(p[i], p[i + 1], ratio, cut_max)
	}
	return 2 * n
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
		x0 := max(int(min(a.x, b.x) - reach), 0)
		y0 := max(int(min(a.y, b.y) - reach), 0)
		x1 := min(int(max(a.x, b.x) + reach), sim.WORLD_WIDTH - 1)
		y1 := min(int(max(a.y, b.y) + reach), sim.WORLD_HEIGHT - 1)
		for y in y0 ..= y1 {
			for x in x0 ..= x1 {
				middle := [2]f32{f32(x), f32(y)} + 0.5
				t := clamp(linalg.dot(middle - a, ab) / length2, 0, 1)
				offset := a + ab * t - middle
				i := y * sim.WORLD_WIDTH + x
				if linalg.dot(offset, offset) >= linalg.dot(nearest[i], nearest[i]) do continue
				nearest[i] = offset
				// +y down: left of (dx, dy) is (dy, -dx)
				if side != nil do side[i] = linalg.dot(middle - a, [2]f32{ab.y, -ab.x}) >= 0 ? 1 : -1
			}
		}
	}
}

