#+private
package sim

import "core:fmt"
import "core:math/linalg"

import "../util"

PIECE_MAX :: 1024
FACTION_MAX :: 256
CHARACTER_MAX :: 1024

WALK_CUTS :: 2
WALK_SMOOTHING :: util.Smoothing {
	softness    = 1,
	soften_iter = 2,
	cut_iter    = WALK_CUTS,
	cut_ratio   = 0.25,
}
// Start point plus PATH_MAX_LEN cells, doubled by each cut
WALK_POINTS_MAX :: (PATH_MAX_LEN + 1) << WALK_CUTS

// Arrow = walker position + remaining path
#assert(WALK_POINTS_MAX + 1 <= ARROW_POINTS_MAX)

// In cells, regardless of terrain
WALK_PER_STEP :: 10 * STEP_SECONDS

// Movement cost per cell, 0 = impassable. Roads override with ROAD_COST.
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

// Normalized elevation
HIGHLAND_ELEVATION :: util.Ramp{0.55, 1.0}
MOUNTAINS_ELEVATION :: 0.85

// Mountains within PASS_REACH cells of a road become highland. Smaller patches than MOUNTAINS_PATCH_MIN too.
PASS_REACH :: 1
MOUNTAINS_PATCH_MIN :: 12

// Radius in cells for basin detection
BASIN_REACH :: 24

// Readiness lost per movement point spent, in percent
ROAD_READINESS_PER_MOVEMENT :: 0.1
READINESS_PER_MOVEMENT :: 1

// Readiness recovered at end of turn, scaled by the fraction of movement left
READINESS_RECOVERY :: 20

WORLD: struct {
	atlas:           Atlas,
	// Index 0 = region 1
	region_names:    [dynamic; REGIONS_MAX]Name,
	region_capitals: [dynamic; REGIONS_MAX]Piece_Id,
	// Pieces, names and armies are parallel arrays indexed by slot
	pieces:          [PIECE_MAX]Piece,
	piece_names:     [PIECE_MAX]Name,
	armies:          [PIECE_MAX]Army,
	// Free slots; the last is used next
	pieces_free:     [dynamic; PIECE_MAX]u16,
	factions:        [FACTION_MAX]Faction,
	faction_names:   [FACTION_MAX]Name,
	factions_free:   [dynamic; FACTION_MAX]u16,
	characters:      [CHARACTER_MAX]Character,
	character_names: [CHARACTER_MAX]Name,
	characters_free: [dynamic; CHARACTER_MAX]u16,
	// Faction whose turn it is (played by the player), nil = none
	player:          Faction_Id,
	interaction:     Interaction,
	movement:        Movement,
	// From 1. Each faction plays once per turn, in slot order.
	turn:            int,
}

// Nil actor = none open
Interaction :: struct {
	actor, target: Piece_Id,
	// Computed when opened
	conquerable:   bool,
}

Movement :: struct {
	// Walking piece, nil = none
	subject:       Piece_Id,
	// Smoothed path. cost[i] = cost per cell from point i-1 to i. next = point being walked to.
	path:          [dynamic; WALK_POINTS_MAX][2]f32,
	cost:          [dynamic; WALK_POINTS_MAX]f32,
	next:          int,
	target:        Piece_Id,
	// Reach of the focus. Nil subject and 0 key = none. Key hashes all flood inputs; recomputed only on change.
	flood:         Pathfind_Flood,
	enemy_zones:   [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones:  [dynamic; PIECE_MAX]util.Disc,
	bodies:        [dynamic; PIECE_MAX]util.Disc,
	flood_subject: Piece_Id,
	flood_key:     u64,
}

// Full again once WORLD.turn moves past movement_turn
movement_budget :: proc(piece: Piece) -> f32 {
	if piece.movement_turn != WORLD.turn do return piece.movement_per_turn
	return max(0, piece.movement_per_turn - piece.movement_spent)
}

Atlas :: struct {
	// Incremented on terrain change
	revision: u32,
	terrain:  [CELLS_MAX]Terrain,
}

Terrain :: struct {
	surface:       Surface,
	elevation:     u8,
	trees:         u8,
	moisture:      u8,
	// 0 = none
	way:           [Way_Kind]Way_Id,
	// Derived at load
	type:          Terrain_Type,
	type_strength: u8,
	region:        Region_Id,
}

// Per-cell inputs for terrain classification, in the temp allocator
Land :: struct {
	// Distance in cells
	to_river, to_sea: []f32,
	// Mean surrounding elevation minus own; > 0 in basins and valleys. Used for lowland since there's no sea level.
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
	util.distance_from(land.to_river, is_river, WORLD_SIZE)
	util.distance_from(land.to_sea, is_sea, WORLD_SIZE)

	elevation := make([]f32, CELLS_MAX, context.temp_allocator)
	is_land := make([]f32, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain {
		if cell.surface in WATER do continue
		elevation[i] = util.normalized(cell.elevation)
		is_land[i] = 1
	}
	around := make([]f32, CELLS_MAX, context.temp_allocator)
	count := make([]f32, CELLS_MAX, context.temp_allocator)
	util.box_sum(around, elevation, WORLD_SIZE, BASIN_REACH)
	util.box_sum(count, is_land, WORLD_SIZE, BASIN_REACH)
	land.basin = make([]f32, CELLS_MAX, context.temp_allocator)
	for i in 0 ..< CELLS_MAX {
		if is_land[i] > 0 do land.basin[i] = around[i] / count[i] - elevation[i]
	}
	return
}

// Best-suited type and its strength; Open if nothing scores at least 1/6.
// Priority: mountains > fertile/marsh > highland > forest/desert/steppe/fields.
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
	elevation := util.normalized(cell.elevation)
	if elevation >= MOUNTAINS_ELEVATION do return .Mountains, max(u8)
	trees := util.normalized(cell.trees)
	moisture := util.normalized(cell.moisture)
	low := util.ramp(0.22, 0.12, elevation)
	delta := util.ramp(6, 2, land.to_river[i]) * util.ramp(16, 6, land.to_sea[i])
	dry_river := util.ramp(0.62, 0.52, moisture) * util.ramp(5, 1.5, land.to_river[i])
	valley :=
		util.ramp(0.55, 0.65, moisture) *
		util.ramp(12, 4, land.to_river[i]) *
		util.ramp(0.02, 0.07, land.basin[i])
	suits := [Terrain_Type]f32 {
		.Open      = 1.0 / 6,
		.Forest    = util.ramp(0.05, 0.75, trees),
		.Desert    = util.ramp(0.47, 0.35, moisture),
		.Steppe    = util.ramp(0.40, 0.47, moisture) * util.ramp(0.58, 0.48, moisture),
		.Fertile   = 1.3 * max(dry_river, valley),
		.Marsh     = 1.5 * low * max(delta, util.ramp(0.80, 0.88, moisture)),
		.Highland  = highland_suit(elevation),
		.Mountains = 0,
		.Fields    = 0.6 * util.ramp(0.52, 0.62, moisture) * util.ramp(0.3, 0.1, trees),
	}
	most: f32
	for s, type in suits {
		if s > most do best, strength, most = type, util.to_u8(s), s
	}
	if best == .Open do strength = 0
	return
}

highland_suit :: proc(elevation: f32) -> f32 {
	return 1.2 * util.ramp(HIGHLAND_ELEVATION, elevation)
}

terrain_to_highland :: proc(cell: ^Terrain) {
	cell.type = .Highland
	cell.type_strength = util.to_u8(highland_suit(util.normalized(cell.elevation)))
}

// Mountains near roads become highland (passes)
terrain_open_passes :: proc(terrain: []Terrain) {
	for road, i in terrain {
		if road.way[.Road] == 0 do continue
		around := util.cell_rect_clip(util.cell_rect_around(util.grid_pos(i, WORLD_SIZE), PASS_REACH), WORLD_SIZE)
		for y in around.min.y ..< around.max.y do for x in around.min.x ..< around.max.x {
			cell := &terrain[util.grid_index({x, y}, WORLD_SIZE)]
			if cell.type == .Mountains do terrain_to_highland(cell)
		}
	}
}

// Mountain patches (8-connected) smaller than MOUNTAINS_PATCH_MIN become highland
terrain_drop_specks :: proc(terrain: []Terrain) {
	impassable := make([]bool, CELLS_MAX, context.temp_allocator)
	for cell, i in terrain do impassable[i] = cell.type == .Mountains && cell.way[.Road] == 0
	patches := make([]u16, CELLS_MAX, context.temp_allocator)
	count := util.grid_components(patches, impassable, WORLD_SIZE, true)
	sizes := make([]int, count + 1, context.temp_allocator)
	for patch in patches do sizes[patch] += 1
	for patch, i in patches {
		if patch != 0 && sizes[patch] < MOUNTAINS_PATCH_MIN do terrain_to_highland(&terrain[i])
	}
}

// 0 = none
Way_Id :: distinct u16

world_init :: proc() {
	for index := PIECE_MAX - 1; index >= 0; index -= 1 do append(&WORLD.pieces_free, u16(index))
	for index := FACTION_MAX - 1; index >= 0; index -= 1 do append(&WORLD.factions_free, u16(index))
	for index := CHARACTER_MAX - 1; index >= 0; index -= 1 do append(&WORLD.characters_free, u16(index))
}

world_load :: proc(scenario: Scenario) -> bool {
	terrain := &WORLD.atlas.terrain
	ok :=
		len(scenario.surface) == CELLS_MAX &&
		len(scenario.elevation) == CELLS_MAX &&
		len(scenario.trees) == CELLS_MAX &&
		len(scenario.moisture) == CELLS_MAX &&
		len(scenario.regions) == CELLS_MAX
	for layer in scenario.ways do ok &&= len(layer) == CELLS_MAX
	if ok {
		for &cell, i in terrain {
			cell = {
				surface   = scenario.surface[i],
				elevation = scenario.elevation[i],
				trees     = scenario.trees[i],
				moisture  = scenario.moisture[i],
				region    = scenario.regions[i],
			}
			for layer, kind in scenario.ways do cell.way[kind] = Way_Id(layer[i])
		}
	} else {
		for &cell in terrain do cell = {
			surface = .Sea,
		}
	}
	// Clear everything but surface on water
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	// Make roads 4-connected: fill diagonal steps with the lower corner cell
	for y in 0 ..< WORLD_HEIGHT - 1 {
		for x in 0 ..< WORLD_WIDTH {
			pos := [2]int{x, y}
			at := &terrain[util.grid_index(pos, WORLD_SIZE)]
			if at.way[.Road] == 0 do continue
			for dx in ([2]int{-1, 1}) {
				diagonal := pos + {dx, 1}
				if !util.grid_contains(diagonal, WORLD_SIZE) do continue
				if terrain[util.grid_index(diagonal, WORLD_SIZE)].way[.Road] == 0 do continue
				a := &terrain[util.grid_index(pos + {dx, 0}, WORLD_SIZE)]
				b := &terrain[util.grid_index(pos + {0, 1}, WORLD_SIZE)]
				if a.way[.Road] != 0 || b.way[.Road] != 0 do continue
				corner := a.elevation <= b.elevation ? a : b
				if corner.surface in WATER do corner = corner == a ? b : a
				if corner.surface not_in WATER do corner.way[.Road] = at.way[.Road]
			}
		}
	}
	// Terrain types
	{
		land := measure_land(terrain[:])
		for &cell, i in terrain do cell.type, cell.type_strength = terrain_type_of(terrain[:], &land, i)
		terrain_open_passes(terrain[:])
		terrain_drop_specks(terrain[:])
	}
	// Land pathfinding grid
	{
		grid, off_road := pathfind_build_begin(.Land)
		for cell, i in WORLD.atlas.terrain {
			grid[i] =
				cell.surface != .Land ? 0 : cell.way[.Road] != 0 ? ROAD_COST : TERRAIN_COSTS[cell.type]
			// A road cell over impassable terrain keeps its road cost
			off_road[i] = cell.surface != .Land ? 0 : max(TERRAIN_COSTS[cell.type], grid[i])
		}
		pathfind_build_end(.Land, scenario.cached_files[.Pathfind_Land])
	}
	// Sea pathfinding grid
	{
		grid, off_road := pathfind_build_begin(.Sea)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.surface == .Land ? 0 : 1
			off_road[i] = grid[i]
		}
		pathfind_build_end(.Sea, scenario.cached_files[.Pathfind_Sea])
	}
	clear(&WORLD.region_names)
	clear(&WORLD.region_capitals)
	for name in scenario.region_names[:min(len(scenario.region_names), REGIONS_MAX)] {
		append(&WORLD.region_names, Name{})
		name_set(&WORLD.region_names[len(WORLD.region_names) - 1], name)
		append(&WORLD.region_capitals, Piece_Id{})
	}
	WORLD.atlas.revision += 1
	WORLD.interaction = {}

	// Factions, characters, pieces
	{
		factions: [dynamic; FACTION_MAX]Faction_Id
		for faction in scenario.factions {
			append(
				&factions,
				faction_spawn({culture = faction.culture, color = faction.color}, faction.name),
			)
		}
		characters: [dynamic; CHARACTER_MAX]Character_Id
		for name in scenario.character_names {
			append(&characters, character_spawn({}, name))
		}
		for piece in scenario.pieces {
			owner: Faction_Id
			if piece.owner >= 0 && piece.owner < len(factions) do owner = factions[piece.owner]
			general: Character_Id
			if piece.general > 0 && piece.general <= len(characters) do general = characters[piece.general - 1]
			id := piece_spawn(
				{
					pos = piece.pos,
					icon = piece.icon,
					owner = owner,
					culture = piece.culture,
					movement_domain = piece.movement_domain,
					movement_per_turn = piece.movement_per_turn,
					contact = piece.contact,
					body = piece.body,
				hindrance = piece.hindrance,
					traits = piece.traits,
					general = general,
				},
				piece.army,
				piece.name,
			)
			if piece.capital_of > 0 && int(piece.capital_of) <= len(WORLD.region_capitals) {
				WORLD.region_capitals[piece.capital_of - 1] = id
			}
		}
	}

	// First turn: first faction plays
	WORLD.turn = 1
	WORLD.player = {}
	for faction, index in WORLD.factions {
		if faction_alive(faction) {
			WORLD.player = faction_id(index)
			break
		}
	}
	return ok
}

world_step :: proc(input: Step_Input) {
	mov := &WORLD.movement

	// Step: Decide
	turn_ending := input.end_turn && turn_endable()

	// Step: Movemnt Flood
	{
		zones, bodies := &mov.enemy_zones, &mov.bodies
		clear(zones)
		clear(bodies)
		clear(&mov.friend_zones)
		subject := piece_get(input.focus)
		if subject == nil || subject.movement_domain == nil {
			mov.flood_subject, mov.flood_key = {}, 0
		} else {
			domain := subject.movement_domain.(Pathfind_Domain)

			// Gather bodies (can't stop on), enemy zones (slow, no roads) and friendly contacts touching the flood
			// square, padded a cell for rounding
			half: f32 = PATHFIND_FLOOD_SIZE / 2 + 1
			square := [4]f32{subject.pos.x - half, subject.pos.y - half, 2 * half, 2 * half}
			for other, index in WORLD.pieces {
				if !piece_alive(other) || piece_id(index) == input.focus do continue
				body := util.Disc{other.pos, subject.body + other.body}
				if util.disc_overlaps_rect(body, square) do append(bodies, body)
				if other.contact.radius == 0 || domain not_in other.contact.domains do continue
				contact := util.Disc{other.pos, other.contact.radius}
				if !util.disc_overlaps_rect(contact, square) do continue
				if pieces_friendly(subject^, other) {
					append(&mov.friend_zones, contact)
				} else {
					append(zones, Pathfind_Zone{contact, other.hindrance})
				}
			}

			// Reflood only when an input changed
			budget := movement_budget(subject^)
			key := util.hash_contents(input.focus, subject.pos, budget, domain, zones[:], bodies[:])
			if key != mov.flood_key {
				pathfind_flood(subject.pos, domain, budget, zones[:], bodies[:], &mov.flood)
				mov.flood_subject, mov.flood_key = input.focus, key
			}
		}
	}

	// Step: Orders
	if input.order != nil {
		walker := mov.flood_subject
		ordering := ordering()
		if piece := piece_get(walker); piece == nil || ordering == {} || piece.owner != ordering do walker = {}
		target: Piece_Id
		stop: [2]int
		ok: bool
		switch order in input.order {
		case Move_Focus_To_Point:
			if walker != {} do stop, ok = pathfind_flood_stop(&mov.flood, order.destination, order.snap)
		case Move_Focus_To_Piece:
			target = order.target
			other := piece_get(target)
			if walker != {} && other != nil && mov.flood.domain in other.contact.domains {
				stop, ok = pathfind_flood_stop_within(&mov.flood, util.Disc{other.pos, other.contact.radius})
			}
		}
		path: [dynamic; PATH_MAX_LEN][2]f32
		cost: [dynamic; PATH_MAX_LEN]f32
		mover := piece_get(walker)
		if ok &&
		   mover != nil &&
		   pathfind_flood_trace(&mov.flood, util.cell_center(stop), &path, &cost) {
			mov.subject, mov.target = walker, target
			clear(&mov.path)
			clear(&mov.cost)
			append(&mov.path, mover.pos)
			append(&mov.cost, 0)
			append(&mov.path, ..path[:])
			append(&mov.cost, ..cost[:])
			mov.next = 1

			// Smooth; cut points keep their segment's cost
			n := len(mov.path)
			resize(&mov.path, n << WALK_CUTS)
			resize(&mov.cost, n << WALK_CUTS)
			n = util.smooth_polyline(mov.path[:], n, false, WALK_SMOOTHING, mov.cost[:])
			resize(&mov.path, n)
			resize(&mov.cost, n)
		} else {
			fmt.eprintfln("No way for %v to %v", walker, input.order)
		}
	}

	// Step: Walk
	// What the walker did this step. Nil piece = nobody walked.
	walk: struct {
		piece:          Piece_Id,
		spent_road:     f32,
		spent_off_road: f32,
		met:            Piece_Id,
	}
	if subject := piece_get(mov.subject); subject != nil {
		walk.piece = mov.subject
		before := subject.pos
		step: f32 = WALK_PER_STEP
		for step > 0 && mov.next < len(mov.path) {
			target, cost := mov.path[mov.next], mov.cost[mov.next]
			distance := linalg.distance(subject.pos, target)
			walked := min(step, distance)
			subject.pos =
				walked < distance ? subject.pos + linalg.normalize(target - subject.pos) * walked : target
			step -= walked
			if walked == distance do mov.next += 1

			// Pay from the budget, as far as it lasts
			spent := min(walked * cost, movement_budget(subject^))
			if subject.movement_turn != WORLD.turn {
				subject.movement_turn = WORLD.turn
				subject.movement_spent = 0
			}
			subject.movement_spent += spent
			// Road cells always cost exactly ROAD_COST
			if cost == ROAD_COST do walk.spent_road += spent
			else do walk.spent_off_road += spent
		}

		// Contact: entering an enemy zone ends the walk
		domain := subject.movement_domain.(Pathfind_Domain)
		for other, index in WORLD.pieces {
			if !piece_alive(other) || piece_id(index) == walk.piece || pieces_friendly(subject^, other) do continue
			if other.contact.radius == 0 || domain not_in other.contact.domains do continue
			zone := util.Disc{other.pos, other.contact.radius}
			if util.disc_contains(zone, subject.pos) && !util.disc_contains(zone, before) {
				walk.met = piece_id(index)
				break
			}
		}

		if walk.met != {} || mov.next >= len(mov.path) {
			if walk.met == {} do walk.met = mov.target
			mov.subject, mov.target, mov.next = {}, {}, 0
		}
	} else {
		// Walker gone
		mov.subject, mov.target, mov.next = {}, {}, 0
	}

	// Step: Interaction
	open := &WORLD.interaction
	if open.actor != {} {
		if input.conquer && open.conquerable {
			actor, conquered := piece_get(open.actor), piece_get(open.target)
			if actor != nil && conquered != nil do conquered.owner = actor.owner
			open^ = {}
		} else if input.leave {
			open^ = {}
		}
	} else if actor, other := piece_get(walk.piece), piece_get(walk.met);
	   actor != nil && other != nil && !pieces_friendly(actor^, other^) {
		open^ = {
			actor       = walk.piece,
			target      = walk.met,
			conquerable = .Captures in actor.traits && .Capturable in other.traits,
		}
	}

	// Step: Armies
	for &army, index in WORLD.armies {
		if !army.active do continue
		piece := WORLD.pieces[index]
		readiness := army.readiness
		if walk.piece != {} && int(walk.piece.index) == index {
			readiness -= walk.spent_road * ROAD_READINESS_PER_MOVEMENT
			readiness -= walk.spent_off_road * READINESS_PER_MOVEMENT
		}
		if turn_ending && piece.owner == WORLD.player && piece.movement_per_turn > 0 {
			readiness += movement_budget(piece) / piece.movement_per_turn * READINESS_RECOVERY
		}
		army.readiness = clamp(readiness, 0, 100)
	}

	// Step: Turn End
	// Next faction plays; wrapping past the last slot starts a new turn
	if turn_ending {
		from := int(WORLD.player.index)
		next: Faction_Id
		for step in 1 ..= FACTION_MAX {
			index := from + step
			if index == FACTION_MAX do WORLD.turn += 1
			index %= FACTION_MAX
			if faction_alive(WORLD.factions[index]) {
				next = faction_id(index)
				break
			}
		}
		WORLD.player = next
	}
}

// The player, or nil while an interaction is open
ordering :: proc() -> Faction_Id {
	return WORLD.interaction.actor == {} ? WORLD.player : {}
}

turn_endable :: proc() -> bool {
	return WORLD.movement.subject == {} && WORLD.interaction.actor == {}
}

pieces_friendly :: proc(a, b: Piece) -> bool {
	return faction_get(a.owner) != nil && a.owner == b.owner
}

Piece :: struct {
	// Incremented on spawn and despawn: odd = occupied, even = free
	generation:        u16,
	// In cells
	pos:               [2]f32,
	icon:              Icon,
	owner:             Faction_Id,
	culture:           Culture,
	movement_domain:   Maybe(Pathfind_Domain),
	// See movement_budget
	movement_per_turn: f32,
	movement_spent:    f32,
	movement_turn:     int,
	// Enemies entering it must stop
	contact:           Contact,
	// Radius in cells; other pieces can't stop overlapping it
	body:              f32,
	// Enemy movement cost multiplier inside its contact zone
	hindrance:         f32,
	traits:            bit_set[Piece_Trait;u8],
	general:           Character_Id,
}

// Returns nil if all slots are full. Pass an inactive army for none.
piece_spawn :: proc(piece: Piece, army: Army, name: string) -> Piece_Id {
	index, ok := pop_safe(&WORLD.pieces_free)
	if !ok do return {}
	slot := &WORLD.pieces[index]
	generation := slot.generation + 1
	slot^ = piece
	slot.generation = generation
	name_set(&WORLD.piece_names[index], name)
	WORLD.armies[index] = army
	return {index, generation}
}

// Stale or nil id: no-op
piece_despawn :: proc(id: Piece_Id) {
	piece := piece_get(id)
	if piece == nil do return
	piece.generation += 1
	clear(&WORLD.piece_names[id.index])
	WORLD.armies[id.index] = {}
	append(&WORLD.pieces_free, id.index)
}

// Nil if the id is stale or nil
piece_get :: proc(id: Piece_Id) -> ^Piece {
	piece := &WORLD.pieces[id.index]
	if id.generation & 1 == 0 || piece.generation != id.generation do return nil
	return piece
}

piece_alive :: proc(piece: Piece) -> bool {
	return piece.generation & 1 == 1
}

piece_id :: proc(index: int) -> Piece_Id {
	return {u16(index), WORLD.pieces[index].generation}
}

Faction :: struct {
	// Odd = occupied, even = free
	generation: u16,
	culture:    Culture,
	color:      [4]f32,
}

// Up to 56 bytes of UTF-8, by value. string(name[:]) is valid until the name is set again.
Name :: [dynamic; 56]u8

// Truncates on a UTF-8 boundary
name_set :: proc(name: ^Name, text: string) {
	clear(name)
	if append(name, ..transmute([]u8)text) == len(text) do return
	// Truncated: drop a partial trailing character
	first := len(name) - 1
	for first > 0 && name[first] & 0xC0 == 0x80 do first -= 1
	if name[first] >= 0xC0 && first + utf8_length(name[first]) > len(name) do resize(name, first)

	utf8_length :: proc(first: u8) -> int {
		return first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : 2
	}
}

// Even generation (including the zero id) = nil
Faction_Id :: struct {
	index:      u16,
	generation: u16,
}

// Returns nil if all slots are full
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

// Stale or nil id: no-op. Its pieces are left with no faction.
faction_despawn :: proc(id: Faction_Id) {
	faction := faction_get(id)
	if faction == nil do return
	faction.generation += 1
	clear(&WORLD.faction_names[id.index])
	append(&WORLD.factions_free, id.index)
}

// Nil if the id is stale or nil
faction_get :: proc(id: Faction_Id) -> ^Faction {
	faction := &WORLD.factions[id.index]
	if id.generation & 1 == 0 || faction.generation != id.generation do return nil
	return faction
}

faction_alive :: proc(faction: Faction) -> bool {
	return faction.generation & 1 == 1
}

faction_id :: proc(index: int) -> Faction_Id {
	return {u16(index), WORLD.factions[index].generation}
}

Character :: struct {
	// Odd = occupied, even = free
	generation: u16,
}

// Even generation (including the zero id) = nil
Character_Id :: struct {
	index:      u16,
	generation: u16,
}

// Returns nil if all slots are full
character_spawn :: proc(character: Character, name: string) -> Character_Id {
	index, ok := pop_safe(&WORLD.characters_free)
	if !ok do return {}
	slot := &WORLD.characters[index]
	generation := slot.generation + 1
	slot^ = character
	slot.generation = generation
	name_set(&WORLD.character_names[index], name)
	return {index, generation}
}

// Stale or nil id: no-op. Pieces it led are left with no general.
character_despawn :: proc(id: Character_Id) {
	character := character_get(id)
	if character == nil do return
	character.generation += 1
	clear(&WORLD.character_names[id.index])
	append(&WORLD.characters_free, id.index)
}

// Nil if the id is stale or nil
character_get :: proc(id: Character_Id) -> ^Character {
	character := &WORLD.characters[id.index]
	if id.generation & 1 == 0 || character.generation != id.generation do return nil
	return character
}

character_alive :: proc(character: Character) -> bool {
	return character.generation & 1 == 1
}

character_id :: proc(index: int) -> Character_Id {
	return {u16(index), WORLD.characters[index].generation}
}
