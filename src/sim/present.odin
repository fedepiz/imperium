#+private
package sim

import "core:fmt"
import "core:math"

import "../span"
import "../util"

// Area slots, in drawing order
REACH_AREA :: 0
FRIEND_AREA :: 1
ZONE_AREA :: 2
// Indices into the game's area palette
REACH_LOOK :: 1
ZONE_LOOK :: 2
OTHER_REACH_LOOK :: 3
FRIEND_LOOK :: 4

// Regions with no owner, and all regions when Muted
@(private = "file")
REGION_UNHELD_COLOR :: [4]f32{0.6, 0.6, 0.6, 1}

// Golden ratio, so hues of nearby ids stay apart
@(private = "file")
REGION_HUE_STEP :: 0.618034
@(private = "file")
REGION_SATURATION :: 0.55
@(private = "file")
REGION_VALUE :: 0.75

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

// Report wording
@(private = "file", rodata)
POSTURE_WORDS := [Posture]string {
	.Press    = "presses",
	.Standard = "stands",
	.Probe    = "probes",
}
@(private = "file", rodata)
CHOICE_WORDS := [Crisis_Choice]string {
	.Hold      = "holds",
	.Commit    = "commits",
	.Break_Off = "breaks off",
}
@(private = "file", rodata)
OUTCOME_LOSER_WORDS := [Battle_Outcome]string {
	.Avoided      = "gets away",
	.Stalemate    = "holds its ground",
	.Probed       = "pulls out",
	.Withdrew     = "withdraws",
	.Repulsed     = "is repulsed",
	.Defeat       = "is defeated",
	.Heavy_Defeat = "is heavily defeated",
	.Rout         = "is routed",
}

@(private = "file", rodata)
ROLE_TITLES := [Battle_Role]string {
	.Attacker = "Attacker",
	.Defender = "Defender",
}

@(private = "file", rodata)
ICON_TITLES := [Icon]string {
	.Village    = "Village",
	.Town       = "Town",
	.City       = "City",
	.Large_City = "Large City",
	.Army       = "Army",
	.Fleet      = "Fleet",
}

world_present :: proc(
	focus: Piece_Id,
	pointed: Region_Id,
	region_colouring: Region_Colouring_Mode,
	out: ^Scene,
) {
	mov := &WORLD.movement
	ordering := ordering()

	// Supply map (only when rebuilt)
	if out.supply_map_revision != WORLD.supply_map_revision {
		out.supply_map_revision = WORLD.supply_map_revision
		out.supply_map = WORLD.supply_map
	}

	// Ground (only when the atlas changed)
	if out.ground_revision != WORLD.atlas.revision {
		out.ground_revision = WORLD.atlas.revision
		for cell, i in WORLD.atlas.terrain {
			ground := Ground {
				surface       = cell.surface,
				elevation     = cell.elevation,
				trees         = cell.trees,
				moisture      = cell.moisture,
				type          = cell.type,
				type_strength = cell.type_strength,
				region        = cell.region,
			}
			for id, kind in cell.way do if id != 0 do ground.ways += {kind}
			out.ground[i] = ground
		}
	}

	// Pawns
	clear(&out.pawns)
	for piece, index in WORLD.pieces {
		if !piece_alive(piece) do continue
		id := piece_id(index)
		pawn := Pawn {
			handle  = id,
			pos     = piece.pos,
			picture = {piece.icon, piece.culture},
			label   = string(WORLD.piece_names[index][:]),
		}
		if id == focus do pawn.flags += {.Focused}
		if ordering != {} && piece.owner == ordering do pawn.flags += {.Controlled}
		if id == WORLD.engagement.attacker || id == WORLD.engagement.defender do pawn.flags += {.Engaged}
		append(&out.pawns, pawn)
	}

	// Walk arrow
	clear(&out.arrows)
	clear(&out.arrow_points)
	if walker := piece_get(mov.subject); walker != nil {
		begin := len(out.arrow_points)
		append(&out.arrow_points, walker.pos)
		append(&out.arrow_points, ..mov.path[mov.next:])
		append(&out.arrows, span.from_range(begin, len(out.arrow_points)))
	}

	// Reach and zones of the focus (hidden while it walks)
	flood := &mov.flood
	shown := mov.flood_subject != {} && mov.flood_subject == focus && mov.flood_subject != mov.subject
	// Flood key doubles as the areas' revision
	revision := shown ? mov.flood_key : 0
	reach := &out.areas[REACH_AREA]
	if reach.revision != revision {
		reach.revision, reach.cells = revision, {}
		reach.on_water, reach.corner = flood.domain != .Land, flood.corner
		if shown do for cost, i in flood.cost do reach.cells[i] = cost != math.INF_F32
	}
	reach.look = OTHER_REACH_LOOK
	if piece := piece_get(focus); piece != nil && ordering != {} && piece.owner == ordering {
		reach.look = REACH_LOOK
	}
	clear(&out.circles)
	for slot in 0 ..< 2 {
		area := &out.areas[FRIEND_AREA + slot]
		area.revision = revision
		area.look = slot == 0 ? FRIEND_LOOK : ZONE_LOOK
		area.on_water = flood.domain != .Land
		begin := len(out.circles)
		count := slot == 0 ? len(mov.friend_zones) : len(mov.enemy_zones)
		for i in 0 ..< count {
			disc := slot == 0 ? mov.friend_zones[i] : mov.enemy_zones[i].disc
			if shown && len(out.circles) < CIRCLES_MAX do append(&out.circles, Circle{disc.center, disc.radius})
		}
		area.circles = span.from_range(begin, len(out.circles))
	}

	// Regions
	clear(&out.regions)
	for &name, index in WORLD.region_names {
		id := Region_Id(index + 1)
		color: [4]f32
		switch region_colouring {
		case .Owner:
			color = REGION_UNHELD_COLOR
			if capital := piece_get(WORLD.region_capitals[index]); capital != nil {
				if faction := faction_get(capital.owner); faction != nil do color = faction.color
			}
		case .Identity:
			color = region_identity_color(id)
		case .Muted:
			color = REGION_UNHELD_COLOR
		}
		highlighted := !shown && id == pointed && region_colouring != .Muted
		append(
			&out.regions,
			Region{name = string(name[:]), color = color, highlighted = highlighted},
		)
	}

	// Cards
	clear(&out.cards)
	status := Card {
		place = .Status,
		title = fmt.tprintf("Turn %d", WORLD.turn),
	}
	player := faction_get(WORLD.player)
	append(&status.fields, Field{label = "Playing", value = player != nil ? faction_name(WORLD.player) : "None"})
	append(
		&status.actions,
		Action{label = "End turn", ask = .End_Turn, enabled = turn_endable()},
	)
	append(&out.cards, status)
	if piece := piece_get(focus); piece != nil {
		card := Card {
			place   = .Focus,
			title   = piece_title(focus),
			picture = Picture{piece.icon, piece.culture},
		}
		append(&card.fields, Field{label = "Type", value = ICON_TITLES[piece.icon]})
		faction := faction_get(piece.owner)
		append(&card.fields, Field{label = "Faction", value = faction != nil ? faction_name(piece.owner) : "None"})
		append(&card.fields, Field{label = "Culture", value = fmt.tprintf("%v", piece.culture)})
		if character_get(piece.general) != nil {
			append(&card.fields, Field{label = "General", value = string(WORLD.character_names[piece.general.index][:])})
		}
		army := WORLD.armies[focus.index]
		if army.active do append(&card.fields, Field{label = "Baggage", value = fmt.tprintf("%.0f turns", army.baggage)})
		if piece.movement_domain != nil {
			budget := fmt.tprintf(
				"%s of %s",
				util.format_compact(f64(movement_budget(focus))),
				util.format_compact(f64(piece.movement_per_turn)),
			)
			append(&card.stats, Field{label = "Movement", value = budget})
		}
		if army.active {
			men := fmt.tprintf(
				"%s of %s",
				util.format_compact(f64(army.men)),
				util.format_compact(f64(army.men_max)),
			)
			append(&card.stats, Field{label = "Men", value = men})
			append(&card.stats, Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
			append(&card.stats, Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
			supply: f32 = army.baggage > 0 ? 100 * army.stock / army.baggage : 0
			append(&card.stats, Field{label = "Supply", value = fmt.tprintf("%.0f%%", supply)})
			stock := fmt.tprintf("%.1f (%+.1f)", army.stock, army.resupply)
			append(&card.stats, Field{label = "Stock", value = stock})
			append(&card.stats, Field{label = "Source", value = fmt.tprintf("%v", army.resupply_source)})
			efficiency := fmt.tprintf("%.0f%%", 100 * army.resupply_efficiency)
			append(&card.stats, Field{label = "Efficiency", value = efficiency})
		}
		append(&out.cards, card)
	}
	open := WORLD.interaction
	if actor, met := piece_get(open.actor), piece_get(open.target); actor != nil && met != nil {
		card := Card {
			place   = .Interaction,
			title   = piece_title(open.target),
			picture = Picture{met.icon, met.culture},
		}
		append(&card.fields, Field{label = "Met by", value = piece_title(open.actor)})
		faction := faction_get(met.owner)
		append(&card.fields, Field{label = "Faction", value = faction != nil ? faction_name(met.owner) : "None"})
		append(
			&card.actions,
			Action{label = "Conquer", ask = .Conquer, enabled = open.conquerable},
		)
		append(
			&card.actions,
			Action{label = "Back", ask = .Leave_Interaction, enabled = true},
		)
		append(&out.cards, card)
	}

	// Engagement: the attacker's side on the left, the defender's on the right. Announced with both sides as they
	// stand, then the result.
	if engagement := &WORLD.engagement; engagement.attacker != {} {
		result := engagement.result
		roles := [Battle_Role]Piece_Id {
			.Attacker = engagement.attacker,
			.Defender = engagement.defender,
		}
		names := [Battle_Role]string {
			.Attacker = piece_title(roles[.Attacker]),
			.Defender = piece_title(roles[.Defender]),
		}
		winner, loser := names[result.winner], names[OTHER_ROLE[result.winner]]
		card := Card {
			place = .Battle,
		}
		switch engagement.stage {
		case .Announce:
			card.title = fmt.tprintf("%s attacks %s", names[.Attacker], names[.Defender])
		case .Report:
			card.title = "Battle report"
			a, d := result.sides[.Attacker], result.sides[.Defender]
			lines := &card.lines
			append(
				lines,
				fmt.tprintf(
					"%s attacks %s, power %.1f against %.1f.",
					names[.Attacker], names[.Defender], a.power, d.power,
				),
			)

			// Avoiding battle
			if roll := result.avoid; roll.rolled {
				got_away := result.outcome == .Avoided ? "gets away" : "is caught"
				append(
					lines,
					fmt.tprintf(
						"%s tries to avoid battle: rolls %.0f, total %.0f against %.0f, and %s.",
						names[.Defender], roll.dice, roll.total, roll.target, got_away,
					),
				)
			}
			if result.outcome == .Avoided do break

			// Postures and onset
			append(
				lines,
				fmt.tprintf(
					"%s %s; %s %s.",
					names[.Attacker], POSTURE_WORDS[a.posture], names[.Defender], POSTURE_WORDS[d.posture],
				),
			)
			if a.onset.rolled {
				append(
					lines,
					fmt.tprintf(
						"Onset: %s rolls %.0f for %.1f, %s rolls %.0f for %.1f.",
						names[.Attacker], a.onset.dice, a.onset.total, names[.Defender], d.onset.dice, d.onset.total,
					),
				)
				ahead: Battle_Role = a.onset.total > d.onset.total ? .Attacker : .Defender
				switch {
				case result.onset_margin < ONSET_TIE:
					append(lines, "Neither gains the upper hand.")
				case !result.crisis_chosen && !result.pulled_out:
					append(
						lines,
						fmt.tprintf(
							"%s wins by %.1f, and %s %s.",
							names[ahead], result.onset_margin, names[OTHER_ROLE[ahead]],
							OUTCOME_LOSER_WORDS[result.outcome],
						),
					)
				case:
					append(
						lines,
						fmt.tprintf(
							"%s wins by %.1f and gains an edge of %.1f.",
							names[ahead], result.onset_margin, result.sides[ahead].edge,
						),
					)
				}
			}
			if result.pulled_out do append(lines, fmt.tprintf("%s, probing and behind, pulls out.", loser))

			// Crisis
			if result.crisis_chosen {
				append(
					lines,
					fmt.tprintf(
						"%s %s; %s %s.",
						names[.Attacker], CHOICE_WORDS[a.choice], names[.Defender], CHOICE_WORDS[d.choice],
					),
				)
				if a.crisis.rolled {
					append(
						lines,
						fmt.tprintf(
							"Crisis: %s rolls %.0f for %.1f, %s rolls %.0f for %.1f, a margin of %.1f.",
							names[.Attacker], a.crisis.dice, a.crisis.total, names[.Defender], d.crisis.dice,
							d.crisis.total, result.crisis_margin,
						),
					)
				}
				if result.outcome == .Stalemate {
					append(lines, "Stalemate.")
				} else {
					append(lines, fmt.tprintf("%s %s.", loser, OUTCOME_LOSER_WORDS[result.outcome]))
				}
				if result.worsened do append(lines, fmt.tprintf("Having pressed or committed, %s fares worse.", loser))
			}

			// Pursuit and holding together
			if roll := result.pursuit; roll.rolled {
				caught := result.pursued ? "catches them" : "they get away"
				append(
					lines,
					fmt.tprintf(
						"%s pursues: rolls %.0f, total %.0f against %.0f, and %s.",
						winner, roll.dice, roll.total, roll.target, caught,
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
						names[role], side.hold.dice, side.hold.total, side.hold.target, fate,
					),
				)
			}
		case .Outcome:
			card.title = fmt.tprintf("Battle: %s", OUTCOME_TITLES[result.outcome])
		case .Fall_Back:
			card.title = fmt.tprintf("%s falls back", loser)
		case .Pursuit:
			card.title = fmt.tprintf("%s pursues", winner)
		}
		if engagement.stage != .Report do for role in Battle_Role {
			column := role == .Attacker ? &card.fields : &card.stats
			append(column, Field{label = ROLE_TITLES[role], value = piece_title(roles[role])})
			if engagement.stage == .Announce {
				side := engagement.battle.sides[role]
				other := engagement.battle.sides[OTHER_ROLE[role]]
				append(column, Field{label = "Commander", value = fmt.tprintf("%v", side.temperament)})
				append(column, Field{label = "Men", value = util.format_compact(f64(side.men))})
				append(column, Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", side.proficiency)})
				append(column, Field{label = "Readiness", value = fmt.tprintf("%.0f%%", side.readiness)})
				append(column, Field{label = "Power", value = fmt.tprintf("%.1f", battle_strength(side, other))})
				continue
			}
			side := result.sides[role]
			append(column, Field{label = "Posture", value = fmt.tprintf("%v", side.posture)})
			append(column, Field{label = "Men", value = util.format_compact(f64(side.men))})
			append(column, Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.readiness)})
			append(column, Field{label = "Supply", value = fmt.tprintf("%+.1f", side.stock)})
			if side.dissolved do append(column, Field{label = "Fate", value = "Dissolved"})
		}
		append(&card.actions, Action{label = "Next", ask = .Battle_Next, enabled = WORLD.movement.subject == {}})
		append(&out.cards, card)
	}

	// Caches
	out.caches = {}
	pathfind_cache_get(&out.caches[.Pathfind_Land], .Land)
	pathfind_cache_get(&out.caches[.Pathfind_Sea], .Sea)
}

@(private = "file")
region_identity_color :: proc(id: Region_Id) -> [4]f32 {
	hue := math.mod(f32(id) * REGION_HUE_STEP, 1) * 6
	// HSV to RGB
	channel :: proc(hue, offset: f32) -> f32 {
		k := math.mod(offset + hue, 6)
		return REGION_VALUE - REGION_VALUE * REGION_SATURATION * max(0, min(k, 4 - k, 1))
	}
	return {channel(hue, 5), channel(hue, 3), channel(hue, 1), 1}
}

// Name, or icon title if unnamed. Piece must be alive.
@(private = "file")
piece_title :: proc(id: Piece_Id) -> string {
	name := WORLD.piece_names[id.index][:]
	return len(name) > 0 ? string(name) : ICON_TITLES[WORLD.pieces[id.index].icon]
}

// Faction must be alive
@(private = "file")
faction_name :: proc(id: Faction_Id) -> string {
	return string(WORLD.faction_names[id.index][:])
}

