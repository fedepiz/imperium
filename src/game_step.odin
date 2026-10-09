package main

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:mem"

STEPS_PER_SECOND :: 60
STEP_SECONDS :: 1.0 / f32(STEPS_PER_SECOND)
STEPS_PER_FRAME_MAX :: 4

CONTACTS_MAX :: 256

WALK_SMOOTHING :: Polyline_Smoothing {
	softness    = 1,
	soften_iter = 2,
	cut_iter    = 2,
	cut_ratio   = 0.25,
}
WALK_POINTS_MAX :: (PATHFIND_PATH_MAX + 1) << uint(WALK_SMOOTHING.cut_iter)

@(private = "file")
WALK_CELLS_PER_SECOND :: 10
@(private = "file")
ROAD_READINESS_PER_MOVEMENT :: 0.1
@(private = "file")
READINESS_PER_MOVEMENT :: 1
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
MEN_PER_SUPPLY :: 200
@(private = "file")
ORDERED_ATTACK_BONUS :: 2
@(private = "file")
FALL_BACK_BUDGET :: 10
@(private = "file")
PURSUIT_BUDGET :: 15
@(private = "file")
PURSUIT_SNAP :: 9
@(private = "file")
FORAGE_RADIUS :: 12

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

Game_Ask :: enum u8 {
	End_Turn,
	Conquer,
	Leave,
	Battle_Next,
}

Game_Order :: struct {
	piece:       Piece_Id,
	target:      Piece_Id,
	destination: [2]f32,
	snap:        int,
}

Game_Input :: struct {
	asks:  bit_set[Game_Ask],
	order: Maybe(Game_Order),
}

Contact :: struct {
	initiator: Piece_Id,
	other:     Piece_Id,
	targeted:  bool,
}

Interaction :: struct {
	actor:       Piece_Id,
	target:      Piece_Id,
	conquerable: bool,
}

Engagement_Stage :: enum u8 {
	Announce,
	Report,
	Outcome,
	Fall_Back,
	Pursuit,
}

Engagement :: struct {
	attacker:    Piece_Id,
	defender:    Piece_Id,
	battle:      Battle,
	result:      Battle_Result,
	stage:       Engagement_Stage,
	loser_start: [2]f32,
}

Movement :: struct {
	walker:       Piece_Id,
	target:       Piece_Id,
	path:         Polylines(WALK_POINTS_MAX, 1),
	path_costs:   [dynamic; WALK_POINTS_MAX]f32,
	next:         int,
	flood:        Pathfind_Flood,
	flooded:      Piece_Id,
	flood_key:    u64,
	enemy_zones:  [dynamic; PIECE_MAX]Pathfind_Zone,
	friend_zones: [dynamic; PIECE_MAX]Disc,
	bodies:       [dynamic; PIECE_MAX]Disc,
}

game_ordering :: proc(game: ^Game) -> Faction_Id {
	settled := game.interaction.actor == {} && game.engagement.attacker == {} && !game.ending
	return settled ? game.player : 0
}

game_turn_endable :: proc(game: ^Game) -> bool {
	return(
		!game.ending &&
		game.movement.walker == {} &&
		len(game.contacts) == 0 &&
		game.interaction.actor == {} &&
		game.engagement.attacker == {} \
	)
}

game_movement_left :: proc(game: ^Game, piece: Piece_Data) -> f32 {
	if piece.movement_turn != game.turn do return piece.movement_per_turn
	return max(0, piece.movement_per_turn - piece.movement_spent)
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

game_step :: proc(game: ^Game, focus: Piece_Id, input: Game_Input) {
	movement := &game.movement
	engagement := &game.engagement

	if .End_Turn in input.asks && game_turn_endable(game) {
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

	if game.interaction.actor != {} {
		if .Conquer in input.asks && game.interaction.conquerable {
			actor := slot_map_get_ptr(&game.pieces, game.interaction.actor)
			conquered := slot_map_get_ptr(&game.pieces, game.interaction.target)
			if actor != nil && conquered != nil do conquered.owner = actor.owner
			game.interaction = {}
		} else if .Leave in input.asks {
			game.interaction = {}
		}
	}

	for len(game.contacts) > 0 && engagement.attacker == {} && game.interaction.actor == {} {
		contact := game.contacts[0]
		ordered_remove(&game.contacts, 0)
		initiator := slot_map_get_ptr(&game.pieces, contact.initiator)
		other := slot_map_get_ptr(&game.pieces, contact.other)
		if initiator == nil || other == nil || pieces_friendly(initiator, other) do continue
		reach := max(initiator.contact_radius, other.contact_radius)
		if linalg.distance(initiator.pos, other.pos) >= reach do continue

		initiator_army, initiator_is_army := &initiator.army.?
		other_army, other_is_army := &other.army.?
		if !initiator_is_army || !other_is_army {
			game.interaction = {
				actor       = contact.initiator,
				target      = contact.other,
				conquerable = .Captures in initiator.flags && .Capturable in other.flags,
			}
			continue
		}

		ids := [2]Piece_Id{contact.initiator, contact.other}
		armies := [2]^Army{initiator_army, other_army}
		sides: [2]Battle_Side
		for army, i in armies {
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
		strength_gap := battle_strength(sides[0], sides[1]) - battle_strength(sides[1], sides[0])
		eagerness: f32 = contact.targeted ? ORDERED_ATTACK_BONUS : 0
		initiator_fresh := armies[0].attacked_turn != game.turn
		other_fresh := armies[1].attacked_turn != game.turn
		switch {
		case initiator_fresh && strength_gap + eagerness >= BATTLE_ATTACK_THRESHOLD[sides[0].temperament]:
		case other_fresh && -strength_gap >= BATTLE_ATTACK_THRESHOLD[sides[1].temperament]:
			ids[0], ids[1] = ids[1], ids[0]
			armies[0], armies[1] = armies[1], armies[0]
			sides[0], sides[1] = sides[1], sides[0]
		case:
			continue
		}
		armies[0].attacked_turn = game.turn

		seed_source := [3]u64{u64(game.turn), transmute(u64)ids[0], transmute(u64)ids[1]}
		engagement^ = {
			attacker = ids[0],
			defender = ids[1],
			stage = .Announce,
			battle = {
				sides = {.Attacker = sides[0], .Defender = sides[1]},
				seed = hash.fnv64a(mem.slice_to_bytes(seed_source[:])),
			},
		}
	}

	fought: struct {
		roles:  [Battle_Role]Piece_Id,
		result: Battle_Result,
	}
	order: Game_Order
	order_budget: f32
	if engagement.attacker != {} && .Battle_Next in input.asks && movement.walker == {} {
		result := engagement.result
		roles := [Battle_Role]Piece_Id {
			.Attacker = engagement.attacker,
			.Defender = engagement.defender,
		}
		winner := roles[result.winner]
		loser := roles[BATTLE_OTHER_ROLE[result.winner]]
		closed := true
		switch engagement.stage {
		case .Announce:
			engagement.result = battle_resolve(engagement.battle)
			fought = {roles, engagement.result}
			engagement.stage = .Report
			closed = false
		case .Report:
			engagement.stage = .Outcome
			closed = false
		case .Outcome:
			for side, role in result.sides do if side.dissolved do slot_map_remove(&game.pieces, roles[role])
			beaten := slot_map_get_ptr(&game.pieces, loser)
			victor := slot_map_get_ptr(&game.pieces, winner)
			if beaten == nil || victor == nil do break
			if !result.sides[BATTLE_OTHER_ROLE[result.winner]].falls_back do break
			engagement.loser_start = beaten.pos
			away := linalg.normalize0(beaten.pos - victor.pos)
			order = {
				piece       = loser,
				destination = beaten.pos + away * FALL_BACK_BUDGET,
				snap        = 2 * FALL_BACK_BUDGET + 1,
			}
			order_budget = FALL_BACK_BUDGET
			engagement.stage = .Fall_Back
			closed = false
		case .Fall_Back:
			if !result.pursued do break
			if slot_map_get_ptr(&game.pieces, winner) == nil || slot_map_get_ptr(&game.pieces, loser) == nil do break
			order = {
				piece       = winner,
				destination = engagement.loser_start,
				snap        = PURSUIT_SNAP,
			}
			order_budget = PURSUIT_BUDGET
			engagement.stage = .Pursuit
			closed = false
		case .Pursuit:
		}
		if closed do engagement^ = {}
	}

	if player_order, ordered := input.order.?; ordered && order.piece == {} {
		piece := slot_map_get_ptr(&game.pieces, player_order.piece)
		ordering := game_ordering(game)
		if piece != nil && ordering != 0 && piece.owner == ordering do order = player_order
	}

	{
		flooded := order.piece != {} ? order.piece : focus
		clear(&movement.enemy_zones)
		clear(&movement.friend_zones)
		clear(&movement.bodies)
		subject := slot_map_get_ptr(&game.pieces, flooded)
		domain, moves := Pathfind_Domain{}, false
		if subject != nil do domain, moves = subject.domain.?
		if !moves {
			movement.flooded = {}
			movement.flood_key = 0
		} else {
			budget := order.piece != {} && order_budget > 0 ? order_budget : game_movement_left(game, subject^)
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
				} else {
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
		if target := slot_map_get_ptr(&game.pieces, order.target); target != nil {
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
			walker := slot_map_get_ptr(&game.pieces, order.piece)
			raw := new(Polylines(PATHFIND_PATH_MAX + 1, 1), context.temp_allocator)
			raw_points := polylines_reserve(len(cells) + 1, false, raw)
			raw_points[0] = walker.pos
			copy(raw_points[1:], cells[:])

			polylines_clear(&movement.path)
			polylines_smooth(raw, WALK_SMOOTHING, &movement.path)

			clear(&movement.path_costs)
			for _, point in movement.path.points {
				raw_point := min(point >> uint(WALK_SMOOTHING.cut_iter), len(cells))
				append(&movement.path_costs, raw_point == 0 ? 0 : cell_costs[raw_point - 1])
			}

			movement.walker = order.piece
			movement.target = order.target
			movement.next = 1
		} else {
			fmt.eprintln("No way for", order.piece)
		}
	}

	walk: struct {
		piece:          Piece_Id,
		spent_road:     f32,
		spent_off_road: f32,
	}
	if walker := slot_map_get_ptr(&game.pieces, movement.walker); walker != nil {
		walk.piece = movement.walker
		start := walker.pos
		path := movement.path.points[:]
		stride: f32 = WALK_CELLS_PER_SECOND * STEP_SECONDS
		for stride > 0 && movement.next < len(path) {
			next_point := path[movement.next]
			cost := movement.path_costs[movement.next]
			distance := linalg.distance(walker.pos, next_point)
			walked := min(stride, distance)
			stride -= walked
			if walked < distance {
				walker.pos += linalg.normalize(next_point - walker.pos) * walked
			} else {
				walker.pos = next_point
				movement.next += 1
			}

			spent := min(walked * cost, game_movement_left(game, walker^))
			if walker.movement_turn != game.turn {
				walker.movement_turn = game.turn
				walker.movement_spent = 0
			}
			walker.movement_spent += spent
			if cost == ROAD_COST {
				walk.spent_road += spent
			} else {
				walk.spent_off_road += spent
			}
		}

		met: Piece_Id
		domain, _ := walker.domain.?
		if engagement.attacker == {} {
			others := slot_map_iterator(&game.pieces)
			for other, other_id in slot_map_iterate(&others) {
				if other_id == walk.piece || pieces_friendly(walker, other) do continue
				if other.contact_radius == 0 || domain not_in other.contact_domains do continue
				zone := Disc{other.pos, other.contact_radius}
				if disc_contains(zone, walker.pos) && !disc_contains(zone, start) {
					met = other_id
					break
				}
			}
		}

		arrived := movement.next >= len(path)
		if met != {} || arrived {
			if met == {} do met = movement.target
			if met != {} {
				append(&game.contacts, Contact{walk.piece, met, met == movement.target})
			}
			movement.walker = {}
			movement.target = {}
			movement.next = 0
		}
	} else {
		movement.walker = {}
		movement.target = {}
		movement.next = 0
	}

	turn_ending :=
		game.ending &&
		len(game.contacts) == 0 &&
		engagement.attacker == {} &&
		game.interaction.actor == {} &&
		movement.walker == {}

	pieces := slot_map_iterator(&game.pieces)
	for piece, id in slot_map_iterate(&pieces) {
		army, is_army := &piece.army.?
		if !is_army do continue
		readiness := army.readiness
		stock := army.stock

		for fought_id, role in fought.roles {
			if fought_id != id do continue
			side := fought.result.sides[role]
			army.men = max(0, army.men + int(math.round(side.men_change)))
			readiness += side.readiness_change
			stock += side.stock_change
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

		if walk.piece == id {
			readiness -= walk.spent_road * ROAD_READINESS_PER_MOVEMENT
			readiness -= walk.spent_off_road * READINESS_PER_MOVEMENT
			stock -= walk.spent_road * ROAD_STOCK_PER_MOVEMENT
			stock -= walk.spent_off_road * STOCK_PER_MOVEMENT
		}

		if turn_ending && piece.owner == game.player {
			stock = clamp(stock + army.resupply, 0, army.baggage)
			readiness_cap: f32 = army.baggage > 0 ? 100 * stock / army.baggage : 0
			exertion: f32 =
				piece.movement_per_turn > 0 ? 1 - game_movement_left(game, piece^) / piece.movement_per_turn : 0
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
		game_supply_build(game)
	}
}
