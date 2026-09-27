#+private
package game

import "core:math"
import "core:slice"
import "core:slice/heap"

PATH_MAX_LEN :: 1_000

Disc :: struct {
	center: [2]f32,
	radius: f32,
}

// How many cells get grouped together in the search
@(private = "file")
BLOCKING_FACTOR :: 4

@(private = "file")
CELLS_FINE_MAX :: WORLD_WIDTH * WORLD_HEIGHT
@(private = "file")
CELLS_COARSE_MAX :: CELLS_FINE_MAX / (BLOCKING_FACTOR * BLOCKING_FACTOR)

#assert(WORLD_WIDTH % BLOCKING_FACTOR == 0 && WORLD_HEIGHT % BLOCKING_FACTOR == 0)

// How many blocks a domain keeps the costs to and from of every other block, to bound the costs between blocks
@(private = "file")
LANDMARKS_MAX :: 16

// How many blocks the world is across and down
@(private = "file")
BLOCKS_SIZE :: [2]int{WORLD_WIDTH / BLOCKING_FACTOR, WORLD_HEIGHT / BLOCKING_FACTOR}

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

// The step to the neighbour in each direction, in cells; y grows down the map
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

// How far the step in each direction goes, in cells
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

// The direction back the other way
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

// A node queued with its priority at the time. A node is queued again whenever its priority improves.
@(private = "file")
Heap_Entry :: struct {
	priority: f32,
	index:    u32,
}

// Orders the heap for core:slice/heap, which keeps the greatest first: the lowest priority comes first
@(private = "file")
heap_entry_less :: proc(a, b: Heap_Entry) -> bool {
	return a.priority > b.priority
}

@(private = "file")
Pathfind_Table :: struct {
	// Input cost grid
	grid:      [CELLS_FINE_MAX]f32,
	// Per cell, which piece of ground connected by moves it is in, counting from 1; 0 for a cell of cost 0
	component: [CELLS_FINE_MAX]u16,
	// The lowest cost of any enterable cell
	min_cost:  f32,
	// Coarse-grained grid
	coarse:    struct {
		// Representative fine cell for coarse cell: its cheapest enterable cell, or its first cell if it has none
		representative: [CELLS_COARSE_MAX][2]int,
		// Coarse adjacency move cost: of the cheapest way between the representatives within the two blocks, or the four
		// blocks around their shared corner; 0 if there is none
		move:           [CELLS_COARSE_MAX][Dir]f32,
	},
	// Blocks spread over the largest component, far from each other
	landmarks: struct {
		// Per landmark and block, the cost of the cheapest way over the blocks from the landmark to the block, and from
		// the block to the landmark; infinite if there is none
		from, to: [LANDMARKS_MAX][CELLS_COARSE_MAX]f32,
		count:    int,
	},
}

Pathfind_Domain :: enum {
	Land,
	Sea,
}

@(private = "file")
TABLE: [Pathfind_Domain]Pathfind_Table

// How much the heuristic overestimates by at most, as a factor
@(private = "file")
HEURISTIC_TIE_BREAK :: 1 + 1.0 / 1024

// The grid a search runs over: the cells, or the blocks of cells
@(private = "file")
Level :: enum u8 {
	Fine,
	Coarse,
}

// The state of the latest search over one level
@(private = "file")
Search_Scratch :: struct {
	// Node-states
	node:  [CELLS_FINE_MAX]Node,
	// Heap, with room for each block queued once per direction
	heap:  [dynamic; len(Dir) * CELLS_COARSE_MAX]Heap_Entry,
	// Which search the node-states are from: a node whose stamp is not the latest has not been reached by it
	stamp: u32,
}

@(private = "file")
SCRATCH: struct {
	search:         [Level]Search_Scratch,
	// Per block, the corridor stamp of the latest trace whose corridor it is in
	corridor:       [CELLS_COARSE_MAX]u32,
	corridor_stamp: u32,
}

// Queues an entry on a search's heap
@(private = "file")
heap_push :: proc(scratch: ^Search_Scratch, entry: Heap_Entry) {
	assert(len(scratch.heap) < cap(scratch.heap), "Pathfinding heap full")
	append(&scratch.heap, entry)
	heap.push(scratch.heap[:], heap_entry_less)
}

// Takes the entry of lowest priority off a search's heap, which must not be empty
@(private = "file")
heap_pop :: proc(scratch: ^Search_Scratch) -> Heap_Entry {
	heap.pop(scratch.heap[:], heap_entry_less)
	return pop(&scratch.heap)
}

// Puts a block in the latest corridor, if it is in the world
@(private = "file")
corridor_mark :: proc(block: [2]int) {
	if grid_contains(block, BLOCKS_SIZE) do SCRATCH.corridor[grid_index(block, BLOCKS_SIZE)] = SCRATCH.corridor_stamp
}

// Searches a level of a table for the cheapest way from one node to another, given as cells or blocks. Each node
// reached keeps in SCRATCH the cost of the cheapest way to it found, and the direction back to the node before it on
// that way. Over the cells, it moves only within the latest corridor, and never diagonally past an unenterable cell.
@(private = "file")
search :: proc(table: ^Pathfind_Table, $level: Level, from, to: [2]int) -> (cost: f32, ok: bool) {
	scratch := &SCRATCH.search[level]
	scratch.stamp += 1
	clear(&scratch.heap)
	size := level == .Fine ? WORLD_SIZE : BLOCKS_SIZE

	// No more than the cheapest way from a node to the goal costs, but for the tie-break, which puts the nearer the goal
	// first of nodes as promising, at the price of ways up to that much dearer than the cheapest. It is the octile
	// distance at the lowest cost; over the blocks, from representative to representative, and at least how much
	// farther the goal is than the node from each landmark, and the node than the goal to each landmark.
	estimate :: proc(table: ^Pathfind_Table, $level: Level, node, goal: [2]int) -> f32 {
		when level == .Fine {
			h := octile(node, goal) * table.min_cost
		} else {
			a := grid_index(node, BLOCKS_SIZE)
			b := grid_index(goal, BLOCKS_SIZE)
			h := octile(table.coarse.representative[a], table.coarse.representative[b]) * table.min_cost
			for l in 0 ..< table.landmarks.count {
				from := &table.landmarks.from[l]
				to := &table.landmarks.to[l]
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
		// A node is queued again whenever its cost improves, so its older entries come up after it is expanded
		if node.closed do continue
		node.closed = true
		if index == goal do return node.g, true

		at := grid_pos(int(index), size)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, size) do continue
			next_index := grid_index(next, size)
			when level == .Fine {
				move := table.grid[next_index] * DIR_LENGTH[dir]
				if move == 0 do continue
				if SCRATCH.corridor[grid_index(next / BLOCKING_FACTOR, BLOCKS_SIZE)] != SCRATCH.corridor_stamp do continue
				if DIR_OFFSET[dir].x != 0 && DIR_OFFSET[dir].y != 0 {
					if table.grid[grid_index({next.x, at.y}, size)] == 0 || table.grid[grid_index({at.x, next.y}, size)] == 0 do continue
				}
			} else {
				move := table.coarse.move[index][dir]
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

// The length of the shortest way between two cells moving in the eight directions, in cells
@(private = "file")
octile :: proc(a, b: [2]int) -> f32 {
	d := [2]f32{f32(abs(a.x - b.x)), f32(abs(a.y - b.y))}
	return max(d.x, d.y) + (math.SQRT_TWO - 1) * min(d.x, d.y)
}

// Where in a grid of a size, of cells or blocks, the node at a position is kept
@(private = "file")
grid_index :: proc(pos, size: [2]int) -> int {
	return pos.y * size.x + pos.x
}

// The position of the node kept at an index of a grid of a size
@(private = "file")
grid_pos :: proc(index: int, size: [2]int) -> [2]int {
	return {index % size.x, index / size.x}
}

// Whether a position is inside a grid of a size
@(private = "file")
grid_contains :: proc(pos, size: [2]int) -> bool {
	return pos.x >= 0 && pos.y >= 0 && pos.x < size.x && pos.y < size.y
}

pathfind_build_begin :: proc(domain: Pathfind_Domain) -> []f32 {
	return TABLE[domain].grid[:]
}

// Derives what the searches of a domain use from the grid written since pathfind_build_begin
pathfind_build_end :: proc(domain: Pathfind_Domain) {
	table := &TABLE[domain]

	table.min_cost = math.INF_F32
	for cost in table.grid do if cost > 0 do table.min_cost = min(table.min_cost, cost)
	if table.min_cost == math.INF_F32 do table.min_cost = 1

	// Components, by flooding each in turn. Without cutting corners, cells connected by moves in eight directions are
	// connected by moves in four.
	table.component = {}
	queue := make([]u32, CELLS_FINE_MAX, context.temp_allocator)
	count: u16 = 0
	for cost, start in table.grid {
		if cost == 0 || table.component[start] != 0 do continue
		assert(count < max(u16), "Too many pathfinding components")
		count += 1
		table.component[start] = count
		queue[0] = u32(start)
		head, tail := 0, 1
		for head < tail {
			cell := grid_pos(int(queue[head]), WORLD_SIZE)
			head += 1
			for dir in ([4]Dir{.N, .W, .E, .S}) {
				next := cell + DIR_OFFSET[dir]
				if !grid_contains(next, WORLD_SIZE) do continue
				next_index := grid_index(next, WORLD_SIZE)
				if table.grid[next_index] == 0 || table.component[next_index] != 0 do continue
				table.component[next_index] = count
				queue[tail] = u32(next_index)
				tail += 1
			}
		}
	}

	// Representatives: the cheapest cell, and of those the nearest the middle
	for &representative, block_index in table.coarse.representative {
		corner := grid_pos(block_index, BLOCKS_SIZE) * BLOCKING_FACTOR
		representative = corner
		best_cost: f32 = 0
		best_distance := 0
		for y in 0 ..< BLOCKING_FACTOR do for x in 0 ..< BLOCKING_FACTOR {
			cell := corner + {x, y}
			cost := table.grid[grid_index(cell, WORLD_SIZE)]
			if cost == 0 do continue
			// Twice the offset from the middle, to keep it whole
			offset := 2 * [2]int{x, y} + 1 - BLOCKING_FACTOR
			distance := offset.x * offset.x + offset.y * offset.y
			if best_cost == 0 || cost < best_cost || (cost == best_cost && distance < best_distance) {
				representative, best_cost, best_distance = cell, cost, distance
			}
		}
	}

	// Moves, each searched over the cells of its blocks
	for &moves, block_index in table.coarse.move {
		moves = {}
		block := grid_pos(block_index, BLOCKS_SIZE)
		from := table.coarse.representative[block_index]
		from_index := grid_index(from, WORLD_SIZE)
		if table.grid[from_index] == 0 do continue
		for &move, dir in moves {
			next := block + DIR_OFFSET[dir]
			if !grid_contains(next, BLOCKS_SIZE) do continue
			to := table.coarse.representative[grid_index(next, BLOCKS_SIZE)]
			to_index := grid_index(to, WORLD_SIZE)
			if table.grid[to_index] == 0 || table.component[to_index] != table.component[from_index] do continue
			// The blocks around the corner the two blocks share, which for a straight move are just the two
			SCRATCH.corridor_stamp += 1
			for around in ([4][2]int{block, next, {block.x, next.y}, {next.x, block.y}}) do corridor_mark(around)
			if cost, ok := search(table, .Fine, from, to); ok do move = cost
		}
	}

	// Landmarks: each the block of the largest component farthest from those before it, the first farthest from its first
	// block
	sizes := make([]int, int(max(u16)) + 1, context.temp_allocator)
	for component in table.component do sizes[component] += 1
	largest := 1
	for size, component in sizes[1:] do if size > sizes[largest] do largest = component + 1
	in_largest := make([]bool, CELLS_COARSE_MAX, context.temp_allocator)
	first := -1
	for representative, block_index in table.coarse.representative {
		cell_index := grid_index(representative, WORLD_SIZE)
		in_largest[block_index] =
			table.grid[cell_index] != 0 && int(table.component[cell_index]) == largest
		if in_largest[block_index] && first < 0 do first = block_index
	}
	table.landmarks.count = 0
	if first < 0 do return
	// Per block, the cost from the nearest landmark so far
	nearest := make([]f32, CELLS_COARSE_MAX, context.temp_allocator)
	blocks_dijkstra(table, first, false, nearest)
	for table.landmarks.count < LANDMARKS_MAX {
		farthest := -1
		for block_index in 0 ..< CELLS_COARSE_MAX {
			if !in_largest[block_index] || nearest[block_index] == math.INF_F32 do continue
			if farthest < 0 || nearest[block_index] > nearest[farthest] do farthest = block_index
		}
		if farthest < 0 || nearest[farthest] == 0 do break
		l := table.landmarks.count
		table.landmarks.count += 1
		blocks_dijkstra(table, farthest, false, table.landmarks.from[l][:])
		blocks_dijkstra(table, farthest, true, table.landmarks.to[l][:])
		for &cost, block_index in nearest do cost = min(cost, table.landmarks.from[l][block_index])
	}
}

// Fills cost with the cost of the cheapest way over the blocks from a block to every block, or with reverse, from
// every block to it; infinite where there is none
@(private = "file")
blocks_dijkstra :: proc(table: ^Pathfind_Table, start: int, reverse: bool, cost: []f32) {
	scratch := &SCRATCH.search[.Coarse]
	clear(&scratch.heap)
	slice.fill(cost, math.INF_F32)
	cost[start] = 0
	heap_push(scratch, {0, u32(start)})
	for len(scratch.heap) > 0 {
		entry := heap_pop(scratch)
		// A block is queued again whenever its cost improves, so its older entries come up after it is settled
		if entry.priority > cost[entry.index] do continue
		at := grid_pos(int(entry.index), BLOCKS_SIZE)
		for dir in Dir {
			next := at + DIR_OFFSET[dir]
			if !grid_contains(next, BLOCKS_SIZE) do continue
			next_index := grid_index(next, BLOCKS_SIZE)
			move :=
				reverse ? table.coarse.move[next_index][DIR_OPPOSITE[dir]] : table.coarse.move[entry.index][dir]
			if move == 0 do continue
			next_cost := entry.priority + move
			if next_cost >= cost[next_index] do continue
			cost[next_index] = next_cost
			heap_push(scratch, {next_cost, u32(next_index)})
		}
	}
}

// Finds the cheapest way from src to dst, both in cells: out gets the centres of the cells along it, after src's up to
// and including dst's. False, with out empty, if there is no way or it is longer than out holds.
pathfind_trace :: proc(
	src: [2]f32, // Which pathfind domain
	domain: Pathfind_Domain, // Where does the path start from
	// Where does it end
	dst: [2]f32,
	// Relevant zones. For now assumed to always mean opposition zone of conrol
	zones: []Disc,
	// Output
	out: ^[dynamic; PATH_MAX_LEN][2]f32,
) -> (
	ok: bool,
) {
	clear(out)
	table := &TABLE[domain]
	from := [2]int{int(math.floor(src.x)), int(math.floor(src.y))}
	to := [2]int{int(math.floor(dst.x)), int(math.floor(dst.y))}
	if !grid_contains(from, WORLD_SIZE) || !grid_contains(to, WORLD_SIZE) do return false
	// Different components have no way between them, and component 0 is the cells of cost 0
	component := table.component[grid_index(from, WORLD_SIZE)]
	if component == 0 || component != table.component[grid_index(to, WORLD_SIZE)] do return false

	// The corridor: the blocks of the way over the blocks, and those around them
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
	// The way back from dst, then turned around
	for cell := to; cell != from; {
		if len(out) == PATH_MAX_LEN {
			clear(out)
			return false
		}
		append(out, [2]f32{f32(cell.x), f32(cell.y)} + 0.5)
		cell += DIR_OFFSET[SCRATCH.search[.Fine].node[grid_index(cell, WORLD_SIZE)].parent]
	}
	slice.reverse(out[:])
	return true
}

