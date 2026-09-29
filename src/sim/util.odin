#+private
package sim

import "core:math"

// Sums values over a square reaching reach cells either way of each cell of a grid, size across and down, cut off at
// its edges: along the rows, then down the columns, each from running totals.
box_sum :: proc(out, values: []f32, size: [2]int, reach: int) {
	assert(len(out) == size.x * size.y && len(values) == size.x * size.y)
	totals := make([]f32, max(size.x, size.y) + 1, context.temp_allocator)
	rows := make([]f32, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x do totals[x + 1] = totals[x] + values[y * size.x + x]
		for x in 0 ..< size.x {
			rows[y * size.x + x] = totals[min(x + reach + 1, size.x)] - totals[max(x - reach, 0)]
		}
	}
	for x in 0 ..< size.x {
		for y in 0 ..< size.y do totals[y + 1] = totals[y] + rows[y * size.x + x]
		for y in 0 ..< size.y {
			out[y * size.x + x] = totals[min(y + reach + 1, size.y)] - totals[max(y - reach, 0)]
		}
	}
}

// Euclidean distance from every cell of a grid, size across and down, to the nearest source cell, by the exact
// transform of Felzenszwalb and Huttenlocher: a pass down each column, then along each row.
distance_from :: proc(out: []f32, source: []bool, size: [2]int) {
	assert(len(out) == size.x * size.y && len(source) == size.x * size.y)
	FAR :: 1e20
	n := max(size.x, size.y)
	line := make([]f32, n, context.temp_allocator)
	result := make([]f32, n, context.temp_allocator)
	parabolas := make([]i32, n, context.temp_allocator)
	bounds := make([]f32, n + 1, context.temp_allocator)
	for x in 0 ..< size.x {
		for y in 0 ..< size.y {
			line[y] = source[y * size.x + x] ? 0 : FAR
		}
		distance_line(line[:size.y], result, parabolas, bounds)
		for y in 0 ..< size.y {
			out[y * size.x + x] = result[y]
		}
	}
	for y in 0 ..< size.y {
		row := out[y * size.x:][:size.x]
		distance_line(row, result, parabolas, bounds)
		for x in 0 ..< size.x {
			row[x] = math.sqrt(result[x])
		}
	}
}

// One-dimensional squared distance transform of f into out: the lower envelope of parabolas rooted at each sample.
// parabolas and bounds are scratch, at least as long as f and one longer.
@(private = "file")
distance_line :: proc(f, out: []f32, parabolas: []i32, bounds: []f32) {
	v, z := parabolas, bounds
	intersect :: proc(f: []f32, q, p: int) -> f32 {
		return ((f[q] + f32(q * q)) - (f[p] + f32(p * p))) / f32(2 * q - 2 * p)
	}
	k := 0
	v[0] = 0
	z[0] = -math.F32_MAX
	z[1] = math.F32_MAX
	for q in 1 ..< len(f) {
		s := intersect(f, q, int(v[k]))
		for s <= z[k] {
			k -= 1
			s = intersect(f, q, int(v[k]))
		}
		k += 1
		v[k] = i32(q)
		z[k] = s
		z[k + 1] = math.F32_MAX
	}
	k = 0
	for q in 0 ..< len(f) {
		for z[k + 1] < f32(q) {
			k += 1
		}
		d := f32(q - int(v[k]))
		out[q] = d * d + f[v[k]]
	}
}

// A smooth step over a value, 0 at from and 1 at full; full below from makes it fall.
Ramp :: struct {
	from, full: f32,
}

// 0 at from, 1 at full, smooth between; full below from makes it fall.
ramp :: proc {
	ramp_between,
	ramp_over,
}

@(private = "file")
ramp_over :: proc(r: Ramp, value: f32) -> f32 {
	return ramp_between(r.from, r.full, value)
}

@(private = "file")
ramp_between :: proc(from, full, value: f32) -> f32 {
	return full > from ? math.smoothstep(from, full, value) : 1 - math.smoothstep(full, from, value)
}

// A byte as a fraction: 0 at 0, 1 at max(u8)
normalized :: proc(value: u8) -> f32 {
	return f32(value) / f32(max(u8))
}
