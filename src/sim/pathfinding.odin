#+private
package sim

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
import "core:slice/heap"
import "core:time"

PATH_MAX_LEN :: 1_000

// Changes with any edit to this file, invalidating caches built by older code
@(private = "file")
CACHE_SOURCE :: #hash(#load("pathfinding.odin", string), "fnv64a")

// Max heuristic overestimate factor
@(private = "file")
HEURISTIC_TIE_BREAK :: 1 + 1.0 / 1024

// Side of the flood square, in cells, centred on the start cell
PATHFIND_FLOOD_SIZE :: 256
PATHFIND_FLOOD_CELLS :: PATHFIND_FLOOD_SIZE * PATHFIND_FLOOD_SIZE

@(private = "file")
FLOOD_SQUARE :: [2]int{PATHFIND_FLOOD_SIZE, PATHFIND_FLOOD_SIZE}

#assert(
	PATHFIND_FLOOD_CELLS <= CELLS_COARSE_MAX,
	"a flood queues each cell up to once per direction on the heap",
)

// Side of a coarse block, in cells
@(private = "file")
BLOCKING_FACTOR :: 4

@(private = "file")
CELLS_FINE_MAX :: WORLD_WIDTH * WORLD_HEIGHT
@(private = "file")
CELLS_COARSE_MAX :: CELLS_FINE_MAX / (BLOCKING_FACTOR * BLOCKING_FACTOR)

#assert(WORLD_WIDTH % BLOCKING_FACTOR == 0 && WORLD_HEIGHT % BLOCKING_FACTOR == 0)

// Landmarks for the ALT heuristic
@(private = "file")
LANDMARKS_MAX :: 16

@(private = "file")
BLOCKS_SIZE :: [2]int{WORLD_WIDTH / BLOCKING_FACTOR, WORLD_HEIGHT / BLOCKING_FACTOR}

// Cells whose centres are within radius of center. In cells.
Disc :: struct {
	center: [2]f32,
	radius: f32,
}

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

@(private = "file")
Node :: struct {
	g:      f32,
	stamp:  u32,
	parent: Dir,
	closed: bool,
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
Pathfind_Table :: struct {
	// Input cost grid
	grid:    [CELLS_FINE_MAX]f32,
	// Key of the grid `derived` was built from, see pathfind_key
	key:     u64,
	derived: Derived,
}

@(private = "file")
Derived :: struct {
	// Connected component per cell, from 1; 0 = impassable
	component: [CELLS_FINE_MAX]u16,
	min_cost:  f32,
	coarse:    struct {
		// Cheapest passable cell of the block, or its first cell
		representative: [CELLS_COARSE_MAX][2]int,
		// Cost between representatives, searched within the two blocks (four for diagonals); 0 = none
		move:           [CELLS_COARSE_MAX][Dir]f32,
	},
	// Blocks in the largest component, spread far apart
	landmarks: struct {
		// Coarse costs landmark->block and block->landmark; infinite = unreachable
		from, to: [LANDMARKS_MAX][CELLS_COARSE_MAX]f32,
		count:    int,
	},
}

@(private = "file")
TABLE: [Pathfind_Domain]Pathfind_Table

@(private = "file")
Level :: enum u8 {
	Fine,
	Coarse,
}

@(private = "file")
Search_Scratch :: struct {
	node:  [CELLS_FINE_MAX]Node,
	// Room for each block queued once per direction
	heap:  [dynamic; len(Dir) * CELLS_COARSE_MAX]Heap_Entry,
	// Nodes with an older stamp are unvisited
	stamp: u32,
}

@(private = "file")
SCRATCH: struct {
	search:         [Level]Search_Scratch,
	// Block is in the current corridor if equal to corridor_stamp
	corridor:       [CELLS_COARSE_MAX]u32,
	corridor_stamp: u32,
}

@(private = "file")
heap_push :: proc(scratch: ^Search_Scratch, entry: Heap_Entry) {
	assert(len(scratch.heap) < cap(scratch.heap), "Pathfinding heap full")
	append(&scratch.heap, entry)
	heap.push(scratch.heap[:], heap_entry_less)
}

// Heap must not be empty
@(private = "file")
heap_pop :: proc(scratch: ^Search_Scratch) -> Heap_Entry {
	heap.pop(scratch.heap[:], heap_entry_less)
	return pop(&scratch.heap)
}

@(private = "file")
corridor_mark :: proc(block: [2]int) {
	if grid_contains(block, BLOCKS_SIZE) do SCRATCH.corridor[grid_index(block, BLOCKS_SIZE)] = SCRATCH.corridor_stamp
}

// A* over cells or blocks. Results (cost, back direction) are left in SCRATCH. The fine level stays inside the
// current corridor and never cuts corners past impassable cells.
@(private = "file")
search :: proc(table: ^Pathfind_Table, $level: Level, from, to: [2]int) -> (cost: f32, ok: bool) {
	scratch := &SCRATCH.search[level]
	scratch.stamp += 1
	clear(&scratch.heap)
	size := level == .Fine ? WORLD_SIZE : BLOCKS_SIZE

	// Octile distance * min cost; at the coarse level, max'd with the landmark (ALT) bounds. Scaled by the tie-break.
	estimate :: proc(table: ^Pathfind_Table, $level: Level, node, goal: [2]int) -> f32 {
		when level == .Fine {
			h := octile(node, goal) * table.derived.min_cost
		} else {
			a := grid_index(node, BLOCKS_SIZE)
			b := grid_index(goal, BLOCKS_SIZE)
			h :=
				octile(
					table.derived.coarse.representative[a],
					table.derived.coarse.representative[b],
				) *
				table.derived.min_cost
			for l in 0 ..< table.derived.landmarks.count {
				from := &table.derived.landmarks.from[l]
				to := &table.derived.landmarks.to[l]
				if from[a] < math.INF_F32 && from[b] < math.INF_F32 do h = max(h, from[b] - from[a])
				if to[a] < math.INF_F32 && to[b] < math.INF_F32 do h = max(h, to[a] - to[b])
			}
		}
		return h * HEURISTIC_TIE_BREAK
	}
	goal := u32(grid_index(to, size))

	start := u32(grid_index(from, size))
	scratch.node[start] = {
		g     = 0,
		stamp = scratch.stamp,
	}
	heap_push(scratch, {estimate(table, level, from, to), start})

	for len(scratch.heap) > 0 {
		index := heap_pop(scratch).index
		node := &scratch.node[index]
		// Skip stale heap entries
		if node.closed do continue
		node.closed = true
		if index == goal do return node.g, true

		at := grid_pos(int(index), size)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, size) do continue
			next_index := grid_index(next, size)
			when level == .Fine {
				move := step_cost(table, at, dir)
				if move == 0 do continue
				if SCRATCH.corridor[grid_index(next / BLOCKING_FACTOR, BLOCKS_SIZE)] != SCRATCH.corridor_stamp do continue
			} else {
				move := table.derived.coarse.move[index][dir]
				if move == 0 do continue
			}
			next_node := &scratch.node[next_index]
			g := node.g + move
			if next_node.stamp == scratch.stamp && (next_node.closed || g >= next_node.g) do continue
			next_node^ = {
				g      = g,
				stamp  = scratch.stamp,
				parent = DIR_OPPOSITE[dir],
			}
			heap_push(scratch, {g + estimate(table, level, next, to), u32(next_index)})
		}
	}
	return 0, false
}

// Cost of the entered cell * step length. 0 if out of bounds, impassable, or cutting a corner.
@(private = "file")
step_cost :: proc(table: ^Pathfind_Table, at: [2]int, dir: Dir) -> f32 {
	next := at + DIR_OFFSET[dir]
	if !grid_contains(next, WORLD_SIZE) do return 0
	if DIR_OFFSET[dir].x != 0 && DIR_OFFSET[dir].y != 0 {
		if table.grid[grid_index({next.x, at.y}, WORLD_SIZE)] == 0 do return 0
		if table.grid[grid_index({at.x, next.y}, WORLD_SIZE)] == 0 do return 0
	}
	return table.grid[grid_index(next, WORLD_SIZE)] * DIR_LENGTH[dir]
}

@(private = "file")
octile :: proc(a, b: [2]int) -> f32 {
	d := [2]f32{f32(abs(a.x - b.x)), f32(abs(a.y - b.y))}
	return max(d.x, d.y) + (math.SQRT_TWO - 1) * min(d.x, d.y)
}

@(private = "file")
grid_index :: proc(pos, size: [2]int) -> int {
	return pos.y * size.x + pos.x
}

@(private = "file")
grid_pos :: proc(index: int, size: [2]int) -> [2]int {
	return {index % size.x, index / size.x}
}

@(private = "file")
grid_contains :: proc(pos, size: [2]int) -> bool {
	return pos.x >= 0 && pos.y >= 0 && pos.x < size.x && pos.y < size.y
}

pathfind_build_begin :: proc(domain: Pathfind_Domain) -> []f32 {
	return TABLE[domain].grid[:]
}

// Hash of the grid and of this file's source. Derived layout changes are caught by the size check instead.
@(private = "file")
pathfind_key :: proc(domain: Pathfind_Domain) -> u64 {
	return hash.crc64_xz(mem.slice_to_bytes(TABLE[domain].grid[:]), CACHE_SOURCE)
}

// Data points into the table; valid until the domain is rebuilt
pathfind_cache_get :: proc(out: ^Cached_File, domain: Pathfind_Domain) {
	table := &TABLE[domain]
	out^ = {table.key, mem.ptr_to_bytes(&table.derived)}
}

// Uses cached if its key matches, otherwise derives from the grid
pathfind_build_end :: proc(domain: Pathfind_Domain, cached: Cached_File) {
	table := &TABLE[domain]
	table.key = pathfind_key(domain)
	if len(cached.data) == size_of(Derived) && cached.fingerprint == table.key {
		copy(mem.ptr_to_bytes(&table.derived), cached.data)
		return
	}
	// Log, since deriving is slow
	why := len(cached.data) == 0 ? "not cached" : "cached for other ground"
	fmt.eprintfln("Pathfinding for %v is %s: deriving it", domain, why)
	started := time.tick_now()
	defer fmt.eprintfln("Pathfinding for %v derived in %v", domain, time.tick_since(started))

	table.derived.min_cost = math.INF_F32
	for cost in table.grid do if cost > 0 do table.derived.min_cost = min(table.derived.min_cost, cost)
	if table.derived.min_cost == math.INF_F32 do table.derived.min_cost = 1

	// Components (4-connected flood fill is enough, since moves can't cut corners)
	table.derived.component = {}
	queue := make([]u32, CELLS_FINE_MAX, context.temp_allocator)
	count: u16 = 0
	for cost, start in table.grid {
		if cost == 0 || table.derived.component[start] != 0 do continue
		assert(count < max(u16), "Too many pathfinding components")
		count += 1
		table.derived.component[start] = count
		queue[0] = u32(start)
		head, tail := 0, 1
		for head < tail {
			cell := grid_pos(int(queue[head]), WORLD_SIZE)
			head += 1
			for dir in ([4]Dir{.N, .W, .E, .S}) {
				next := cell + DIR_OFFSET[dir]
				if !grid_contains(next, WORLD_SIZE) do continue
				next_index := grid_index(next, WORLD_SIZE)
				if table.grid[next_index] == 0 || table.derived.component[next_index] != 0 do continue
				table.derived.component[next_index] = count
				queue[tail] = u32(next_index)
				tail += 1
			}
		}
	}

	// Representatives: cheapest cell, nearest the block centre on ties
	for &representative, block_index in table.derived.coarse.representative {
		corner := grid_pos(block_index, BLOCKS_SIZE) * BLOCKING_FACTOR
		representative = corner
		best_cost: f32 = 0
		best_distance := 0
		for y in 0 ..< BLOCKING_FACTOR do for x in 0 ..< BLOCKING_FACTOR {
			cell := corner + {x, y}
			cost := table.grid[grid_index(cell, WORLD_SIZE)]
			if cost == 0 do continue
			// Doubled to stay integer
			offset := 2 * [2]int{x, y} + 1 - BLOCKING_FACTOR
			distance := offset.x * offset.x + offset.y * offset.y
			if best_cost == 0 || cost < best_cost || (cost == best_cost && distance < best_distance) {
				representative, best_cost, best_distance = cell, cost, distance
			}
		}
	}

	// Coarse moves
	for &moves, block_index in table.derived.coarse.move {
		moves = {}
		block := grid_pos(block_index, BLOCKS_SIZE)
		from := table.derived.coarse.representative[block_index]
		from_index := grid_index(from, WORLD_SIZE)
		if table.grid[from_index] == 0 do continue
		for &move, dir in moves {
			next := block + DIR_OFFSET[dir]
			if !grid_contains(next, BLOCKS_SIZE) do continue
			to := table.derived.coarse.representative[grid_index(next, BLOCKS_SIZE)]
			to_index := grid_index(to, WORLD_SIZE)
			if table.grid[to_index] == 0 || table.derived.component[to_index] != table.derived.component[from_index] do continue
			// Corridor: the blocks around the shared corner
			SCRATCH.corridor_stamp += 1
			for around in ([4][2]int{block, next, {block.x, next.y}, {next.x, block.y}}) do corridor_mark(around)
			if cost, ok := search(table, .Fine, from, to); ok do move = cost
		}
	}

	// Landmarks: farthest-point sampling over the largest component
	sizes := make([]int, int(max(u16)) + 1, context.temp_allocator)
	for component in table.derived.component do sizes[component] += 1
	largest := 1
	for size, component in sizes[1:] do if size > sizes[largest] do largest = component + 1
	in_largest := make([]bool, CELLS_COARSE_MAX, context.temp_allocator)
	first := -1
	for representative, block_index in table.derived.coarse.representative {
		cell_index := grid_index(representative, WORLD_SIZE)
		in_largest[block_index] =
			table.grid[cell_index] != 0 && int(table.derived.component[cell_index]) == largest
		if in_largest[block_index] && first < 0 do first = block_index
	}
	table.derived.landmarks.count = 0
	if first < 0 do return
	nearest := make([]f32, CELLS_COARSE_MAX, context.temp_allocator)
	blocks_dijkstra(table, first, false, nearest)
	for table.derived.landmarks.count < LANDMARKS_MAX {
		farthest := -1
		for block_index in 0 ..< CELLS_COARSE_MAX {
			if !in_largest[block_index] || nearest[block_index] == math.INF_F32 do continue
			if farthest < 0 || nearest[block_index] > nearest[farthest] do farthest = block_index
		}
		if farthest < 0 || nearest[farthest] == 0 do break
		l := table.derived.landmarks.count
		table.derived.landmarks.count += 1
		blocks_dijkstra(table, farthest, false, table.derived.landmarks.from[l][:])
		blocks_dijkstra(table, farthest, true, table.derived.landmarks.to[l][:])
		for &cost, block_index in nearest do cost = min(cost, table.derived.landmarks.from[l][block_index])
	}
}

// Dijkstra over blocks from a block (or to it, with reverse). Infinite = unreachable.
@(private = "file")
blocks_dijkstra :: proc(table: ^Pathfind_Table, start: int, reverse: bool, cost: []f32) {
	scratch := &SCRATCH.search[.Coarse]
	clear(&scratch.heap)
	slice.fill(cost, math.INF_F32)
	cost[start] = 0
	heap_push(scratch, {0, u32(start)})
	for len(scratch.heap) > 0 {
		entry := heap_pop(scratch)
		// Skip stale heap entries
		if entry.priority > cost[entry.index] do continue
		at := grid_pos(int(entry.index), BLOCKS_SIZE)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, BLOCKS_SIZE) do continue
			next_index := grid_index(next, BLOCKS_SIZE)
			move :=
				reverse ? table.derived.coarse.move[next_index][DIR_OPPOSITE[dir]] : table.derived.coarse.move[entry.index][dir]
			if move == 0 do continue
			next_cost := entry.priority + move
			if next_cost >= cost[next_index] do continue
			cost[next_index] = next_cost
			heap_push(scratch, {next_cost, u32(next_index)})
		}
	}
}

// out: cell centres after src up to and including dst. costs: per-cell cost of each. In cells.
// False (both empty) if unreachable or longer than PATH_MAX_LEN.
pathfind_trace :: proc(
	src: [2]f32,
	domain: Pathfind_Domain,
	dst: [2]f32,
	// Enemy zones of control
	zones: []Disc,
	out: ^[dynamic; PATH_MAX_LEN][2]f32,
	costs: ^[dynamic; PATH_MAX_LEN]f32,
) -> (
	ok: bool,
) {
	clear(out)
	clear(costs)
	table := &TABLE[domain]
	from := [2]int{int(math.floor(src.x)), int(math.floor(src.y))}
	to := [2]int{int(math.floor(dst.x)), int(math.floor(dst.y))}
	if !grid_contains(from, WORLD_SIZE) || !grid_contains(to, WORLD_SIZE) do return false
	// Different components (or component 0, impassable) can't connect
	component := table.derived.component[grid_index(from, WORLD_SIZE)]
	if component == 0 || component != table.derived.component[grid_index(to, WORLD_SIZE)] do return false

	// Coarse path, then corridor around it
	from_block := from / BLOCKING_FACTOR
	to_block := to / BLOCKING_FACTOR
	if from_block != to_block do _ = search(table, .Coarse, from_block, to_block) or_return
	SCRATCH.corridor_stamp += 1
	block := to_block
	for {
		for dy in -1 ..= 1 do for dx in -1 ..= 1 do corridor_mark(block + {dx, dy})
		if block == from_block do break
		block += DIR_OFFSET[SCRATCH.search[.Coarse].node[grid_index(block, BLOCKS_SIZE)].parent]
	}

	_ = search(table, .Fine, from, to) or_return
	// Walk back from dst, then reverse
	for cell := to; cell != from; {
		if len(out) == PATH_MAX_LEN {
			clear(out)
			clear(costs)
			return false
		}
		index := grid_index(cell, WORLD_SIZE)
		append(out, [2]f32{f32(cell.x), f32(cell.y)} + 0.5)
		append(costs, table.grid[index])
		cell += DIR_OFFSET[SCRATCH.search[.Fine].node[index].parent]
	}
	slice.reverse(out[:])
	slice.reverse(costs[:])
	return true
}



// Cells reachable within a budget, and the cheapest way to each
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
	// Zone cells can be entered but not left; no_stop cells can be passed but not stopped on
	zone:    [PATHFIND_FLOOD_CELLS]bool,
	no_stop: [PATHFIND_FLOOD_CELLS]bool,
}

// Dijkstra within budget over the square. Never leaves a zone cell (src's included). Empty if src is out of bounds
// or impassable.
pathfind_flood :: proc(
	src: [2]f32,
	domain: Pathfind_Domain,
	budget: f32,
	zones, no_stop: []Disc,
	flood: ^Pathfind_Flood,
) {
	table := &TABLE[domain]
	flood.src, flood.domain, flood.budget = src, domain, budget
	flood.start = {int(math.floor(src.x)), int(math.floor(src.y))}
	flood.corner = flood.start - PATHFIND_FLOOD_SIZE / 2
	slice.fill(flood.cost[:], math.INF_F32)
	stamp(flood, flood.zone[:], zones)
	stamp(flood, flood.no_stop[:], no_stop)
	if !grid_contains(flood.start, WORLD_SIZE) || table.grid[grid_index(flood.start, WORLD_SIZE)] == 0 do return

	scratch := &SCRATCH.search[.Fine]
	clear(&scratch.heap)
	start := grid_index(flood.start - flood.corner, FLOOD_SQUARE)
	flood.cost[start] = 0
	heap_push(scratch, {0, u32(start)})
	for len(scratch.heap) > 0 {
		entry := heap_pop(scratch)
		// Skip stale heap entries
		if entry.priority > flood.cost[entry.index] do continue
		if flood.zone[entry.index] do continue
		at := grid_pos(int(entry.index), FLOOD_SQUARE)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, FLOOD_SQUARE) do continue
			move := step_cost(table, flood.corner + at, dir)
			if move == 0 do continue
			cost := entry.priority + move
			next_index := grid_index(next, FLOOD_SQUARE)
			if cost > budget || cost >= flood.cost[next_index] do continue
			flood.cost[next_index] = cost
			flood.back[next_index] = DIR_OPPOSITE[dir]
			heap_push(scratch, {cost, u32(next_index)})
		}
	}
}

@(private = "file")
stamp :: proc(flood: ^Pathfind_Flood, mask: []bool, discs: []Disc) {
	slice.fill(mask, false)
	for disc in discs {
		lo, hi := linalg.floor(disc.center - disc.radius), linalg.floor(disc.center + disc.radius)
		first := linalg.max([2]int{int(lo.x), int(lo.y)} - flood.corner, 0)
		last := linalg.min([2]int{int(hi.x), int(hi.y)} - flood.corner, PATHFIND_FLOOD_SIZE - 1)
		for y in first.y ..= last.y do for x in first.x ..= last.x {
			middle := [2]f32{f32(flood.corner.x + x), f32(flood.corner.y + y)} + 0.5
			if linalg.distance(middle, disc.center) < disc.radius do mask[grid_index({x, y}, FLOOD_SQUARE)] = true
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
	to := [2]int{int(math.floor(dst.x)), int(math.floor(dst.y))}
	nearest := math.INF_F32
	if !flood_reaches(flood, to) {
		for y in 0 ..< snap {
			for x in 0 ..< snap {
				at := to - snap / 2 + {x, y}
				if !flood_reaches(flood, at) || flood.no_stop[grid_index(at - flood.corner, FLOOD_SQUARE)] do continue
				distance := linalg.distance([2]f32{f32(at.x), f32(at.y)} + 0.5, dst)
				if distance < nearest do cell, ok, nearest = at, true, distance
			}
		}
		return
	}
	for cost, i in flood.cost {
		if cost == math.INF_F32 || flood.no_stop[i] do continue
		at := flood.corner + grid_pos(i, FLOOD_SQUARE)
		distance := linalg.distance([2]f32{f32(at.x), f32(at.y)} + 0.5, dst)
		if distance < nearest do cell, ok, nearest = at, true, distance
	}
	return
}

// Cheapest stoppable cell inside the disc
pathfind_flood_stop_within :: proc(
	flood: ^Pathfind_Flood,
	center: [2]f32,
	radius: f32,
) -> (
	cell: [2]int,
	ok: bool,
) {
	cheapest := math.INF_F32
	for cost, i in flood.cost {
		if cost >= cheapest || flood.no_stop[i] do continue
		at := flood.corner + grid_pos(i, FLOOD_SQUARE)
		if linalg.distance([2]f32{f32(at.x), f32(at.y)} + 0.5, center) >= radius do continue
		cell, ok, cheapest = at, true, cost
	}
	return
}

// Output as pathfind_trace. False (both empty) if dst isn't reached.
pathfind_flood_trace :: proc(
	flood: ^Pathfind_Flood,
	dst: [2]f32,
	out: ^[dynamic; PATH_MAX_LEN][2]f32,
	costs: ^[dynamic; PATH_MAX_LEN]f32,
) -> (
	ok: bool,
) {
	clear(out)
	clear(costs)
	to := [2]int{int(math.floor(dst.x)), int(math.floor(dst.y))}
	if !flood_reaches(flood, to) do return false
	table := &TABLE[flood.domain]
	// Walk back from dst, then reverse
	for cell := to; cell != flood.start; {
		if len(out) == PATH_MAX_LEN {
			clear(out)
			clear(costs)
			return false
		}
		append(out, [2]f32{f32(cell.x), f32(cell.y)} + 0.5)
		append(costs, table.grid[grid_index(cell, WORLD_SIZE)])
		cell += DIR_OFFSET[flood.back[grid_index(cell - flood.corner, FLOOD_SQUARE)]]
	}
	slice.reverse(out[:])
	slice.reverse(costs[:])
	return true
}
