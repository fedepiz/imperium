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
FACTOR_TITLES := [Factor_Kind]string {
	.Dice        = "Roll",
	.Proficiency = "Proficiency",
	.Readiness   = "Readiness",
	.Numbers     = "Numbers",
	.Posture     = "Posture",
	.Ground      = "Ground",
	.Edge        = "Edge",
	.Commit      = "Committed",
	.Mobility    = "Mobility",
	.Losses      = "Losses",
	.Attacker    = "Attacker",
	.Defender    = "Defender",
	.Margin      = "Margin",
	.Engaged     = "Engaged",
	.Share       = "Share",
	.Lost        = "Lost",
	.Carried     = "Not carried",
	.Men_Ratio   = "Men ratio",
	.Baggage     = "Baggage full",
	.Men_Left    = "Men left",
}

@(private = "file")
Factor_Unit :: enum u8 {
	Points,
	Men,
	Percent,
	Ratio,
}

@(private = "file", rodata)
FACTOR_UNITS := #partial [Factor_Kind]Factor_Unit {
	.Engaged   = .Men,
	.Men_Left  = .Men,
	.Share     = .Percent,
	.Men_Ratio = .Ratio,
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
		if id == WORLD.interaction.actor || id == WORLD.interaction.target do pawn.flags += {.Engaged}
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
	// Interaction: a town met, or a battle
	open := &WORLD.interaction
	if actor, met := piece_get(open.actor), piece_get(open.target);
	   open.stage == .Meet_Town && actor != nil && met != nil {
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
			Action{label = "Back", ask = .Leave, enabled = true},
		)
		append(&out.cards, card)
	}

	// Battle: attacker's side left, defender's right. The actor and target are in the result's contact order.
	if open.actor != {} && open.stage != .Meet_Town {
		result := &open.result
		ids := [2]Piece_Id{open.actor, open.target}
		names := [2]string{piece_title(open.actor), piece_title(open.target)}
		attacker := result.attacker
		defender := 1 - attacker
		winner, loser := names[result.winner], names[1 - result.winner]
		card := Card {
			place = .Interaction,
		}
		#partial switch open.stage {
		case .Announce:
			card.title = fmt.tprintf("%s attacks %s", names[attacker], names[defender])
		case .Refused:
			card.title = fmt.tprintf("%s won't attack %s", names[attacker], names[defender])
			attacked := WORLD.piece_turns[open.actor.index].attacked
			reason := attacked ? "It has already attacked this turn." : "Its commander judges the odds too poor."
			card_line(&card, {text = reason})
		case .Report:
			card.title = "Battle report"
			a := &result.sides[attacker]
			d := &result.sides[defender]
			card_line(
				&card,
				{text = fmt.tprintf("%s attacks %s, power ", names[attacker], names[defender])},
				tally_part(&card, a.power),
				{text = " against "},
				tally_part(&card, d.power),
				{text = "."},
			)

			// Avoiding battle
			if len(result.avoid.factors) > 0 {
				got_away := result.outcome == .Avoided ? "gets away" : "is caught"
				card_line(
					&card,
					{text = fmt.tprintf("%s tries to avoid battle: ", names[defender])},
					tally_part(&card, result.avoid),
					{text = fmt.tprintf(" against %v, and %s.", result.mobility_target, got_away)},
				)
			}

			// The battle, then its outcome
			if result.outcome != .Avoided {
				postures := fmt.tprintf(
					"%s %s; %s %s.",
					names[attacker], POSTURE_WORDS[a.posture], names[defender], POSTURE_WORDS[d.posture],
				)
				card_line(&card, {text = postures})
				if len(a.onset.factors) > 0 {
					card_line(
						&card,
						{text = fmt.tprintf("Onset: %s ", names[attacker])},
						tally_part(&card, a.onset),
						{text = fmt.tprintf(", %s ", names[defender])},
						tally_part(&card, d.onset),
						{text = "."},
					)
					ahead := result.onset_ahead
					edge := &result.sides[ahead].edge
					switch {
					case result.onset_tied:
						card_line(&card, {text = "Neither gains the upper hand."})
					case len(edge.factors) == 0:
						card_line(
							&card,
							{text = fmt.tprintf("%s wins by ", names[ahead])},
							tally_part(&card, result.onset_margin),
							{text = "."},
						)
					case:
						card_line(
							&card,
							{text = fmt.tprintf("%s wins by ", names[ahead])},
							tally_part(&card, result.onset_margin),
							{text = " and gains an edge of "},
							tally_part(&card, edge^),
							{text = "."},
						)
					}
				}
				if result.pulled_out do card_line(&card, {text = fmt.tprintf("%s is probing and falls behind.", loser)})
				if result.crisis_chosen {
					choices := fmt.tprintf(
						"%s %s; %s %s.",
						names[attacker], CHOICE_WORDS[a.choice], names[defender], CHOICE_WORDS[d.choice],
					)
					card_line(&card, {text = choices})
					if len(a.crisis.factors) > 0 {
						card_line(
							&card,
							{text = fmt.tprintf("Crisis: %s ", names[attacker])},
							tally_part(&card, a.crisis),
							{text = fmt.tprintf(", %s ", names[defender])},
							tally_part(&card, d.crisis),
							{text = ", a margin of "},
							tally_part(&card, result.crisis_margin),
							{text = "."},
						)
					}
				}
				if result.outcome == .Stalemate {
					card_line(&card, {text = "Stalemate."})
				} else {
					card_line(&card, {text = fmt.tprintf("%s %s.", loser, OUTCOME_LOSER_WORDS[result.outcome])})
				}
				if result.worsened {
					card_line(&card, {text = fmt.tprintf("Having pressed or committed, %s fares worse.", loser)})
				}
			}

			// Cohesion
			for &side, i in result.sides {
				if len(side.cohesion.factors) == 0 do continue
				fate := side.dissolved ? "dissolves" : "holds together"
				card_line(
					&card,
					{text = fmt.tprintf("%s checks cohesion: ", names[i])},
					tally_part(&card, side.cohesion),
					{text = fmt.tprintf(" against %v, and %s.", result.cohesion_target, fate)},
				)
			}

			// Pursuit
			if len(result.pursuit.factors) > 0 {
				caught := result.caught ? "catches them" : "they get away"
				card_line(
					&card,
					{text = fmt.tprintf("%s pursues: ", winner)},
					tally_part(&card, result.pursuit),
					{text = fmt.tprintf(" against %v, and %s.", result.mobility_target, caught)},
				)
			}
		case .Outcome:
			card.title = fmt.tprintf("Battle: %s", OUTCOME_TITLES[result.outcome])
		case .Fall_Back:
			switch {
			case !result.follows:
				card.title = fmt.tprintf("%s falls back", loser)
			case len(result.pursuit.factors) == 0:
				card.title = fmt.tprintf("%s falls back; %s advances", loser, winner)
			case result.caught:
				card.title = fmt.tprintf("%s pursues and catches %s", winner, loser)
			case:
				card.title = fmt.tprintf("%s pursues; %s gets away", winner, loser)
			}
		}
		order := [Battle_Role]int{.Attacker = attacker, .Defender = defender}
		if open.stage != .Report do for i, role in order {
			column := role == .Attacker ? &card.fields : &card.stats
			append(column, Field{label = ROLE_TITLES[role], value = names[i]})
			if open.stage == .Announce || open.stage == .Refused {
				side := WORLD.armies[ids[i].index]
				power := result.sides[i].power
				append(column, Field{label = "Commander", value = fmt.tprintf("%v", side.temperament)})
				append(column, Field{label = "Men", value = util.format_compact(f64(side.men))})
				append(column, Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", side.proficiency)})
				append(column, Field{label = "Readiness", value = fmt.tprintf("%.0f%%", side.readiness)})
				append(column, tally_field(&card, "Power", power, fmt.tprintf("%.1f", power.total)))
				continue
			}
			side := &result.sides[i]
			// The chase's losses alone
			if open.stage == .Fall_Back {
				if !result.caught || i == result.winner do continue
				men := util.format_compact(f64(side.pursuit_men.total))
				append(column, tally_field(&card, "Men", side.pursuit_men, men))
				append(column, Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.pursuit_readiness)})
				continue
			}
			append(column, Field{label = "Posture", value = fmt.tprintf("%v", side.posture)})
			append(column, tally_field(&card, "Men", side.men, util.format_compact(f64(side.men.total))))
			append(column, Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.readiness)})
			append(column, tally_field(&card, "Supply", side.stock, fmt.tprintf("%+.1f", side.stock.total)))
			if side.dissolved do append(column, Field{label = "Fate", value = "Dissolved"})
		}
		append(&card.actions, Action{label = "Next", ask = .Next, enabled = WORLD.movement.subject == {}})
		append(&out.cards, card)
	}

	// Caches
	out.caches = {}
	pathfind_cache_get(&out.caches[.Pathfind_Land], .Land)
	pathfind_cache_get(&out.caches[.Pathfind_Sea], .Sea)
}

// Adds a paragraph made of parts
@(private = "file")
card_line :: proc(card: ^Card, parts: ..Line_Part) {
	begin := len(card.parts)
	append(&card.parts, ..parts)
	append(&card.lines, span.from_range(begin, len(card.parts)))
}

// Adds the tally's factors as a breakdown under total; returns its index + 1
@(private = "file")
card_breakdown :: proc(card: ^Card, tally: Tally, total: string) -> int {
	breakdown := Breakdown {
		total = total,
	}
	for factor, i in tally.factors {
		value: string
		switch FACTOR_UNITS[factor.kind] {
		case .Points:
			value = i == 0 ? fmt.tprintf("%.1f", factor.value) : fmt.tprintf("%+.1f", factor.value)
		case .Men:
			value = util.format_compact(f64(factor.value))
		case .Percent:
			value = fmt.tprintf("%.0f%%", 100 * factor.value)
		case .Ratio:
			value = fmt.tprintf("%.2f", factor.value)
		}
		if factor.op == .Scale do value = fmt.tprintf("× %s", value)
		append(&breakdown.terms, Field{label = FACTOR_TITLES[factor.kind], value = value})
	}
	append(&card.breakdowns, breakdown)
	return len(card.breakdowns)
}

// The tally's total, its factors on hover
@(private = "file")
tally_part :: proc(card: ^Card, tally: Tally) -> Line_Part {
	total := fmt.tprintf("%.1f", tally.total)
	return {text = total, breakdown = card_breakdown(card, tally, total)}
}

// A field showing total, the tally's factors on hover
@(private = "file")
tally_field :: proc(card: ^Card, label: string, tally: Tally, total: string) -> Field {
	if len(tally.factors) == 0 do return {label = label, value = total}
	return {label = label, value = total, breakdown = card_breakdown(card, tally, total)}
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

