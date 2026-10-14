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
MOBILISE_READINESS :: 20
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
SPENT_ROLL_TARGET :: 6
@(private = "file")
SPENT_ROLL_PER_READINESS :: 0.2

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

// The ordered piece, and the piece pursuing it
Mover :: enum u8 {
	Leader,
	Chaser,
}

// Movement spent per cell walked
March_Rate :: struct {
	road:     f32,
	off_road: f32,
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
}

Movement :: struct {
	marches:      [Mover]March,
	flood:        Pathfind_Flood,
	flooded:      Piece_Id,
	flood_key:    u64,
	enemy_zones:  [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones: [dynamic; PIECE_MAX]Disc,
	bodies:       [dynamic; PIECE_MAX]Disc,
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

Event_Spent_Roll :: struct {
	piece:     Piece_Id,
	readiness: f32,
	roll:      f32,
	total:     f32,
	target:    f32,
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
	Event_Spent_Roll,
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
		pathfind_spread(.Land, sources[:], blocked, SUPPLY_DECAY, .Max, spread)
		for value, i in spread do game.supply_network[i] = u8(clamp(value, 0, 100) + 0.5)
	}

	// Control, per faction: never outside its regions
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
		pathfind_spread(.Land, sources[:], blocked, CONTROL_DECAY, .Max, spread)
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

// In/out: march.next.
// Moves pos along the march by up to stride. Returns the movement spent, on and off road
@(private = "file")
walk_along :: proc(
	march: ^March,
	pos: [2]f32,
	stride: f32,
) -> (
	moved: [2]f32,
	road, off_road: f32,
) {
	moved = pos
	stride := stride
	path := march.path.points[:]
	for stride > 0 && march.next < len(path) {
		target := path[march.next]
		rate := march.rates[march.next]
		distance := linalg.distance(moved, target)
		walked := min(stride, distance)
		if walked < distance {
			moved += linalg.normalize(target - moved) * walked
		} else {
			moved = target
			march.next += 1
		}
		stride -= walked
		road += walked * rate.road
		off_road += walked * rate.off_road
	}
	return
}

// Floods from subject within budget (0: its movement left), unless the last flood matches.
// Leaves out ignored's zone and body. False if subject is gone or does not move
@(private = "file")
flood_from :: proc(game: ^Game, subject_id: Piece_Id, budget: f32, ignored: Piece_Id) -> bool {
	movement := &game.movement
	clear(&movement.enemy_zones)
	clear(&movement.friend_zones)
	clear(&movement.bodies)
	subject := slot_map_get(&game.pieces, subject_id)
	domain, moves := Pathfind_Domain{}, false
	if subject != nil do domain, moves = subject.domain.?
	if !moves {
		movement.flooded = {}
		movement.flood_key = 0
		return false
	}

	budget := budget > 0 ? budget : subject.this_turn.movement_left
	half: f32 = PATHFIND_FLOOD_SIZE / 2 + 1
	lo := subject.pos - half
	hi := subject.pos + half
	others := slot_map_iterator(&game.pieces)
	for other, other_id in slot_map_iterate(&others) {
		if other_id == subject_id || other_id == ignored do continue
		body := Disc{other.pos, subject.body_radius + other.body_radius}
		if disc_overlaps_box(body, lo, hi) do append(&movement.bodies, body)
		if other.contact_radius == 0 || domain not_in other.contact_domains do continue
		zone := Disc{other.pos, other.contact_radius}
		if !disc_overlaps_box(zone, lo, hi) do continue
		if pieces_friendly(subject, other) {
			append(&movement.friend_zones, zone)
		} else {
			append(&movement.enemy_zones, Pathfind_Zone{zone, other.hindrance})
		}
	}

	key_source := [4]u64 {
		transmute(u64)subject_id,
		transmute(u64)subject.pos,
		u64(transmute(u32)budget),
		u64(domain),
	}
	key := hash.fnv64a(mem.slice_to_bytes(key_source[:]))
	key = hash.fnv64a(mem.slice_to_bytes(movement.enemy_zones[:]), key)
	key = hash.fnv64a(mem.slice_to_bytes(movement.bodies[:]), key)
	if key != movement.flood_key {
		pathfind_flood(
			subject.pos,
			domain,
			budget,
			movement.enemy_zones[:],
			movement.bodies[:],
			&movement.flood,
		)
		movement.flooded = subject_id
		movement.flood_key = key
	}
	return true
}

// Out: game.movement.marches[mover], written only when a route is found; events.
// Floods from the order's piece, picks where to stop, then traces and smooths the path
@(private = "file")
march_plan :: proc(
	game: ^Game,
	order: Walk_Order,
	mover: Mover,
	events: ^[dynamic; GAME_EVENTS_MAX]Game_Event,
) -> bool {
	if !flood_from(game, order.piece, order.budget, order.ignored) {
		append(events, Event_Order_Refused{order.piece, .Cannot_Move})
		return false
	}

	flood := &game.movement.flood
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
		append(events, Event_Order_Refused{order.piece, .No_Route})
		return false
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
	walker := slot_map_get(&game.pieces, order.piece)
	raw := new(Polylines(PATHFIND_PATH_MAX + 1, 1), context.temp_allocator)
	raw_points := polylines_reserve(len(cells) + 1, false, raw)
	raw_points[0] = walker.pos
	copy(raw_points[1:], cells[:])

	march := &game.movement.marches[mover]
	spent_along := new([WALK_POINTS_MAX][2]f32, context.temp_allocator)
	polylines_clear(&march.path)
	polylines_smooth(raw, WALK_SMOOTHING, &march.path, spent[:len(cells) + 1], spent_along[:])
	if len(march.path.points) == 0 {
		polylines_reserve(1, false, &march.path)[0] = walker.pos
	}

	// Each segment's share of the movement, per cell walked
	clear(&march.rates)
	append(&march.rates, March_Rate{})
	points := march.path.points[:]
	for q in 1 ..< len(points) {
		length := linalg.distance(points[q - 1], points[q])
		share := spent_along[q] - spent_along[q - 1]
		rate: March_Rate
		if length > 0 do rate = {share[0] / length, share[1] / length}
		append(&march.rates, rate)
	}

	march.piece = order.piece
	march.target = order.target
	march.into = order.into
	march.clear_of = order.clear_of
	march.next = 1
	march_end := march.path.points[len(march.path.points) - 1]
	append(events, Event_March{order.piece, mover, order.target, march_end})
	return true
}

game_step :: proc(
	game: ^Game,
	focus: Piece_Id,
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
						mobility    = army_type.mobility,
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

	for len(game.contacts) > 0 && game.interaction.actor == {} {
		contact := game.contacts[0]
		ordered_remove(&game.contacts, 0)
		event := Event_Contact{contact.initiator, contact.other, contact.targeted, .Lapsed}
		initiator := slot_map_get(&game.pieces, contact.initiator)
		other := slot_map_get(&game.pieces, contact.other)
		if initiator == nil || other == nil || pieces_friendly(initiator, other) {
			append(events, event)
			continue
		}
		reach := max(initiator.contact_radius, other.contact_radius)
		if linalg.distance(initiator.pos, other.pos) >= reach {
			append(events, event)
			continue
		}

		if .Has_Army not_in initiator.flags || .Has_Army not_in other.flags {
			event.outcome = .Met
			append(events, event)
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
			guarded := occupant != nil && .Has_Army in occupant.flags && !occupant.army.spent
			if (fortified && guarded) || (held && piece.army.spent) do sheltered = true
		}
		if sheltered {
			append(events, event)
			continue
		}
		sortie := behind_walls[0] || behind_walls[1]

		battle := Battle {
			ordered = contact.targeted,
			seed    = seed_from(u64(game.turn), u64(game.player), transmute(u64)ids[0], transmute(u64)ids[1]),
		}
		for piece, i in pieces {
			army := piece.army
			limited := behind_walls[1 - i]
			flags: bit_set[Battle_Side_Flag]
			if army.spent do flags += {.Spent}
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
				mobility      = army.mobility,
				temperament   = army.temperament,
				name          = game_piece_title(piece),
			}
		}

		result := battle_resolve(battle)
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

	if player_order, ordered := input.(Move_Order); ordered {
		piece := slot_map_get(&game.pieces, player_order.piece)
		refusal: Maybe(Order_Refusal)
		switch {
		case orders[.Leader].piece != {}:
			refusal = .Superseded
		case piece == nil:
			refusal = .No_Such_Piece
		case !game.can_move:
			refusal = .Not_Now
		case piece.owner != game.player:
			refusal = .Not_Yours
		}
		if reason, refused := refusal.?; refused {
			append(events, Event_Order_Refused{player_order.piece, reason})
		} else {
			order := &orders[.Leader]
			order^ = {
				piece       = player_order.piece,
				target      = player_order.target,
				destination = player_order.destination,
				snap        = player_order.snap,
			}
			target := slot_map_get(&game.pieces, player_order.target)
			enters :=
				target != nil &&
				.Can_Enter in piece.flags &&
				.Can_Contain in target.flags &&
				target.contains == {} &&
				pieces_friendly(piece, target)
			if enters do order.target, order.into = {}, player_order.target
		}
	}

	// The ordered marches: the leader's, then the chaser's toward where the leader starts or ends
	for &order, mover in orders {
		if order.piece == {} do continue
		if mover == .Chaser {
			leader := movement.marches[.Leader].path.points[:]
			order.destination = order.follows ? leader[len(leader) - 1] : leader[0]
		}
		if !march_plan(game, order, mover, events) do break
	}
	// Otherwise, the focused piece's reach
	if orders[.Leader].piece == {} do flood_from(game, focus, 0, {})

	walks: [Mover]struct {
		piece:            Piece_Id,
		marched_road:     f32,
		marched_off_road: f32,
		overdrawn:        f32,
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
			moved, road, off_road := walk_along(&march, piece.pos, WALK_CELLS_PER_STEP)
			piece.pos = moved
			walks[mover] = {march.piece, road, off_road, 0}
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
			readiness -= walk.marched_road * ROAD_READINESS_PER_MOVEMENT
			readiness -= walk.marched_off_road * READINESS_PER_MOVEMENT
			readiness -= walk.overdrawn * OVERDRAW_READINESS
		}

		if turn_ending && piece.owner == game.player {
			changes += {.Turn_End}
			exertion: f32 =
				piece.movement_per_turn > 0 ? 1 - piece.this_turn.movement_left / piece.movement_per_turn : 0
			// Recovery: toward the supply level; gains scaled by rest
			delta := clamp(army.supply - readiness, -READINESS_SPEED, READINESS_SPEED)
			if delta > 0 do delta *= 1 - exertion
			readiness += delta
			if army.spent && readiness >= SPENT_READINESS {
				rng := seed_from(u64(game.turn), u64(game.player), transmute(u64)id)
				roll := roll_2d6(&rng)
				total := roll + (readiness - SPENT_READINESS) * SPENT_ROLL_PER_READINESS
				append(events, Event_Spent_Roll{id, readiness, roll, total, SPENT_ROLL_TARGET})
				if total > SPENT_ROLL_TARGET {
					army.spent = false
					append(events, Event_Unspent{id})
				}
			}

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
		if army.readiness < SPENT_READINESS && !army.spent {
			army.spent = true
			append(events, Event_Spent{id, army.readiness})
		}
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

		all := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&all) do piece.this_turn = {movement_left = piece.movement_per_turn}
		game_networks_build(game)
	}
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
