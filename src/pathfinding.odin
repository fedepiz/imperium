#+private
package main

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:slice/heap"

// Pathfinding over the map's cells, for each domain: a cost grid per cell, filled by the caller through
// pathfind_grid. Then: flood within a budget, or spread a value

Pathfind_Domain :: enum {
	Land,
	Sea,
}

// Cells in a traced path
PATHFIND_PATH_MAX :: 1_000

// Side of the flood square, in cells, centred on the start cell
PATHFIND_FLOOD_SIZE :: 256
PATHFIND_FLOOD_CELLS :: PATHFIND_FLOOD_SIZE * PATHFIND_FLOOD_SIZE

@(private = "file")
FLOOD_SQUARE :: [2]int{PATHFIND_FLOOD_SIZE, PATHFIND_FLOOD_SIZE}

@(private = "file")
Dir :: enum u8 {
	NW,
	N,
	NE,
	W,
	E,
	SW,
	S,
	SE,
}

// +y is down
@(private = "file", rodata)
DIR_OFFSET := [Dir][2]int {
	.NW = {-1, -1},
	.N  = {0, -1},
	.NE = {1, -1},
	.W  = {-1, 0},
	.E  = {1, 0},
	.SW = {-1, 1},
	.S  = {0, 1},
	.SE = {1, 1},
}

// Step length per direction, in cells
@(private = "file", rodata)
DIR_LENGTH := [Dir]f32 {
	.NW = math.SQRT_TWO,
	.N  = 1,
	.NE = math.SQRT_TWO,
	.W  = 1,
	.E  = 1,
	.SW = math.SQRT_TWO,
	.S  = 1,
	.SE = math.SQRT_TWO,
}

@(private = "file", rodata)
DIR_OPPOSITE := [Dir]Dir {
	.NW = .SE,
	.N  = .S,
	.NE = .SW,
	.W  = .E,
	.E  = .W,
	.SW = .NE,
	.S  = .N,
	.SE = .NW,
}

// A node is re-queued whenever its priority improves
@(private = "file")
Heap_Entry :: struct {
	priority: f32,
	index:    u32,
}

// Min-heap ordering for core:slice/heap (which is a max-heap)
@(private = "file")
heap_entry_less :: proc(a, b: Heap_Entry) -> bool {
	return a.priority > b.priority
}

@(private = "file")
GRIDS: [Pathfind_Domain][MAP_CELLS]f32

@(private = "file")
FLOOD_HEAP: [dynamic; len(Dir) * PATHFIND_FLOOD_CELLS]Heap_Entry

// The domain's cost of entering each cell, 0 = impassable, for the caller to fill
pathfind_grid :: proc(domain: Pathfind_Domain) -> []f32 {
	return GRIDS[domain][:]
}

// Cost of the entered cell * step length. 0 if out of bounds, impassable, or cutting a corner.
@(private = "file")
step_cost :: proc(grid: []f32, at: [2]int, dir: Dir) -> f32 {
	next := at + DIR_OFFSET[dir]
	if !grid_contains(next, MAP_SIZE) do return 0
	if DIR_OFFSET[dir].x != 0 && DIR_OFFSET[dir].y != 0 {
		if grid[grid_index({next.x, at.y}, MAP_SIZE)] == 0 do return 0
		if grid[grid_index({at.x, next.y}, MAP_SIZE)] == 0 do return 0
	}
	return grid[grid_index(next, MAP_SIZE)] * DIR_LENGTH[dir]
}

// Cells reachable within a budget, and the cheapest way to each
// Entering costs the cell's cost × hindrance
Pathfind_Zone :: struct {
	disc:      Disc,
	hindrance: f32,
}

Pathfind_Flood :: struct {
	src:     [2]f32,
	domain:  Pathfind_Domain,
	budget:  f32,
	// start: src's cell. corner: top left of the square.
	start:   [2]int,
	corner:  [2]int,
	// Infinite = not reached
	cost:    [PATHFIND_FLOOD_CELLS]f32,
	back:    [PATHFIND_FLOOD_CELLS]Dir,
	// Enemy zone hindrance, 0 = none; overlaps take the max
	zone:    [PATHFIND_FLOOD_CELLS]f32,
	// Can be passed but not stopped on
	no_stop: [PATHFIND_FLOOD_CELLS]bool,
}

// Dijkstra within budget over the square. Empty if src is out of bounds or impassable.
pathfind_flood :: proc(
	src: [2]f32,
	domain: Pathfind_Domain,
	budget: f32,
	zones: []Pathfind_Zone,
	no_stop: []Disc,
	flood: ^Pathfind_Flood,
) {
	grid := GRIDS[domain][:]
	flood.src = src
	flood.domain = domain
	flood.budget = budget
	flood.start = {int(math.floor(src.x)), int(math.floor(src.y))}
	flood.corner = flood.start - PATHFIND_FLOOD_SIZE / 2
	slice.fill(flood.cost[:], math.INF_F32)
	slice.fill(flood.zone[:], 0)
	slice.fill(flood.no_stop[:], false)
	for zone in zones do stamp(flood, flood.zone[:], zone.disc, zone.hindrance)
	for disc in no_stop do stamp(flood, flood.no_stop[:], disc, true)
	if !grid_contains(flood.start, MAP_SIZE) || grid[grid_index(flood.start, MAP_SIZE)] == 0 do return

	clear(&FLOOD_HEAP)
	start := grid_index(flood.start - flood.corner, FLOOD_SQUARE)
	flood.cost[start] = 0
	flood_push({0, u32(start)})
	for len(FLOOD_HEAP) > 0 {
		heap.pop(FLOOD_HEAP[:], heap_entry_less)
		entry := pop(&FLOOD_HEAP)
		// Skip stale heap entries
		if entry.priority > flood.cost[entry.index] do continue
		at := grid_pos(int(entry.index), FLOOD_SQUARE)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, FLOOD_SQUARE) do continue
			move := step_cost(grid, flood.corner + at, dir)
			if move == 0 do continue
			next_index := grid_index(next, FLOOD_SQUARE)
			// Inside an enemy zone: hindered
			if hindrance := flood.zone[next_index]; hindrance > 0 do move *= hindrance
			cost := entry.priority + move
			if cost > budget || cost >= flood.cost[next_index] do continue
			flood.cost[next_index] = cost
			flood.back[next_index] = DIR_OPPOSITE[dir]
			flood_push({cost, u32(next_index)})
		}
	}
}

// Writes value into the flood-square cells whose centres are inside disc; f32 masks keep the max
@(private = "file")
stamp :: proc(flood: ^Pathfind_Flood, mask: []$T, disc: Disc, value: T) {
	covered := cell_rect_covering(disc.center - disc.radius, disc.center + disc.radius)
	local := cell_rect_clip({covered.min - flood.corner, covered.max - flood.corner}, FLOOD_SQUARE)
	for y in local.min.y ..< local.max.y do for x in local.min.x ..< local.max.x {
		if !disc_contains(disc, cell_center(flood.corner + {x, y})) do continue
		cell := &mask[grid_index({x, y}, FLOOD_SQUARE)]
		when T == bool {
			cell^ = value
		} else {
			cell^ = max(cell^, value)
		}
	}
}

@(private = "file")
flood_reaches :: proc(flood: ^Pathfind_Flood, cell: [2]int) -> bool {
	local := cell - flood.corner
	return(
		grid_contains(local, FLOOD_SQUARE) &&
		flood.cost[grid_index(local, FLOOD_SQUARE)] < math.INF_F32 \
	)
}

// Cell to stop at for dst: dst's own if possible, else the nearest reached stoppable cell within a snap-sized square
// (none with snap 0)
pathfind_flood_stop :: proc(flood: ^Pathfind_Flood, dst: [2]f32, snap: int) -> (cell: [2]int, ok: bool) {
	to := cell_of(dst)
	nearest := math.INF_F32
	if !flood_reaches(flood, to) {
		for y in 0 ..< snap {
			for x in 0 ..< snap {
				at := to - snap / 2 + {x, y}
				if !flood_reaches(flood, at) || flood.no_stop[grid_index(at - flood.corner, FLOOD_SQUARE)] do continue
				distance := linalg.distance(cell_center(at), dst)
				if distance < nearest do cell, ok, nearest = at, true, distance
			}
		}
		return
	}
	for cost, i in flood.cost {
		if cost == math.INF_F32 || flood.no_stop[i] do continue
		at := flood.corner + grid_pos(i, FLOOD_SQUARE)
		distance := linalg.distance(cell_center(at), dst)
		if distance < nearest do cell, ok, nearest = at, true, distance
	}
	return
}

// Cheapest stoppable cell inside the disc
pathfind_flood_stop_within :: proc(
	flood: ^Pathfind_Flood,
	disc: Disc,
) -> (
	cell: [2]int,
	ok: bool,
) {
	cheapest := math.INF_F32
	for cost, i in flood.cost {
		if cost >= cheapest || flood.no_stop[i] do continue
		at := flood.corner + grid_pos(i, FLOOD_SQUARE)
		if !disc_contains(disc, cell_center(at)) do continue
		cell, ok, cheapest = at, true, cost
	}
	return
}

// Output as pathfind_trace. False (both empty) if dst isn't reached.
pathfind_flood_trace :: proc(
	flood: ^Pathfind_Flood,
	dst: [2]f32,
	out: ^[dynamic; PATHFIND_PATH_MAX][2]f32,
	costs: ^[dynamic; PATHFIND_PATH_MAX]f32,
) -> (
	ok: bool,
) {
	clear(out)
	clear(costs)
	to := [2]int{int(math.floor(dst.x)), int(math.floor(dst.y))}
	if !flood_reaches(flood, to) do return false
	grid := GRIDS[flood.domain][:]
	// Walk back from dst, then reverse
	for cell := to; cell != flood.start; {
		if len(out) == PATHFIND_PATH_MAX {
			clear(out)
			clear(costs)
			return false
		}
		index := grid_index(cell, MAP_SIZE)
		local := grid_index(cell - flood.corner, FLOOD_SQUARE)
		cost := grid[index]
		if hindrance := flood.zone[local]; hindrance > 0 do cost *= hindrance
		append(out, cell_center(cell))
		append(costs, cost)
		cell += DIR_OFFSET[flood.back[local]]
	}
	slice.reverse(out[:])
	slice.reverse(costs[:])
	return true
}

// Spread ------------------------------------------------------------------------------------------------------------

Pathfind_Source :: struct {
	// In cells
	pos:   [2]f32,
	value: f32,
}

// Multi-source decaying spread over a domain: out[cell] = max over sources of value − decay × path cost, 0 where
// nothing reaches. Enemy zones cost × hindrance, as in the flood. out is MAP_CELLS long.
pathfind_spread :: proc(
	domain: Pathfind_Domain,
	sources: []Pathfind_Source,
	zones: []Pathfind_Zone,
	decay: f32,
	out: []f32,
) {
	assert(len(out) == MAP_CELLS && decay > 0)
	grid := GRIDS[domain][:]
	slice.fill(out, 0)

	// Zone hindrance per cell, 0 = none; overlaps take the max
	hindrance := make([]f32, MAP_CELLS, context.temp_allocator)
	for zone in zones {
		disc := zone.disc
		covered := cell_rect_clip(cell_rect_covering(disc.center - disc.radius, disc.center + disc.radius), MAP_SIZE)
		for y in covered.min.y ..< covered.max.y do for x in covered.min.x ..< covered.max.x {
			if !disc_contains(disc, cell_center({x, y})) do continue
			cell := &hindrance[grid_index({x, y}, MAP_SIZE)]
			cell^ = max(cell^, zone.hindrance)
		}
	}

	// Dijkstra, highest value first (priority = −value)
	queue := make([dynamic]Heap_Entry, context.temp_allocator)
	for source in sources {
		cell := cell_of(source.pos)
		if !grid_contains(cell, MAP_SIZE) do continue
		index := grid_index(cell, MAP_SIZE)
		if grid[index] == 0 || source.value <= out[index] do continue
		out[index] = source.value
		append(&queue, Heap_Entry{-source.value, u32(index)})
		heap.push(queue[:], heap_entry_less)
	}
	for len(queue) > 0 {
		heap.pop(queue[:], heap_entry_less)
		entry := pop(&queue)
		value := -entry.priority
		// Skip stale heap entries
		if value < out[entry.index] do continue
		at := grid_pos(int(entry.index), MAP_SIZE)
		for dir in Dir {
			move := step_cost(grid, at, dir)
			if move == 0 do continue
			next := grid_index(at + DIR_OFFSET[dir], MAP_SIZE)
			if h := hindrance[next]; h > 0 do move *= h
			reached := value - decay * move
			if reached <= out[next] do continue
			out[next] = reached
			append(&queue, Heap_Entry{-reached, u32(next)})
			heap.push(queue[:], heap_entry_less)
		}
	}
}

@(private = "file")
flood_push :: proc(entry: Heap_Entry) {
	assert(len(FLOOD_HEAP) < cap(FLOOD_HEAP), "Pathfinding heap full")
	append(&FLOOD_HEAP, entry)
	heap.push(FLOOD_HEAP[:], heap_entry_less)
}
