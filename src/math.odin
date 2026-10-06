#+private
package main
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"

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

Rect :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

Axis :: enum {
	X,
	Y,
}

//  Shelf packing algorithm
shelf_pack :: proc(region: [2]int, sizes: [][2]int, padding: int, pos: [][2]int) -> bool {
	assert(len(sizes) == len(pos))

	Pack_Entry :: struct {
		height: int,
		index:  int,
	}

	// Sort the inputs by height to simplify shelf-packing
	entries := make([]Pack_Entry, len(sizes), context.temp_allocator)
	for size, i in sizes do entries[i] = {size.y, i}
	slice.sort_by(entries, proc(a, b: Pack_Entry) -> bool {return a.height > b.height})

	// Perform shelf packing
	cursor: [2]int
	shelf_height := 0
	for entry in entries {
		size := sizes[entry.index]
		if size.x == 0 || size.y == 0 {
			pos[entry.index] = {}
		} else {
			if cursor.x + size.x > region.x {
				cursor.x = 0
				cursor.y += shelf_height + padding
				shelf_height = 0
			}

			if cursor.x + size.x > region.x || cursor.y + size.y > region.y {
				return false
			}

			pos[entry.index] = cursor
			cursor.x += size.x + padding
			shelf_height = max(shelf_height, size.y)
		}
	}
	return true
}

// Grids: row-major, index = y * size.x + x, cell (x, y) covers [x, x + 1) x [y, y + 1)

// Exact Euclidean distance transform (Felzenszwalb-Huttenlocher), columns then rows.
// out[i] = distance from cell i to the nearest cell with source[i] set, in cells
distance_transform :: proc(source: []bool, size: [2]int, out: []f32) {
	assert(len(out) == size.x * size.y && len(source) == len(out))

	// 1D squared distance transform: lower envelope of parabolas.
	// Scratch: parabolas len(f), bounds len(f) + 1
	line :: proc(f: []f64, parabolas: []int, bounds: []f64, out: []f64) {
		// Abscissa where parabolas q and p intersect
		crossing :: proc(f: []f64, q, p: int) -> f64 {
			return ((f[q] + f64(q * q)) - (f[p] + f64(p * p))) / f64(2 * q - 2 * p)
		}
		if len(f) == 0 do return
		k := 0
		parabolas[0] = 0
		bounds[0] = math.inf_f64(-1)
		bounds[1] = math.inf_f64(1)
		for q in 1 ..< len(f) {
			s := crossing(f, q, parabolas[k])
			// bounds[0] = -inf, so this terminates
			for s <= bounds[k] {
				k -= 1
				s = crossing(f, q, parabolas[k])
			}
			k += 1
			parabolas[k] = q
			bounds[k] = s
			bounds[k + 1] = math.inf_f64(1)
		}
		k = 0
		for q in 0 ..< len(f) {
			for bounds[k + 1] < f64(q) do k += 1
			p := parabolas[k]
			out[q] = f64((q - p) * (q - p)) + f[p]
		}
	}

	// Squared distance: 0 at sources, FAR elsewhere
	FAR :: 1e12
	squared := make([]f64, len(source), context.temp_allocator)
	for is_source, i in source do squared[i] = is_source ? 0 : FAR

	n := max(size.x, size.y)
	column := make([]f64, n, context.temp_allocator)
	result := make([]f64, n, context.temp_allocator)
	parabolas := make([]int, n, context.temp_allocator)
	bounds := make([]f64, n + 1, context.temp_allocator)
	for x in 0 ..< size.x {
		for y in 0 ..< size.y do column[y] = squared[y * size.x + x]
		line(column[:size.y], parabolas, bounds, result)
		for y in 0 ..< size.y do squared[y * size.x + x] = result[y]
	}
	for y in 0 ..< size.y {
		row := squared[y * size.x:][:size.x]
		line(row, parabolas, bounds, result)
		copy(row, result[:size.x])
	}

	for &distance, i in out do distance = f32(math.sqrt(squared[i]))
}

// Polylines

// One polyline inside a shared points buffer
Polyline_Run :: struct {
	begin:  int,
	len:    int,
	// Last point joins the first
	closed: bool,
}

// A set of polylines packed in one points buffer. Fixed capacity: appends past it are dropped
Polylines :: struct {
	// Note: these [dynamic] are built from slices and are nil-allocator backed
	points: [dynamic][2]f32,
	runs:   [dynamic]Polyline_Run,
}

// Empty set over caller storage. Capacity = len of each slice
polylines_over :: proc(points: [][2]f32, runs: []Polyline_Run) -> Polylines {
	return {mem.buffer_from_slice(points), mem.buffer_from_slice(runs)}
}

// Neighbour averaging (soften), then Chaikin corner cutting
Polyline_Smoothing :: struct {
	// Pull toward the neighbours' average per soften pass, 0..1
	softness:      f32,
	soften_iter:   int,
	// Runs of at most this many points are not softened
	soften_longer: int,
	// Each cut doubles the point count
	cut_iter:      int,
	// Cut position along each segment, (0, 0.5]. Lower keeps corners sharper
	cut_ratio:     f32,
	// Max cut distance, 0 = unlimited
	cut_max:       f32,
}

// Smooths every run of src into dst. A run of n points becomes n << cut_iter points.
// Open runs keep their end points. Runs under 2 points, or that do not fit in dst, are dropped
polylines_smooth :: proc(src: Polylines, smoothing: Polyline_Smoothing, dst: ^Polylines) {
	assert(smoothing.softness >= 0 && smoothing.softness <= 1)
	assert(smoothing.cut_ratio > 0 && smoothing.cut_ratio <= 0.5)
	assert(smoothing.cut_iter >= 0)

	cut :: proc(a, b: [2]f32, smoothing: Polyline_Smoothing) -> (near_a, near_b: [2]f32) {
		t := smoothing.cut_ratio
		if smoothing.cut_max > 0 {
			t = min(t, smoothing.cut_max / max(linalg.length(b - a), 1e-6))
		}
		return a + (b - a) * t, b + (a - b) * t
	}

	for run in src.runs {
		n := run.len
		begin := len(dst.points)
		size := n << uint(smoothing.cut_iter)
		if n < 2 || len(dst.runs) == cap(dst.runs) || begin + size > cap(dst.points) do continue

		resize(&dst.points, begin + size)
		p := dst.points[begin:]
		copy(p, src.points[run.begin:][:n])

		// Soften
		if n > smoothing.soften_longer {
			for _ in 0 ..< smoothing.soften_iter {
				first := p[0]
				prev := run.closed ? p[n - 1] : p[0]
				for i in 0 ..< n {
					if !run.closed && (i == 0 || i == n - 1) do continue
					here := p[i]
					average := (prev + 2 * here + (i + 1 < n ? p[i + 1] : first)) / 4
					p[i] = here + (average - here) * smoothing.softness
					prev = here
				}
			}
		}

		// Cut corners. Backwards, so reads happen before overwrites
		for _ in 0 ..< smoothing.cut_iter {
			if run.closed {
				for i := n - 1; i >= 0; i -= 1 {
					p[2 * i], p[2 * i + 1] = cut(p[i], p[(i + 1) % n], smoothing)
				}
			} else {
				p[2 * n - 1] = p[n - 1]
				for i := n - 2; i >= 0; i -= 1 {
					p[2 * i + 1], p[2 * i + 2] = cut(p[i], p[i + 1], smoothing)
				}
			}
			n *= 2
		}

		append(&dst.runs, Polyline_Run{begin = begin, len = n, closed = run.closed})
	}
}

// For each cell whose centre is within reach of a run and nearer to it than |nearest[i]|:
// nearest[i] = offset from the cell centre to the closest point of the run,
// side[i] (optional) = 1 if the centre is left of the segment's direction, -1 if right (+y down).
// Initialise nearest to offsets longer than reach
polylines_stamp :: proc(
	lines: Polylines,
	reach: f32,
	size: [2]int,
	nearest: [][2]f32,
	side: []f32,
) {
	assert(len(nearest) == size.x * size.y && (side == nil || len(side) == len(nearest)))

	for run in lines.runs {
		points := lines.points[run.begin:][:run.len]
		n := len(points)
		segments := run.closed ? n : n - 1
		for s in 0 ..< segments {
			a := points[s]
			b := points[(s + 1) % n]
			ab := b - a
			length2 := max(linalg.dot(ab, ab), 1e-6)

			// Cells touched by the segment's box grown by reach, clipped to the grid
			lo := linalg.min(a, b) - reach
			hi := linalg.max(a, b) + reach
			x_min := clamp(int(math.floor(lo.x)), 0, size.x)
			y_min := clamp(int(math.floor(lo.y)), 0, size.y)
			x_max := clamp(int(math.floor(hi.x)) + 1, 0, size.x)
			y_max := clamp(int(math.floor(hi.y)) + 1, 0, size.y)

			for y in y_min ..< y_max {
				for x in x_min ..< x_max {
					centre := [2]f32{f32(x), f32(y)} + 0.5
					t := clamp(linalg.dot(centre - a, ab) / length2, 0, 1)
					offset := a + ab * t - centre
					i := y * size.x + x
					if linalg.dot(offset, offset) >= linalg.dot(nearest[i], nearest[i]) do continue
					nearest[i] = offset
					// +y down: left of (dx, dy) is (dy, -dx)
					if side != nil {
						side[i] = linalg.dot(centre - a, [2]f32{ab.y, -ab.x}) >= 0 ? 1 : -1
					}
				}
			}
		}
	}
}

// Traces the edges between cells of different labels as polylines along cell corners, appended to out.
// Label 0 = no cell: edges against it are not traced. The larger label is on the left of each run (+y down).
// Runs are open between corners where 1, 3 or 4 edges meet, closed loops elsewhere. Unsmoothed
boundaries_trace :: proc(labels: []u16, size: [2]int, out: ^Polylines) {
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
		out: ^Polylines,
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
