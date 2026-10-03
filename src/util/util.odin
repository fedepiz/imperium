package util

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"

// Grids ---------------------------------------------------------------------------------------------------------------
// Row-major: index = y * size.x + x

grid_index :: proc(pos, size: [2]int) -> int {
	return pos.y * size.x + pos.x
}

grid_pos :: proc(index: int, size: [2]int) -> [2]int {
	return {index % size.x, index / size.x}
}

grid_contains :: proc(pos, size: [2]int) -> bool {
	return pos.x >= 0 && pos.y >= 0 && pos.x < size.x && pos.y < size.y
}

// Cells in [min, max). Iterate with `for y in r.min.y ..< r.max.y do for x in r.min.x ..< r.max.x`.
Cell_Rect :: struct {
	min, max: [2]int,
}

cell_rect_empty :: proc(r: Cell_Rect) -> bool {
	return r.max.x <= r.min.x || r.max.y <= r.min.y
}

cell_rect_union :: proc(a, b: Cell_Rect) -> Cell_Rect {
	if cell_rect_empty(a) do return b
	if cell_rect_empty(b) do return a
	return {linalg.min(a.min, b.min), linalg.max(a.max, b.max)}
}

// Intersection with the grid [0, size)
cell_rect_clip :: proc(r: Cell_Rect, size: [2]int) -> Cell_Rect {
	return {linalg.clamp(r.min, 0, size), linalg.clamp(r.max, 0, size)}
}

// Cells within reach of center, on both axes
cell_rect_around :: proc(center: [2]int, reach: int) -> Cell_Rect {
	return {center - reach, center + reach + 1}
}

// Cells touched by the box [lo, hi], in cells
cell_rect_covering :: proc(lo, hi: [2]f32) -> Cell_Rect {
	return {cell_of(lo), cell_of(hi) + 1}
}

// Labels mask's connected components 1, 2, ...; 0 where mask is false. 4-connected, or 8 with diagonal.
// Returns the component count.
grid_components :: proc(labels: []u16, mask: []bool, size: [2]int, diagonal: bool) -> int {
	assert(len(labels) == size.x * size.y && len(mask) == size.x * size.y)
	for &label in labels do label = 0
	queue := make([]u32, len(mask), context.temp_allocator)
	count := 0
	for inside, start in mask {
		if !inside || labels[start] != 0 do continue
		assert(count < int(max(u16)), "too many components")
		count += 1
		label := u16(count)
		labels[start] = label
		queue[0] = u32(start)
		head, tail := 0, 1
		for head < tail {
			cell := grid_pos(int(queue[head]), size)
			head += 1
			around := cell_rect_clip(cell_rect_around(cell, 1), size)
			for y in around.min.y ..< around.max.y do for x in around.min.x ..< around.max.x {
				if !diagonal && x != cell.x && y != cell.y do continue
				next := grid_index({x, y}, size)
				if !mask[next] || labels[next] != 0 do continue
				labels[next] = label
				queue[tail] = u32(next)
				tail += 1
			}
		}
	}
	return count
}

// Box sum over a (2*reach+1) square around each cell, clipped at edges. Separable, with running totals.
box_sum :: proc(out, values: []f32, size: [2]int, reach: int) {
	assert(len(out) == size.x * size.y && len(values) == size.x * size.y)
	totals := make([]f32, max(size.x, size.y) + 1, context.temp_allocator)
	rows := make([]f32, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x do totals[x + 1] = totals[x] + values[grid_index({x, y}, size)]
		for x in 0 ..< size.x {
			rows[grid_index({x, y}, size)] = totals[min(x + reach + 1, size.x)] - totals[max(x - reach, 0)]
		}
	}
	for x in 0 ..< size.x {
		for y in 0 ..< size.y do totals[y + 1] = totals[y] + rows[grid_index({x, y}, size)]
		for y in 0 ..< size.y {
			out[grid_index({x, y}, size)] = totals[min(y + reach + 1, size.y)] - totals[max(y - reach, 0)]
		}
	}
}

// distance_squared input: 0 at sources, DISTANCE_FAR elsewhere
DISTANCE_FAR :: 1e12

// In place: squared distance to the nearest source. Exact (Felzenszwalb-Huttenlocher), columns then rows.
distance_squared :: proc(squared: []f64, size: [2]int) {
	assert(len(squared) == size.x * size.y)
	n := max(size.x, size.y)
	line := make([]f64, n, context.temp_allocator)
	result := make([]f64, n, context.temp_allocator)
	parabolas := make([]int, n, context.temp_allocator)
	bounds := make([]f64, n + 1, context.temp_allocator)
	for x in 0 ..< size.x {
		for y in 0 ..< size.y do line[y] = squared[grid_index({x, y}, size)]
		distance_line(line[:size.y], result, parabolas, bounds)
		for y in 0 ..< size.y do squared[grid_index({x, y}, size)] = result[y]
	}
	for y in 0 ..< size.y {
		row := squared[grid_index({0, y}, size):][:size.x]
		distance_line(row, result, parabolas, bounds)
		copy(row, result[:size.x])
	}
}

// Euclidean distance to the nearest source cell
distance_from :: proc(out: []f32, source: []bool, size: [2]int) {
	assert(len(out) == len(source))
	squared := make([]f64, len(source), context.temp_allocator)
	for is_source, i in source do squared[i] = is_source ? 0 : DISTANCE_FAR
	distance_squared(squared, size)
	for &distance, i in out do distance = f32(math.sqrt(squared[i]))
}

// 1D squared distance transform (lower envelope of parabolas). Scratch: parabolas len(f), bounds len(f)+1.
@(private = "file")
distance_line :: proc(f, out: []f64, parabolas: []int, bounds: []f64) {
	// Intersection of parabolas q and p
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

// Bilinear sample at p (in cells, values at cell centres), clamped at edges
bilinear :: proc(values: []f32, size: [2]int, p: [2]f32) -> f32 {
	q := p - 0.5
	base := [2]int{int(math.floor(q.x)), int(math.floor(q.y))}
	f := q - [2]f32{f32(base.x), f32(base.y)}
	at :: proc(values: []f32, size: [2]int, x, y: int) -> f32 {
		return values[grid_index({clamp(x, 0, size.x - 1), clamp(y, 0, size.y - 1)}, size)]
	}
	top := math.lerp(at(values, size, base.x, base.y), at(values, size, base.x + 1, base.y), f.x)
	bottom := math.lerp(at(values, size, base.x, base.y + 1), at(values, size, base.x + 1, base.y + 1), f.x)
	return math.lerp(top, bottom, f.y)
}

// Math ----------------------------------------------------------------------------------------------------------------

// Smoothstep: 0 at from, 1 at full. full < from makes it decreasing.
Ramp :: struct {
	from, full: f32,
}

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

// 0..255 to 0..1
normalized :: proc(value: u8) -> f32 {
	return f32(value) / f32(max(u8))
}

// Fraction of the remaining distance to cover this frame when easing toward a target at rate (per second).
// Frame-rate independent.
ease_step :: proc(rate, dt: f32) -> f32 {
	return 1 - math.exp(-rate * dt)
}

// 0..1 to 0..255, clamped and rounded. Inverse of normalized.
to_u8 :: proc(value: f32) -> u8 {
	return u8(clamp(value, 0, 1) * f32(max(u8)) + 0.5)
}

// Geometry ------------------------------------------------------------------------------------------------------------

cell_center :: proc(cell: [2]int) -> [2]f32 {
	return {f32(cell.x), f32(cell.y)} + 0.5
}

// The cell containing p
cell_of :: proc(p: [2]f32) -> [2]int {
	return {int(math.floor(p.x)), int(math.floor(p.y))}
}

// In cells
Disc :: struct {
	center: [2]f32,
	radius: f32,
}

// Strictly inside
disc_contains :: proc(disc: Disc, p: [2]f32) -> bool {
	return linalg.distance(p, disc.center) < disc.radius
}

// rect is [x, y, width, height]
disc_overlaps_rect :: proc(disc: Disc, rect: [4]f32) -> bool {
	nearest := linalg.clamp(disc.center, rect.xy, rect.xy + rect.zw)
	return linalg.distance(nearest, disc.center) <= disc.radius
}

// Neighbour averaging (soften), then Chaikin corner cutting
Smoothing :: struct {
	// 0..1, pull toward neighbours' average per iteration
	softness:    f32,
	soften_iter: int,
	// Each cut doubles the points
	cut_iter:    int,
	// 0..0.5: near 0 keeps corners crisp, 0.5 cuts most
	cut_ratio:   f32,
	// Max cut distance, 0 = unlimited
	cut_max:     f32,
}

// Smooths the first n points of p in place and returns the new count (n << cut_iter); p must have room for it.
// Open lines keep their ends. values (optional) holds per-point data for the segment ending at each point; cut points
// take their segment's value.
smooth_polyline :: proc(p: [][2]f32, n: int, closed: bool, smoothing: Smoothing, values: []f32 = nil) -> int {
	assert(smoothing.softness >= 0 && smoothing.softness <= 1, "softness runs from 0 to 1")
	assert(smoothing.cut_ratio > 0 && smoothing.cut_ratio <= 0.5, "cut_ratio runs above 0 up to 0.5")
	assert(len(p) >= n << uint(smoothing.cut_iter) && (values == nil || len(values) >= len(p)))
	n := n
	if n < 2 do return n

	// Soften
	for _ in 0 ..< smoothing.soften_iter {
		first, prev := p[0], closed ? p[n - 1] : p[0]
		for i in 0 ..< n {
			if !closed && (i == 0 || i == n - 1) do continue
			here := p[i]
			average := (prev + 2 * here + (i + 1 < n ? p[i + 1] : first)) / 4
			p[i] = here + (average - here) * smoothing.softness
			prev = here
		}
	}

	// Cut corners. Backwards, so reads happen before overwrites.
	cut :: proc(a, b: [2]f32, smoothing: Smoothing) -> (near_a, near_b: [2]f32) {
		t := smoothing.cut_ratio
		if smoothing.cut_max > 0 do t = min(t, smoothing.cut_max / max(linalg.length(b - a), 1e-6))
		return a + (b - a) * t, b + (a - b) * t
	}
	for _ in 0 ..< smoothing.cut_iter {
		if closed {
			for i := n - 1; i >= 0; i -= 1 {
				j := (i + 1) % n
				if values != nil {
					value := values[j]
					values[2 * i] = value
					values[2 * i + 1] = value
				}
				p[2 * i], p[2 * i + 1] = cut(p[i], p[j], smoothing)
			}
		} else {
			p[2 * n - 1] = p[n - 1]
			if values != nil do values[2 * n - 1] = values[n - 1]
			for i := n - 2; i >= 0; i -= 1 {
				if values != nil {
					value := values[i + 1]
					values[2 * i + 1] = value
					values[2 * i + 2] = value
				}
				p[2 * i + 1], p[2 * i + 2] = cut(p[i], p[i + 1], smoothing)
			}
		}
		n *= 2
	}
	return n
}

// Random --------------------------------------------------------------------------------------------------------------

// splitmix64's mixer: every input bit affects every output bit
random_mix :: proc(z: u64) -> u64 {
	z := z
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

// The next number of the sequence; state starts as the seed (splitmix64)
random_next :: proc(state: ^u64) -> u64 {
	state^ += 0x9e3779b97f4a7c15
	return random_mix(state^)
}

// Uniform on [0, 1)
random_unit :: proc(state: ^u64) -> f32 {
	return f32(random_next(state) >> 40) / (1 << 24)
}

// Deterministic hash to [0, 1)
random_xy :: proc(x, y: int, stream: u32) -> f32 {
	key := u64(u32(x)) << 32 | u64(u32(y))
	return f32(random_mix(key ~ u64(stream) * 0x9e3779b97f4a7c15) >> 40) / (1 << 24)
}

// roll in 0..1. picked = false if all weights are 0.
pick_weighted :: proc(weights: []f32, roll: f32) -> (index: int, picked: bool) {
	total: f32
	for weight in weights do total += weight
	left := roll * total
	for weight, k in weights {
		if weight <= 0 do continue
		index, picked = k, true
		left -= weight
		if left < 0 do break
	}
	return
}

// Text --------------------------------------------------------------------------------------------------------------

// Compact number for display, three significant digits from 1000 up: 200, 1.50K, 10.0K, 200K, 1.20M. Temp allocator.
format_compact :: proc(value: f64) -> string {
	SUFFIXES := [?]string{"", "K", "M", "B"}
	sign := value < 0 ? "-" : ""
	magnitude := abs(value)
	tier := 0
	// Rounded, not raw, so 999.6 becomes 1.00K rather than 1000
	for math.round(magnitude) >= 1000 && tier < len(SUFFIXES) - 1 {
		magnitude /= 1000
		tier += 1
	}
	if tier == 0 do return fmt.tprintf("%s%.0f", sign, magnitude)
	// Decimals from the rounded value, so 9999 shows 10.0K rather than 10.00K
	switch {
	case math.round(magnitude * 100) < 1000:
		return fmt.tprintf("%s%.2f%s", sign, magnitude, SUFFIXES[tier])
	case math.round(magnitude * 10) < 1000:
		return fmt.tprintf("%s%.1f%s", sign, magnitude, SUFFIXES[tier])
	}
	return fmt.tprintf("%s%.0f%s", sign, magnitude, SUFFIXES[tier])
}

// Hashing -------------------------------------------------------------------------------------------------------------

// FNV-1a over each value's bytes. Slices and dynamic arrays hash their length and elements, not their header.
// Padding bytes are hashed too, so only pass types without padding.
hash_contents :: proc(values: ..any) -> u64 {
	key := hash.fnv64a(nil)
	for value in values {
		bytes := mem.any_to_bytes(value)
		#partial switch info in runtime.type_info_base(type_info_of(value.id)).variant {
		case runtime.Type_Info_Slice:
			raw := (^runtime.Raw_Slice)(value.data)
			bytes = ([^]byte)(raw.data)[:raw.len * info.elem_size]
			key = hash.fnv64a(mem.ptr_to_bytes(&raw.len), key)
		case runtime.Type_Info_Dynamic_Array:
			raw := (^runtime.Raw_Dynamic_Array)(value.data)
			bytes = ([^]byte)(raw.data)[:raw.len * info.elem_size]
			key = hash.fnv64a(mem.ptr_to_bytes(&raw.len), key)
		}
		key = hash.fnv64a(bytes, key)
	}
	return key
}
