#+private
package sim

import "core:fmt"
import "core:hash"
import "core:math/linalg"
import "core:mem"

PIECE_MAX :: 1024
FACTION_MAX :: 256

WORLD: struct {
	atlas:         Atlas,
	// Every slot a piece can be in, and each slot's name, set by piece_spawn
	pieces:        [PIECE_MAX]Piece,
	piece_names:   [PIECE_MAX]Name,
	// The slots with no piece in them, the next to be used last
	pieces_free:   [dynamic; PIECE_MAX]u16,
	// Every slot a faction can be in, each slot's name, set by faction_spawn, and the slots with no faction in them,
	// the next to be used last
	factions:      [FACTION_MAX]Faction,
	faction_names: [FACTION_MAX]Name,
	factions_free: [dynamic; FACTION_MAX]u16,
	// The faction whose turn it is, which the player plays, or nil for none
	player:        Faction_Id,
	movement:      Movement,
	// The turn being played, counting from 1: each faction plays once in a turn, in the order of their slots
	turn:          int,
}

// The piece walking, and where the focus can walk
Movement :: struct {
	// The piece walking, nil when none
	subject:       Piece_Id,
	// Its path, as cell middles, the cost of entering each, and the next point it walks to
	path:          [dynamic; PATH_MAX_LEN][2]f32,
	cost:          [dynamic; PATH_MAX_LEN]f32,
	next:          int,
	// The piece it walks to meet, or nil
	target:        Piece_Id,
	// Where the focus can walk: nil subject and 0 key when none. The key hashes the flood's inputs, zones and bodies
	// among them, rebuilt every tick.
	flood:         Pathfind_Flood,
	zones, bodies: [dynamic; PIECE_MAX]Disc,
	flood_subject: Piece_Id,
	flood_key:     u64,
}

// Floods where the focus can walk. Runs once per tick, first in present; the next step's orders use it.
movement_flood :: proc(mov: ^Movement, focus: Piece_Id) {
	zones, bodies := &mov.zones, &mov.bodies
	clear(zones)
	clear(bodies)
	subject := piece_get(focus)
	if subject == nil || subject.movement_domain == nil {
		mov.flood_subject, mov.flood_key = {}, 0
		return
	}
	domain := subject.movement_domain.(Pathfind_Domain)

	// No stopping on bodies; enemy contacts are zones, stopping it once entered. Only discs near the flood count.
	for other, index in WORLD.pieces {
		if !piece_alive(other) || piece_id(index) == focus do continue
		near := PATHFIND_FLOOD_SIZE / 2 + max(other.contact.radius, subject.body + other.body) + 1
		if abs(other.pos.x - subject.pos.x) > near || abs(other.pos.y - subject.pos.y) > near do continue
		append(bodies, Disc{other.pos, subject.body + other.body})
		friend := faction_get(other.owner) != nil && other.owner == subject.owner
		if !friend && other.contact.radius > 0 && domain in other.contact.domains {
			append(zones, Disc{other.pos, other.contact.radius})
		}
	}

	focus, pos, budget := focus, subject.pos, subject.movement_budget
	counts := [2]int{len(zones), len(bodies)}
	key := hash.fnv64a(mem.ptr_to_bytes(&focus))
	key = hash.fnv64a(mem.ptr_to_bytes(&pos), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&budget), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&domain), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&counts), key)
	key = hash.fnv64a(mem.slice_to_bytes(zones[:]), key)
	key = hash.fnv64a(mem.slice_to_bytes(bodies[:]), key)
	if key == mov.flood_key do return
	pathfind_flood(pos, domain, budget, zones[:], bodies[:], &mov.flood)
	mov.flood_subject, mov.flood_key = focus, key
}

// Walks the subject walk_distance cells along its path, paying from its budget. At the end it meets its target, which
// does nothing yet.
movement_advance :: proc(mov: ^Movement, walk_distance: f32) {
	if mov.subject == {} do return
	subject := piece_get(mov.subject)
	is_over: bool
	if subject == nil {
		is_over = true
	} else {
		step := walk_distance
		for step > 0 && mov.next < len(mov.path) {
			target, cost := mov.path[mov.next], mov.cost[mov.next]
			distance := linalg.distance(subject.pos, target)
			if step < distance {
				subject.pos += linalg.normalize(target - subject.pos) * step
				subject.movement_budget = max(0, subject.movement_budget - step * cost)
				break
			}
			step -= distance
			subject.movement_budget = max(0, subject.movement_budget - distance * cost)
			subject.pos = target
			mov.next += 1
		}

		is_over = mov.next >= len(mov.path)
	}

	if is_over {
		mov.subject, mov.target, mov.next = {}, {}, 0
	}
}

Atlas :: struct {
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	revision: u32,
	terrain:  [CELLS_MAX]Terrain,
}

Terrain :: struct {
	surface:       Surface,
	elevation:     u8,
	trees:         u8,
	moisture:      u8,
	// For each way kind, which way is this cell assigned to. (Way_Id = 0 is nil)
	way:           [Way_Kind]Way_Id,
	// Worked out from the land around it at load
	type:          Terrain_Type,
	type_strength: u8,
}

// Land movement cost per cell walked, by terrain type, 0 for impassable; a road costs ROAD_COST whatever its type
TERRAIN_COSTS := [Terrain_Type]f32 {
	.Open      = 1,
	.Forest    = 2,
	.Desert    = 1.5,
	.Steppe    = 1,
	.Fertile   = 1,
	.Marsh     = 2.5,
	.Highland  = 3,
	.Mountains = 0,
	.Fields    = 1,
}
ROAD_COST :: 0.4

// Over elevation: mountain country, and from where it is too high to cross
HIGHLAND_ELEVATION :: Ramp{0.55, 1.0}
MOUNTAINS_ELEVATION :: 0.85

// How far from a road, in cells either way, mountains open into a pass, and the fewest cells a patch of mountains
// holds: smaller patches are highland.
PASS_REACH :: 1
MOUNTAINS_PATCH_MIN :: 12

// How far around a cell, in cells either way, the land it is compared with to find basins reaches
BASIN_REACH :: 24

// What the terrain types need beyond the cells, in the temp allocator: cells to the nearest river and to the sea, and
// how far each land cell lies below the land around it.
Land :: struct {
	to_river, to_sea: []f32,
	// The mean elevation of the land within BASIN_REACH cells, less the cell's own: above 0 in basins and valleys.
	// Elevation has no fixed sea level, so this, not elevation, tells lowland.
	basin:            []f32,
}

measure_land :: proc(terrain: []Terrain) -> (land: Land) {
	is_river := make([]bool, CELLS_MAX, context.temp_allocator)
	is_sea := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		is_river[i] = cell.way[.River] != 0
		is_sea[i] = cell.surface == .Sea
	}
	land.to_river = make([]f32, CELLS_MAX, context.temp_allocator)
	land.to_sea = make([]f32, CELLS_MAX, context.temp_allocator)
	distance_from(land.to_river, is_river, WORLD_SIZE)
	distance_from(land.to_sea, is_sea, WORLD_SIZE)

	elevation := make([]f32, CELLS_MAX, context.temp_allocator)
	is_land := make([]f32, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		if cell.surface in WATER do continue
		elevation[i] = normalized(cell.elevation)
		is_land[i] = 1
	}
	around := make([]f32, CELLS_MAX, context.temp_allocator)
	count := make([]f32, CELLS_MAX, context.temp_allocator)
	box_sum(around, elevation, WORLD_SIZE, BASIN_REACH)
	box_sum(count, is_land, WORLD_SIZE, BASIN_REACH)
	land.basin = make([]f32, CELLS_MAX, context.temp_allocator)
	for i in 0 ..< CELLS_MAX {
		if is_land[i] > 0 do land.basin[i] = around[i] / count[i] - elevation[i]
	}
	return
}

// Cell i's terrain type: whichever suits it best, how well being its strength, unless none suits it by at least a
// sixth; mountains above MOUNTAINS_ELEVATION, fully. Desert, steppe and fields follow the moisture, forest the trees. Land along a river is fertile: close along it
// in dry country, and farther out where a wet river valley or basin lies below the land around it. Low, level ground is
// marsh where it is very wet or where a river meets the sea; fertile land and marsh win over the rest. Highland follows
// the mountains, and wins over forest, desert and steppe where they are at their fullest.
terrain_type_of :: proc(
	terrain: []Terrain,
	land: ^Land,
	i: int,
) -> (
	best: Terrain_Type,
	strength: u8,
) {
	if terrain[i].surface in WATER do return
	cell := terrain[i]
	elevation := normalized(cell.elevation)
	if elevation >= MOUNTAINS_ELEVATION do return .Mountains, max(u8)
	trees := normalized(cell.trees)
	moisture := normalized(cell.moisture)
	low := ramp(0.22, 0.12, elevation)
	delta := ramp(6, 2, land.to_river[i]) * ramp(16, 6, land.to_sea[i])
	dry_river := ramp(0.62, 0.52, moisture) * ramp(5, 1.5, land.to_river[i])
	valley :=
		ramp(0.55, 0.65, moisture) *
		ramp(12, 4, land.to_river[i]) *
		ramp(0.02, 0.07, land.basin[i])
	suits := [Terrain_Type]f32 {
		.Open      = 1.0 / 6,
		.Forest    = ramp(0.05, 0.75, trees),
		.Desert    = ramp(0.47, 0.35, moisture),
		.Steppe    = ramp(0.40, 0.47, moisture) * ramp(0.58, 0.48, moisture),
		.Fertile   = 1.3 * max(dry_river, valley),
		.Marsh     = 1.5 * low * max(delta, ramp(0.80, 0.88, moisture)),
		.Highland  = highland_suit(elevation),
		.Mountains = 0,
		.Fields    = 0.6 * ramp(0.52, 0.62, moisture) * ramp(0.3, 0.1, trees),
	}
	most: f32
	for s, type in suits {
		if s > most do best, strength, most = type, u8(min(s, 1) * f32(max(u8)) + 0.5), s
	}
	if best == .Open do strength = 0
	return
}

// How well highland suits a cell of an elevation, normalized
highland_suit :: proc(elevation: f32) -> f32 {
	return 1.2 * ramp(HIGHLAND_ELEVATION, elevation)
}

// Makes a cell highland, as strongly as its elevation suits it
terrain_to_highland :: proc(cell: ^Terrain) {
	cell.type = .Highland
	cell.type_strength = u8(min(highland_suit(normalized(cell.elevation)), 1) * f32(max(u8)) + 0.5)
}

// Mountains within PASS_REACH cells of a road are highland: a road through the mountains runs along a pass, which can
// be crossed off the road too.
terrain_open_passes :: proc(terrain: []Terrain) {
	for y in 0 ..< WORLD_HEIGHT {
		for x in 0 ..< WORLD_WIDTH {
			if terrain[y * WORLD_WIDTH + x].way[.Road] == 0 do continue
			for dy in -PASS_REACH ..= PASS_REACH {
				for dx in -PASS_REACH ..= PASS_REACH {
					at := [2]int{x + dx, y + dy}
					if at.x < 0 || at.y < 0 || at.x >= WORLD_WIDTH || at.y >= WORLD_HEIGHT do continue
					cell := &terrain[at.y * WORLD_WIDTH + at.x]
					if cell.type == .Mountains do terrain_to_highland(cell)
				}
			}
		}
	}
}

// Patches of mountains too small to stand as a range are highland: cells that cannot be crossed, touching at a side
// or a corner, fewer than MOUNTAINS_PATCH_MIN. A road's cells can be crossed, so they are in no patch.
terrain_drop_specks :: proc(terrain: []Terrain) {
	impassable :: proc(cell: Terrain) -> bool {
		return cell.type == .Mountains && cell.way[.Road] == 0
	}
	seen := make([]bool, CELLS_MAX, context.temp_allocator)
	// The cells of the patch being found, which are also the queue of cells to look around
	patch := make([dynamic]int, 0, 64, context.temp_allocator)
	for start in 0 ..< CELLS_MAX {
		if seen[start] || !impassable(terrain[start]) do continue
		clear(&patch)
		append(&patch, start)
		seen[start] = true
		for next := 0; next < len(patch); next += 1 {
			x := patch[next] % WORLD_WIDTH
			y := patch[next] / WORLD_WIDTH
			for dy in -1 ..= 1 {
				for dx in -1 ..= 1 {
					at := [2]int{x + dx, y + dy}
					if at.x < 0 || at.y < 0 || at.x >= WORLD_WIDTH || at.y >= WORLD_HEIGHT do continue
					i := at.y * WORLD_WIDTH + at.x
					if seen[i] || !impassable(terrain[i]) do continue
					seen[i] = true
					append(&patch, i)
				}
			}
		}
		if len(patch) >= MOUNTAINS_PATCH_MIN do continue
		for i in patch do terrain_to_highland(&terrain[i])
	}
}

// Which way of its kind runs through a cell. Id 0 is none.
Way_Id :: distinct u16

world_init :: proc() {
	for index := PIECE_MAX - 1; index >= 0; index -= 1 do append(&WORLD.pieces_free, u16(index))
	for index := FACTION_MAX - 1; index >= 0; index -= 1 do append(&WORLD.factions_free, u16(index))
}

world_load :: proc(scenario: Scenario) -> bool {
	terrain := &WORLD.atlas.terrain
	ok :=
		len(scenario.surface) == CELLS_MAX &&
		len(scenario.elevation) == CELLS_MAX &&
		len(scenario.trees) == CELLS_MAX &&
		len(scenario.moisture) == CELLS_MAX
	for layer in scenario.ways do ok &&= len(layer) == CELLS_MAX
	if ok {
		for &cell, i in terrain {
			cell = {
				surface   = scenario.surface[i],
				elevation = scenario.elevation[i],
				trees     = scenario.trees[i],
				moisture  = scenario.moisture[i],
			}
			for layer, kind in scenario.ways do cell.way[kind] = Way_Id(layer[i])
		}
	} else {
		for &cell in terrain do cell = {
			surface = .Sea,
		}
	}
	// Water cells carry nothing else.
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	// Roads step only across cell sides: where one steps diagonally, the lower of the corners beside the step joins it
	for y in 0 ..< WORLD_HEIGHT - 1 {
		for x in 0 ..< WORLD_WIDTH {
			at := &terrain[y * WORLD_WIDTH + x]
			if at.way[.Road] == 0 do continue
			for dx in ([2]int{-1, 1}) {
				if x + dx < 0 || x + dx >= WORLD_WIDTH do continue
				if terrain[(y + 1) * WORLD_WIDTH + x + dx].way[.Road] == 0 do continue
				a, b := &terrain[y * WORLD_WIDTH + x + dx], &terrain[(y + 1) * WORLD_WIDTH + x]
				if a.way[.Road] != 0 || b.way[.Road] != 0 do continue
				corner := a.elevation <= b.elevation ? a : b
				if corner.surface in WATER do corner = corner == a ? b : a
				if corner.surface not_in WATER do corner.way[.Road] = at.way[.Road]
			}
		}
	}
	// Each land cell's type
	{
		land := measure_land(terrain[:])
		for &cell, i in terrain do cell.type, cell.type_strength = terrain_type_of(terrain[:], &land, i)
		terrain_open_passes(terrain[:])
		terrain_drop_specks(terrain[:])
	}
	// Land, by terrain type, roads whatever their type
	{
		grid := pathfind_build_begin(.Land)
		for cell, i in WORLD.atlas.terrain {
			grid[i] =
				cell.surface != .Land ? 0 : cell.way[.Road] != 0 ? ROAD_COST : TERRAIN_COSTS[cell.type]
		}
		pathfind_build_end(.Land, scenario.cached_files[.Pathfind_Land])
	}
	// Sea
	{
		grid := pathfind_build_begin(.Sea)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.surface == .Land ? 0 : 1
		}
		pathfind_build_end(.Sea, scenario.cached_files[.Pathfind_Sea])
	}
	WORLD.atlas.revision += 1
	world_load_test_pieces()
	turns_begin()
	return ok
}

world_step :: proc(commands: []Command, walk_distance: f32) {
	mov := &WORLD.movement
	for command in commands {
		// A walk: where it stops, and whom it meets there. Only the focus walks, from the flood the last present made.
		walker, target: Piece_Id
		stop: [2]int
		ok: bool
		switch c in command {
		case Move_To_Point:
			walker = c.piece
			if walker == mov.flood_subject do stop, ok = pathfind_flood_stop(&mov.flood, c.destination, c.snap)
		case Move_To_Piece:
			walker, target = c.piece, c.target
			other := piece_get(target)
			if walker == mov.flood_subject &&
			   other != nil &&
			   mov.flood.domain in other.contact.domains {
				stop, ok = pathfind_flood_stop_within(&mov.flood, other.pos, other.contact.radius)
			}
		case End_Turn:
			if turn_can_end() do turn_end()
			continue
		}
		path: [dynamic; PATH_MAX_LEN][2]f32
		cost: [dynamic; PATH_MAX_LEN]f32
		if !ok ||
		   !pathfind_flood_trace(
				   &mov.flood,
				   [2]f32{f32(stop.x), f32(stop.y)} + 0.5,
				   &path,
				   &cost,
			   ) {
			fmt.eprintfln("No way for %v to %v", walker, command)
			continue
		}
		mov.subject, mov.target = walker, target
		mov.path = path
		mov.cost = cost
		mov.next = 0
	}
	movement_advance(mov, walk_distance)
}

// Starts turn 1, played first by the faction in the first slot with one, every piece's movement budget full
@(private = "file")
turns_begin :: proc() {
	WORLD.turn = 1
	WORLD.player = {}
	for &piece in WORLD.pieces {
		if piece_alive(piece) && piece.movement_domain != nil do piece.movement_budget = piece.movement_per_turn
	}
	for faction, index in WORLD.factions {
		if faction_alive(faction) {
			WORLD.player = faction_id(index)
			return
		}
	}
}

// Ends the player's faction's part of the turn, refilling its pieces' movement budgets: the faction in the next slot
// with one plays, and once past the last slot, the next turn begins. Nil when there is no faction.
@(private = "file")
turn_end :: proc() {
	for &piece in WORLD.pieces {
		if piece_alive(piece) && piece.owner == WORLD.player && piece.movement_domain != nil {
			piece.movement_budget = piece.movement_per_turn
		}
	}
	from := int(WORLD.player.index)
	for step in 1 ..= FACTION_MAX {
		index := from + step
		if index == FACTION_MAX do WORLD.turn += 1
		index %= FACTION_MAX
		if faction_alive(WORLD.factions[index]) {
			WORLD.player = faction_id(index)
			return
		}
	}
	WORLD.player = {}
}

// The turn can end: no piece is moving
turn_can_end :: proc() -> bool {
	return WORLD.movement.subject == {}
}

// Test factions and their pieces in late-Roman Italy and Germanic lands north of the Alps, in place of whatever factions
// and pieces there were. Rome plays first.
@(private = "file")
world_load_test_pieces :: proc() {
	Test_Faction :: enum {
		Rome,
		Alamanni,
	}
	Test_Faction_Def :: struct {
		name:    string,
		culture: Culture,
	}
	@(static, rodata)
	TEST_FACTIONS := [Test_Faction]Test_Faction_Def {
		.Rome     = {"Rome", .Roman},
		.Alamanni = {"Alamanni", .Germanic},
	}
	Test_Piece :: struct {
		pos:      [2]f32,
		icon:     Icon,
		name:     string,
		owner:    Test_Faction,
		culture:  Culture,
		movement: Maybe(Pathfind_Domain),
		per_turn: f32,
	}
	@(static, rodata)
	TEST_PIECES := [?]Test_Piece {
		{{342, 432}, .Large_City, "Roma", .Rome, .Roman, nil, 0},
		{{296, 374}, .Large_City, "Mediolanum", .Rome, .Roman, nil, 0},
		{{351, 400}, .City, "Ravenna", .Rome, .Roman, nil, 0},
		{{412, 462}, .City, "Tarentum", .Rome, .Roman, nil, 0},
		{{367, 369}, .Town, "Aquileia", .Rome, .Roman, nil, 0},
		{{367, 449}, .Town, "Neapolis", .Rome, .Roman, nil, 0},
		{{330, 401}, .Town, "Florentia", .Rome, .Roman, nil, 0},
		{{296, 391}, .Town, "Genua", .Rome, .Roman, nil, 0},
		{{327, 374}, .Town, "Verona", .Rome, .Roman, nil, 0},
		{{260, 379}, .Town, "Segusio", .Rome, .Roman, nil, 0},
		{{393, 506}, .Town, "Rhegium", .Rome, .Roman, nil, 0},
		{{385, 527}, .Town, "Syracusae", .Rome, .Roman, nil, 0},
		{{419, 374}, .Town, "Siscia", .Rome, .Roman, nil, 0},
		{{470, 396}, .Town, "Domavia", .Rome, .Roman, nil, 0},
		{{421, 405}, .City, "Salona", .Rome, .Roman, nil, 0},
		{{334, 419}, .Army, "", .Rome, .Roman, .Land, 30},
		{{353, 455}, .Fleet, "", .Rome, .Roman, .Sea, 80},
		{{355, 393}, .Fleet, "", .Rome, .Roman, .Sea, 80},
		{{350, 430}, .Priest, "", .Rome, .Roman, .Land, 40},
		{{306, 382}, .Envoy, "", .Rome, .Roman, .Land, 50},
		{{325, 327}, .Large_City, "Augusta Vindelicorum", .Alamanni, .Germanic, nil, 0},
		{{242, 345}, .City, "Vesontio", .Alamanni, .Germanic, nil, 0},
		{{385, 354}, .City, "Virunum", .Alamanni, .Germanic, nil, 0},
		{{253, 367}, .Town, "Octodurum", .Alamanni, .Germanic, nil, 0},
		{{362, 336}, .Town, "Iuvavum", .Alamanni, .Germanic, nil, 0},
		{{316, 342}, .Army, "", .Alamanni, .Germanic, .Land, 30},
		{{292, 340}, .Envoy, "", .Alamanni, .Germanic, .Land, 50},
	}
	// What each test piece is, by its icon
	// Each test piece's contact and body, by icon
	@(static, rodata)
	TEST_CONTACTS := [Icon]Contact {
		.Village    = {6, {.Land}},
		.Town       = {7, {.Land}},
		.City       = {8, {.Land}},
		.Large_City = {9, {.Land}},
		.Army       = {8, {.Land}},
		.Fleet      = {8, {.Sea}},
		.Priest     = {4, {.Land}},
		.Envoy      = {4, {.Land}},
	}
	@(static, rodata)
	TEST_BODIES := [Icon]f32 {
		.Village    = 2,
		.Town       = 2.5,
		.City       = 3,
		.Large_City = 3.5,
		.Army       = 2,
		.Fleet      = 2,
		.Priest     = 2,
		.Envoy      = 2,
	}
	for piece, index in WORLD.pieces do if piece_alive(piece) do piece_despawn(piece_id(index))
	for faction, index in WORLD.factions do if faction_alive(faction) do faction_despawn(faction_id(index))
	factions: [Test_Faction]Faction_Id
	for faction, test in TEST_FACTIONS do factions[test] = faction_spawn({culture = faction.culture}, faction.name)
	// The Roman army walks to Neapolis.
	for piece in TEST_PIECES {
		piece_spawn(
			{
				pos = piece.pos,
				icon = piece.icon,
				owner = factions[piece.owner],
				culture = piece.culture,
				movement_domain = piece.movement,
				movement_per_turn = piece.per_turn,
				contact = TEST_CONTACTS[piece.icon],
				body = TEST_BODIES[piece.icon],
			},
			piece.name,
		)
	}
}

// A thing of the game's that stands on the map, drawn as a pawn
Piece :: struct {
	// Bumped as the slot takes a piece and as it frees it: odd while there is a piece in the slot, even while it is
	// free. Ids to earlier pieces go stale. Set by piece_spawn.
	generation:        u16,
	// Where it stands, in cells
	pos:               [2]f32,
	icon:              Icon,
	// The faction it belongs to
	owner:             Faction_Id,
	culture:           Culture,
	movement_domain:   Maybe(Pathfind_Domain),
	// The cost it can still spend walking this turn
	movement_budget:   f32,
	// What its movement budget is recharged to at the start of each turn
	movement_per_turn: f32,
	// Where others touch it; for enemies, a zone they stop in once entered
	contact:           Contact,
	// Radius in cells; no other piece stops overlapping it
	body:              f32,
}

// Radius in cells, 0 for none, and the movement domains it reaches
Contact :: struct {
	radius:  f32,
	domains: bit_set[Pathfind_Domain],
}

// Puts a piece in a free slot under a name, which may be empty, returning its id, or nil when every slot is full
piece_spawn :: proc(piece: Piece, name: string) -> Piece_Id {
	index, ok := pop_safe(&WORLD.pieces_free)
	if !ok do return {}
	slot := &WORLD.pieces[index]
	generation := slot.generation + 1
	slot^ = piece
	slot.generation = generation
	name_set(&WORLD.piece_names[index], name)
	return {index, generation}
}

// Frees a piece's slot. A stale or nil id does nothing.
piece_despawn :: proc(id: Piece_Id) {
	piece := piece_get(id)
	if piece == nil do return
	piece.generation += 1
	clear(&WORLD.piece_names[id.index])
	append(&WORLD.pieces_free, id.index)
}

// The piece an id is to, or nil when the id is stale or nil
piece_get :: proc(id: Piece_Id) -> ^Piece {
	piece := &WORLD.pieces[id.index]
	if id.generation & 1 == 0 || piece.generation != id.generation do return nil
	return piece
}

// There is a piece in the slot
piece_alive :: proc(piece: Piece) -> bool {
	return piece.generation & 1 == 1
}

// The id of the piece in a slot
piece_id :: proc(index: int) -> Piece_Id {
	return {u16(index), WORLD.pieces[index].generation}
}

// A people with its own name, holding pieces
Faction :: struct {
	// Bumped as the slot takes a faction and as it frees it: odd while there is a faction in the slot, even while it is
	// free. Ids to earlier factions go stale. Set by faction_spawn.
	generation: u16,
	// Its people's culture
	culture:    Culture,
}

// A proper name, held by value: up to 56 bytes of UTF-8, 64 in all. Its text is string(name[:]), a view that lasts as
// long as the name is not set again.
Name :: [dynamic; 56]u8

// Sets a name to text, cut to fit on a character boundary
name_set :: proc(name: ^Name, text: string) {
	clear(name)
	if append(name, ..transmute([]u8)text) == len(text) do return
	// Cut short: if the cut went through a character, drop what was kept of it, from its first byte on
	first := len(name) - 1
	for first > 0 && name[first] & 0xC0 == 0x80 do first -= 1
	if name[first] >= 0xC0 && first + utf8_length(name[first]) > len(name) do resize(name, first)

	// How many bytes the character a UTF-8 first byte begins takes
	utf8_length :: proc(first: u8) -> int {
		return first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : 2
	}
}

// Which faction: its slot, and the slot's generation while the faction is in it. An id with an even generation, like
// the zero id, is nil: no faction.
Faction_Id :: struct {
	index:      u16,
	generation: u16,
}

// Puts a faction in a free slot under a name, returning its id, or nil when every slot is full
faction_spawn :: proc(faction: Faction, name: string) -> Faction_Id {
	index, ok := pop_safe(&WORLD.factions_free)
	if !ok do return {}
	slot := &WORLD.factions[index]
	generation := slot.generation + 1
	slot^ = faction
	slot.generation = generation
	name_set(&WORLD.faction_names[index], name)
	return {index, generation}
}

// Frees a faction's slot. A stale or nil id does nothing; the pieces it held are left with no faction.
faction_despawn :: proc(id: Faction_Id) {
	faction := faction_get(id)
	if faction == nil do return
	faction.generation += 1
	clear(&WORLD.faction_names[id.index])
	append(&WORLD.factions_free, id.index)
}

// The faction an id is to, or nil when the id is stale or nil
faction_get :: proc(id: Faction_Id) -> ^Faction {
	faction := &WORLD.factions[id.index]
	if id.generation & 1 == 0 || faction.generation != id.generation do return nil
	return faction
}

// There is a faction in the slot
faction_alive :: proc(faction: Faction) -> bool {
	return faction.generation & 1 == 1
}

// The id of the faction in a slot
faction_id :: proc(index: int) -> Faction_Id {
	return {u16(index), WORLD.factions[index].generation}
}
