#+private
package game

import "core:math/linalg"

import "../sim"
import "../span"

// Lines through the world, in cells: ways and coasts, and later borders. They are traced from the cells into runs of
// points, stepping from cell to cell; each run is smoothed as it ends, then read out run by run.

// The most points a run is traced with, and the most runs
POLYLINE_POINTS_MAX :: 1 << 16
POLYLINE_RUNS_MAX :: 1 << 13
// The most times a run's corners can be cut. Each cut doubles its points, so this sizes the smoothed points.
POLYLINE_CORNER_ITER_MAX :: 3
// Room for the smoothed points of all the runs
POLYLINE_SMOOTHED_MAX :: POLYLINE_POINTS_MAX << POLYLINE_CORNER_ITER_MAX
// Runs of up to this many points are not softened, which would shrink them to specks.
POLYLINE_SHORT :: 8

// How a run is smoothed. First, if simplify is above 0, every point within simplify cells of the line between the
// points kept either side of it is dropped: steps from cell to cell straighten into long runs at any angle, bending
// only where the cells really turn. Softening then moves each point toward the average of its neighbours, twice, by
// softness from 0 to 1: it rounds whole stretches of line, drawing in capes and filling bays. Then every corner is cut
// cut_iter times, Chaikin's way: each segment becomes two points cut_ratio of the way in from its ends, but never more
// than cut_max cells in if cut_max is above 0, which rounds only the corners. A ratio near 0 cuts little, keeping
// corners crisp; 0.5 cuts the most.
Polyline_Smoothing :: struct {
	simplify:  f32,
	softness:  f32,
	cut_iter:  int,
	cut_ratio: f32,
	cut_max:   f32,
}

// A smoothed run, as polylines_get reads it out: its points, and whether they close from the last back to the first
Polyline :: struct {
	points: [][2]f32,
	closed: bool,
}

@(private = "file")
POLYLINES: struct {
	// The points of the run being traced
	tracing: [dynamic; POLYLINE_POINTS_MAX][2]f32,
	// The runs ended since the last clear, smoothed
	points:  [dynamic; POLYLINE_SMOOTHED_MAX][2]f32,
	runs:    [dynamic; POLYLINE_RUNS_MAX]Polyline_Run,
}

// A smoothed run: a span of the points, and whether it closes from its last point back to its first
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

// Adds a point to the run being traced. A full run takes no more.
polylines_add :: proc(point: [2]f32) {
	lines := &POLYLINES
	if len(lines.tracing) < POLYLINE_POINTS_MAX do append(&lines.tracing, point)
}

// Ends the run being traced, the points added since the last run ended, and smooths it as it asks: see
// Polyline_Smoothing. An open run keeps its ends where they are. Runs of fewer than two points are dropped, as are runs
// past the room there is.
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
	if smoothing.simplify > 0 do n = polyline_simplify(p, n, smoothing.simplify)
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
	for _ in 0 ..< smoothing.cut_iter do n = polyline_cut_corners(p, n, closed, smoothing.cut_ratio, smoothing.cut_max)
	resize(&lines.points, begin + n)
	append(&lines.runs, Polyline_Run{points = {begin, n}, closed = closed})
}

// How many runs have been ended since the last clear
polylines_count :: proc() -> int {
	return len(POLYLINES.runs)
}

// A run, smoothed
polylines_get :: proc(run: int) -> Polyline {
	lines := &POLYLINES
	r := lines.runs[run]
	return {points = lines.points[r.points.begin:][:r.points.len], closed = r.closed}
}

// Drops, in place, those of the first n points of p that lie within tolerance cells of the line between the points
// kept either side of them, Douglas and Peucker's way, and returns how many are left. The first and last are kept.
@(private = "file")
polyline_simplify :: proc(p: [][2]f32, n: int, tolerance: f32) -> int {
	if n < 3 do return n
	keep := make([]bool, n, context.temp_allocator)
	keep[0] = true
	keep[n - 1] = true
	// Stretches between two kept points, still to be split at their farthest point from the line between them
	stretches := make([dynamic][2]int, 0, n, context.temp_allocator)
	append(&stretches, [2]int{0, n - 1})
	for len(stretches) > 0 {
		s := pop(&stretches)
		a := p[s[0]]
		ab := p[s[1]] - a
		length2 := max(linalg.dot(ab, ab), 1e-6)
		farthest := -1
		far := tolerance
		for i in s[0] + 1 ..< s[1] {
			t := clamp(linalg.dot(p[i] - a, ab) / length2, 0, 1)
			d := linalg.length(a + ab * t - p[i])
			if d <= far do continue
			farthest = i
			far = d
		}
		if farthest < 0 do continue
		keep[farthest] = true
		append(&stretches, [2]int{s[0], farthest}, [2]int{farthest, s[1]})
	}
	count := 0
	for i in 0 ..< n {
		if !keep[i] do continue
		p[count] = p[i]
		count += 1
	}
	return count
}

// Cuts every corner of the first n points of p, in place, and returns how many points there are now: twice as many.
// Each segment becomes the two points ratio of the way in from its ends, but no more than cut_max cells in if cut_max
// is above 0; an open line keeps its end points. The points are written from the last back, so each is read before
// anything is written over it.
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

// Records a line as the nearest one of every cell within reach cells of it, where it is nearer than what the cell
// holds: nearest gets the offset from the cell's middle to the nearest point of the line, and side, if given, which
// side of the line the middle lies on, 1 to the left of its direction and -1 to the right.
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
				// With y down the map, the left of a direction (dx, dy) is (dy, -dx).
				if side != nil do side[i] = linalg.dot(middle - a, [2]f32{ab.y, -ab.x}) >= 0 ? 1 : -1
			}
		}
	}
}

