package game

import "core:math/linalg"

import "../span"

// Lines through the world, in cells: rivers and coasts, and later borders or roads. They are traced from the cells into
// runs of points, stepping from cell to cell, smoothed all together by polylines_smooth, then read out run by run.

POLYLINE_POINTS_MAX :: 1 << 16
POLYLINE_RUNS_MAX :: 1 << 13
// Smoothing makes four times as many points: the corners are cut twice, each time doubling them.
POLYLINE_SMOOTHED_MAX :: 4 * POLYLINE_POINTS_MAX
// Runs of up to this many points only have their corners cut.
POLYLINE_SHORT :: 8

Polylines :: struct {
	// The traced points, and the runs of them that make lines. A closed run goes from its last point back to its first.
	points:        [POLYLINE_POINTS_MAX][2]f32,
	point_count:   int,
	runs:          [POLYLINE_RUNS_MAX]span.Span,
	closed:        [POLYLINE_RUNS_MAX]bool,
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
polylines_end :: proc(lines: ^Polylines, closed: bool) {
	begin := lines.run_count > 0 ? lines.runs[lines.run_count - 1].begin + lines.runs[lines.run_count - 1].len : 0
	run := span.from_range(begin, lines.point_count)
	if run.len < 2 || lines.run_count == POLYLINE_RUNS_MAX {
		lines.point_count = begin
		return
	}
	lines.runs[lines.run_count] = run
	lines.closed[lines.run_count] = closed
	lines.run_count += 1
}

// A run's smoothed points.
polylines_smoothed :: proc(lines: ^Polylines, run: int) -> [][2]f32 {
	s := lines.smoothed_runs[run]
	return lines.smoothed[s.begin:][:s.len]
}

// Smooths every run: cell to cell steps are softened first, then the corners are cut twice, Chaikin's way. Open runs
// keep their ends where they are. Runs of a few points are not softened, which would shrink them to specks.
polylines_smooth :: proc(lines: ^Polylines) {
	out := 0
	for run, r in lines.runs[:lines.run_count] {
		n := run.len
		closed := lines.closed[r]
		lines.smoothed_runs[r] = {}
		if out + 4 * n > POLYLINE_SMOOTHED_MAX do continue
		p := lines.smoothed[out:][:4 * n]
		copy(p, lines.points[run.begin:][:n])
		for _ in 0 ..< (n > POLYLINE_SHORT ? 2 : 0) {
			first, prev := p[0], closed ? p[n - 1] : p[0]
			for i in 0 ..< n {
				if !closed && (i == 0 || i == n - 1) do continue
				here := p[i]
				p[i] = (prev + 2 * here + (i + 1 < n ? p[i + 1] : first)) / 4
				prev = here
			}
		}
		for _ in 0 ..< 2 do n = polyline_cut_corners(p, n, closed)
		lines.smoothed_runs[r] = {out, n}
		out += n
	}
}

// Cuts every corner of the first n points of p, in place, and returns how many points there are now: twice as many.
// Each segment becomes the two points a quarter of the way in from its ends; an open line keeps its end points. The
// points are written from the last back, so each is read before anything is written over it.
@(private = "file")
polyline_cut_corners :: proc(p: [][2]f32, n: int, closed: bool) -> int {
	if closed {
		for i := n - 1; i >= 0; i -= 1 {
			a, b := p[i], p[(i + 1) % n]
			p[2 * i], p[2 * i + 1] = a * 0.75 + b * 0.25, a * 0.25 + b * 0.75
		}
		return 2 * n
	}
	p[2 * n - 1] = p[n - 1]
	for i := n - 2; i >= 0; i -= 1 {
		a, b := p[i], p[i + 1]
		p[2 * i + 1], p[2 * i + 2] = a * 0.75 + b * 0.25, a * 0.25 + b * 0.75
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
