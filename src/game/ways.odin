#+private
package game

import "core:fmt"
import "core:math"
import "core:os"

import "../sim"
import "../span"
import "../tabula"

// Ways ----------------------------------------------------------------------------------------------------------------
// Rivers and roads. Loaded as cell lists, smoothed into lines; the sim's way cells are the cells the smoothed line
// crosses, so map and sim always agree.

WAYS_MAX :: 1 << 12
WAY_POINTS_MAX :: 1 << 17

@(rodata)
WAY_FILES := [sim.Way_Kind]string {
	.River = "rivers.txt",
	.Road  = "roads.txt",
}

// Rivers: wide curves. Roads: straight, tight bends.
@(rodata)
WAY_SMOOTHING := [sim.Way_Kind]Polyline_Smoothing {
	.River = {cut_iter = 3, cut_ratio = 0.25},
	.Road = {cut_iter = 2, cut_ratio = 0.25, cut_max = 1.5},
}

Way :: struct {
	kind:   sim.Way_Kind,
	// Marked on its cells
	id:     u16,
	// Range of WAYS.points
	points: span.Span,
}

WAYS: struct {
	ways:   [dynamic; WAYS_MAX]Way,
	points: [dynamic; WAY_POINTS_MAX][2]f32,
}

way_line :: proc(way: Way) -> Polyline {
	return {points = WAYS.points[way.points.begin:][:way.points.len]}
}

// Replaces WAYS. layers: per kind, per cell way id (0 = none), in the temp allocator. Prints the error and returns
// false on failure. File format (tabula): `way = { id = 1  points = [[x, y], ...] }`, cells from top left.
ways_load :: proc(folder: string) -> (layers: [sim.Way_Kind][]u16, ok: bool) {
	clear(&WAYS.ways)
	clear(&WAYS.points)
	for file, kind in WAY_FILES {
		layers[kind] = make([]u16, sim.CELLS_MAX, context.temp_allocator)
		ways_read(fmt.tprintf("%s/%s", folder, file), kind, layers[kind]) or_return
	}
	return layers, true
}

@(private = "file")
ways_read :: proc(path: string, kind: sim.Way_Kind, layer: []u16) -> bool {
	fail :: proc(path: string, way: int, message: string) -> bool {
		fmt.eprintfln("%s, way %d: %s", path, way + 1, message)
		return false
	}
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read %s: %v", path, err)
		return false
	}
	root, error, parsed := tabula.parse(string(source), context.temp_allocator)
	if !parsed {
		fmt.eprintfln("%s:%d:%d: %s", path, error.line, error.column, error.message)
		return false
	}
	for row, n in root.children {
		if row.key != "way" do return fail(path, n, fmt.tprintf("expected a way, not %q", row.key))
		id, has_id := tabula.get_num(row, "id")
		if !has_id || id < 1 || id > f32(max(u16)) || id != math.floor(id) {
			return fail(path, n, "its id must be a whole number from 1 to 65535")
		}
		points := tabula.find(row, "points")
		if len(points.children) < 2 do return fail(path, n, "it needs at least two points")
		polylines_clear()
		for point in points.children {
			whole :: proc(row: tabula.Row) -> bool {return .Has_Num in row.flags && row.num == math.floor(row.num)}
			if len(point.children) != 2 || !whole(point.children[0]) || !whole(point.children[1]) {
				return fail(path, n, "each point must be a cell, [x, y] in whole numbers")
			}
			polylines_add([2]f32{point.children[0].num, point.children[1].num} + 0.5)
		}
		polylines_end(false, WAY_SMOOTHING[kind])
		if polylines_count() == 0 do return fail(path, n, "it has too many points")
		line := polylines_get(0)
		if len(WAYS.ways) == WAYS_MAX || len(WAYS.points) + len(line.points) > WAY_POINTS_MAX {
			return fail(path, n, "there are too many ways, or too many points in them")
		}
		append(&WAYS.ways, Way{kind = kind, id = u16(id), points = {len(WAYS.points), len(line.points)}})
		append(&WAYS.points, ..line.points)
		way_mark(layer, line.points, u16(id))
	}
	return true
}

// Marks every cell the line passes through (grid traversal). Off-world cells are skipped.
@(private = "file")
way_mark :: proc(layer: []u16, points: [][2]f32, id: u16) {
	mark :: proc(layer: []u16, cell: [2]int, id: u16) {
		if cell.x < 0 || cell.y < 0 || cell.x >= sim.WORLD_WIDTH || cell.y >= sim.WORLD_HEIGHT do return
		layer[cell.y * sim.WORLD_WIDTH + cell.x] = id
	}
	for s in 1 ..< len(points) {
		a, b := points[s - 1], points[s]
		ab := b - a
		cell := [2]int{int(math.floor(a.x)), int(math.floor(a.y))}
		last := [2]int{int(math.floor(b.x)), int(math.floor(b.y))}
		step := [2]int{ab.x < 0 ? -1 : 1, ab.y < 0 ? -1 : 1}
		// Parameter (0 at a, 1 at b) of the next cell boundary per axis, and the step between boundaries
		next := [2]f32{math.INF_F32, math.INF_F32}
		apart := [2]f32{math.INF_F32, math.INF_F32}
		for axis in 0 ..< 2 {
			if ab[axis] == 0 do continue
			side := f32(cell[axis] + (step[axis] > 0 ? 1 : 0))
			next[axis] = (side - a[axis]) / ab[axis]
			apart[axis] = abs(1 / ab[axis])
		}
		mark(layer, cell, id)
		for cell != last {
			axis := next.x < next.y ? 0 : 1
			// Rounding can overshoot b
			if next[axis] > 1 do break
			cell[axis] += step[axis]
			next[axis] += apart[axis]
			mark(layer, cell, id)
		}
	}
}
