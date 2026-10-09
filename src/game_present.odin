package main

import "core:fmt"
import "core:math"

CARD_LINES_MAX :: REPORT_LINES_MAX
CARD_PARTS_MAX :: REPORT_PARTS_MAX
CARD_BREAKDOWNS_MAX :: 48
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
COLUMN_TITLES := [2]string{"Attacker", "Defender"}

Game_Ask :: enum u8 {
	End_Turn,
	Conquer,
	Leave,
	Next,
}

Card_Part :: struct {
	text:      string,
	breakdown: Maybe(int),
}

Card_Field :: struct {
	label:     string,
	value:     string,
	breakdown: Maybe(int),
}

Card_Term :: struct {
	label: string,
	value: string,
}

Card_Breakdown :: struct {
	note:  string,
	terms: [dynamic; REPORT_TALLY_FACTORS_MAX]Card_Term,
	total: string,
}

Card_Action :: struct {
	label:   string,
	ask:     Game_Ask,
	enabled: bool,
}

Card :: struct {
	title:      string,
	lines:      [dynamic; CARD_LINES_MAX]Span,
	parts:      [dynamic; CARD_PARTS_MAX]Card_Part,
	breakdowns: [dynamic; CARD_BREAKDOWNS_MAX]Card_Breakdown,
	fields:     [dynamic; CARD_FIELDS_MAX]Card_Field,
	stats:      [dynamic; CARD_FIELDS_MAX]Card_Field,
	actions:    [dynamic; CARD_ACTIONS_MAX]Card_Action,
}

Cards :: struct {
	status:      Card,
	focus:       Maybe(Card),
	interaction: Maybe(Card),
}

game_present_map :: proc(
	game: ^Game,
	focus: Piece_Id,
	pointer: Maybe([2]f32),
	mode: Map_Mode,
	frame: ^Render_Terrain_Frame,
) {
	movement := &game.movement

	pointed: Region_Id
	if at, on_map := pointer.?; on_map && grid_contains(cell_of(at), MAP_SIZE) {
		pointed = Region_Id(game.terrain.regions[grid_index(cell_of(at), MAP_SIZE)])
	}
	reach_shown :=
		movement.flood_key != 0 && movement.flooded == focus && movement.flooded != movement.walker

	frame.region_display = mode == .Control ? .Filled_When_Far : .Hidden
	for &region, id in game.regions {
		color := REGION_UNHELD_COLOR
		capital := slot_map_get(&game.pieces, region.capital)
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
		piece := slot_map_get(&game.pieces, focus)
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

	if walker := slot_map_get(&game.pieces, movement.walker); walker != nil {
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
		engaged := id == game.interaction.actor || id == game.interaction.target
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

game_piece_title :: proc(piece: ^Piece_Data) -> string {
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

@(private = "file")
card_breakdown :: proc(card: ^Card, tally: ^Report_Tally, total: string) -> Maybe(int) {
	breakdown := Card_Breakdown {
		total = total,
	}
	for &factor, i in tally.factors {
		value: string
		switch factor.unit {
		case .Points:
			value = i == 0 ? fmt.tprintf("%.1f", factor.value) : fmt.tprintf("%+.1f", factor.value)
		case .Men:
			value = compact_number(f64(factor.value))
		case .Percent:
			value = fmt.tprintf("%.0f%%", 100 * factor.value)
		case .Ratio:
			value = fmt.tprintf("%.2f", factor.value)
		}
		if factor.op == .Scale do value = fmt.tprintf("x %s", value)
		append(&breakdown.terms, Card_Term{string(factor.label[:]), value})
	}
	if append(&card.breakdowns, breakdown) == 0 do return nil
	return len(card.breakdowns) - 1
}

@(private = "file")
card_note :: proc(card: ^Card, note: string) -> Maybe(int) {
	if append(&card.breakdowns, Card_Breakdown{note = note}) == 0 do return nil
	return len(card.breakdowns) - 1
}

@(private = "file")
card_tally_field :: proc(card: ^Card, label: string, tally: ^Report_Tally, total: string) -> Card_Field {
	if len(tally.factors) == 0 do return {label = label, value = total}
	return {label = label, value = total, breakdown = card_breakdown(card, tally, total)}
}

@(private = "file")
card_report :: proc(card: ^Card, report: ^Report) {
	for line in report.lines {
		begin := len(card.parts)
		for part in span_slice(report.parts[:], line) {
			text := report_string(report, part.text)
			shown := Card_Part {
				text = text,
			}
			if tally, has_tally := part.tally.?; has_tally {
				shown.breakdown = card_breakdown(card, &report.tallies[tally], text)
			}
			if part.note.len > 0 do shown.breakdown = card_note(card, report_string(report, part.note))
			append(&card.parts, shown)
		}
		append(&card.lines, Span{begin, len(card.parts) - begin})
	}
}

game_cards :: proc(game: ^Game, focus: Piece_Id, cards: ^Cards) {
	cards^ = {}

	status := &cards.status
	status.title = fmt.tprintf("Turn %d", game.turn)
	append(&status.fields, Card_Field{label = "Playing", value = faction_title(game, game.player)})
	append(&status.actions, Card_Action{"End turn", .End_Turn, game_turn_endable(game)})

	if piece := slot_map_get(&game.pieces, focus); piece != nil {
		card := Card {
			title = game_piece_title(piece),
		}
		append(&card.fields, Card_Field{label = "Type", value = ICON_TITLES[piece.icon]})
		append(&card.fields, Card_Field{label = "Faction", value = faction_title(game, piece.owner)})
		append(&card.fields, Card_Field{label = "Culture", value = fmt.tprint(piece.culture)})
		if piece.general != 0 {
			general := name_to_string(&game.characters[piece.general].name)
			append(&card.fields, Card_Field{label = "General", value = general})
		}
		army, is_army := piece.army.?
		if is_army {
			append(&card.fields, Card_Field{label = "Baggage", value = fmt.tprintf("%.0f turns", army.baggage)})
		}
		if piece.domain != nil {
			left := compact_number(f64(game_movement_left(piece^)))
			per_turn := compact_number(f64(piece.movement_per_turn))
			append(&card.stats, Card_Field{label = "Movement", value = fmt.tprintf("%s of %s", left, per_turn)})
		}
		if is_army {
			men := fmt.tprintf("%s of %s", compact_number(f64(army.men)), compact_number(f64(army.men_max)))
			supply: f32 = army.baggage > 0 ? 100 * army.stock / army.baggage : 0
			stock := fmt.tprintf("%.1f (%+.1f)", army.stock, army.resupply)
			efficiency := fmt.tprintf("%.0f%%", 100 * army.resupply_efficiency)
			append(&card.stats, Card_Field{label = "Men", value = men})
			append(&card.stats, Card_Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
			append(&card.stats, Card_Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
			append(&card.stats, Card_Field{label = "Supply", value = fmt.tprintf("%.0f%%", supply)})
			append(&card.stats, Card_Field{label = "Stock", value = stock})
			append(&card.stats, Card_Field{label = "Source", value = fmt.tprint(army.resupply_source)})
			append(&card.stats, Card_Field{label = "Efficiency", value = efficiency})
		}
		cards.focus = card
	}

	open := &game.interaction
	if open.actor == {} do return

	if open.stage == .Meet_Town {
		actor := slot_map_get(&game.pieces, open.actor)
		met := slot_map_get(&game.pieces, open.target)
		if actor == nil || met == nil do return
		card := Card {
			title = game_piece_title(met),
		}
		append(&card.fields, Card_Field{label = "Met by", value = game_piece_title(actor)})
		append(&card.fields, Card_Field{label = "Faction", value = faction_title(game, met.owner)})
		append(&card.actions, Card_Action{"Conquer", .Conquer, open.conquerable})
		append(&card.actions, Card_Action{"Back", .Leave, true})
		cards.interaction = card
		return
	}

	result := &open.result
	report := &result.report
	names := [2]string{report_string(report, result.names[0]), report_string(report, result.names[1])}
	pieces := [2]^Piece_Data{slot_map_get(&game.pieces, open.actor), slot_map_get(&game.pieces, open.target)}
	attacker := result.attacker
	defender := 1 - attacker
	card: Card
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
		card.title = fmt.tprintf("Battle: %s", report_string(report, result.outcome_title))
	case .Fall_Back:
		card.title = report_string(report, result.follow_title)
	}

	if open.stage != .Report {
		for side_index, column in ([2]int{attacker, defender}) {
			fields := column == 0 ? &card.fields : &card.stats
			append(fields, Card_Field{label = COLUMN_TITLES[column], value = names[side_index]})
			side := &result.sides[side_index]
			#partial switch open.stage {
			case .Announce, .Refused:
				piece := pieces[side_index]
				if piece == nil do continue
				army, is_army := piece.army.?
				if !is_army do continue
				temperament := game_commander_temperament(game, piece)
				power := fmt.tprintf("%.1f", side.power.total)
				append(fields, Card_Field{label = "Commander", value = fmt.tprint(temperament)})
				append(fields, Card_Field{label = "Men", value = compact_number(f64(army.men))})
				append(fields, Card_Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
				append(fields, card_tally_field(&card, "Power", &side.power, power))
			case .Fall_Back:
				if !result.caught || side_index == result.winner do continue
				men := compact_number(f64(side.pursuit_men.total))
				append(fields, card_tally_field(&card, "Men", &side.pursuit_men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.pursuit_readiness)})
			case:
				men := compact_number(f64(side.men.total))
				stock := fmt.tprintf("%+.1f", side.stock.total)
				append(fields, Card_Field{label = "Posture", value = report_string(report, side.posture)})
				append(fields, card_tally_field(&card, "Men", &side.men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f", side.readiness)})
				append(fields, card_tally_field(&card, "Supply", &side.stock, stock))
				if side.dissolved do append(fields, Card_Field{label = "Fate", value = "Dissolved"})
			}
		}
	}

	append(&card.actions, Card_Action{"Next", .Next, game.movement.walker == {}})
	cards.interaction = card
}
