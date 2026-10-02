#+private
package sim

import "core:fmt"
import "core:math"
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

// Readiness lost per movement point marched, in percent; overdraw: per point beyond the budget, on top
ROAD_READINESS_PER_MOVEMENT :: 0.1
READINESS_PER_MOVEMENT :: 1
OVERDRAW_READINESS :: 2

// End of turn: readiness rises toward stock / baggage by up to READINESS_RECOVERY, scaled by
// rest = (1 − exertion)², and drops by SUPPLY_DRAG when above it
READINESS_RECOVERY :: 20
SUPPLY_DRAG :: 5

// Resupply per turn = min(fed, 1 + SUPPLY_REFILL_MAX) − 1, in turns of supply, where fed = what the place can feed
// (supply map or foraging, whichever is more) / nearby friendly men
SUPPLY_REFILL_MAX :: 1
// Stock used per movement point marched, in turns: on roads, and off them
ROAD_STOCK_PER_MOVEMENT :: 0.002
STOCK_PER_MOVEMENT :: 0.01

// Supply lost per movement point of path cost from a source
SUPPLY_DECAY :: 2
// Men a cell's supply point feeds
MEN_PER_SUPPLY :: 200
// Initiative to attack: sent at the enemy; intercepting one that entered the zone
ORDERED_INITIATIVE :: 2
INTERCEPT_INITIATIVE :: -1
// Falling back, in movement points: at most when getting away; when caught
FALL_BACK_BUDGET :: 10
CHASE_BUDGET :: 15

// Armies within this many cells share supply (network: friendly ones; forage: all), weighted by
// 1 − distance / FORAGE_RADIUS
FORAGE_RADIUS :: 12

// What the land yields to foragers, 0..1, by terrain type; blended from Open by the type's strength
FORAGE_YIELD := [Terrain_Type]f32 {
	.Open      = 0.7,
	.Forest    = 0.5,
	.Desert    = 0.1,
	.Steppe    = 0.5,
	.Fertile   = 1,
	.Marsh     = 0.3,
	.Highland  = 0.3,
	.Mountains = 0.05,
	.Fields    = 1,
}

WORLD: struct {
	atlas:               Atlas,
	// Index 0 = region 1
	region_names:        [dynamic; REGIONS_MAX]Name,
	region_capitals:     [dynamic; REGIONS_MAX]Piece_Id,
	// Pieces, names, armies and turn data are parallel arrays indexed by slot
	pieces:              [PIECE_MAX]Piece,
	piece_names:         [PIECE_MAX]Name,
	armies:              [PIECE_MAX]Army,
	// Cleared at each faction's turn start
	piece_turns:         [PIECE_MAX]Piece_Turn,
	// Free slots; the last is used next
	pieces_free:         [dynamic; PIECE_MAX]u16,
	factions:            [FACTION_MAX]Faction,
	faction_names:       [FACTION_MAX]Name,
	factions_free:       [dynamic; FACTION_MAX]u16,
	characters:          [CHARACTER_MAX]Character,
	character_names:     [CHARACTER_MAX]Name,
	characters_free:     [dynamic; CHARACTER_MAX]u16,
	// Faction whose turn it is (played by the player), nil = none
	player:              Faction_Id,
	interaction:         Interaction,
	// Detected contacts waiting to be resolved, oldest first
	contacts:            [dynamic; CONTACTS_MAX]Contact_Event,
	// The player asked to end the turn; it ends once contacts are resolved and nothing is open
	ending:              bool,
	movement:            Movement,
	// From 1. Each faction plays once per turn, in slot order.
	turn:                int,
	// The player's supply map, 0..100 per cell, rebuilt at the start of each faction's turn
	supply_map:          [CELLS_MAX]u8,
	supply_map_revision: u32,
}

CONTACTS_MAX :: 256

// What a piece did this turn
Piece_Turn :: struct {
	// Its army attacked; each attacks at most once per turn
	attacked:       bool,
	movement_spent: f32,
}

// Two enemy pieces touching: the initiator (the one that moved in, or the player's army at a turn's end), and whether
// it was sent at the other
Contact_Event :: struct {
	initiator, other: Piece_Id,
	targeted:         bool,
}

// Something being resolved, waiting on the player's answer. Nil actor = none open.
Interaction :: struct {
	// In a battle: attacker and defender
	actor, target: Piece_Id,
	stage:         Interaction_Stage,
	// Meet_Town: computed when opened
	conquerable:   bool,
	// Battle: both sides as they stood when announced; fought on the first Next
	battle:        Battle,
	result:        Battle_Result,
}

Interaction_Stage :: enum u8 {
	// Met a piece that isn't an army: Conquer or Leave
	Meet_Town,
	// Battle, advanced by Next. Who attacks whom, before it's fought.
	Announce,
	// What happened in the battle
	Report,
	// What it cost each side
	Outcome,
	// The loser falls back, the winner trailing as it chose
	Fall_Back,
	// An ordered attack the commander won't make; closes on Next
	Refused,
}

Movement :: struct {
	// Walking piece, nil = none
	subject:        Piece_Id,
	// Smoothed path. cost[i] = cost per cell from point i-1 to i. next = point being walked to.
	path:           [dynamic; WALK_POINTS_MAX][2]f32,
	cost:           [dynamic; WALK_POINTS_MAX]f32,
	next:           int,
	target:         Piece_Id,
	// Ends once outside its zone and the chaser has stopped; nil = at the path's end
	clear_of:       Piece_Id,
	// Trails the subject, stepping onto the path at point 0; to the end when chaser_follows, else to point 0. Stops
	// on reaching the subject or spending chaser_budget movement points.
	chaser:         Piece_Id,
	chaser_next:    int,
	chaser_follows: bool,
	chaser_budget:  f32,
	// Reach of the focus. Nil subject and 0 key = none. Key hashes all flood inputs; recomputed only on change.
	flood:          Pathfind_Flood,
	enemy_zones:    [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones:   [dynamic; PIECE_MAX]util.Disc,
	bodies:         [dynamic; PIECE_MAX]util.Disc,
	flood_subject:  Piece_Id,
	flood_key:      u64,
}

// pos moved along path toward point next, up to step cells, ending at point last or once max_due movement points are
// due. The leg onto point 0 costs like the first segment.
walk_along :: proc(
	pos: [2]f32,
	path: [][2]f32,
	cost: []f32,
	next, last: int,
	step, max_due: f32,
) -> (
	moved: [2]f32,
	reached: int,
	road, off_road: f32,
) {
	moved, reached = pos, next
	step := step
	for step > 0 && reached <= last && road + off_road < max_due {
		target := path[reached]
		segment_cost := cost[clamp(reached, 1, len(cost) - 1)]
		distance := linalg.distance(moved, target)
		walked := min(step, distance)
		if segment_cost > 0 do walked = min(walked, (max_due - road - off_road) / segment_cost)
		moved = walked < distance ? moved + linalg.normalize(target - moved) * walked : target
		step -= walked
		if walked == distance do reached += 1
		// Road cells always cost exactly ROAD_COST
		if segment_cost == ROAD_COST do road += walked * segment_cost
		else do off_road += walked * segment_cost
	}
	return
}

// 0 for a stale or nil id
movement_budget :: proc(id: Piece_Id) -> f32 {
	piece := piece_get(id)
	if piece == nil do return 0
	return max(0, piece.movement_per_turn - WORLD.piece_turns[id.index].movement_spent)
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
		around := util.cell_rect_clip(
			util.cell_rect_around(util.grid_pos(i, WORLD_SIZE), PASS_REACH),
			WORLD_SIZE,
		)
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
					supply = piece.supply,
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
	supply_map_build(WORLD.player)
	return ok
}

world_step :: proc(input: Step_Input) {
	mov := &WORLD.movement

	// Step: End Turn Request
	// Ending the turn is a request: the player's armies sitting in an enemy army's zone make contact, then the turn
	// ends once every contact is resolved and nothing is open
	if input.end_turn && turn_endable() {
		WORLD.ending = true
		for piece, index in WORLD.pieces {
			if !piece_alive(piece) || piece.owner != WORLD.player || !WORLD.armies[index].active do continue
			for other, other_index in WORLD.pieces {
				if !piece_alive(other) || pieces_friendly(piece, other) || !WORLD.armies[other_index].active do continue
				if linalg.distance(piece.pos, other.pos) >= other.contact.radius do continue
				append(
					&WORLD.contacts,
					Contact_Event{piece_id(index), piece_id(other_index), false},
				)
			}
		}
	}

	// This tick's order, if any: at most one piece is sent to walk per tick
	order:          struct {
		piece:          Piece_Id,
		// Toward the target's contact zone when set, else toward destination (snapped within a square of snap cells)
		destination:    [2]f32,
		snap:           int,
		target:         Piece_Id,
		// Movement points the walk may use; 0 = the piece's movement budget left
		budget:         f32,
		// Its zone doesn't slow the walk
		unhindered_by:  Piece_Id,
		// See Movement
		clear_of:       Piece_Id,
		chaser:         Piece_Id,
		chaser_follows: bool,
		chaser_budget:  f32,
	}

	// Step: Interaction
	// Answers to the open interaction. A battle advances on Next once nothing walks.
	// Battle and chase losses, for the Armies step
	losses: [Battle_Role]struct {
		army:                  Piece_Id,
		men, readiness, stock: f32,
	}
	if open := &WORLD.interaction; open.actor != {} {
		if open.stage == .Meet_Town {
			if input.answer == .Conquer && open.conquerable {
				actor, conquered := piece_get(open.actor), piece_get(open.target)
				if actor != nil && conquered != nil do conquered.owner = actor.owner
				open^ = {}
			} else if input.answer == .Leave {
				open^ = {}
			}
		} else if input.answer == .Next && mov.subject == {} {
			result := open.result
			roles := [Battle_Role]Piece_Id {
				.Attacker = open.actor,
				.Defender = open.target,
			}
			loser_role := OTHER_ROLE[result.winner]
			loser := roles[loser_role]
			winner := roles[result.winner]
			close := true
			#partial switch open.stage {
			case .Announce:
				open.result = combat_resolve(open.battle)
				for id, role in roles {
					side := open.result.sides[role]
					losses[role] = {id, side.men, side.readiness, side.stock}
				}
				open.stage = .Report
				close = false
			case .Report:
				open.stage = .Outcome
				close = false
			case .Outcome:
				// Dissolved armies leave the map
				for side, role in result.sides do if side.dissolved do piece_despawn(roles[role])

				// Fall back away from the winner: the chase's length when caught, else until clear of the winner. The
				// winner trails within movement left plus the temperament's overdraw. Chase losses land here.
				beaten, victor := piece_get(loser), piece_get(winner)
				if !result.sides[loser_role].falls_back || beaten == nil || victor == nil do break
				reach: f32 = result.caught ? CHASE_BUDGET : FALL_BACK_BUDGET
				order = {
					piece         = loser,
					destination   = beaten.pos + linalg.normalize0(beaten.pos - victor.pos) * reach,
					snap          = 2 * int(reach) + 1,
					budget        = reach,
					unhindered_by = winner,
				}
				if !result.caught do order.clear_of = winner
				if result.follow != .Stay {
					temperament := open.battle.sides[result.winner].temperament
					order.chaser = winner
					order.chaser_follows = result.caught
					order.chaser_budget = movement_budget(winner) + TEMPERAMENT_FOLLOW_OVERDRAW[temperament]
				}
				side := result.sides[loser_role]
				if result.caught do losses[loser_role] = {loser, side.pursuit_men, side.pursuit_readiness, 0}
				open.stage = .Fall_Back
				close = false
			}
			if close do open^ = {}
		}
	}

	// Step: Contacts
	// Oldest first, until one opens an interaction. A contact holds while both live, are enemies and touch. Between
	// armies the initiator attacks, else the other may intercept; a refused ordered attack is announced. Other enemy
	// pieces are met.
	for len(WORLD.contacts) > 0 && WORLD.interaction.actor == {} {
		contact := WORLD.contacts[0]
		ordered_remove(&WORLD.contacts, 0)
		initiator, other := piece_get(contact.initiator), piece_get(contact.other)
		if initiator == nil || other == nil || pieces_friendly(initiator^, other^) do continue
		reach := max(initiator.contact.radius, other.contact.radius)
		if linalg.distance(initiator.pos, other.pos) >= reach do continue

		if !WORLD.armies[contact.initiator.index].active ||
		   !WORLD.armies[contact.other.index].active {
			WORLD.interaction = {
				actor       = contact.initiator,
				target      = contact.other,
				stage       = .Meet_Town,
				conquerable = .Captures in initiator.traits && .Capturable in other.traits,
			}
			continue
		}

		ids := [2]Piece_Id{contact.initiator, contact.other}
		sides: [2]Battle_Side
		for id, i in ids {
			army := WORLD.armies[id.index]
			sides[i] = {
				men         = f32(army.men),
				men_max     = f32(army.men_max),
				proficiency = army.proficiency,
				readiness   = army.readiness,
				stock       = army.stock,
				baggage     = army.baggage,
				mobility    = army.mobility,
				temperament = army.temperament,
			}
		}
		gap := battle_strength(sides[0], sides[1]) - battle_strength(sides[1], sides[0])
		ordered: f32 = contact.targeted ? ORDERED_INITIATIVE : 0
		initiative := [2]f32 {
			TEMPERAMENT_ATTACK_INITIATIVE[sides[0].temperament] + ordered,
			TEMPERAMENT_ATTACK_INITIATIVE[sides[1].temperament] + INTERCEPT_INITIATIVE,
		}
		fresh := [2]bool {
			!WORLD.piece_turns[ids[0].index].attacked,
			!WORLD.piece_turns[ids[1].index].attacked,
		}
		switch {
		case fresh[0] && gap + initiative[0] >= 0:
		case fresh[1] && -gap + initiative[1] >= 0:
			ids[0], ids[1] = ids[1], ids[0]
			sides[0], sides[1] = sides[1], sides[0]
		case contact.targeted:
			WORLD.interaction = {
				actor = ids[0],
				target = ids[1],
				stage = .Refused,
				battle = {sides = {.Attacker = sides[0], .Defender = sides[1]}},
			}
			continue
		case:
			continue
		}
		WORLD.piece_turns[ids[0].index].attacked = true
		WORLD.interaction = {
			actor = ids[0],
			target = ids[1],
			stage = .Announce,
			battle = {
				sides = {.Attacker = sides[0], .Defender = sides[1]},
				can_avoid = true,
				seed = util.hash_contents(WORLD.turn, WORLD.player, ids[0], ids[1]),
			},
		}
	}

	// Step: Player Order
	// Unless the battle sent someone this tick; only for a piece the player controls
	if order.piece == {} && input.order != nil {
		player_piece: Piece_Id
		switch player_order in input.order {
		case Move_To_Point:
			player_piece = player_order.piece
			order.destination, order.snap = player_order.destination, player_order.snap
		case Move_To_Piece:
			player_piece = player_order.piece
			order.target = player_order.target
		}
		if piece := piece_get(player_piece);
		   piece != nil && ordering() != {} && piece.owner == ordering() {
			order.piece = player_piece
		}
	}

	// Step: Movement Flood
	// Where this tick's ordered piece can walk, else the focus (for showing its reach)
	{
		flooded := order.piece != {} ? order.piece : input.focus
		zones, bodies := &mov.enemy_zones, &mov.bodies
		clear(zones)
		clear(bodies)
		clear(&mov.friend_zones)
		subject := piece_get(flooded)
		if subject == nil || subject.movement_domain == nil {
			mov.flood_subject, mov.flood_key = {}, 0
		} else {
			domain := subject.movement_domain.(Pathfind_Domain)
			budget :=
				order.piece != {} && order.budget > 0 ? order.budget : movement_budget(flooded)

			// Gather bodies (can't stop on), enemy zones (slow, no roads) and friendly contacts touching the flood
			// square, padded a cell for rounding
			half: f32 = PATHFIND_FLOOD_SIZE / 2 + 1
			square := [4]f32{subject.pos.x - half, subject.pos.y - half, 2 * half, 2 * half}
			for other, index in WORLD.pieces {
				if !piece_alive(other) || piece_id(index) == flooded do continue
				body := util.Disc{other.pos, subject.body + other.body}
				if util.disc_overlaps_rect(body, square) do append(bodies, body)
				if other.contact.radius == 0 || domain not_in other.contact.domains do continue
				contact := util.Disc{other.pos, other.contact.radius}
				if !util.disc_overlaps_rect(contact, square) do continue
				if pieces_friendly(subject^, other) {
					append(&mov.friend_zones, contact)
				} else if piece_id(index) != order.unhindered_by {
					append(zones, Pathfind_Zone{contact, other.hindrance})
				}
			}

			// Reflood only when an input changed
			key := util.hash_contents(flooded, subject.pos, budget, domain, zones[:], bodies[:])
			if key != mov.flood_key {
				pathfind_flood(subject.pos, domain, budget, zones[:], bodies[:], &mov.flood)
				mov.flood_subject, mov.flood_key = flooded, key
			}
		}
	}

	// Step: Orders
	// Start this tick's walk along the flood's cheapest path, smoothed
	if order.piece != {} && mov.flood_subject == order.piece {
		stop: [2]int
		ok: bool
		if target := piece_get(order.target); target != nil {
			if mov.flood.domain in target.contact.domains {
				stop, ok = pathfind_flood_stop_within(
					&mov.flood,
					util.Disc{target.pos, target.contact.radius},
				)
			}
		} else {
			stop, ok = pathfind_flood_stop(&mov.flood, order.destination, order.snap)
		}
		path: [dynamic; PATH_MAX_LEN][2]f32
		cost: [dynamic; PATH_MAX_LEN]f32
		if ok && pathfind_flood_trace(&mov.flood, util.cell_center(stop), &path, &cost) {
			mov.subject, mov.target = order.piece, order.target
			clear(&mov.path)
			clear(&mov.cost)
			append(&mov.path, piece_get(order.piece).pos)
			append(&mov.cost, 0)
			append(&mov.path, ..path[:])
			append(&mov.cost, ..cost[:])
			mov.next = 1
			mov.clear_of = order.clear_of
			mov.chaser = order.chaser
			mov.chaser_next = 0
			mov.chaser_follows = order.chaser_follows
			mov.chaser_budget = order.chaser_budget

			// Smooth; cut points keep their segment's cost
			n := len(mov.path)
			resize(&mov.path, n << WALK_CUTS)
			resize(&mov.cost, n << WALK_CUTS)
			n = util.smooth_polyline(mov.path[:], n, false, WALK_SMOOTHING, mov.cost[:])
			resize(&mov.path, n)
			resize(&mov.cost, n)
		} else {
			fmt.eprintfln("No way for %v", order.piece)
		}
	}

	// Step: Walk
	// What the subject, then its chaser, did this step. Nil piece = didn't walk.
	walks: [2]struct {
		piece:            Piece_Id,
		// Movement points, all of the walk
		marched_road:     f32,
		marched_off_road: f32,
		// Movement points beyond the budget
		overdrawn:        f32,
	}
	if subject := piece_get(mov.subject); subject != nil {
		before := subject.pos
		last := len(mov.path) - 1

		// Subject: holds while clear of clear_of's zone
		clear_of := piece_get(mov.clear_of)
		clear := clear_of != nil && !util.disc_contains({clear_of.pos, clear_of.contact.radius}, subject.pos)
		if !clear {
			moved, reached, road, off_road := walk_along(
				subject.pos,
				mov.path[:],
				mov.cost[:],
				mov.next,
				last,
				WALK_PER_STEP,
				math.INF_F32,
			)
			subject.pos = moved
			mov.next = reached
			walks[0] = {mov.subject, road, off_road, 0}
		}

		// Chaser: stops on reaching the subject, its last point or the end of its budget
		chasing: bool
		if chaser := piece_get(mov.chaser); chaser != nil {
			until := mov.chaser_follows ? last : 0
			touching := linalg.distance(chaser.pos, subject.pos) <= chaser.body + subject.body
			chasing = !touching && mov.chaser_next <= until && mov.chaser_budget > 0
			if chasing {
				moved, reached, road, off_road := walk_along(
					chaser.pos,
					mov.path[:],
					mov.cost[:],
					mov.chaser_next,
					until,
					WALK_PER_STEP,
					mov.chaser_budget,
				)
				chaser.pos = moved
				mov.chaser_next = reached
				mov.chaser_budget -= road + off_road
				walks[1] = {mov.chaser, road, off_road, 0}
			}
		}

		// Pay from the budget; the rest is overdrawn
		for &walk in walks {
			if walk.piece == {} do continue
			due := walk.marched_road + walk.marched_off_road
			spent := min(due, movement_budget(walk.piece))
			WORLD.piece_turns[walk.piece.index].movement_spent += spent
			walk.overdrawn = due - spent
		}

		// Contact: entering an enemy zone ends the walk (not while an interaction plays out its walks)
		met: Piece_Id
		domain := subject.movement_domain.(Pathfind_Domain)
		if WORLD.interaction.actor == {} do for other, index in WORLD.pieces {
			if !piece_alive(other) || piece_id(index) == mov.subject || pieces_friendly(subject^, other) do continue
			if other.contact.radius == 0 || domain not_in other.contact.domains do continue
			zone := util.Disc{other.pos, other.contact.radius}
			if util.disc_contains(zone, subject.pos) && !util.disc_contains(zone, before) {
				met = piece_id(index)
				break
			}
		}

		if met != {} || ((mov.next > last || clear) && !chasing) {
			if met == {} do met = mov.target
			if met != {} do append(&WORLD.contacts, Contact_Event{mov.subject, met, met == mov.target})
			mov.subject, mov.target, mov.next = {}, {}, 0
			mov.clear_of, mov.chaser = {}, {}
		}
	} else {
		// Walker gone
		mov.subject, mov.target, mov.next = {}, {}, 0
		mov.clear_of, mov.chaser = {}, {}
	}

	// The turn ends now if it was asked to and everything is settled
	turn_ending :=
		WORLD.ending &&
		len(WORLD.contacts) == 0 &&
		WORLD.interaction.actor == {} &&
		mov.subject == {}

	// Step: Armies
	for &army, index in WORLD.armies {
		if !army.active do continue
		piece := WORLD.pieces[index]
		readiness := army.readiness
		stock := army.stock

		// Battle and chase losses
		for loss in losses {
			if loss.army == {} || int(loss.army.index) != index do continue
			army.men = max(0, army.men + int(math.round(loss.men)))
			readiness += loss.readiness
			stock += loss.stock
		}

		// Resupply, live for the player's armies: the better of network and foraging, each as men fed over own men,
		// times that source's efficiency. The supply map is the player's.
		if piece.owner == WORLD.player {
			men := f32(army.men)
			cell := util.cell_of(piece.pos)
			network, network_efficiency, forage, forage_efficiency: f32
			if util.grid_contains(cell, WORLD_SIZE) && men > 0 {
				at := util.grid_index(cell, WORLD_SIZE)

				// Men nearby, weighted by distance: friendly ones, and everyone (any faction)
				friendly_men, all_men: f32
				for other, other_index in WORLD.armies {
					if !other.active do continue
					other_piece := WORLD.pieces[other_index]
					distance := linalg.distance(piece.pos, other_piece.pos)
					if distance >= FORAGE_RADIUS do continue
					weighted := f32(other.men) * (1 - distance / FORAGE_RADIUS)
					all_men += weighted
					if other_piece.owner == piece.owner do friendly_men += weighted
				}

				// Network: the supply map here, shared with friendly armies nearby
				network_efficiency = men / friendly_men
				network = f32(WORLD.supply_map[at]) * MEN_PER_SUPPLY / men * network_efficiency

				// Foraging: the land's yield times the army's skill, shared with every army nearby
				land := WORLD.atlas.terrain[at]
				yield: f32
				if land.surface == .Land {
					yield = math.lerp(
						FORAGE_YIELD[.Open],
						FORAGE_YIELD[land.type],
						util.normalized(land.type_strength),
					)
				}
				forage_efficiency = men / all_men
				forage = army.foraging * yield * MEN_PER_SUPPLY / men * forage_efficiency
			}
			fed := network
			army.resupply_source = .Network
			army.resupply_efficiency = network_efficiency
			if forage > network {
				fed = forage
				army.resupply_source = .Foraging
				army.resupply_efficiency = forage_efficiency
			}
			army.resupply = min(fed, 1 + SUPPLY_REFILL_MAX) - 1
		}

		// Marching
		for walk in walks {
			if walk.piece == {} || int(walk.piece.index) != index do continue
			readiness -= walk.marched_road * ROAD_READINESS_PER_MOVEMENT
			readiness -= walk.marched_off_road * READINESS_PER_MOVEMENT
			readiness -= walk.overdrawn * OVERDRAW_READINESS
			stock -= walk.marched_road * ROAD_STOCK_PER_MOVEMENT
			stock -= walk.marched_off_road * STOCK_PER_MOVEMENT
		}
		// End of its faction's turn: supplies in and out, then rest toward what the stock allows
		if turn_ending && piece.owner == WORLD.player {
			stock += army.resupply
			stock = clamp(stock, 0, army.baggage)
			cap: f32 = army.baggage > 0 ? 100 * stock / army.baggage : 0
			exertion: f32 =
				piece.movement_per_turn > 0 ? 1 - movement_budget(piece_id(index)) / piece.movement_per_turn : 0
			rest := (1 - exertion) * (1 - exertion)
			if readiness < cap {
				readiness = min(cap, readiness + READINESS_RECOVERY * rest)
			} else {
				readiness = max(cap, readiness - SUPPLY_DRAG)
			}
		}
		army.readiness = clamp(readiness, 0, 100)
		army.stock = clamp(stock, 0, army.baggage)
	}

	// Step: Turn End
	// Next faction plays; wrapping past the last slot starts a new turn
	if turn_ending {
		WORLD.ending = false
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

	// Step: Turn Start
	if turn_ending {
		WORLD.piece_turns = {}
		supply_map_build(WORLD.player)
	}
}

// Rebuilds the supply map for a faction: spread from its sources, slowed by everyone else's zones
supply_map_build :: proc(faction: Faction_Id) {
	sources: [dynamic; PIECE_MAX]Pathfind_Source
	zones: [dynamic; PIECE_MAX]Pathfind_Zone
	for piece in WORLD.pieces {
		if !piece_alive(piece) do continue
		if piece.owner == faction {
			if piece.supply > 0 do append(&sources, Pathfind_Source{piece.pos, piece.supply})
		} else if piece.contact.radius > 0 && .Land in piece.contact.domains {
			append(&zones, Pathfind_Zone{{piece.pos, piece.contact.radius}, piece.hindrance})
		}
	}
	spread := make([]f32, CELLS_MAX, context.temp_allocator)
	pathfind_spread(.Land, sources[:], zones[:], SUPPLY_DECAY, spread)
	for value, i in spread do WORLD.supply_map[i] = u8(clamp(value, 0, 100) + 0.5)
	WORLD.supply_map_revision += 1
}

// The player, or nil while an interaction is open
ordering :: proc() -> Faction_Id {
	return(
		WORLD.interaction.actor == {} && !WORLD.ending ? WORLD.player : {} \
	)
}

turn_endable :: proc() -> bool {
	return(
		!WORLD.ending &&
		WORLD.movement.subject == {} &&
		len(WORLD.contacts) == 0 &&
		WORLD.interaction.actor == {} \
	)
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
	// Enemies entering it must stop
	contact:           Contact,
	// Radius in cells; other pieces can't stop overlapping it
	body:              f32,
	// Enemy movement cost multiplier inside its contact zone
	hindrance:         f32,
	traits:            bit_set[Piece_Trait;u8],
	general:           Character_Id,
	// Supply source value, 0 = not a source
	supply:            f32,
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
	WORLD.piece_turns[index] = {}
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
