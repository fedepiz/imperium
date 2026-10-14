package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"

STEPS_PER_SECOND :: 60
STEP_SECONDS :: 1.0 / f32(STEPS_PER_SECOND)

CONTACTS_MAX :: 256

WALK_SMOOTHING :: Polyline_Smoothing {
	softness    = 1,
	soften_iter = 2,
	cut_iter    = 2,
	cut_ratio   = 0.25,
}
WALK_POINTS_MAX :: (PATHFIND_PATH_MAX + 1) << uint(WALK_SMOOTHING.cut_iter)

@(private = "file")
WALK_CELLS_PER_STEP :: 10 * STEP_SECONDS
@(private = "file")
SAIL_CELLS_PER_STEP :: 40 * STEP_SECONDS
// In cells along the lanes
@(private = "file")
SEA_RANGE :: 300
@(private = "file")
ROAD_READINESS_PER_MOVEMENT :: 0.2
@(private = "file")
READINESS_PER_MOVEMENT :: 1
@(private = "file")
OVERDRAW_READINESS :: 2
// Most readiness gained or lost per turn moving toward the supply level
@(private = "file")
READINESS_SPEED :: 10
@(private = "file")
SUPPLY_DECAY :: 2
@(private = "file")
MEN_PER_SUPPLY :: 250
// Share of full strength regained per turn on home land, at 100% supply
@(private = "file")
REINFORCEMENT_SHARE :: 0.05
// Share of its men an army above its full strength loses per turn
@(private = "file")
DESERTION_SHARE :: 0.05
@(private = "file")
PIECES_TO_REMOVE_MAX :: 32
// Share of its full strength a demobilised title gathers per turn
@(private = "file")
TITLE_GATHER_SHARE :: 0.05
@(private = "file")
MOBILISE_READINESS :: 50
// Share of the gap to its target closed per turn, never less than INFLUENCE_STEP_MIN
@(private = "file")
INFLUENCE_RATE :: 0.1
@(private = "file")
INFLUENCE_STEP_MIN :: 1
// Per coin of wealth
@(private = "file")
INFLUENCE_PER_WEALTH :: 2
// Gained when an appointment raises his rank
@(private = "file")
PROMOTED_LOYALTY :: 10
// In turns: at least, and below
@(private = "file")
NEW_CHARACTER_AGE :: [2]int{20, 40}
@(private = "file")
NEW_CHARACTER_INFLUENCE :: 5
@(private = "file")
NEW_CHARACTER_LOYALTY :: 50
// Control lost per unit of travel cost from its source
@(private = "file")
CONTROL_DECAY :: 1
// Path cost per cell along a sea lane
@(private = "file")
SEA_LANE_COST :: 0.2
@(private = "file")
FOOD_PER_POPULATION :: 1
// Share of the gap to what food supports closed per turn, and the most it grows per turn, as a share of itself
@(private = "file")
POPULATION_RATE :: 0.05
@(private = "file")
POPULATION_GROWTH_MAX :: 0.02
@(private = "file")
FALL_BACK_BUDGET :: 10
@(private = "file")
CHASE_BUDGET :: 15
@(private = "file")
SUPPLY_RADIUS :: 12
@(private = "file")
NO_GENERAL_TEMPERAMENT :: Temperament.Steady
// Engaged share of the side outside the walls in a sortie
@(private = "file")
SORTIE_ENEMY_SHARE :: 0.5
@(private = "file")
SPENT_READINESS :: 25
@(private = "file")
SPENT_CLEAR_READINESS :: 50
@(private = "file")
BATTLE_PREDICTION_RUNS :: 100

// By whether the marcher won, then by the battle's outcome
@(private = "file", rodata)
BATTLE_FORECASTS := [2][Battle_Outcome]Battle_Forecast {
	{
		.None = .No_Battle,
		.Avoided = .Evasion,
		.Stalemate = .Stalemate,
		.Probed = .Close_Win,
		.Withdrew = .Close_Win,
		.Repulsed = .Close_Win,
		.Defeat = .Clear_Win,
		.Heavy_Defeat = .Clear_Win,
		.Rout = .Clear_Win,
	},
	{
		.None = .No_Battle,
		.Avoided = .Evasion,
		.Stalemate = .Stalemate,
		.Probed = .Close_Defeat,
		.Withdrew = .Close_Defeat,
		.Repulsed = .Close_Defeat,
		.Defeat = .Clear_Defeat,
		.Heavy_Defeat = .Clear_Defeat,
		.Rout = .Clear_Defeat,
	},
}

@(private = "file", rodata)
FORAGE_YIELD := [Render_Cover]f32 {
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

Move_Order :: struct {
	piece:       Piece_Id,
	target:      Piece_Id,
	destination: [2]f32,
	snap:        int,
}

// At most one a step
Game_Order :: union {
	Move_Order,
	Town_Order,
	Title_Order,
	Appoint_Order,
	Dismiss_Order,
	End_Turn_Order,
	Next_Order,
}

End_Turn_Order :: struct {}

// Past the battle report's stage
Next_Order :: struct {}

Town_Action :: enum u8 {
	Build,
	Demolish,
	Cancel,
}

Town_Order :: struct {
	town:   Piece_Id,
	slot:   int,
	action: Town_Action,
	// Build: the building
	kind:   Building_Kind_Id,
}

Title_Action :: enum u8 {
	Mobilise,
	Demobilise,
}

Appoint_Order :: struct {
	office:    Office_Id,
	character: Character_Id,
}

Dismiss_Order :: struct {
	office: Office_Id,
}

Title_Order :: struct {
	office: Office_Id,
	action: Title_Action,
}

Contact :: struct {
	initiator: Piece_Id,
	other:     Piece_Id,
	targeted:  bool,
}

Interaction_Stage :: enum u8 {
	Announce,
	Report,
	Outcome,
	Fall_Back,
	Refused,
}

Interaction :: struct {
	actor:  Piece_Id,
	target: Piece_Id,
	stage:  Interaction_Stage,
	result: Battle_Result,
}

// How a battle goes, for one side
Battle_Forecast :: enum u8 {
	Clear_Win,
	Close_Win,
	Stalemate,
	Close_Defeat,
	Clear_Defeat,
	Evasion,
	No_Battle,
}

// Each step: the last prediction's marcher, as it would arrive, and its target, each attacking the other
// BATTLE_PREDICTION_RUNS times. Runs 0: none
Battle_Prediction :: struct {
	marcher:  Piece_Id,
	target:   Piece_Id,
	runs:     int,
	// For the marcher. Shares of the runs, 0..1
	outcomes: [Battle_Forecast]f32,
	// The marcher's first, from the first run
	power:    [2]Report_Tally,
}

// The ordered piece, and the piece pursuing it
Mover :: enum u8 {
	Leader,
	Chaser,
}

// Spent per cell walked: movement on and off road, and readiness
March_Rate :: struct {
	road:      f32,
	off_road:  f32,
	readiness: f32,
}

// One piece's walk along its own smoothed path
March :: struct {
	piece:    Piece_Id,
	// Contacted on arrival
	target:   Piece_Id,
	// Entered on arrival
	into:     Piece_Id,
	// The walk ends once outside its zone
	clear_of: Piece_Id,
	path:     Polylines(WALK_POINTS_MAX, 1),
	// On the segment ending at each point. [0] unused
	rates:    [dynamic; WALK_POINTS_MAX]March_Rate,
	next:     int,
	sails:    bool,
	// The whole walk's
	movement_spent: f32,
	readiness_lost: f32,
}

// What a move order would do. Its march's piece: none when it has no route
March_Prediction :: struct {
	march:         March,
	// Its piece's, on arrival
	movement_left: f32,
	readiness:     f32,
	statuses:      bit_set[Army_Status],
}

Sea_Reach :: struct {
	piece:      Piece_Id,
	// 0: not at a beach
	start:      Beach_Id,
	// In cells along the lanes. INF: out of reach
	cost:       [BEACHES_MAX]f32,
	reached_by: [BEACHES_MAX]Sea_Lane_Id,
	// Reached and unoccupied
	landable:   bit_set[0 ..< BEACHES_MAX],
}

Movement :: struct {
	marches:      [Mover]March,
	sea_reach:    Sea_Reach,
	flood:        Pathfind_Flood,
	flooded:      Piece_Id,
	flood_key:    u64,
	enemy_zones:  [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones: [dynamic; PIECE_MAX]Disc,
	bodies:       [dynamic; PIECE_MAX]Disc,
	// Each step: the move ordered, else the move hovered while nothing is under way. Its piece none: neither
	predicted:    Move_Order,
	prediction:   March_Prediction,
}

GAME_EVENTS_MAX :: 2048

Order_Refusal :: enum u8 {
	Superseded,
	No_Such_Piece,
	Not_Now,
	Not_Yours,
	Cannot_Move,
	No_Route,
}

Contact_Outcome :: enum u8 {
	Lapsed,
	Met,
	Battle,
	Refused,
	Declined,
}

Army_Change :: enum u8 {
	Battle,
	Chase,
	March,
	Turn_End,
}

Event_End_Turn :: struct {
	accepted: bool,
}

Event_Order_Refused :: struct {
	piece:  Piece_Id,
	reason: Order_Refusal,
}

Event_March :: struct {
	piece:  Piece_Id,
	mover:  Mover,
	target: Piece_Id,
	to:     [2]f32,
	sails:  bool,
}

Event_Moved :: struct {
	piece:         Piece_Id,
	pos:           [2]f32,
	movement_left: f32,
	overdrawn:     f32,
}

Event_Arrived :: struct {
	piece: Piece_Id,
	pos:   [2]f32,
}

Event_Enter :: struct {
	piece:      Piece_Id,
	settlement: Piece_Id,
}

Event_Exit :: struct {
	piece:      Piece_Id,
	settlement: Piece_Id,
}

Event_Contact :: struct {
	initiator: Piece_Id,
	other:     Piece_Id,
	targeted:  bool,
	outcome:   Contact_Outcome,
}

Event_Interaction :: struct {
	actor:  Piece_Id,
	target: Piece_Id,
	stage:  Interaction_Stage,
	closed: bool,
}

Event_Conquered :: struct {
	piece: Piece_Id,
	by:    Piece_Id,
	from:  Faction_Id,
	to:    Faction_Id,
}

Event_Removed :: struct {
	piece: Piece_Id,
}

Event_Army :: struct {
	piece:   Piece_Id,
	changes: bit_set[Army_Change],
	army:    Army,
}

Event_Spent :: struct {
	piece:     Piece_Id,
	readiness: f32,
}

Event_Unspent :: struct {
	piece: Piece_Id,
}

Event_Turn :: struct {
	turn:   int,
	player: Faction_Id,
}

// Kind 0: a demolition
Event_Project_Started :: struct {
	town: Piece_Id,
	slot: int,
	kind: Building_Kind_Id,
}

Event_Project_Cancelled :: struct {
	town: Piece_Id,
	slot: int,
}

// Kind 0: demolished
Event_Project_Finished :: struct {
	town: Piece_Id,
	slot: int,
	kind: Building_Kind_Id,
}

Event_Mobilised :: struct {
	army:   Piece_Id,
	office: Office_Id,
}

Event_Demobilised :: struct {
	army:   Piece_Id,
	office: Office_Id,
}

Event_Dismissed :: struct {
	office:    Office_Id,
	character: Character_Id,
}

// Vacated: the office he left, if any
Event_Appointed :: struct {
	office:    Office_Id,
	character: Character_Id,
	vacated:   Office_Id,
}

Game_Event :: union {
	Event_End_Turn,
	Event_Order_Refused,
	Event_March,
	Event_Moved,
	Event_Arrived,
	Event_Enter,
	Event_Exit,
	Event_Contact,
	Event_Interaction,
	Event_Conquered,
	Event_Removed,
	Event_Army,
	Event_Spent,
	Event_Unspent,
	Event_Turn,
	Event_Project_Started,
	Event_Project_Cancelled,
	Event_Project_Finished,
	Event_Mobilised,
	Event_Demobilised,
	Event_Appointed,
	Event_Dismissed,
}

// The marches a step plans, in order. Move: the one ordered, else the selected piece's
@(private = "file")
Planned_March :: enum u8 {
	Leader,
	Chaser,
	Move,
}

@(private = "file")
Walk_Order :: struct {
	piece:       Piece_Id,
	target:      Piece_Id,
	into:        Piece_Id,
	destination: [2]f32,
	snap:        int,
	// 0: the piece's movement left
	budget:      f32,
	// Its zone and body are left out of the flood
	ignored:     Piece_Id,
	clear_of:    Piece_Id,
	// Chaser: heads where the leader ends, not where it starts
	follows:     bool,
	// False: only flooded, for its reach
	aimed:       bool,
}

// Built at load and each turn change. Supply: the strongest source, kept out of enemy zones. Control: the strongest
// source, within the owner's regions, up to 100
game_networks_build :: proc(game: ^Game) {
	spread := make([]f32, MAP_CELLS, context.temp_allocator)
	blocked := make([]bool, MAP_CELLS, context.temp_allocator)

	// Supply
	{
		sources: [dynamic; PIECE_MAX]Pathfind_Source
		it := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&it) {
			if piece.owner == game.player {
				if piece.supply_production > 0 {
					append(&sources, Pathfind_Source{piece.pos, piece.supply_production})
				}
			} else if piece.contact_radius > 0 && .Land in piece.contact_domains {
				// Enemy zones block the spread
				zone := Disc{piece.pos, piece.contact_radius}
				covered := cell_rect_clip(cell_rect_covering(zone.center - zone.radius, zone.center + zone.radius), MAP_SIZE)
				for y in covered.min.y ..< covered.max.y do for x in covered.min.x ..< covered.max.x {
					if disc_contains(zone, cell_center({x, y})) do blocked[grid_index({x, y}, MAP_SIZE)] = true
				}
			}
		}
		pathfind_spread(.Land, sources[:], blocked, nil, SUPPLY_DECAY, .Max, spread)
		for value, i in spread do game.supply_network[i] = u8(clamp(value, 0, 100) + 0.5)
	}

	// Control, per faction: never outside its regions
	lanes: [dynamic; SEA_LANES_MAX]Pathfind_Link
	for lane, l in game.sea_lanes {
		if l == 0 do continue
		ends := [2][2]int{cell_of(game.beaches[lane.from].pos), cell_of(game.beaches[lane.to].pos)}
		append(&lanes, Pathfind_Link{ends, lane.length * SEA_LANE_COST})
	}
	for faction in 1 ..< len(game.factions) {
		owner := Faction_Id(faction)
		for region, i in game.terrain.regions do blocked[i] = game.regions[region].owner != owner

		sources: [dynamic; PIECE_MAX]Pathfind_Source
		towns := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&towns) {
			if .Has_Town not_in piece.flags || piece.owner != owner do continue
			strength: f32
			for kind_id in piece.town.buildings do strength += game.building_kinds[kind_id].control
			if strength > 0 do append(&sources, Pathfind_Source{piece.pos, strength})
		}
		pathfind_spread(.Land, sources[:], blocked, lanes[:], CONTROL_DECAY, .Max, spread)
		if owner == game.player {
			for value, i in spread do game.control_network[i] = u8(clamp(value, 0, 100) + 0.5)
		}
		read := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&read) {
			if .Has_Town not_in piece.flags || piece.owner != owner do continue
			piece.town.control = min(spread[grid_index(cell_of(piece.pos), MAP_SIZE)], 100)
		}
	}
}

@(private = "file")
pieces_friendly :: proc(a, b: ^Piece_Data) -> bool {
	return a.owner != 0 && a.owner == b.owner
}

// Hover: the move order a right click would give, its piece none when there is none
game_step :: proc(
	game: ^Game,
	focus: Piece_Id,
	hover: Move_Order,
	input: Game_Order,
	events: ^[dynamic; GAME_EVENTS_MAX]Game_Event,
) {
	// The start step: taken by loading
	starting := game.step == 0
	game.step += 1
	movement := &game.movement

	_, ending := input.(End_Turn_Order)
	end_turn_accepted := ending && game.endable
	if ending do append(events, Event_End_Turn{end_turn_accepted})
	if end_turn_accepted {
		game.ending = true
		own := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&own) {
			if piece.owner != game.player || .Has_Army not_in piece.flags do continue
			enemies := slot_map_iterator(&game.pieces)
			for enemy, enemy_id in slot_map_iterate(&enemies) {
				if .Has_Army not_in enemy.flags || pieces_friendly(piece, enemy) do continue
				if linalg.distance(piece.pos, enemy.pos) >= enemy.contact_radius do continue
				append(&game.contacts, Contact{initiator = piece_id, other = enemy_id})
			}
		}
	}

	pieces_to_remove: [dynamic; PIECES_TO_REMOVE_MAX]Piece_Id

	// Step: Town order
	if order, ordered := input.(Town_Order); ordered && order.slot >= 0 && order.slot < TOWN_SLOT_COUNT {
		piece := slot_map_get(&game.pieces, order.town)
		if piece != nil && .Has_Town in piece.flags {
			town := &piece.town
			slot := order.slot
			allows := town.building_orders[slot]
			project := &town.projects[slot]
			switch order.action {
			case .Build:
				if int(order.kind) in allows.buildable {
					kind := &game.building_kinds[order.kind]
					game.factions[piece.owner].treasury -= kind.build_coin
					project^ = {
						active     = true,
						kind       = order.kind,
						turns_left = kind.build_turns,
					}
					append(events, Event_Project_Started{order.town, slot, order.kind})
				}
			case .Demolish:
				if allows.demolish {
					project^ = {
						active     = true,
						turns_left = 1,
					}
					append(events, Event_Project_Started{order.town, slot, 0})
				}
			case .Cancel:
				if allows.cancel {
					project^ = {}
					append(events, Event_Project_Cancelled{order.town, slot})
				}
			}
		}
	}

	// Step: Title order
	if order, ordered := input.(Title_Order); ordered && game.under_way == {} {
		office := slot_map_get(&game.offices, order.office)
		if office != nil && office.faction == game.player && game.office_kinds[office.kind].army_type != 0 {
			army_type_id := game.office_kinds[office.kind].army_type
			army_type := &game.army_types[army_type_id]
			switch order.action {
			case .Mobilise:
				at := slot_map_get(&game.pieces, office.muster_at)
				if office.can_mobilise && at != nil {
					mobilised := game.army_template
					mobilised.name = name_from_string(fmt.tprintf("%s of %s", name_to_string(&army_type.name), name_to_string(&at.name)))
					mobilised.owner = office.faction
					mobilised.culture = at.culture
					mobilised.flags += {.Has_Army}
					// Next to the town: the first land cell around it
					mobilised.pos = at.pos
					land := pathfind_grid(.Land)
					reach := at.body_radius + mobilised.body_radius + 1
					for i in 0 ..< 8 {
						angle := f32(i) * math.TAU / 8
						cell := at.pos + reach * [2]f32{math.cos(angle), math.sin(angle)}
						if grid_contains(cell_of(cell), MAP_SIZE) && land[grid_index(cell_of(cell), MAP_SIZE)] > 0 {
							mobilised.pos = cell
							break
						}
					}
					mobilised.army = {
						men         = office.men,
						men_max     = office.men_max,
						proficiency = army_type.proficiency,
						readiness   = MOBILISE_READINESS,
						foraging    = army_type.foraging,
						supply      = 100,
						type        = army_type_id,
						title       = order.office,
					}
					if army_type.scope == .Local {
						mobilised.army.home = Region_Id(game.terrain.regions[grid_index(cell_of(at.pos), MAP_SIZE)])
					}
					army := slot_map_insert(&game.pieces, mobilised)
					office.men = 0
					append(events, Event_Mobilised{army, order.office})
				}
			case .Demobilise:
				army := slot_map_get(&game.pieces, office.army)
				if army != nil {
					office.men = army.army.men
					append(events, Event_Demobilised{office.army, order.office})
					append(&pieces_to_remove, office.army)
				}
			}
		}
	}

	// Step: Appointment order
	if order, ordered := input.(Appoint_Order); ordered && game.appointment.can_appoint && order.office == game.appointment.office {
		chosen := -1
		for candidate, c in game.appointment.candidates do if candidate.character == order.character do chosen = c
		office := slot_map_get(&game.offices, order.office)
		if chosen >= 0 && office != nil && office.holder == 0 {
			character := &game.characters[order.character]
			kind := &game.office_kinds[office.kind]
			for candidate in game.appointment.candidates[:chosen] {
				passed := &game.characters[candidate.character]
				if passed.rank > character.rank do passed.loyalty = max(0, passed.loyalty - PASSED_OVER_LOYALTY)
			}
			vacated := character.office
			if old := slot_map_get(&game.offices, vacated); old != nil do old.holder = 0
			office.holder = order.character
			office.term_left = kind.term
			if character.rank < kind.rank {
				character.rank = kind.rank
				character.loyalty = min(100, character.loyalty + PROMOTED_LOYALTY)
			}
			append(events, Event_Appointed{order.office, order.character, vacated})
		}
	}

	// Step: Dismissal order
	if order, ordered := input.(Dismiss_Order); ordered {
		office := slot_map_get(&game.offices, order.office)
		if office != nil && office.holder != 0 && office.dismissal == .Allowed {
			if .Feudal in game.office_kinds[office.kind].flags {
				fiefs := slot_map_iterator(&game.offices)
				for fief in slot_map_iterate(&fiefs) {
					if fief.faction != office.faction || fief.holder == 0 || .Feudal not_in game.office_kinds[fief.kind].flags do continue
					holder := &game.characters[fief.holder]
					holder.loyalty = max(0, holder.loyalty - FEUDAL_DISMISSAL_LOYALTY)
				}
			}
			append(events, Event_Dismissed{order.office, office.holder})
			office.holder = 0
		}
	}

	orders: [Mover]Walk_Order
	losses: [2]struct {
		army:      Piece_Id,
		change:    Army_Change,
		men:       f32,
		readiness: f32,
	}
	if open := &game.interaction; open.actor != {} {
		if _, next := input.(Next_Order); next && movement.marches[.Leader].piece == {} {
			result := &open.result
			ids := [2]Piece_Id{open.actor, open.target}
			fallen := 1 - result.winner
			loser := ids[fallen]
			winner := ids[result.winner]
			closed := true
			#partial switch open.stage {
			case .Announce:
				for side, i in result.sides {
					losses[i] = {ids[i], .Battle, side.men.total, side.readiness}
				}
				open.stage = .Report
				closed = false
			case .Report:
				open.stage = .Outcome
				closed = false
			case .Outcome:
				for side, i in result.sides {
					piece := slot_map_get(&game.pieces, ids[i])
					if !side.dissolved || piece == nil do continue
					// Capitulates: changes hands, and the army inside surrenders
					removed_id := ids[i]
					opponent := slot_map_get(&game.pieces, ids[1 - i])
					captures := opponent != nil && .Captures in opponent.flags
					if .Capturable in piece.flags && captures {
						append(
							events,
							Event_Conquered{ids[i], ids[1 - i], piece.owner, opponent.owner},
						)
						piece.owner = opponent.owner
						removed_id = piece.contains
					}
					if slot_map_get(&game.pieces, removed_id) != nil do append(&pieces_to_remove, removed_id)
				}
				beaten := slot_map_get(&game.pieces, loser)
				victor := slot_map_get(&game.pieces, winner)
				if !result.sides[fallen].falls_back || result.sides[fallen].dissolved || beaten == nil || victor == nil do break

				reach: f32 = result.caught ? CHASE_BUDGET : FALL_BACK_BUDGET
				away := linalg.normalize0(beaten.pos - victor.pos)
				orders[.Leader] = {
					piece       = loser,
					destination = beaten.pos + away * reach,
					snap        = 2 * int(reach) + 1,
					budget      = reach,
					ignored     = winner,
					aimed       = true,
				}
				if !result.caught do orders[.Leader].clear_of = winner
				if result.follows {
					orders[.Chaser] = {
						piece   = winner,
						// Any reached cell: as near the destination as its budget allows
						snap    = PATHFIND_FLOOD_SIZE,
						budget  = victor.this_turn.movement_left + result.follow_overdraw,
						ignored = loser,
						follows = result.caught,
						aimed   = true,
					}
				}
				if result.caught {
					side := result.sides[fallen]
					losses[fallen] = {
						loser,
						.Chase,
						side.pursuit_men.total,
						side.pursuit_readiness,
					}
				}
				open.stage = .Fall_Back
				closed = false
			}
			append(events, Event_Interaction{open.actor, open.target, open.stage, closed})
			if closed do open^ = {}
		}
	}

	// Step: Piece removals
	for removed_id in pieces_to_remove {
		removed := slot_map_get(&game.pieces, removed_id)
		if removed == nil do continue
		if removed.inside != {} do append(events, Event_Exit{removed_id, removed.inside})
		occupants := slot_map_iterator(&game.pieces)
		for occupant, occupant_id in slot_map_iterate(&occupants) {
			if occupant.inside != removed_id do continue
			occupant.inside = {}
			append(events, Event_Exit{occupant_id, removed_id})
		}
		slot_map_remove(&game.pieces, removed_id)
		append(events, Event_Removed{removed_id})
	}

	// Step: Garrisons
	{
		cleared := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&cleared) do piece.contains = {}
		linked := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&linked) {
			if settlement := slot_map_get(&game.pieces, piece.inside); settlement != nil do settlement.contains = piece_id
		}
	}

	// Step: Battles. The contacts in turn until one opens an interaction, each run once with its seed. Then the last
	// prediction's marcher, as it would arrive, and its target attacking each other, BATTLE_PREDICTION_RUNS times each
	Battle_Entry :: struct {
		contact:      Contact,
		predicted:    bool,
		// The marcher's side, predicted
		marcher_side: int,
	}
	entries: [dynamic; CONTACTS_MAX + 2]Battle_Entry
	for contact in game.contacts do append(&entries, Battle_Entry{contact = contact})
	predicted_march := &movement.prediction.march
	game.battle_prediction = {}
	arrival: Piece_Data
	if marcher := slot_map_get(&game.pieces, predicted_march.piece); marcher != nil && predicted_march.target != {} {
		game.battle_prediction.marcher = predicted_march.piece
		game.battle_prediction.target = predicted_march.target
		game.battle_prediction.runs = 2 * BATTLE_PREDICTION_RUNS
		append(&entries, Battle_Entry{{predicted_march.piece, predicted_march.target, true}, true, 0})
		append(&entries, Battle_Entry{{predicted_march.target, predicted_march.piece, true}, true, 1})
		arrival = marcher^
		arrival.pos = predicted_march.path.points[len(predicted_march.path.points) - 1]
		arrival.inside = {}
		arrival.army.readiness = movement.prediction.readiness
		arrival.army.statuses = movement.prediction.statuses
	}
	predicted_runs := 0
	contacts_done := 0
	for entry in entries {
		contact := entry.contact
		if !entry.predicted && game.interaction.actor != {} do continue
		if !entry.predicted do contacts_done += 1
		event := Event_Contact{contact.initiator, contact.other, contact.targeted, .Lapsed}
		initiator := slot_map_get(&game.pieces, contact.initiator)
		other := slot_map_get(&game.pieces, contact.other)
		if entry.predicted && entry.marcher_side == 0 do initiator = &arrival
		if entry.predicted && entry.marcher_side == 1 do other = &arrival
		if initiator == nil || other == nil || pieces_friendly(initiator, other) {
			if !entry.predicted do append(events, event)
			continue
		}
		reach := max(initiator.contact_radius, other.contact_radius)
		if linalg.distance(initiator.pos, other.pos) >= reach {
			if !entry.predicted do append(events, event)
			continue
		}

		if .Has_Army not_in initiator.flags || .Has_Army not_in other.flags {
			event.outcome = .Met
			if !entry.predicted do append(events, event)
			continue
		}

		ids := [2]Piece_Id{contact.initiator, contact.other}
		pieces := [2]^Piece_Data{initiator, other}

		// Fighting from a fortified piece: as its garrison, or as an army inside it
		behind_walls: [2]bool
		sheltered := false
		for piece, i in pieces {
			holder := slot_map_get(&game.pieces, piece.inside)
			occupant := slot_map_get(&game.pieces, piece.contains)
			fortified := .Fortified in piece.flags
			held := holder != nil && .Fortified in holder.flags
			behind_walls[i] = fortified || held
			guarded := occupant != nil && .Has_Army in occupant.flags && .Spent not_in occupant.army.statuses
			if (fortified && guarded) || (held && .Spent in piece.army.statuses) do sheltered = true
		}
		if sheltered {
			if !entry.predicted do append(events, event)
			continue
		}
		sortie := behind_walls[0] || behind_walls[1]

		battle := Battle {
			ordered = contact.targeted,
		}
		for piece, i in pieces {
			army := piece.army
			limited := behind_walls[1 - i]
			flags: bit_set[Battle_Side_Flag]
			if .Spent in army.statuses do flags += {.Spent}
			if .Seasick in army.statuses do flags += {.Seasick}
			if piece.inside != {} do flags += {.Garrisoning}
			if behind_walls[i] do flags += {.Behind_Walls}
			if .Fortified in piece.flags do flags += {.Inherent_Garrison}
			// Only the initiator attacks
			if i == 0 && (behind_walls[i] || !piece.this_turn.attacked) do flags += {.Can_Attack}
			if !sortie do flags += {.Can_Avoid, .Can_Fall_Back, .Can_Pursue}
			battle.sides[i] = {
				men           = f32(army.men),
				men_max       = f32(army.men_max),
				engaged_share = limited ? SORTIE_ENEMY_SHARE : 1,
				engaged_max   = limited ? f32(pieces[1 - i].army.men) : math.INF_F32,
				proficiency   = army.proficiency,
				readiness     = army.readiness,
				flags         = flags,
				agility       = army.agility,
				temperament   = army.temperament,
				name          = game_piece_title(piece),
			}
		}

		runs := entry.predicted ? BATTLE_PREDICTION_RUNS : 1
		for run in 0 ..< runs {
			battle.seed = seed_from(u64(game.turn), u64(game.player), transmute(u64)ids[0], transmute(u64)ids[1])
			if entry.predicted do battle.seed = seed_from(u64(run), transmute(u64)ids[0], transmute(u64)ids[1])
			result := battle_resolve(battle)

			if entry.predicted {
				predicting := &game.battle_prediction
				if predicted_runs == 0 {
					predicting.power[0] = result.sides[entry.marcher_side].power
					predicting.power[1] = result.sides[1 - entry.marcher_side].power
				}
				predicted_runs += 1
				predicting.outcomes[BATTLE_FORECASTS[result.winner == entry.marcher_side ? 0 : 1][result.outcome]] += 1
				continue
			}

			if result.fought {
				for piece in pieces {
					piece.this_turn.fought = true
					piece.army.statuses -= {.Resting}
				}
			}
			event.outcome = result.fought ? .Battle : result.refused ? .Refused : .Declined
			append(events, event)
			if !result.fought && !result.refused do continue
			if result.fought && !behind_walls[result.attacker] {
				pieces[result.attacker].this_turn.attacked = true
			}
			game.interaction = {
				actor  = ids[0],
				target = ids[1],
				stage  = result.fought ? .Announce : .Refused,
			}
			game.interaction.result = result
		}
	}
	for _ in 0 ..< contacts_done do ordered_remove(&game.contacts, 0)
	// Runs of a battle that never started: no battle
	if predicting := &game.battle_prediction; predicting.runs > 0 {
		predicting.outcomes[.No_Battle] += f32(predicting.runs - predicted_runs)
		for &share in predicting.outcomes do share /= f32(predicting.runs)
	}

	// Step: Sea reach. Of the piece ordered to move, else of the focused piece
	reach := &movement.sea_reach
	{
		reach^ = {piece = focus}
		if order, ordered := input.(Move_Order); ordered do reach.piece = order.piece
		for &cost in reach.cost do cost = math.INF_F32
		sailor := slot_map_get(&game.pieces, reach.piece)
		if sailor != nil && .Has_Army in sailor.flags {
			for beach, b in game.beaches {
				if b > 0 && linalg.distance(sailor.pos, beach.pos) <= BEACH_RADIUS do reach.start = Beach_Id(b)
			}
		}
		// Only through beaches in the sailor's regions
		if reach.start != 0 && sailor.this_turn.movement_left > 0 {
			reach.cost[reach.start] = 0
			done: bit_set[0 ..< BEACHES_MAX]
			for {
				at := 0
				for b in 1 ..< len(game.beaches) do if b not_in done && reach.cost[b] < reach.cost[at] do at = b
				if at == 0 do break
				done += {at}
				if Beach_Id(at) != reach.start && game.regions[game.beaches[at].region].owner != sailor.owner do continue
				for lane, l in game.sea_lanes {
					other := lane.from == Beach_Id(at) ? lane.to : lane.to == Beach_Id(at) ? lane.from : 0
					cost := reach.cost[at] + lane.length
					if other == 0 || cost > SEA_RANGE || cost >= reach.cost[other] do continue
					reach.cost[other] = cost
					reach.reached_by[other] = Sea_Lane_Id(l)
				}
			}
			for beach, b in game.beaches {
				if b == 0 || Beach_Id(b) == reach.start || reach.cost[b] == math.INF_F32 do continue
				taken := false
				others := slot_map_iterator(&game.pieces)
				for other, other_id in slot_map_iterate(&others) {
					if other_id == reach.piece do continue
					if linalg.distance(other.pos, beach.pos) < other.body_radius + sailor.body_radius do taken = true
				}
				if !taken do reach.landable += {b}
			}
		}
	}

	// Step: Marches. Fall back and chase, then the move: ordered, else the selected piece's, aimed where hovered while
	// nothing is under way
	movement.predicted = {}
	march_orders: [Planned_March]Walk_Order
	march_orders[.Leader] = orders[.Leader]
	march_orders[.Chaser] = orders[.Chaser]
	landing: Beach_Id
	sea_route: [dynamic; BEACHES_MAX]Sea_Lane_Id
	sea_points := 1
	{
		move, ordered := input.(Move_Order)
		hovering := slot_map_get(&game.pieces, hover.piece)
		aimed := ordered || hovering != nil && hover.piece == focus && hovering.owner == game.player && game.under_way == {}
		if !ordered do move = aimed ? hover : Move_Order{piece = focus}
		piece := slot_map_get(&game.pieces, move.piece)
		if aimed && piece != nil {
			movement.predicted = move
			for beach, b in game.beaches {
				if b in reach.landable && linalg.distance(beach.pos, move.destination) <= BEACH_RADIUS do landing = Beach_Id(b)
			}
			for at := landing; landing != 0 && at != reach.start; {
				lane := &game.sea_lanes[reach.reached_by[at]]
				append(&sea_route, reach.reached_by[at])
				sea_points += game.sea_lane_curves.runs[reach.reached_by[at] - 1].len
				at = lane.from == at ? lane.to : lane.from
			}
		}
		march_orders[.Move] = {
			piece       = move.piece,
			target      = move.target,
			destination = move.destination,
			snap        = move.snap,
			aimed       = aimed && landing == 0,
		}
		target := slot_map_get(&game.pieces, move.target)
		enters :=
			piece != nil &&
			target != nil &&
			.Can_Enter in piece.flags &&
			.Can_Contain in target.flags &&
			target.contains == {} &&
			pieces_friendly(piece, target)
		if enters {
			march_orders[.Move].target = {}
			march_orders[.Move].into = move.target
		}
	}

	// Step: March plans. Flooded unless the last flood matches, then, aimed: stopped, traced and smoothed. The move's
	// flood is last: it stays for its reach
	planned := new([Planned_March]March, context.temp_allocator)
	march_refusals: [Planned_March]Maybe(Order_Refusal)
	for &order, planned_march in march_orders {
		if order.piece == {} do continue
		if planned_march == .Chaser {
			leader := planned[.Leader].path.points[:]
			if len(leader) == 0 do continue
			order.destination = order.follows ? leader[len(leader) - 1] : leader[0]
		}

		clear(&movement.enemy_zones)
		clear(&movement.friend_zones)
		clear(&movement.bodies)
		marcher := slot_map_get(&game.pieces, order.piece)
		domain, moves := Pathfind_Domain{}, false
		if marcher != nil do domain, moves = marcher.domain.?
		if !moves {
			movement.flooded = {}
			movement.flood_key = 0
			march_refusals[planned_march] = .Cannot_Move
			continue
		}
		budget := order.budget > 0 ? order.budget : marcher.this_turn.movement_left
		half: f32 = PATHFIND_FLOOD_SIZE / 2 + 1
		lo := marcher.pos - half
		hi := marcher.pos + half
		others := slot_map_iterator(&game.pieces)
		for other, other_id in slot_map_iterate(&others) {
			if other_id == order.piece || other_id == order.ignored do continue
			body := Disc{other.pos, marcher.body_radius + other.body_radius}
			if disc_overlaps_box(body, lo, hi) do append(&movement.bodies, body)
			if other.contact_radius == 0 || domain not_in other.contact_domains do continue
			zone := Disc{other.pos, other.contact_radius}
			if !disc_overlaps_box(zone, lo, hi) do continue
			if pieces_friendly(marcher, other) {
				append(&movement.friend_zones, zone)
			} else {
				append(&movement.enemy_zones, Pathfind_Zone{zone, other.hindrance})
			}
		}
		key_source := [4]u64 {
			transmute(u64)order.piece,
			transmute(u64)marcher.pos,
			u64(transmute(u32)budget),
			u64(domain),
		}
		key := hash.fnv64a(mem.slice_to_bytes(key_source[:]))
		key = hash.fnv64a(mem.slice_to_bytes(movement.enemy_zones[:]), key)
		key = hash.fnv64a(mem.slice_to_bytes(movement.bodies[:]), key)
		if key != movement.flood_key {
			pathfind_flood(marcher.pos, domain, budget, movement.enemy_zones[:], movement.bodies[:], &movement.flood)
			movement.flooded = order.piece
			movement.flood_key = key
		}
		if !order.aimed do continue

		flood := &movement.flood
		stop: [2]int
		stoppable := false
		settlement := slot_map_get(&game.pieces, order.into)
		if settlement != nil {
			stop, stoppable = cell_of(settlement.pos), true
		} else if target := slot_map_get(&game.pieces, order.target); target != nil {
			if flood.domain in target.contact_domains {
				target_zone := Disc{target.pos, target.contact_radius}
				stop, stoppable = pathfind_flood_stop_within(flood, target_zone)
			}
		} else {
			stop, stoppable = pathfind_flood_stop(flood, order.destination, order.snap)
		}

		cells: [dynamic; PATHFIND_PATH_MAX][2]f32
		cell_costs: [dynamic; PATHFIND_PATH_MAX]f32
		traced := stoppable && pathfind_flood_trace(flood, cell_center(stop), &cells, &cell_costs)
		if !traced {
			march_refusals[planned_march] = .No_Route
			continue
		}

		cell_roads: [dynamic; PATHFIND_PATH_MAX]bool
		for cell in cells {
			append(&cell_roads, game.terrain.road[grid_index(cell_of(cell), MAP_SIZE)])
		}
		// Movement spent reaching each raw point: road, off road
		spent := new([PATHFIND_PATH_MAX + 1][2]f32, context.temp_allocator)
		for cost, k in cell_costs {
			spent[k + 1] = spent[k] + (cell_roads[k] ? {cost, 0} : {0, cost})
		}
		if settlement != nil && len(cells) > 0 do cells[len(cells) - 1] = settlement.pos
		raw := new(Polylines(PATHFIND_PATH_MAX + 1, 1), context.temp_allocator)
		raw_points := polylines_reserve(len(cells) + 1, false, raw)
		raw_points[0] = marcher.pos
		copy(raw_points[1:], cells[:])

		march := &planned[planned_march]
		spent_along := new([WALK_POINTS_MAX][2]f32, context.temp_allocator)
		polylines_smooth(raw, WALK_SMOOTHING, &march.path, spent[:len(cells) + 1], spent_along[:])
		if len(march.path.points) == 0 {
			polylines_reserve(1, false, &march.path)[0] = marcher.pos
		}

		// Each segment's share of the movement and the readiness, per cell walked
		append(&march.rates, March_Rate{})
		points := march.path.points[:]
		for q in 1 ..< len(points) {
			length := linalg.distance(points[q - 1], points[q])
			share := spent_along[q] - spent_along[q - 1]
			rate: March_Rate
			if length > 0 {
				lost := share[0] * ROAD_READINESS_PER_MOVEMENT + share[1] * READINESS_PER_MOVEMENT
				rate = {share[0] / length, share[1] / length, lost / length}
				march.movement_spent += share[0] + share[1]
				march.readiness_lost += lost
			}
			append(&march.rates, rate)
		}

		march.piece = order.piece
		march.target = order.target
		march.into = order.into
		march.clear_of = order.clear_of
		march.next = 1
	}

	// Step: Prediction. Of the aimed move: its sail, or its walk
	movement.prediction = {}
	{
		piece := slot_map_get(&game.pieces, movement.predicted.piece)
		prediction := &movement.prediction
		march := &prediction.march
		switch {
		case piece == nil:
		case landing != 0 && sea_points > WALK_POINTS_MAX:
			march_refusals[.Move] = .No_Route
		case landing != 0:
			march^ = {
				piece = movement.predicted.piece,
				next  = 1,
				sails = true,
			}
			points := polylines_reserve(sea_points, false, &march.path)
			points[0] = piece.pos
			filled := 1
			at := reach.start
			#reverse for lane_id in sea_route {
				lane := &game.sea_lanes[lane_id]
				run := game.sea_lane_curves.runs[lane_id - 1]
				leg := points[filled:][:run.len]
				copy(leg, game.sea_lane_curves.points[run.begin:][:run.len])
				if lane.from != at do slice.reverse(leg)
				filled += run.len
				at = lane.from == at ? lane.to : lane.from
			}
			// Sailing spends no movement, and takes all that is left
			for _ in 0 ..< sea_points do append(&march.rates, March_Rate{})
			prediction.movement_left = 0
			prediction.readiness = piece.army.readiness
			sailed := piece.army.statuses - {.Resting} + ({.Seasick} - piece.army.prevent_status)
			prediction.statuses = army_spent_statuses(sailed, piece.army.prevent_status, prediction.readiness)
			planned[.Move] = march^
		case march_refusals[.Move] != nil:
		case:
			march^ = planned[.Move]
			prediction.movement_left = max(0, piece.this_turn.movement_left - march.movement_spent)
			prediction.readiness = max(0, piece.army.readiness - march.readiness_lost)
			prediction.statuses = army_spent_statuses(piece.army.statuses - {.Resting}, piece.army.prevent_status, prediction.readiness)
		}
	}

	// Step: Confirmed marches. The fall back and the chase, and the move when ordered
	{
		confirmed: [Planned_March]bool
		confirmed[.Leader] = march_orders[.Leader].piece != {}
		confirmed[.Chaser] = march_orders[.Chaser].piece != {} && march_refusals[.Leader] == nil
		if move, ordered := input.(Move_Order); ordered {
			piece := slot_map_get(&game.pieces, move.piece)
			confirmed[.Move] = true
			switch {
			case orders[.Leader].piece != {}:
				march_refusals[.Move] = .Superseded
			case piece == nil:
				march_refusals[.Move] = .No_Such_Piece
			case !game.can_move:
				march_refusals[.Move] = .Not_Now
			case piece.owner != game.player:
				march_refusals[.Move] = .Not_Yours
			}
		}
		movers := [Planned_March]Mover {
			.Leader = .Leader,
			.Chaser = .Chaser,
			.Move   = .Leader,
		}
		for planned_march in Planned_March {
			if !confirmed[planned_march] do continue
			order := march_orders[planned_march]
			if refusal, refused := march_refusals[planned_march].?; refused {
				append(events, Event_Order_Refused{order.piece, refusal})
				continue
			}
			march := &planned[planned_march]
			movement.marches[movers[planned_march]] = march^
			if marcher := slot_map_get(&game.pieces, order.piece); march.sails do marcher.this_turn.movement_left = 0
			march_end := march.path.points[len(march.path.points) - 1]
			append(events, Event_March{order.piece, movers[planned_march], march.target, march_end, march.sails})
		}
	}

	walks: [Mover]struct {
		piece:            Piece_Id,
		marched_road:     f32,
		marched_off_road: f32,
		overdrawn:        f32,
		readiness_lost:   f32,
	}
	leader := slot_map_get(&game.pieces, movement.marches[.Leader].piece)
	walk_done := leader == nil
	if leader != nil {
		// Leader first. The chaser waits while touching it
		for &march, mover in movement.marches {
			piece := slot_map_get(&game.pieces, march.piece)
			if piece == nil do continue
			clear_of := slot_map_get(&game.pieces, march.clear_of)
			got_clear :=
				clear_of != nil &&
				!disc_contains({clear_of.pos, clear_of.contact_radius}, piece.pos)
			if got_clear do march.next = len(march.path.points)
			touching :=
				mover == .Chaser &&
				linalg.distance(piece.pos, leader.pos) <= piece.body_radius + leader.body_radius
			if touching || march.next == len(march.path.points) do continue
			walk := &walks[mover]
			walk.piece = march.piece
			stride: f32 = march.sails ? SAIL_CELLS_PER_STEP : WALK_CELLS_PER_STEP
			path := march.path.points[:]
			for stride > 0 && march.next < len(path) {
				target := path[march.next]
				rate := march.rates[march.next]
				distance := linalg.distance(piece.pos, target)
				walked := min(stride, distance)
				if walked < distance {
					piece.pos += linalg.normalize(target - piece.pos) * walked
				} else {
					piece.pos = target
					march.next += 1
				}
				stride -= walked
				walk.marched_road += walked * rate.road
				walk.marched_off_road += walked * rate.off_road
				walk.readiness_lost += walked * rate.readiness
			}
			if march.sails {
				piece.this_turn.moved_sea = true
				piece.army.statuses += {.Seasick} - piece.army.prevent_status
			} else {
				piece.this_turn.moved_land = true
			}
			piece.army.statuses -= {.Resting}
		}

		for &walk in walks {
			piece := slot_map_get(&game.pieces, walk.piece)
			if piece == nil do continue
			due := walk.marched_road + walk.marched_off_road
			if piece.inside != {} {
				append(events, Event_Exit{walk.piece, piece.inside})
				piece.inside = {}
			}
			spent := min(due, piece.this_turn.movement_left)
			piece.this_turn.movement_left -= spent
			walk.overdrawn = due - spent
			walk.readiness_lost += walk.overdrawn * OVERDRAW_READINESS
			append(
				events,
				Event_Moved{walk.piece, piece.pos, piece.this_turn.movement_left, walk.overdrawn},
			)
		}

		// Ends with the leader's march, unless the chaser still walked
		leader_march := &movement.marches[.Leader]
		walk_done =
			leader_march.next == len(leader_march.path.points) && walks[.Chaser].piece == {}
		if walk_done {
			for &march in movement.marches {
				piece := slot_map_get(&game.pieces, march.piece)
				if piece == nil do continue
				append(events, Event_Arrived{march.piece, piece.pos})
				if march.target != {} {
					append(&game.contacts, Contact{march.piece, march.target, true})
				}
				settlement := slot_map_get(&game.pieces, march.into)
				if settlement != nil && settlement.contains == {} {
					piece.pos = settlement.pos
					piece.inside = march.into
					append(events, Event_Enter{march.piece, march.into})
				}
			}
		}
	}
	if walk_done do movement.marches = {}

	// Step: Under way
	game.under_way = {}
	if movement.marches[.Leader].piece != {} do game.under_way += {.March}
	if len(game.contacts) > 0 do game.under_way += {.Contact}
	if game.interaction.actor != {} do game.under_way += {.Battle}
	if game.ending do game.under_way += {.Ending}
	game.can_move = game.under_way & {.Battle, .Ending} == {}
	turn_ending := game.under_way == {.Ending}


	// Step: Projects (turn end)
	if turn_ending {
		building := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&building) {
			if .Has_Town not_in piece.flags || piece.owner != game.player do continue
			for &project, slot in piece.town.projects {
				if !project.active do continue
				project.turns_left -= 1
				if project.turns_left > 0 do continue
				piece.town.buildings[slot] = project.kind
				append(events, Event_Project_Finished{piece_id, slot, project.kind})
				project = {}
			}
		}
	}

	// Step: Regions
	for &region in game.regions {
		capital := slot_map_get(&game.pieces, region.capital)
		region.owner = capital != nil ? capital.owner : 0
	}

	// Step: Settlements
	{
		settlements := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&settlements) {
			if .Has_Town not_in piece.flags do continue
			main := &game.building_kinds[piece.town.buildings[MAIN_SLOT]]
			piece.icon = main.icon
			piece.town.slots = main.slots
			piece.supply_production = main.supply
			piece.hindrance = main.hindrance
			piece.contact_radius = main.contact
			piece.body_radius = main.body
		}
	}

	// Step: Army stats
	{
		armies := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&armies) {
			if .Has_Army not_in piece.flags do continue
			army_type := &game.army_types[piece.army.type]
			modifiers: Army_Modifiers
			for trait in army_type.traits do modifiers = army_modifiers_combine(modifiers, game.army_traits[trait].modifiers)
			piece.army.agility = army_type.agility + modifiers.agility
			piece.army.readiness_recovery = modifiers.readiness_recovery
			piece.army.prevent_status = modifiers.prevent_status
			if _, moves := piece.domain.?; moves do piece.movement_per_turn = game.army_template.movement_per_turn + modifiers.movement
		}
	}

	// Step: Networks (start)
	if starting do game_networks_build(game)

	// Step: Titles
	// Destroyed when its building is gone or replaced, or its town lost with its army out of the field
	{
		cleared := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&cleared) do piece.town.titles = {}
		offices := slot_map_iterator(&game.offices)
		for office, office_id in slot_map_iterate(&offices) {
			town := slot_map_get(&game.pieces, office.town)
			if town == nil do continue
			office.elapsed = town.owner != office.faction
			built := town.town.buildings[office.slot] == office.building
			in_field := slot_map_get(&game.pieces, office.army) != nil
			if !built || (office.elapsed && !in_field) {
				slot_map_remove(&game.offices, office_id)
				continue
			}
			if !office.elapsed do town.town.titles[office.slot] = office_id
		}
		missing := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&missing) {
			if .Has_Town not_in piece.flags do continue
			for kind_id, slot in piece.town.buildings {
				kind := game.building_kinds[kind_id].title
				if kind == 0 || piece.town.titles[slot] != {} do continue
				title := fmt.tprintf("%s of %s", name_to_string(&game.office_kinds[kind].name), name_to_string(&piece.name))
				piece.town.titles[slot] = slot_map_insert(
					&game.offices,
					Office {
						kind = kind,
						faction = piece.owner,
						title = name_from_string(title),
						town = piece_id,
						slot = slot,
						building = kind_id,
					},
				)
			}
		}
	}

	// Step: Holders
	{
		for &faction in game.factions do faction.characters = 0
		for &character, c in game.characters {
			character.office = {}
			if c > 0 do game.factions[character.faction].characters += 1
		}
		held := slot_map_iterator(&game.offices)
		for office, office_id in slot_map_iterate(&held) {
			office.army = {}
			if office.holder != 0 do game.characters[office.holder].office = office_id
		}
		armies := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&armies) {
			if .Has_Army not_in piece.flags do continue
			if piece.army.title != {} {
				title := slot_map_get(&game.offices, piece.army.title)
				piece.general = title != nil ? title.holder : 0
				if title != nil do title.army = piece_id
			}
			piece.army.temperament = piece.general != 0 ? game.characters[piece.general].temperament : NO_GENERAL_TEMPERAMENT
		}
		allowing := slot_map_iterator(&game.offices)
		for office in slot_map_iterate(&allowing) {
			kind := &game.office_kinds[office.kind]
			switch {
			case .Eternal in kind.flags:
				office.dismissal = .For_Life
			case .Dismissable not_in kind.flags:
				office.dismissal = .Not_Dismissable
			case office.term_left > 0:
				office.dismissal = .In_Term
			case office.faction != game.player || game.under_way != {}:
				office.dismissal = .Not_Now
			case:
				office.dismissal = .Allowed
			}
			office.muster_at = office.town != {} ? office.town : game.factions[office.faction].capital
			// Not while its building is being demolished or replaced
			town := slot_map_get(&game.pieces, office.town)
			kept := town == nil || !town.town.projects[office.slot].active
			at := slot_map_get(&game.pieces, office.muster_at)
			held := at != nil && at.owner == office.faction && !office.elapsed
			playing := office.faction == game.player && game.under_way == {}
			office.can_mobilise = kind.army_type != 0 && office.holder != 0 && office.army == {} && office.men > 0 && held && kept && playing
		}
	}

	// Step: Building orders
	{
		ordering := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&ordering) {
			if .Has_Town not_in piece.flags do continue
			town := &piece.town
			treasury := game.factions[piece.owner].treasury
			acting := piece.owner == game.player && game.under_way == {}
			for &allows, slot in town.building_orders {
				allows = {}
				if slot >= town.slots && slot != MAIN_SLOT do continue
				here := town.buildings[slot]
				if here == 0 {
					for &kind, k in game.building_kinds {
						if k == 0 || kind.upgraded_from != 0 || !game.culture_buildings[piece.culture][k] do continue
						if (.Main in kind.flags) == (slot == MAIN_SLOT) do allows.offered += {k}
					}
				} else if next := game.building_kinds[here].upgrade; next != 0 && game.culture_buildings[piece.culture][next] {
					allows.offered += {int(next)}
				}
				project := town.projects[slot].active
				if !acting do continue
				allows.cancel = project
				// Not while its title's army is in the field
				title := slot_map_get(&game.offices, town.titles[slot])
				if project || (title != nil && title.army != {}) do continue
				for k in allows.offered do if treasury >= game.building_kinds[k].build_coin do allows.buildable += {k}
				allows.demolish = here != 0 && slot != MAIN_SLOT
			}
		}
	}

	// Step: Towns
	{
		for &faction in game.factions {
			faction.income = 0
			faction.upkeep = 0
			faction.food_sent = 0
			faction.food_taken = 0
		}
		towns := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&towns) {
			if .Has_Town not_in piece.flags do continue
			town := &piece.town
			// Short of people, every building runs at the share it has
			town.staff_needed = 0
			for kind_id in town.buildings do town.staff_needed += game.building_kinds[kind_id].population
			town.staffing = town.staff_needed > 0 ? min(1, town.population / town.staff_needed) : 1

			town.food = 0
			town.income = 0
			town.wealth = 0
			town.upkeep = 0
			town.public_order = 0
			town.unrest = 0
			town.food_sent = 0
			town.food_taken = 0
			town.salaries_global = 0
			town.salaries_local = 0
			town.shares = 0
			for kind_id, slot in town.buildings {
				kind := &game.building_kinds[kind_id]
				town.slot_food[slot] = (kind.food + kind.food_fertility * town.fertility) * town.staffing
				town.food += town.slot_food[slot]
				town.income += kind.income * town.staffing * town.control / 100
				town.wealth += kind.income * town.staffing * (1 - town.control / 100)
				// Paid however staffed
				town.upkeep += kind.upkeep
				if kind.public_order > 0 do town.public_order += kind.public_order
				else do town.unrest -= kind.public_order
				if kind.food_store > 0 do town.food_sent += kind.food_store * town.staffing
				else do town.food_taken -= kind.food_store * town.staffing
				// Weights count whether held or not
				title := slot_map_get(&game.offices, town.titles[slot])
				if title == nil do continue
				if title.holder != 0 {
					town.salaries_global += kind.title_salary_global
					town.salaries_local += kind.title_salary_local
				}
				town.shares += kind.title_salary_local_share
			}
			town.upkeep += town.salaries_global
			town.wealth_shared = max(0, town.wealth - town.salaries_local)
			game.factions[piece.owner].income += town.income
			game.factions[piece.owner].upkeep += town.upkeep
			town.population_supported = town.food / FOOD_PER_POPULATION
			town.food_eaten = town.population * FOOD_PER_POPULATION

			// The surplus and what buildings send, as far as control reaches
			town.food_sent = (town.food_sent + max(0, town.food - town.food_eaten)) * town.control / 100
			game.factions[piece.owner].food_sent += town.food_sent
			game.factions[piece.owner].food_taken += town.food_taken
		}
	}

	// Step: Pay
	{
		paying := slot_map_iterator(&game.offices)
		for office in slot_map_iterate(&paying) {
			kind := &game.office_kinds[office.kind]
			office.wealth = 0
			town := slot_map_get(&game.pieces, office.town)
			if office.holder != 0 && town == nil {
				office.wealth =
					kind.salary + kind.income_share * game.factions[office.faction].income
				game.factions[office.faction].upkeep += office.wealth
			}
			if office.holder != 0 && town != nil && !office.elapsed {
				building := &game.building_kinds[office.building]
				office.wealth = building.title_salary_global + building.title_salary_local
				if town.town.shares > 0 {
					office.wealth += town.town.wealth_shared * building.title_salary_local_share / town.town.shares
				}
			}
			if kind.army_type == 0 do continue
			office.men_max = int(office.wealth * game.army_types[kind.army_type].men_per_wealth)
			if army := slot_map_get(&game.pieces, office.army); army != nil do army.army.men_max = office.men_max
		}
		for &character in game.characters {
			character.influence_target = 0
			if office := slot_map_get(&game.offices, character.office); office != nil {
				character.influence_target = game.office_kinds[office.kind].influence + office.wealth * INFLUENCE_PER_WEALTH
			}
		}
	}

	// Step: Stability
	{
		weighted, total: [FACTIONS_MAX]f32
		for &character, c in game.characters {
			if c == 0 do continue
			weighted[character.faction] += character.influence * character.loyalty
			total[character.faction] += character.influence
		}
		for &faction, f in game.factions do faction.stability = total[f] > 0 ? weighted[f] / total[f] : 0
	}

	// Step: Ranks
	{
		Ranked :: struct {
			office: Office_Id,
			rank:   int,
			own:    bool,
		}
		ranked := make([dynamic]Ranked, 0, OFFICES_MAX, context.temp_allocator)
		ranking := slot_map_iterator(&game.offices)
		for office, office_id in slot_map_iterate(&ranking) {
			append(&ranked, Ranked{office_id, game.office_kinds[office.kind].rank, office.town == {}})
		}
		slice.sort_by(ranked[:], proc(a, b: Ranked) -> bool {
			if a.rank != b.rank do return a.rank > b.rank
			if a.own != b.own do return a.own
			return a.office.index < b.office.index
		})
		clear(&game.offices_ranked)
		for each in ranked do append(&game.offices_ranked, each.office)
	}

	// Step: Appointment
	{
		game.appointment = {
			can_appoint = game.under_way == {},
		}
		for office_id in game.offices_ranked {
			office := slot_map_get(&game.offices, office_id)
			if office.faction != game.player || office.holder != 0 || office.elapsed do continue
			game.appointment.office = office_id
			break
		}
		if vacancy := slot_map_get(&game.offices, game.appointment.office); vacancy != nil {
			rank := game.office_kinds[vacancy.kind].rank
			Applicant :: struct {
				character: Character_Id,
				rank:      int,
				influence: f32,
			}
			applicants := make([dynamic]Applicant, 0, FACTION_CHARACTERS_MAX, context.temp_allocator)
			for &character, c in game.characters {
				if c == 0 || character.faction != game.player do continue
				if office := slot_map_get(&game.offices, character.office); office != nil {
					kind := &game.office_kinds[office.kind]
					if kind.rank >= rank || office.term_left > 0 || .Eternal in kind.flags do continue
				}
				append(&applicants, Applicant{Character_Id(c), character.rank, character.influence})
			}
			slice.sort_by(applicants[:], proc(a, b: Applicant) -> bool {
				return a.rank != b.rank ? a.rank > b.rank : a.influence > b.influence
			})
			for applicant in applicants {
				passed_over := 0
				for above in game.appointment.candidates do if game.characters[above.character].rank > applicant.rank do passed_over += 1
				if append(&game.appointment.candidates, Candidate{applicant.character, passed_over}) == 0 do break
			}
		}
	}

	game.endable = game.under_way == {} && game.appointment.office == {}

	// Step: Population (turn end)
	if turn_ending {
		growing := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&growing) {
			if .Has_Town not_in piece.flags || piece.owner != game.player do continue
			town := &piece.town
			change := (town.population_supported - town.population) * POPULATION_RATE
			town.population += min(change, town.population * POPULATION_GROWTH_MAX)
		}
	}

	// Step: Treasury (turn end)
	// Either can go below zero for now
	if turn_ending {
		player := &game.factions[game.player]
		player.treasury += player.income - player.upkeep
		player.food_store += player.food_sent - player.food_taken
	}

	// Step: Title men (turn end)
	if turn_ending {
		gathering := slot_map_iterator(&game.offices)
		for office in slot_map_iterate(&gathering) {
			if office.faction != game.player || game.office_kinds[office.kind].army_type == 0 || office.army != {} do continue
			gain := int(math.round(TITLE_GATHER_SHARE * f32(office.men_max)))
			office.men = men_toward_full(office.men, office.men_max, gain)
		}
	}

	// Step: Terms (turn end)
	if turn_ending {
		serving := slot_map_iterator(&game.offices)
		for office in slot_map_iterate(&serving) {
			if office.faction == game.player && office.holder != 0 do office.term_left = max(0, office.term_left - 1)
		}
	}

	// Step: Influence (turn end)
	if turn_ending {
		for &character, c in game.characters {
			if c == 0 || character.faction != game.player do continue
			gap := character.influence_target - character.influence
			step := max(abs(gap) * INFLUENCE_RATE, INFLUENCE_STEP_MIN)
			character.influence += clamp(gap, -step, step)
		}
	}

	// Step: Armies
	pieces := slot_map_iterator(&game.pieces)
	for piece, id in slot_map_iterate(&pieces) {
		if .Has_Army not_in piece.flags do continue
		army := &piece.army
		readiness := army.readiness
		was_spent := .Spent in army.statuses
		changes: bit_set[Army_Change]

		for loss in losses {
			if loss.army != id do continue
			changes += {loss.change}
			army.men = max(0, army.men + int(math.round(loss.men)))
			readiness += loss.readiness
		}

		if piece.owner == game.player {
			men := f32(army.men)
			cell := cell_of(piece.pos)
			// Per source: needs met (1 = fully), and the army's share of the men crowding it
			fed, efficiency: [Supply_Source]f32
			if grid_contains(cell, MAP_SIZE) && men > 0 {
				at := grid_index(cell, MAP_SIZE)

				// Its own men, and nearby men sharing supply if it shares too
				sharing: f32 = .Shares_Supply in piece.flags ? 1 : 0
				friendly_men, all_men := men, men
				others := slot_map_iterator(&game.pieces)
				for other, other_id in slot_map_iterate(&others) {
					if other_id == id || .Shares_Supply not_in other.flags do continue
					distance := linalg.distance(piece.pos, other.pos)
					if distance >= SUPPLY_RADIUS do continue
					weighted := sharing * f32(other.army.men) * (1 - distance / SUPPLY_RADIUS)
					all_men += weighted
					if other.owner == piece.owner do friendly_men += weighted
				}

				yield: f32
				if game.terrain.surface[at] == 0 {
					cover := game.terrain.cover[at]
					yield = math.lerp(
						FORAGE_YIELD[.Open],
						FORAGE_YIELD[cover.kind],
						f32(cover.strength) / 255,
					)
				}

				// Per source: supply points available here, and the men crowding them
				points := [Supply_Source]f32 {
					.Network  = f32(game.supply_network[at]),
					.Foraging = army.foraging * yield,
				}
				crowd := [Supply_Source]f32 {
					.Network  = friendly_men,
					.Foraging = all_men,
				}
				for source in Supply_Source {
					fed[source] = points[source] * MEN_PER_SUPPLY / crowd[source]
					efficiency[source] = men / crowd[source]
				}
			}

			best := Supply_Source.Network
			for source in Supply_Source do if fed[source] > fed[best] do best = source
			army.supply = 100 * min(fed[best], 1)
			army.supply_source = best
			army.supply_efficiency = efficiency[best]
		}

		for walk in walks {
			if walk.piece != id do continue
			changes += {.March}
			readiness -= walk.readiness_lost
		}

		// Turn end forecast. Still and no enemy within reach: rests. Recovers toward the supply level
		{
			statuses := army.statuses
			if !piece.this_turn.moved_sea do statuses -= {.Seasick}
			rests := !piece.this_turn.moved_land && !piece.this_turn.moved_sea && !piece.this_turn.fought
			enemies := slot_map_iterator(&game.pieces)
			for enemy in slot_map_iterate(&enemies) {
				if pieces_friendly(piece, enemy) || .Land not_in enemy.contact_domains do continue
				if linalg.distance(piece.pos, enemy.pos) < enemy.contact_radius do rests = false
			}
			if rests do statuses += {.Resting} - army.prevent_status
			else do statuses -= {.Resting}
			gain_max: f32 = .Resting in statuses ? READINESS_SPEED : army.readiness_recovery
			army.turn_end_readiness = clamp(readiness + clamp(army.supply - readiness, -READINESS_SPEED, gain_max), 0, 100)
			army.turn_end_statuses = army_spent_statuses(statuses, army.prevent_status, army.turn_end_readiness)
		}

		if turn_ending && piece.owner == game.player {
			changes += {.Turn_End}
			army.statuses = army.turn_end_statuses
			readiness = army.turn_end_readiness

			// Reinforcement on home land: any held region, or a local army's own only
			gain := 0
			cell := cell_of(piece.pos)
			if grid_contains(cell, MAP_SIZE) {
				region := game.terrain.regions[grid_index(cell, MAP_SIZE)]
				at_home := army.home == 0 || Region_Id(region) == army.home
				if game.regions[region].owner == piece.owner && at_home {
					gain = int(math.round(REINFORCEMENT_SHARE * f32(army.men_max) * army.supply / 100))
				}
			}
			army.men = men_toward_full(army.men, army.men_max, gain)
		}

		army.readiness = clamp(readiness, 0, 100)
		army.statuses = army_spent_statuses(army.statuses, army.prevent_status, army.readiness)
		if .Spent in army.statuses && !was_spent do append(events, Event_Spent{id, army.readiness})
		if .Spent not_in army.statuses && was_spent do append(events, Event_Unspent{id})
		if changes != {} do append(events, Event_Army{id, changes, army^})
	}

	// Step: New characters
	if !starting && !game.ending && game.appointment.office != {} && len(game.appointment.candidates) < CANDIDATES_MIN {
		faction := &game.factions[game.player]
		culture := &game.cultures[faction.culture]
		for _ in len(game.appointment.candidates) ..< CANDIDATES_MIN {
			id := Character_Id(len(game.characters))
			if faction.characters >= FACTION_CHARACTERS_MAX || int(id) >= CHARACTERS_MAX || len(culture.names) == 0 do break
			rng := seed_from(u64(game.turn), u64(game.player), u64(id))
			// Name: the first unused from a rolled place; all used, the rolled one numbered
			first := int(random_unit(&rng) * f32(len(culture.names)))
			name := name_from_string(fmt.tprintf("%s %d", name_to_string(&culture.names[first]), id))
			for k in 0 ..< len(culture.names) {
				candidate := culture.names[(first + k) % len(culture.names)]
				used := false
				for other in game.characters do if other.name == candidate do used = true
				if !used {
					name = candidate
					break
				}
			}
			append(
				&game.characters,
				Character {
					name = name,
					faction = game.player,
					age = NEW_CHARACTER_AGE[0] + int(random_unit(&rng) * f32(NEW_CHARACTER_AGE[1] - NEW_CHARACTER_AGE[0])),
					influence = NEW_CHARACTER_INFLUENCE,
					loyalty = NEW_CHARACTER_LOYALTY,
					temperament = Temperament(int(random_unit(&rng) * f32(len(Temperament)))),
					background = Background(int(random_unit(&rng) * f32(len(Background)))),
					disposition = Disposition(int(random_unit(&rng) * f32(len(Disposition)))),
				},
			)
			faction.characters += 1
		}
	}

	// Step: Turn change
	if turn_ending {
		game.ending = false
		next_player := int(game.player) + 1
		if next_player >= len(game.factions) {
			next_player = 1
			game.turn += 1
		}
		game.player = Faction_Id(next_player)
		append(events, Event_Turn{game.turn, game.player})

		game_networks_build(game)
	}

	// Step: Turn start
	if turn_ending || starting {
		all := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&all) do piece.this_turn = {movement_left = piece.movement_per_turn}
	}
}

// Spent below SPENT_READINESS unless prevented, and no longer above SPENT_CLEAR_READINESS
@(private = "file")
army_spent_statuses :: proc(statuses, prevented: bit_set[Army_Status], readiness: f32) -> bit_set[Army_Status] {
	statuses := statuses
	if readiness < SPENT_READINESS do statuses += {.Spent} - prevented
	if readiness > SPENT_CLEAR_READINESS do statuses -= {.Spent}
	return statuses
}

// Above full strength, DESERTION_SHARE of the men leave, at least one
@(private = "file")
men_toward_full :: proc(men, men_max, gain: int) -> int {
	if men > men_max do return max(men_max, men - max(1, int(math.round(DESERTION_SHARE * f32(men)))))
	return min(men_max, men + gain)
}

@(private = "file")
seed_from :: proc(values: ..u64) -> u64 {
	return hash.fnv64a(mem.slice_to_bytes(values))
}
