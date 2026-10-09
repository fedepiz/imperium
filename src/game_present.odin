package main

import "core:fmt"
import "core:math"

CARD_LINES_MAX :: 16
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4

Map_Mode :: enum u8 {
	Control,
	Supply,
	Plain,
}

@(rodata)
MAP_MODE_NAMES := [Map_Mode]string {
	.Control = "Control",
	.Supply  = "Supply",
	.Plain   = "Plain",
}

@(private = "file")
REGION_UNHELD_COLOR :: [3]f32{0.6, 0.6, 0.6}

@(private = "file")
REACH_SLOT :: 0
@(private = "file")
FRIEND_ZONES_SLOT :: 1
@(private = "file")
ENEMY_ZONES_SLOT :: 2

@(private = "file", rodata)
ICON_TITLES := [Map_Icon]string {
	.Village    = "Village",
	.Town       = "Town",
	.City       = "City",
	.Large_City = "Large City",
	.Army       = "Army",
	.Fleet      = "Fleet",
}

@(private = "file", rodata)
ROLE_TITLES := [Battle_Role]string {
	.Attacker = "Attacker",
	.Defender = "Defender",
}

@(private = "file", rodata)
OUTCOME_TITLES := [Battle_Outcome]string {
	.Avoided      = "Avoided",
	.Stalemate    = "Stalemate",
	.Probed       = "Probed",
	.Withdrew     = "Withdrew",
	.Repulsed     = "Repulsed",
	.Defeat       = "Defeat",
	.Heavy_Defeat = "Heavy defeat",
	.Rout         = "Rout",
}

@(private = "file", rodata)
POSTURE_VERBS := [Posture]string {
	.Press    = "presses",
	.Standard = "stands",
	.Probe    = "probes",
}

@(private = "file", rodata)
CHOICE_VERBS := [Crisis_Choice]string {
	.Hold      = "holds",
	.Commit    = "commits",
	.Break_Off = "breaks off",
}

@(private = "file", rodata)
LOSER_FATES := [Battle_Outcome]string {
	.Avoided      = "gets away",
	.Stalemate    = "holds its ground",
	.Probed       = "pulls out",
	.Withdrew     = "withdraws",
	.Repulsed     = "is repulsed",
	.Defeat       = "is defeated",
	.Heavy_Defeat = "is heavily defeated",
	.Rout         = "is routed",
}

Card_Field :: struct {
	label: string,
	value: string,
}

Card_Action :: struct {
	label:   string,
	ask:     Game_Ask,
	enabled: bool,
}

Card :: struct {
	title:   string,
	lines:   [dynamic; CARD_LINES_MAX]string,
	fields:  [dynamic; CARD_FIELDS_MAX]Card_Field,
	stats:   [dynamic; CARD_FIELDS_MAX]Card_Field,
	actions: [dynamic; CARD_ACTIONS_MAX]Card_Action,
}

Cards :: struct {
	status:      Card,
	focus:       Maybe(Card),
	interaction: Maybe(Card),
	battle:      Maybe(Card),
}

game_present_map :: proc(
	game: ^Game,
	focus: Piece_Id,
	pointed: Region_Id,
	mode: Map_Mode,
	frame: ^Render_Terrain_Frame,
) {
	movement := &game.movement
	reach_shown :=
		movement.flood_key != 0 && movement.flooded == focus && movement.flooded != movement.walker

	frame.region_display = mode == .Control ? .Filled_When_Far : .Hidden
	for &region, id in game.regions {
		color := REGION_UNHELD_COLOR
		capital := slot_map_get_ptr(&game.pieces, region.capital)
		if mode == .Control && capital != nil && capital.owner != 0 {
			color = game.factions[capital.owner].color
		}
		frame.regions[id] = {
			color       = color,
			highlighted = mode == .Control && !reach_shown && Region_Id(id) == pointed,
		}
	}

	if reach_shown {
		flood := &movement.flood
		on_water := flood.domain != .Land
		piece := slot_map_get_ptr(&game.pieces, focus)
		controlled := piece != nil && game_ordering(game) != 0 && piece.owner == game_ordering(game)

		frame.highlights[REACH_SLOT] = {
			kind        = controlled ? .Reach : .Foreign_Reach,
			on_water    = on_water,
			corner      = flood.corner,
			size        = {PATHFIND_FLOOD_SIZE, PATHFIND_FLOOD_SIZE},
			cells_begin = len(frame.highlight_cells),
		}
		for cost in flood.cost do append(&frame.highlight_cells, cost < math.INF_F32)

		friends := &frame.highlights[FRIEND_ZONES_SLOT]
		friends^ = {
			kind          = .Contact,
			on_water      = on_water,
			circles_begin = len(frame.highlight_circles),
		}
		for zone in movement.friend_zones {
			append(&frame.highlight_circles, Render_Circle{zone.center, zone.radius})
		}
		friends.circles_len = len(frame.highlight_circles) - friends.circles_begin

		enemies := &frame.highlights[ENEMY_ZONES_SLOT]
		enemies^ = {
			kind          = .Zone,
			on_water      = on_water,
			circles_begin = len(frame.highlight_circles),
		}
		for zone in movement.enemy_zones {
			append(&frame.highlight_circles, Render_Circle{zone.disc.center, zone.disc.radius})
		}
		enemies.circles_len = len(frame.highlight_circles) - enemies.circles_begin
	}

	if walker := slot_map_get_ptr(&game.pieces, movement.walker); walker != nil {
		append(&frame.arrow, walker.pos)
		append(&frame.arrow, ..movement.path.points[movement.next:])
	}

	if mode == .Supply {
		resize(&frame.wash, RENDER_TERRAIN_CELLS)
		for supply, i in game.supply do frame.wash[i] = u8(u32(supply) * 255 / 100)
	}
}

game_present_pawns :: proc(
	game: ^Game,
	focus: Piece_Id,
	pawns: ^Map_Pawns,
	pawn_pieces: ^[dynamic; MAP_PAWNS_MAX]Piece_Id,
) {
	it := slot_map_iterator(&game.pieces)
	for piece, id in slot_map_iterate(&it) {
		engaged := id == game.engagement.attacker || id == game.engagement.defender
		pawn := Map_Pawn {
			pos         = piece.pos,
			icon        = piece.icon,
			culture     = piece.culture,
			highlighted = engaged,
			pulsing     = id == focus,
			label       = name_to_string(&piece.name),
		}
		append(&pawns.scene, pawn)
		append(pawn_pieces, id)
	}
}

@(private = "file")
piece_title :: proc(piece: ^Piece_Data) -> string {
	name := name_to_string(&piece.name)
	return name != "" ? name : ICON_TITLES[piece.icon]
}

@(private = "file")
faction_title :: proc(game: ^Game, faction: Faction_Id) -> string {
	return faction != 0 ? name_to_string(&game.factions[faction].name) : "None"
}

@(private = "file")
compact_number :: proc(value: f64) -> string {
	SUFFIXES :: [?]string{"", "K", "M", "B"}
	sign := value < 0 ? "-" : ""
	magnitude := abs(value)
	tier := 0
	for math.round(magnitude) >= 1000 && tier < len(SUFFIXES) - 1 {
		magnitude /= 1000
		tier += 1
	}
	suffixes := SUFFIXES
	switch {
	case tier == 0:
		return fmt.tprintf("%s%.0f", sign, magnitude)
	case math.round(magnitude * 100) < 1000:
		return fmt.tprintf("%s%.2f%s", sign, magnitude, suffixes[tier])
	case math.round(magnitude * 10) < 1000:
		return fmt.tprintf("%s%.1f%s", sign, magnitude, suffixes[tier])
	}
	return fmt.tprintf("%s%.0f%s", sign, magnitude, suffixes[tier])
}

game_cards :: proc(game: ^Game, focus: Piece_Id, cards: ^Cards) {
	cards^ = {}

	status := &cards.status
	status.title = fmt.tprintf("Turn %d", game.turn)
	append(&status.fields, Card_Field{"Playing", faction_title(game, game.player)})
	append(&status.actions, Card_Action{"End turn", .End_Turn, game_turn_endable(game)})

	if piece := slot_map_get_ptr(&game.pieces, focus); piece != nil {
		card := Card {
			title = piece_title(piece),
		}
		append(&card.fields, Card_Field{"Type", ICON_TITLES[piece.icon]})
		append(&card.fields, Card_Field{"Faction", faction_title(game, piece.owner)})
		append(&card.fields, Card_Field{"Culture", fmt.tprint(piece.culture)})
		if piece.general != 0 {
			general := name_to_string(&game.characters[piece.general].name)
			append(&card.fields, Card_Field{"General", general})
		}
		army, is_army := piece.army.?
		if is_army {
			append(&card.fields, Card_Field{"Baggage", fmt.tprintf("%.0f turns", army.baggage)})
		}
		if piece.domain != nil {
			left := compact_number(f64(game_movement_left(game, piece^)))
			per_turn := compact_number(f64(piece.movement_per_turn))
			append(&card.stats, Card_Field{"Movement", fmt.tprintf("%s of %s", left, per_turn)})
		}
		if is_army {
			men := fmt.tprintf("%s of %s", compact_number(f64(army.men)), compact_number(f64(army.men_max)))
			supply: f32 = army.baggage > 0 ? 100 * army.stock / army.baggage : 0
			append(&card.stats, Card_Field{"Men", men})
			append(&card.stats, Card_Field{"Proficiency", fmt.tprintf("%.0f%%", army.proficiency)})
			append(&card.stats, Card_Field{"Readiness", fmt.tprintf("%.0f%%", army.readiness)})
			append(&card.stats, Card_Field{"Supply", fmt.tprintf("%.0f%%", supply)})
			append(&card.stats, Card_Field{"Stock", fmt.tprintf("%.1f (%+.1f)", army.stock, army.resupply)})
			append(&card.stats, Card_Field{"Source", fmt.tprint(army.resupply_source)})
			append(
				&card.stats,
				Card_Field{"Efficiency", fmt.tprintf("%.0f%%", 100 * army.resupply_efficiency)},
			)
		}
		cards.focus = card
	}

	interaction := game.interaction
	actor := slot_map_get_ptr(&game.pieces, interaction.actor)
	met := slot_map_get_ptr(&game.pieces, interaction.target)
	if actor != nil && met != nil {
		card := Card {
			title = piece_title(met),
		}
		append(&card.fields, Card_Field{"Met by", piece_title(actor)})
		append(&card.fields, Card_Field{"Faction", faction_title(game, met.owner)})
		append(&card.actions, Card_Action{"Conquer", .Conquer, interaction.conquerable})
		append(&card.actions, Card_Action{"Back", .Leave, true})
		cards.interaction = card
	}

	engagement := &game.engagement
	attacker := slot_map_get_ptr(&game.pieces, engagement.attacker)
	defender := slot_map_get_ptr(&game.pieces, engagement.defender)
	if engagement.attacker != {} {
		result := engagement.result
		names := [Battle_Role]string {
			.Attacker = attacker != nil ? piece_title(attacker) : "",
			.Defender = defender != nil ? piece_title(defender) : "",
		}
		winner := names[result.winner]
		loser := names[BATTLE_OTHER_ROLE[result.winner]]
		card: Card

		switch engagement.stage {
		case .Announce:
			card.title = fmt.tprintf("%s attacks %s", names[.Attacker], names[.Defender])
		case .Outcome:
			card.title = fmt.tprintf("Battle: %s", OUTCOME_TITLES[result.outcome])
		case .Fall_Back:
			card.title = fmt.tprintf("%s falls back", loser)
		case .Pursuit:
			card.title = fmt.tprintf("%s pursues", winner)
		case .Report:
			card.title = "Battle report"
			lines := &card.lines
			a := result.sides[.Attacker]
			d := result.sides[.Defender]
			append(
				lines,
				fmt.tprintf(
					"%s attacks %s, power %.1f against %.1f.",
					names[.Attacker],
					names[.Defender],
					a.power,
					d.power,
				),
			)

			if roll := result.avoid; roll.rolled {
				escape := result.outcome == .Avoided ? "gets away" : "is caught"
				append(
					lines,
					fmt.tprintf(
						"%s tries to avoid battle: rolls %.0f, total %.0f against %.0f, and %s.",
						names[.Defender],
						roll.dice,
						roll.total,
						roll.target,
						escape,
					),
				)
			}
			if result.outcome == .Avoided do break

			append(
				lines,
				fmt.tprintf(
					"%s %s; %s %s.",
					names[.Attacker],
					POSTURE_VERBS[a.posture],
					names[.Defender],
					POSTURE_VERBS[d.posture],
				),
			)
			if a.onset.rolled {
				append(
					lines,
					fmt.tprintf(
						"Onset: %s rolls %.0f for %.1f, %s rolls %.0f for %.1f.",
						names[.Attacker],
						a.onset.dice,
						a.onset.total,
						names[.Defender],
						d.onset.dice,
						d.onset.total,
					),
				)
				ahead: Battle_Role = a.onset.total > d.onset.total ? .Attacker : .Defender
				behind := BATTLE_OTHER_ROLE[ahead]
				margin := result.onset_margin
				switch {
				case a.onset.total == d.onset.total:
					append(lines, "Neither gains the upper hand.")
				case !result.crisis_chosen && !result.pulled_out:
					append(
						lines,
						fmt.tprintf(
							"%s wins by %.1f, and %s %s.",
							names[ahead],
							margin,
							names[behind],
							LOSER_FATES[result.outcome],
						),
					)
				case result.sides[ahead].edge == 0:
					append(lines, fmt.tprintf("%s wins by %.1f but gains no edge.", names[ahead], margin))
				case:
					append(
						lines,
						fmt.tprintf(
							"%s wins by %.1f and gains an edge of %.0f.",
							names[ahead],
							margin,
							result.sides[ahead].edge,
						),
					)
				}
			}
			if result.pulled_out {
				append(lines, fmt.tprintf("%s, probing and behind, pulls out.", loser))
			}

			if result.crisis_chosen {
				append(
					lines,
					fmt.tprintf(
						"%s %s; %s %s.",
						names[.Attacker],
						CHOICE_VERBS[a.choice],
						names[.Defender],
						CHOICE_VERBS[d.choice],
					),
				)
				if a.crisis.rolled {
					append(
						lines,
						fmt.tprintf(
							"Crisis: %s rolls %.0f for %.1f, %s rolls %.0f for %.1f, a margin of %.1f.",
							names[.Attacker],
							a.crisis.dice,
							a.crisis.total,
							names[.Defender],
							d.crisis.dice,
							d.crisis.total,
							result.crisis_margin,
						),
					)
				}
				if result.outcome == .Stalemate {
					append(lines, "Stalemate.")
				} else {
					append(lines, fmt.tprintf("%s %s.", loser, LOSER_FATES[result.outcome]))
				}
				if result.worsened {
					append(lines, fmt.tprintf("Having pressed or committed, %s fares worse.", loser))
				}
			}

			if roll := result.pursuit; roll.rolled {
				caught := result.pursued ? "catches them" : "they get away"
				append(
					lines,
					fmt.tprintf(
						"%s pursues: rolls %.0f, total %.0f against %.0f, and %s.",
						winner,
						roll.dice,
						roll.total,
						roll.target,
						caught,
					),
				)
			}
			for side, role in result.sides {
				if !side.hold.rolled do continue
				fate := side.dissolved ? "it dissolves" : "it holds"
				append(
					lines,
					fmt.tprintf(
						"%s rolls %.0f to hold together, total %.1f against %.1f: %s.",
						names[role],
						side.hold.dice,
						side.hold.total,
						side.hold.target,
						fate,
					),
				)
			}
		}

		if engagement.stage != .Report {
			for role in Battle_Role {
				column := role == .Attacker ? &card.fields : &card.stats
				append(column, Card_Field{ROLE_TITLES[role], names[role]})
				if engagement.stage == .Announce {
					side := engagement.battle.sides[role]
					other := engagement.battle.sides[BATTLE_OTHER_ROLE[role]]
					append(column, Card_Field{"Commander", fmt.tprint(side.temperament)})
					append(column, Card_Field{"Men", compact_number(f64(side.men))})
					append(column, Card_Field{"Proficiency", fmt.tprintf("%.0f%%", side.proficiency)})
					append(column, Card_Field{"Readiness", fmt.tprintf("%.0f%%", side.readiness)})
					append(
						column,
						Card_Field{"Power", fmt.tprintf("%.1f", battle_strength(side, other))},
					)
				} else {
					side := result.sides[role]
					append(column, Card_Field{"Posture", fmt.tprint(side.posture)})
					append(column, Card_Field{"Men", compact_number(f64(side.men_change))})
					append(column, Card_Field{"Readiness", fmt.tprintf("%+.0f", side.readiness_change)})
					append(column, Card_Field{"Supply", fmt.tprintf("%+.1f", side.stock_change)})
					if side.dissolved do append(column, Card_Field{"Fate", "Dissolved"})
				}
			}
		}

		append(&card.actions, Card_Action{"Next", .Battle_Next, game.movement.walker == {}})
		cards.battle = card
	}
}
