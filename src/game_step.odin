package main

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"

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

Game_Answer :: enum u8 {
	None,
	Next,
}

Game_Order :: struct {
	piece:       Piece_Id,
	target:      Piece_Id,
	destination: [2]f32,
	snap:        int,
}

Game_Input :: struct {
	end_turn: bool,
	answer:   Game_Answer,
	order:    Maybe(Game_Order),
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

game_ordering :: proc(game: ^Game) -> Faction_Id {
	settled := game.interaction.actor == {} && !game.ending
	return settled ? game.player : 0
}

game_turn_endable :: proc(game: ^Game) -> bool {
	return(
		!game.ending &&
		game.movement.marches[.Leader].piece == {} &&
		len(game.contacts) == 0 &&
		game.interaction.actor == {} \
	)
}

game_commander_temperament :: proc(game: ^Game, piece: ^Piece_Data) -> Temperament {
	return piece.general != 0 ? game.characters[piece.general].temperament : NO_GENERAL_TEMPERAMENT
}

game_movement_left :: proc(piece: Piece_Data) -> f32 {
	return max(0, piece.movement_per_turn - piece.this_turn.movement_spent)
}

game_supply_build :: proc(game: ^Game) {
	sources: [dynamic; PIECE_MAX]Pathfind_Source
	// Enemy zones block the spread
	zones: [dynamic; PIECE_MAX]Disc
	it := slot_map_iterator(&game.pieces)
	for piece in slot_map_iterate(&it) {
		if piece.owner == game.player {
			if piece.supply_production > 0 {
				append(&sources, Pathfind_Source{piece.pos, piece.supply_production})
			}
		} else if piece.contact_radius > 0 && .Land in piece.contact_domains {
			append(&zones, Disc{piece.pos, piece.contact_radius})
		}
	}
	spread := make([]f32, MAP_CELLS, context.temp_allocator)
	pathfind_spread(.Land, sources[:], zones[:], SUPPLY_DECAY, spread)
	for value, i in spread do game.supply_network[i] = u8(clamp(value, 0, 100) + 0.5)
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

	budget := budget > 0 ? budget : game_movement_left(subject^)
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
	input: Game_Input,
	events: ^[dynamic; GAME_EVENTS_MAX]Game_Event,
) {
	game.step += 1
	movement := &game.movement

	end_turn_accepted := input.end_turn && game_turn_endable(game)
	if input.end_turn do append(events, Event_End_Turn{end_turn_accepted})
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

	orders: [Mover]Walk_Order
	losses: [2]struct {
		army:      Piece_Id,
		change:    Army_Change,
		men:       f32,
		readiness: f32,
	}
	if open := &game.interaction; open.actor != {} {
		if input.answer == .Next && movement.marches[.Leader].piece == {} {
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
					removed := slot_map_get(&game.pieces, removed_id)
					if removed == nil do continue
					settlement := slot_map_get(&game.pieces, removed.inside)
					occupant := slot_map_get(&game.pieces, removed.contains)
					if settlement != nil {
						settlement.contains = {}
						append(events, Event_Exit{removed_id, removed.inside})
					}
					if occupant != nil {
						occupant.inside = {}
						append(events, Event_Exit{removed.contains, removed_id})
					}
					if slot_map_remove(&game.pieces, removed_id) {
						append(events, Event_Removed{removed_id})
					}
				}
				beaten := slot_map_get(&game.pieces, loser)
				victor := slot_map_get(&game.pieces, winner)
				if !result.sides[fallen].falls_back || beaten == nil || victor == nil do break

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
						budget  = game_movement_left(victor^) + result.follow_overdraw,
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

		seed_source := [4]u64 {
			u64(game.turn),
			u64(game.player),
			transmute(u64)ids[0],
			transmute(u64)ids[1],
		}
		battle := Battle {
			ordered = contact.targeted,
			seed    = hash.fnv64a(mem.slice_to_bytes(seed_source[:])),
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
				temperament   = game_commander_temperament(game, piece),
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

	if player_order, ordered := input.order.?; ordered {
		piece := slot_map_get(&game.pieces, player_order.piece)
		ordering := game_ordering(game)
		refusal: Maybe(Order_Refusal)
		switch {
		case orders[.Leader].piece != {}:
			refusal = .Superseded
		case piece == nil:
			refusal = .No_Such_Piece
		case ordering == 0:
			refusal = .Not_Now
		case piece.owner != ordering:
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
				if settlement := slot_map_get(&game.pieces, piece.inside); settlement != nil {
					settlement.contains = {}
				}
				append(events, Event_Exit{walk.piece, piece.inside})
				piece.inside = {}
			}
			spent := min(due, game_movement_left(piece^))
			piece.this_turn.movement_spent += spent
			walk.overdrawn = due - spent
			append(
				events,
				Event_Moved{walk.piece, piece.pos, game_movement_left(piece^), walk.overdrawn},
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
					settlement.contains = march.piece
					append(events, Event_Enter{march.piece, march.into})
				}
			}
		}
	}
	if walk_done do movement.marches = {}

	turn_ending :=
		game.ending &&
		len(game.contacts) == 0 &&
		game.interaction.actor == {} &&
		movement.marches[.Leader].piece == {}

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
				piece.movement_per_turn > 0 ? 1 - game_movement_left(piece^) / piece.movement_per_turn : 0
			// Recovery: toward the supply level; gains scaled by rest
			delta := clamp(army.supply - readiness, -READINESS_SPEED, READINESS_SPEED)
			if delta > 0 do delta *= 1 - exertion
			readiness += delta
			if army.spent && readiness >= SPENT_READINESS {
				seed_source := [3]u64{u64(game.turn), u64(game.player), transmute(u64)id}
				rng := hash.fnv64a(mem.slice_to_bytes(seed_source[:]))
				roll := roll_2d6(&rng)
				total := roll + (readiness - SPENT_READINESS) * SPENT_ROLL_PER_READINESS
				append(events, Event_Spent_Roll{id, readiness, roll, total, SPENT_ROLL_TARGET})
				if total > SPENT_ROLL_TARGET {
					army.spent = false
					append(events, Event_Unspent{id})
				}
			}

			// Reinforcement on home land
			cell := cell_of(piece.pos)
			if grid_contains(cell, MAP_SIZE) {
				region := game.terrain.regions[grid_index(cell, MAP_SIZE)]
				capital := slot_map_get(&game.pieces, game.regions[region].capital)
				if capital != nil && capital.owner == piece.owner {
					men := math.round(REINFORCEMENT_SHARE * f32(army.men_max) * army.supply / 100)
					army.men = min(army.men_max, army.men + int(men))
				}
			}
		}

		army.readiness = clamp(readiness, 0, 100)
		if army.readiness < SPENT_READINESS && !army.spent {
			army.spent = true
			append(events, Event_Spent{id, army.readiness})
		}
		if changes != {} do append(events, Event_Army{id, changes, army^})
	}

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
		for piece in slot_map_iterate(&all) do piece.this_turn = {}
		game_supply_build(game)
	}
}

