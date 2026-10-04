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
ROLE_TITLES := [2]string{"Attacker", "Defender"}

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
			title   = string(WORLD.piece_names[focus.index][:]),
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
			title   = string(WORLD.piece_names[open.target.index][:]),
			picture = Picture{met.icon, met.culture},
		}
		met_by := string(WORLD.piece_names[open.actor.index][:])
		append(&card.fields, Field{label = "Met by", value = met_by})
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
		report := &result.report
		ids := [2]Piece_Id{open.actor, open.target}
		names: [2]string
		for id, i in ids do names[i] = string(WORLD.piece_names[id.index][:])
		attacker := result.attacker
		defender := 1 - attacker
		card := Card {
			place = .Interaction,
		}
		#partial switch open.stage {
		case .Announce:
			card.title = fmt.tprintf("%s attacks %s", names[attacker], names[defender])
		case .Refused:
			card.title = fmt.tprintf("%s won't attack %s", names[attacker], names[defender])
			card_report(&card, report)
		case .Report:
			card.title = "Battle report"
			card_report(&card, report)
		case .Outcome:
			outcome := span.to_string(report.text[:], result.outcome_title)
			card.title = fmt.tprintf("Battle: %s", outcome)
		case .Fall_Back:
			card.title = span.to_string(report.text[:], result.follow_title)
		}
		order := [2]int{attacker, defender}
		if open.stage != .Report do for i, column_index in order {
			column := column_index == 0 ? &card.fields : &card.stats
			append(column, Field{label = ROLE_TITLES[column_index], value = names[i]})
			if open.stage == .Announce || open.stage == .Refused {
				side := WORLD.armies[ids[i].index]
				power := &result.sides[i].power
				append(column, Field{label = "Commander", value = fmt.tprintf("%v", side.commander_temperament)})
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
				append(column, tally_field(&card, "Men", &side.pursuit_men, men))
				append(column, Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.pursuit_readiness)})
				continue
			}
			append(column, Field{label = "Posture", value = span.to_string(report.text[:], side.posture)})
			append(column, tally_field(&card, "Men", &side.men, util.format_compact(f64(side.men.total))))
			append(column, Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.readiness)})
			append(column, tally_field(&card, "Supply", &side.stock, fmt.tprintf("%+.1f", side.stock.total)))
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

// Adds the report's lines, each tally's factors and note on hover
@(private = "file")
card_report :: proc(card: ^Card, report: ^Report) {
	for line in report.lines {
		begin := len(card.parts)
		for &part in report.parts[line.begin:][:line.len] {
			text := span.to_string(report.text[:], part.text)
			shown := Line_Part {
				text = text,
			}
			if len(part.tally.factors) > 0 do shown.breakdown = card_breakdown(card, &part.tally, text)
			if part.note.len > 0 {
				note := span.to_string(report.text[:], part.note)
				append(&card.breakdowns, Breakdown{note = note})
				shown.breakdown = len(card.breakdowns)
			}
			append(&card.parts, shown)
		}
		append(&card.lines, span.from_range(begin, len(card.parts)))
	}
}

// Adds the tally's factors as a breakdown under total; returns its index + 1
@(private = "file")
card_breakdown :: proc(card: ^Card, tally: ^Tally, total: string) -> int {
	breakdown := Breakdown {
		total = total,
	}
	for &factor, i in tally.factors {
		value: string
		switch factor.unit {
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
		append(&breakdown.terms, Field{label = string(factor.label[:]), value = value})
	}
	append(&card.breakdowns, breakdown)
	return len(card.breakdowns)
}

// A field showing total, the tally's factors on hover
@(private = "file")
tally_field :: proc(card: ^Card, label: string, tally: ^Tally, total: string) -> Field {
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


// Faction must be alive
@(private = "file")
faction_name :: proc(id: Faction_Id) -> string {
	return string(WORLD.faction_names[id.index][:])
}

