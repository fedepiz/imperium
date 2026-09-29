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
	// Every slot a piece can be in
	pieces:        [PIECE_MAX]Piece,
	// The slots with no piece in them, the next to be used last
	pieces_free:   [dynamic; PIECE_MAX]u16,
	// Every slot a faction can be in, and those with no faction in them, the next to be used last
	factions:      [FACTION_MAX]Faction,
	factions_free: [dynamic; FACTION_MAX]u16,
	// The faction whose turn it is, which the player plays, or nil for none
	player:        Faction_Id,
	movement:      Movement,
	// The turn being played, counting from 1: each faction plays once in a turn, in the order of their slots
	turn:          int,
}

// How far past touching, in cells, a walk to meet a piece may stop
TOUCH_SLACK :: 1

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
	// Where the focus can walk: nil subject and 0 key when none. The key hashes the flood's inputs.
	flood:         Pathfind_Flood,
	flood_subject: Piece_Id,
	flood_key:     u64,
}

// Floods where the focus can walk. Runs once per tick, first in present; the next step's orders use it.
movement_flood :: proc(mov: ^Movement, focus: Piece_Id) {
	subject := piece_get(focus)
	if subject == nil || subject.movement_domain == nil {
		mov.flood_subject, mov.flood_key = {}, 0
		return
	}
	domain := subject.movement_domain.(Pathfind_Domain)

	// Enemy zones stop it and enemy bodies block it; it may pass friendly bodies but not stop on them. Only discs
	// near the flood count.
	zones, blocked, no_stop: [dynamic; PIECE_MAX]Disc
	for other, index in WORLD.pieces {
		if !piece_alive(other) || piece_id(index) == focus do continue
		near := PATHFIND_FLOOD_SIZE / 2 + max(other.zone.radius, subject.body + other.body) + 1
		if abs(other.pos.x - subject.pos.x) > near || abs(other.pos.y - subject.pos.y) > near do continue
		body := Disc{other.pos, subject.body + other.body}
		if faction_get(other.owner) != nil && other.owner == subject.owner {
			append(&no_stop, body)
			continue
		}
		append(&blocked, body)
		if faction_get(other.owner) != nil && other.zone.radius > 0 && domain in other.zone.domains {
			append(&zones, Disc{other.pos, other.zone.radius})
		}
	}

	focus, pos, budget := focus, subject.pos, subject.movement_budget
	counts := [3]int{len(zones), len(blocked), len(no_stop)}
	key := hash.fnv64a(mem.ptr_to_bytes(&focus))
	key = hash.fnv64a(mem.ptr_to_bytes(&pos), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&budget), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&domain), key)
	key = hash.fnv64a(mem.ptr_to_bytes(&counts), key)
	key = hash.fnv64a(mem.slice_to_bytes(zones[:]), key)
	key = hash.fnv64a(mem.slice_to_bytes(blocked[:]), key)
	key = hash.fnv64a(mem.slice_to_bytes(no_stop[:]), key)
	if key == mov.flood_key do return
	pathfind_flood(pos, domain, budget, zones[:], blocked[:], no_stop[:], &mov.flood)
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
	surface:   Surface,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
	// For each way kind, which way is this cell assigned to. (Way_Id = 0 is nil)
	way:       [Way_Kind]Way_Id,
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
	// Land
	{
		OFF_ROAD_COST :: 1
		ROAD_COST :: 0.4

		grid := pathfind_build_begin(.Land)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.way[.Road] != 0 ? ROAD_COST : cell.surface == .Land ? OFF_ROAD_COST : 0
		}
		pathfind_build_end(.Land)
	}
	// Sea
	{
		grid := pathfind_build_begin(.Sea)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.surface == .Land ? 0 : 1
		}
		pathfind_build_end(.Sea)
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
			if walker == mov.flood_subject do stop, ok = pathfind_flood_stop(&mov.flood, c.destination)
		case Move_To_Piece:
			walker, target = c.piece, c.target
			other, piece := piece_get(target), piece_get(walker)
			if walker == mov.flood_subject && other != nil && piece != nil {
				stop, ok = pathfind_flood_stop_within(&mov.flood, other.pos, piece.body + other.body + TOUCH_SLACK)
			}
		case End_Turn:
			if turn_can_end() do turn_end()
			continue
		}
		path: [dynamic; PATH_MAX_LEN][2]f32
		cost: [dynamic; PATH_MAX_LEN]f32
		if !ok || !pathfind_flood_trace(&mov.flood, [2]f32{f32(stop.x), f32(stop.y)} + 0.5, &path, &cost) {
			fmt.eprintfln("No way for %v to %v", walker, command)
			continue
		}
		mov.subject, mov.target = walker, target
		mov.path, mov.cost, mov.next = path, cost, 0
	}
	movement_advance(mov, walk_distance)
}

// Starts turn 1, played first by the faction in the first slot with one
@(private = "file")
turns_begin :: proc() {
	WORLD.turn = 1
	WORLD.player = {}
	for faction, index in WORLD.factions {
		if faction_alive(faction) {
			faction_play(faction_id(index))
			return
		}
	}
}

// Ends the player's faction's part of the turn: the faction in the next slot with one plays, and once past the last
// slot, the next turn begins. Nil when there is no faction.
@(private = "file")
turn_end :: proc() {
	from := int(WORLD.player.index)
	for step in 1 ..= FACTION_MAX {
		index := from + step
		if index == FACTION_MAX do WORLD.turn += 1
		index %= FACTION_MAX
		if faction_alive(WORLD.factions[index]) {
			faction_play(faction_id(index))
			return
		}
	}
	WORLD.player = {}
}

// The faction plays: the player plays it, and every piece of it that moves has its movement budget recharged.
@(private = "file")
faction_play :: proc(id: Faction_Id) {
	WORLD.player = id
	for &piece in WORLD.pieces {
		if piece_alive(piece) && piece.owner == id && piece.movement_domain != nil {
			piece.movement_budget = piece.movement_per_turn
		}
	}
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
	@(static, rodata)
	TEST_FACTIONS := [Test_Faction]Faction {
		.Rome     = {name = "Rome", culture = .Roman},
		.Alamanni = {name = "Alamanni", culture = .Germanic},
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
		{{394, 506}, .Town, "Rhegium", .Rome, .Roman, nil, 0},
		{{385, 527}, .Town, "Syracusae", .Rome, .Roman, nil, 0},
		{{334, 419}, .Army, "", .Rome, .Roman, .Land, 30},
		{{353, 455}, .Fleet, "", .Rome, .Roman, .Sea, 80},
		{{355, 393}, .Fleet, "", .Rome, .Roman, .Sea, 80},
		{{350, 430}, .Priest, "", .Rome, .Roman, .Land, 40},
		{{306, 382}, .Envoy, "", .Rome, .Roman, .Land, 50},
		{{300, 300}, .Large_City, "Alamannia", .Alamanni, .Germanic, nil, 0},
		{{332, 318}, .City, "Castra Regina", .Alamanni, .Germanic, nil, 0},
		{{270, 322}, .Town, "Brisiacum", .Alamanni, .Germanic, nil, 0},
		{{285, 285}, .Village, "", .Alamanni, .Germanic, nil, 0},
		{{316, 342}, .Army, "", .Alamanni, .Germanic, .Land, 30},
		{{292, 340}, .Envoy, "", .Alamanni, .Germanic, .Land, 50},
	}
	// What each test piece is, by its icon
	// Each test piece's zone and body, by icon
	@(static, rodata)
	TEST_ZONES := [Icon]Zone {
		.Village    = {6, {.Land}},
		.Town       = {7, {.Land}},
		.City       = {8, {.Land}},
		.Large_City = {9, {.Land}},
		.Army       = {8, {.Land}},
		.Fleet      = {8, {.Sea}},
		.Priest     = {},
		.Envoy      = {},
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
	@(static, rodata)
	TEST_TITLES := [Icon]string {
		.Village    = "Village",
		.Town       = "Town",
		.City       = "City",
		.Large_City = "Large City",
		.Army       = "Army",
		.Fleet      = "Fleet",
		.Priest     = "Priest",
		.Envoy      = "Envoy",
	}
	for piece, index in WORLD.pieces do if piece_alive(piece) do piece_despawn(piece_id(index))
	for faction, index in WORLD.factions do if faction_alive(faction) do faction_despawn(faction_id(index))
	factions: [Test_Faction]Faction_Id
	for faction, test in TEST_FACTIONS do factions[test] = faction_spawn(faction)
	// The Roman army walks to Neapolis.
	for piece in TEST_PIECES {
		piece_spawn(
			{
				pos = piece.pos,
				icon = piece.icon,
				owner = factions[piece.owner],
				culture = piece.culture,
				name = piece.name,
				title = TEST_TITLES[piece.icon],
				movement_domain = piece.movement,
				movement_per_turn = piece.per_turn,
				zone = TEST_ZONES[piece.icon],
				body = TEST_BODIES[piece.icon],
			},
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
	name:              string,
	title:             string,
	movement_domain:   Maybe(Pathfind_Domain),
	// The cost it can still spend walking this turn
	movement_budget:   f32,
	// What its movement budget is recharged to at the start of each turn
	movement_per_turn: f32,
	// Where pieces of other factions stop: once within it they cannot walk out
	zone:              Zone,
	// Radius in cells; no other piece stops overlapping it, and enemies cannot pass it
	body:              f32,
}

// A disc of cells around a piece, radius cells across from its middle, and the movement it stops. A radius of 0 is no
// zone.
Zone :: struct {
	radius:  f32,
	domains: bit_set[Pathfind_Domain],
}

// Puts a piece in a free slot, returning its id, or nil when every slot is full
piece_spawn :: proc(piece: Piece) -> Piece_Id {
	index, ok := pop_safe(&WORLD.pieces_free)
	if !ok do return {}
	slot := &WORLD.pieces[index]
	generation := slot.generation + 1
	slot^ = piece
	slot.generation = generation
	return {index, generation}
}

// Frees a piece's slot. A stale or nil id does nothing.
piece_despawn :: proc(id: Piece_Id) {
	piece := piece_get(id)
	if piece == nil do return
	piece.generation += 1
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
	name:       string,
	// Its people's culture
	culture:    Culture,
}

// Which faction: its slot, and the slot's generation while the faction is in it. An id with an even generation, like
// the zero id, is nil: no faction.
Faction_Id :: struct {
	index:      u16,
	generation: u16,
}

// Puts a faction in a free slot, returning its id, or nil when every slot is full
faction_spawn :: proc(faction: Faction) -> Faction_Id {
	index, ok := pop_safe(&WORLD.factions_free)
	if !ok do return {}
	slot := &WORLD.factions[index]
	generation := slot.generation + 1
	slot^ = faction
	slot.generation = generation
	return {index, generation}
}

// Frees a faction's slot. A stale or nil id does nothing; the pieces it held are left with no faction.
faction_despawn :: proc(id: Faction_Id) {
	faction := faction_get(id)
	if faction == nil do return
	faction.generation += 1
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
