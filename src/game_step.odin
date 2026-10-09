package main

import "core:fmt"
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
ROAD_READINESS_PER_MOVEMENT :: 0.1
@(private = "file")
READINESS_PER_MOVEMENT :: 1
@(private = "file")
OVERDRAW_READINESS :: 2
@(private = "file")
READINESS_RECOVERY :: 20
@(private = "file")
SUPPLY_DRAG :: 5
@(private = "file")
SUPPLY_REFILL_MAX :: 1
@(private = "file")
ROAD_STOCK_PER_MOVEMENT :: 0.002
@(private = "file")
STOCK_PER_MOVEMENT :: 0.01
@(private = "file")
SUPPLY_DECAY :: 2
@(private = "file")
MEN_PER_SUPPLY :: 250
@(private = "file")
FALL_BACK_BUDGET :: 10
@(private = "file")
CHASE_BUDGET :: 15
@(private = "file")
FORAGE_RADIUS :: 12
@(private = "file")
NO_GENERAL_TEMPERAMENT :: Temperament.Steady

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
	Conquer,
	Leave,
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
	Meet_Town,
	Announce,
	Report,
	Outcome,
	Fall_Back,
	Refused,
}

Interaction :: struct {
	actor:       Piece_Id,
	target:      Piece_Id,
	stage:       Interaction_Stage,
	conquerable: bool,
	result:      Battle_Result,
}

Movement :: struct {
	walker:         Piece_Id,
	target:         Piece_Id,
	path:           Polylines(WALK_POINTS_MAX, 1),
	path_costs:     [dynamic; WALK_POINTS_MAX]f32,
	next:           int,
	clear_of:       Piece_Id,
	chaser:         Piece_Id,
	chaser_next:    int,
	chaser_follows: bool,
	chaser_budget:  f32,
	flood:          Pathfind_Flood,
	flooded:        Piece_Id,
	flood_key:      u64,
	enemy_zones:    [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones:   [dynamic; PIECE_MAX]Disc,
	bodies:         [dynamic; PIECE_MAX]Disc,
}

@(private = "file")
Walk_Order :: struct {
	piece:          Piece_Id,
	target:         Piece_Id,
	destination:    [2]f32,
	snap:           int,
	budget:         f32,
	unhindered_by:  Piece_Id,
	clear_of:       Piece_Id,
	chaser:         Piece_Id,
	chaser_follows: bool,
	chaser_budget:  f32,
}

game_ordering :: proc(game: ^Game) -> Faction_Id {
	settled := game.interaction.actor == {} && !game.ending
	return settled ? game.player : 0
}

game_turn_endable :: proc(game: ^Game) -> bool {
	return(
		!game.ending &&
		game.movement.walker == {} &&
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
	zones: [dynamic; PIECE_MAX]Pathfind_Zone
	it := slot_map_iterator(&game.pieces)
	for piece in slot_map_iterate(&it) {
		if piece.owner == game.player {
			if piece.supply > 0 do append(&sources, Pathfind_Source{piece.pos, piece.supply})
		} else if piece.contact_radius > 0 && .Land in piece.contact_domains {
			append(&zones, Pathfind_Zone{{piece.pos, piece.contact_radius}, piece.hindrance})
		}
	}
	spread := make([]f32, MAP_CELLS, context.temp_allocator)
	pathfind_spread(.Land, sources[:], zones[:], SUPPLY_DECAY, spread)
	for value, i in spread do game.supply[i] = u8(clamp(value, 0, 100) + 0.5)
}

@(private = "file")
pieces_friendly :: proc(a, b: ^Piece_Data) -> bool {
	return a.owner != 0 && a.owner == b.owner
}

@(private = "file")
walk_along :: proc(
	pos: [2]f32,
	path: [][2]f32,
	costs: []f32,
	next, last: int,
	stride, max_due: f32,
) -> (
	moved: [2]f32,
	reached: int,
	road, off_road: f32,
) {
	moved = pos
	reached = next
	stride := stride
	for stride > 0 && reached <= last && road + off_road < max_due {
		target := path[reached]
		cost := costs[clamp(reached, 1, len(costs) - 1)]
		distance := linalg.distance(moved, target)
		walked := min(stride, distance)
		if cost > 0 do walked = min(walked, (max_due - road - off_road) / cost)
		if walked < distance {
			moved += linalg.normalize(target - moved) * walked
		} else {
			moved = target
			reached += 1
		}
		stride -= walked
		if cost == ROAD_COST {
			road += walked * cost
		} else {
			off_road += walked * cost
		}
	}
	return
}

game_step :: proc(game: ^Game, focus: Piece_Id, input: Game_Input) {
	movement := &game.movement

	if input.end_turn && game_turn_endable(game) {
		game.ending = true
		own := slot_map_iterator(&game.pieces)
		for piece, piece_id in slot_map_iterate(&own) {
			if piece.owner != game.player || piece.army == nil do continue
			enemies := slot_map_iterator(&game.pieces)
			for enemy, enemy_id in slot_map_iterate(&enemies) {
				if enemy.army == nil || pieces_friendly(piece, enemy) do continue
				if linalg.distance(piece.pos, enemy.pos) >= enemy.contact_radius do continue
				append(&game.contacts, Contact{initiator = piece_id, other = enemy_id})
			}
		}
	}

	order: Walk_Order
	losses: [2]struct {
		army:      Piece_Id,
		men:       f32,
		readiness: f32,
		stock:     f32,
	}
	if open := &game.interaction; open.actor != {} {
		if open.stage == .Meet_Town {
			if input.answer == .Conquer && open.conquerable {
				actor := slot_map_get(&game.pieces, open.actor)
				conquered := slot_map_get(&game.pieces, open.target)
				if actor != nil && conquered != nil do conquered.owner = actor.owner
				open^ = {}
			} else if input.answer == .Leave {
				open^ = {}
			}
		} else if input.answer == .Next && movement.walker == {} {
			result := &open.result
			ids := [2]Piece_Id{open.actor, open.target}
			fallen := 1 - result.winner
			loser := ids[fallen]
			winner := ids[result.winner]
			closed := true
			#partial switch open.stage {
			case .Announce:
				for side, i in result.sides {
					losses[i] = {ids[i], side.men.total, side.readiness, side.stock.total}
				}
				open.stage = .Report
				closed = false
			case .Report:
				open.stage = .Outcome
				closed = false
			case .Outcome:
				for side, i in result.sides do if side.dissolved do slot_map_remove(&game.pieces, ids[i])
				beaten := slot_map_get(&game.pieces, loser)
				victor := slot_map_get(&game.pieces, winner)
				if !result.sides[fallen].falls_back || beaten == nil || victor == nil do break

				reach: f32 = result.caught ? CHASE_BUDGET : FALL_BACK_BUDGET
				away := linalg.normalize0(beaten.pos - victor.pos)
				order = {
					piece         = loser,
					destination   = beaten.pos + away * reach,
					snap          = 2 * int(reach) + 1,
					budget        = reach,
					unhindered_by = winner,
				}
				if !result.caught do order.clear_of = winner
				if result.follows {
					order.chaser = winner
					order.chaser_follows = result.caught
					order.chaser_budget = game_movement_left(victor^) + result.follow_overdraw
				}
				if result.caught {
					side := result.sides[fallen]
					losses[fallen] = {loser, side.pursuit_men.total, side.pursuit_readiness, 0}
				}
				open.stage = .Fall_Back
				closed = false
			}
			if closed do open^ = {}
		}
	}

	for len(game.contacts) > 0 && game.interaction.actor == {} {
		contact := game.contacts[0]
		ordered_remove(&game.contacts, 0)
		initiator := slot_map_get(&game.pieces, contact.initiator)
		other := slot_map_get(&game.pieces, contact.other)
		if initiator == nil || other == nil || pieces_friendly(initiator, other) do continue
		reach := max(initiator.contact_radius, other.contact_radius)
		if linalg.distance(initiator.pos, other.pos) >= reach do continue

		if initiator.army == nil || other.army == nil {
			game.interaction = {
				actor       = contact.initiator,
				target      = contact.other,
				stage       = .Meet_Town,
				conquerable = .Captures in initiator.flags && .Capturable in other.flags,
			}
			continue
		}

		ids := [2]Piece_Id{contact.initiator, contact.other}
		pieces := [2]^Piece_Data{initiator, other}
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
			army, _ := piece.army.?
			battle.sides[i] = {
				men         = f32(army.men),
				men_max     = f32(army.men_max),
				proficiency = army.proficiency,
				readiness   = army.readiness,
				stock       = army.stock,
				baggage     = army.baggage,
				mobility    = army.mobility,
				temperament = game_commander_temperament(game, piece),
				can_attack  = !piece.this_turn.attacked,
				name        = game_piece_title(piece),
			}
		}

		result := battle_resolve(battle)
		if !result.fought && !result.refused do continue
		if result.fought do pieces[result.attacker].this_turn.attacked = true
		game.interaction = {
			actor  = ids[0],
			target = ids[1],
			stage  = result.fought ? .Announce : .Refused,
		}
		game.interaction.result = result
	}

	if player_order, ordered := input.order.?; ordered && order.piece == {} {
		piece := slot_map_get(&game.pieces, player_order.piece)
		ordering := game_ordering(game)
		if piece != nil && ordering != 0 && piece.owner == ordering {
			order = {
				piece       = player_order.piece,
				target      = player_order.target,
				destination = player_order.destination,
				snap        = player_order.snap,
			}
		}
	}

	{
		flooded := order.piece != {} ? order.piece : focus
		clear(&movement.enemy_zones)
		clear(&movement.friend_zones)
		clear(&movement.bodies)
		subject := slot_map_get(&game.pieces, flooded)
		domain, moves := Pathfind_Domain{}, false
		if subject != nil do domain, moves = subject.domain.?
		if !moves {
			movement.flooded = {}
			movement.flood_key = 0
		} else {
			budget := order.piece != {} && order.budget > 0 ? order.budget : game_movement_left(subject^)
			half: f32 = PATHFIND_FLOOD_SIZE / 2 + 1
			lo := subject.pos - half
			hi := subject.pos + half
			others := slot_map_iterator(&game.pieces)
			for other, other_id in slot_map_iterate(&others) {
				if other_id == flooded do continue
				body := Disc{other.pos, subject.body_radius + other.body_radius}
				if disc_overlaps_box(body, lo, hi) do append(&movement.bodies, body)
				if other.contact_radius == 0 || domain not_in other.contact_domains do continue
				zone := Disc{other.pos, other.contact_radius}
				if !disc_overlaps_box(zone, lo, hi) do continue
				if pieces_friendly(subject, other) {
					append(&movement.friend_zones, zone)
				} else if other_id != order.unhindered_by {
					append(&movement.enemy_zones, Pathfind_Zone{zone, other.hindrance})
				}
			}

			key_source := [4]u64 {
				transmute(u64)flooded,
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
				movement.flooded = flooded
				movement.flood_key = key
			}
		}
	}

	if order.piece != {} && movement.flooded == order.piece {
		stop: [2]int
		stoppable := false
		if target := slot_map_get(&game.pieces, order.target); target != nil {
			if movement.flood.domain in target.contact_domains {
				target_zone := Disc{target.pos, target.contact_radius}
				stop, stoppable = pathfind_flood_stop_within(&movement.flood, target_zone)
			}
		} else {
			stop, stoppable = pathfind_flood_stop(&movement.flood, order.destination, order.snap)
		}

		cells: [dynamic; PATHFIND_PATH_MAX][2]f32
		cell_costs: [dynamic; PATHFIND_PATH_MAX]f32
		traced := stoppable && pathfind_flood_trace(&movement.flood, cell_center(stop), &cells, &cell_costs)
		if traced {
			walker := slot_map_get(&game.pieces, order.piece)
			raw := new(Polylines(PATHFIND_PATH_MAX + 1, 1), context.temp_allocator)
			raw_points := polylines_reserve(len(cells) + 1, false, raw)
			raw_points[0] = walker.pos
			copy(raw_points[1:], cells[:])

			polylines_clear(&movement.path)
			polylines_smooth(raw, WALK_SMOOTHING, &movement.path)
			if len(movement.path.points) == 0 {
				polylines_reserve(1, false, &movement.path)[0] = walker.pos
			}

			clear(&movement.path_costs)
			for _, point in movement.path.points {
				raw_point := min(point >> uint(WALK_SMOOTHING.cut_iter), len(cells))
				append(&movement.path_costs, raw_point == 0 ? 0 : cell_costs[raw_point - 1])
			}

			movement.walker = order.piece
			movement.target = order.target
			movement.next = 1
			movement.clear_of = order.clear_of
			movement.chaser = order.chaser
			movement.chaser_next = 0
			movement.chaser_follows = order.chaser_follows
			movement.chaser_budget = order.chaser_budget
		} else {
			fmt.eprintln("No way for", order.piece)
		}
	}

	walks: [2]struct {
		piece:            Piece_Id,
		marched_road:     f32,
		marched_off_road: f32,
		overdrawn:        f32,
	}
	walker := slot_map_get(&game.pieces, movement.walker)
	walk_done := walker == nil
	if walker != nil {
		path := movement.path.points[:]
		costs := movement.path_costs[:]
		last := len(path) - 1

		clear_of := slot_map_get(&game.pieces, movement.clear_of)
		got_clear := clear_of != nil && !disc_contains({clear_of.pos, clear_of.contact_radius}, walker.pos)
		if !got_clear {
			moved, reached, road, off_road := walk_along(
				walker.pos,
				path,
				costs,
				movement.next,
				last,
				WALK_CELLS_PER_STEP,
				math.INF_F32,
			)
			walker.pos = moved
			movement.next = reached
			walks[0] = {movement.walker, road, off_road, 0}
		}

		chasing := false
		if chaser := slot_map_get(&game.pieces, movement.chaser); chaser != nil {
			until := movement.chaser_follows ? last : 0
			touching := linalg.distance(chaser.pos, walker.pos) <= chaser.body_radius + walker.body_radius
			chasing = !touching && movement.chaser_next <= until && movement.chaser_budget > 0
			if chasing {
				moved, reached, road, off_road := walk_along(
					chaser.pos,
					path,
					costs,
					movement.chaser_next,
					until,
					WALK_CELLS_PER_STEP,
					movement.chaser_budget,
				)
				chaser.pos = moved
				movement.chaser_next = reached
				movement.chaser_budget -= road + off_road
				walks[1] = {movement.chaser, road, off_road, 0}
			}
		}

		for &walk in walks {
			piece := slot_map_get(&game.pieces, walk.piece)
			if piece == nil do continue
			due := walk.marched_road + walk.marched_off_road
			spent := min(due, game_movement_left(piece^))
			piece.this_turn.movement_spent += spent
			walk.overdrawn = due - spent
		}

		walk_done = (movement.next > last || got_clear) && !chasing
		if walk_done && movement.target != {} {
			append(&game.contacts, Contact{movement.walker, movement.target, true})
		}
	}
	if walk_done {
		movement.walker = {}
		movement.target = {}
		movement.next = 0
		movement.clear_of = {}
		movement.chaser = {}
	}

	turn_ending :=
		game.ending &&
		len(game.contacts) == 0 &&
		game.interaction.actor == {} &&
		movement.walker == {}

	pieces := slot_map_iterator(&game.pieces)
	for piece, id in slot_map_iterate(&pieces) {
		army, is_army := &piece.army.?
		if !is_army do continue
		readiness := army.readiness
		stock := army.stock

		for loss in losses {
			if loss.army != id do continue
			army.men = max(0, army.men + int(math.round(loss.men)))
			readiness += loss.readiness
			stock += loss.stock
		}

		if piece.owner == game.player {
			men := f32(army.men)
			cell := cell_of(piece.pos)
			network, network_efficiency, forage, forage_efficiency: f32
			if grid_contains(cell, MAP_SIZE) && men > 0 {
				at := grid_index(cell, MAP_SIZE)

				friendly_men, all_men: f32
				others := slot_map_iterator(&game.pieces)
				for other in slot_map_iterate(&others) {
					other_army, other_is_army := other.army.?
					if !other_is_army do continue
					distance := linalg.distance(piece.pos, other.pos)
					if distance >= FORAGE_RADIUS do continue
					weighted := f32(other_army.men) * (1 - distance / FORAGE_RADIUS)
					all_men += weighted
					if other.owner == piece.owner do friendly_men += weighted
				}

				network_efficiency = men / friendly_men
				network = f32(game.supply[at]) * MEN_PER_SUPPLY / men * network_efficiency

				yield: f32
				if game.terrain.surface[at] == 0 {
					cover := game.terrain.cover[at]
					yield = math.lerp(FORAGE_YIELD[.Open], FORAGE_YIELD[cover.kind], f32(cover.strength) / 255)
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

		for walk in walks {
			if walk.piece != id do continue
			readiness -= walk.marched_road * ROAD_READINESS_PER_MOVEMENT
			readiness -= walk.marched_off_road * READINESS_PER_MOVEMENT
			readiness -= walk.overdrawn * OVERDRAW_READINESS
			stock -= walk.marched_road * ROAD_STOCK_PER_MOVEMENT
			stock -= walk.marched_off_road * STOCK_PER_MOVEMENT
		}

		if turn_ending && piece.owner == game.player {
			stock = clamp(stock + army.resupply, 0, army.baggage)
			readiness_cap: f32 = army.baggage > 0 ? 100 * stock / army.baggage : 0
			exertion: f32 =
				piece.movement_per_turn > 0 ? 1 - game_movement_left(piece^) / piece.movement_per_turn : 0
			rest := (1 - exertion) * (1 - exertion)
			if readiness < readiness_cap {
				readiness = min(readiness_cap, readiness + READINESS_RECOVERY * rest)
			} else {
				readiness = max(readiness_cap, readiness - SUPPLY_DRAG)
			}
		}

		army.readiness = clamp(readiness, 0, 100)
		army.stock = clamp(stock, 0, army.baggage)
	}

	if turn_ending {
		game.ending = false
		next_player := int(game.player) + 1
		if next_player >= len(game.factions) {
			next_player = 1
			game.turn += 1
		}
		game.player = Faction_Id(next_player)

		all := slot_map_iterator(&game.pieces)
		for piece in slot_map_iterate(&all) do piece.this_turn = {}
		game_supply_build(game)
	}
}
