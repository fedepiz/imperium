package main

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"

CARD_LINES_MAX :: REPORT_LINES_MAX
CARD_PARTS_MAX :: REPORT_PARTS_MAX
CARD_BREAKDOWNS_MAX :: 128
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4
CARD_TILES_MAX :: 16
// Its slots', the main one included, and mobilising
CARD_MENUS_MAX :: TOWN_SLOT_COUNT + 1
CARD_MENU_ACTIONS_MAX :: BUILDING_KINDS_MAX

Map_Mode :: enum u8 {
	Political,
	Control,
	Supply,
	Fertility,
	Plain,
}

@(rodata)
MAP_MODE_NAMES := [Map_Mode]string {
	.Political = "Political",
	.Control   = "Control",
	.Supply    = "Supply",
	.Fertility = "Fertility",
	.Plain     = "Plain",
}

Card_Tab :: enum u8 {
	Army,
	Town,
}

@(rodata)
CARD_TAB_NAMES := [Card_Tab]string {
	.Army = "Army",
	.Town = "Town",
}

@(private = "file")
REGION_UNHELD_COLOR :: [3]f32{0.6, 0.6, 0.6}

// Fills the bar, and washes the map greenest
@(private = "file")
FERTILITY_MAX :: 5

@(private = "file")
REACH_SLOT :: 0
@(private = "file")
FRIEND_ZONES_SLOT :: 1
@(private = "file")
ENEMY_ZONES_SLOT :: 2
@(private = "file")
BEACHES_SLOT :: 3
@(private = "file")
LANDINGS_SLOT :: 4

// Movers whose march is drawn as an arrow
@(private = "file")
MARCH_ARROWS :: bit_set[Mover]{.Leader, .Chaser}

@(private = "file", rodata)
ICON_TITLES := [Map_Icon]string {
	.Town       = "Town",
	.City       = "City",
	.Large_City = "Great City",
	.Army       = "Army",
	.Fleet      = "Fleet",
}

@(private = "file", rodata)
COLUMN_TITLES := [2]string{"Attacker", "Defender"}

Game_Ask :: enum u8 {
	Court,
}

COURT_ROWS_MAX :: FACTION_CHARACTERS_MAX
COURT_OFFICES_MAX :: FACTION_OFFICES_MAX
COURT_BREAKDOWNS_MAX :: 512

Court_Row :: struct {
	name:        string,
	rank:        int,
	influence:   f32,
	age:         int,
	temperament: string,
	background:  string,
	disposition: string,
	// Empty: none
	office:      string,
	office_id:   Office_Id,
	// Wealth, Influence and Loyalty
	stats:       [3]Card_Field,
	// Empty army: none
	army:        string,
	men:         Card_Field,
	base:        string,
	dismiss:     Maybe(Dismiss_Order),
	undismissable: string,
	character:   Character_Id,
	rank_breakdown:      Maybe(int),
	dismiss_breakdown:   Maybe(int),
}

Court_Office :: struct {
	title:     string,
	rank:      int,
	// 0: vacant
	holder:      Character_Id,
	holder_name: string,
	// The vacancy being filled
	filling:   bool,
	// Its flags beyond the usual. Empty: none
	traits:    string,
	id:        Office_Id,
	breakdown: Maybe(int),
}

Court_Candidate :: struct {
	character: Character_Id,
	name:      string,
	order:     Appoint_Order,
	breakdown: Maybe(int),
}

// No office: none
Court_Vacancy :: struct {
	office:     Office_Id,
	title:      string,
	rank:       int,
	army:       string,
	candidates: [dynamic; CANDIDATES_MAX]Court_Candidate,
	can_appoint: bool,
}

Court :: struct {
	title:         string,
	rows:          [dynamic; COURT_ROWS_MAX]Court_Row,
	offices:       [dynamic; COURT_OFFICES_MAX]Court_Office,
	breakdowns:    [dynamic; COURT_BREAKDOWNS_MAX]Card_Breakdown,
	// The rank shown in full
	rank_max:      int,
	vacancy:       Court_Vacancy,
}

Card_Part :: struct {
	text:      string,
	breakdown: Maybe(int),
}

Card_Field :: struct {
	label:     string,
	value:     string,
	breakdown: Maybe(int),
	// 0..1: a bar after the value, filled from fill_origin. An origin above 0: a balance
	fill:        Maybe(f32),
	fill_origin: f32,
	// Coloured bad to good by its fill
	graded:      bool,
	// Nil: a plain value
	click:       Card_Click,
}

Card_Term :: struct {
	label: string,
	value: string,
}

Card_Breakdown :: struct {
	note:        string,
	terms:       [dynamic; REPORT_TALLY_FACTORS_MAX]Card_Term,
	total:       string,
	description: string,
}

Card_Click :: union {
	Game_Ask,
	Game_Order,
	Card_Menu_Id,
	Character_Id,
}

Card_Menu_Id :: distinct int

Card_Action :: struct {
	label:   string,
	click:   Card_Click,
	enabled: bool,
}

// No name: empty
Card_Tile :: struct {
	name:      string,
	breakdown: Maybe(int),
	// Not a slot this settlement has
	disabled:  bool,
	project:   string,
	click:     Card_Click,
}

Card_Menu :: struct {
	title:   string,
	actions: [dynamic; CARD_MENU_ACTIONS_MAX]Card_Menu_Action,
}

Card_Menu_Action :: struct {
	label:     string,
	// Its cost, or what it does
	detail:    string,
	enabled:   bool,
	// Hovered, what the building it makes does
	breakdown: Maybe(int),
	order:     Game_Order,
}

Card :: struct {
	title:      string,
	lines:      [dynamic; CARD_LINES_MAX]Span,
	parts:      [dynamic; CARD_PARTS_MAX]Card_Part,
	breakdowns: [dynamic; CARD_BREAKDOWNS_MAX]Card_Breakdown,
	fields:     [dynamic; CARD_FIELDS_MAX]Card_Field,
	stats:      [dynamic; CARD_FIELDS_MAX]Card_Field,
	tiles:      [dynamic; CARD_TILES_MAX]Card_Tile,
	menus:      [dynamic; CARD_MENUS_MAX]Card_Menu,
	// Under its fields, and at its bottom
	buttons:    [dynamic; CARD_ACTIONS_MAX]Card_Action,
	actions:    [dynamic; CARD_ACTIONS_MAX]Card_Action,
	tabs:       bit_set[Card_Tab],
	tab:        Card_Tab,
	map_modes:  bool,
}

Cards :: struct {
	status:            Card,
	focus:             Card,
	interaction:       Card,
	focus_shown:       bool,
	interaction_shown: bool,
	court:             Court,
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
	leader_march := &movement.marches[.Leader]
	reach_shown :=
		movement.flood_key != 0 &&
		movement.flooded == focus &&
		movement.flooded != leader_march.piece

	// Political fills the regions in their owners' colours; Control and Fertility outline them
	#partial switch mode {
	case .Political:
		frame.region_display = .Filled_When_Far
	case .Control, .Fertility:
		frame.region_display = .Outlined
	case:
		frame.region_display = .Hidden
	}
	for &region, id in game.regions {
		color := REGION_UNHELD_COLOR
		if mode == .Political && region.owner != 0 do color = game.factions[region.owner].color
		frame.regions[id] = {
			color       = color,
			highlighted = frame.region_display != .Hidden && !reach_shown && Region_Id(id) == pointed,
		}
	}

	if reach_shown {
		flood := &movement.flood
		on_water := flood.domain != .Land
		piece := slot_map_get(&game.pieces, focus)
		controlled := piece != nil && game.can_move && piece.owner == game.player

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

	reach := &movement.sea_reach
	if reach.piece == focus && leader_march.piece != focus {
		piece := slot_map_get(&game.pieces, focus)
		controlled := piece != nil && game.can_move && piece.owner == game.player
		landings := &frame.highlights[LANDINGS_SLOT]
		landings^ = {
			kind          = controlled ? .Reach : .Foreign_Reach,
			circles_begin = len(frame.highlight_circles),
		}
		for beach, b in game.beaches do if b in reach.landable do append(&frame.highlight_circles, Render_Circle{beach.pos, BEACH_RADIUS})
		landings.circles_len = len(frame.highlight_circles) - landings.circles_begin
	}

	beaches := &frame.highlights[BEACHES_SLOT]
	beaches^ = {
		kind          = .Beach,
		circles_begin = len(frame.highlight_circles),
	}
	for beach, b in game.beaches do if b > 0 do append(&frame.highlight_circles, Render_Circle{beach.pos, BEACH_RADIUS})
	beaches.circles_len = len(frame.highlight_circles) - beaches.circles_begin

	for &march, mover in movement.marches {
		walker := slot_map_get(&game.pieces, march.piece)
		if walker == nil || mover not_in MARCH_ARROWS do continue
		ahead := march.path.points[march.next:]
		arrow := polylines_reserve(len(ahead) + 1, false, &frame.arrows) or_continue
		arrow[0] = walker.pos
		copy(arrow[1:], ahead)
	}

	if mode == .Supply {
		resize(&frame.wash, RENDER_TERRAIN_CELLS)
		for supply, i in game.supply_network do frame.wash[i] = u8(u32(supply) * 255 / 100)
	}
	if mode == .Fertility {
		resize(&frame.wash, RENDER_TERRAIN_CELLS)
		for region, i in game.terrain.regions {
			frame.wash[i] = u8(clamp(game.regions[region].fertility / FERTILITY_MAX, 0, 1) * 255 + 0.5)
		}
	}
	if mode == .Control {
		resize(&frame.wash, RENDER_TERRAIN_CELLS)
		for control, i in game.control_network do frame.wash[i] = u8(u32(control) * 255 / 100)
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
		icon := piece.icon
		for march in game.movement.marches do if march.piece == id && march.sails do icon = .Fleet
		pawn := Map_Pawn {
			pos         = piece.pos,
			icon        = icon,
			look        = game.cultures[piece.culture].look,
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
		}
		if factor.op == .Scale do value = fmt.tprintf("x %s", value)
		append(&breakdown.terms, Card_Term{string(factor.label[:]), value})
	}
	if append(&card.breakdowns, breakdown) == 0 do return nil
	return len(card.breakdowns) - 1
}

// A slot's tile, its menu added to the card
@(private = "file")
card_slot_tile :: proc(game: ^Game, card: ^Card, town_id: Piece_Id, slot: int) -> (tile: Card_Tile) {
	piece := slot_map_get(&game.pieces, town_id)
	town := &piece.town
	allows := town.building_orders[slot]
	cost_of :: proc(kind: ^Building_Kind) -> string {
		if kind.build_coin > 0 do return fmt.tprintf("%.0f turns, %.0f coin", kind.build_turns, kind.build_coin)
		return fmt.tprintf("%.0f turns", kind.build_turns)
	}

	menu: Card_Menu
	here := town.buildings[slot]
	project := town.projects[slot]
	if here != 0 {
		kind := &game.building_kinds[here]
		tile.name = name_to_string(&kind.name)
		tile.breakdown = card_building_breakdown(game, card, kind, town.slot_food[slot])
	}
	if project.active {
		if project.kind == 0 {
			tile.project = "Demolishing"
		} else {
			target := &game.building_kinds[project.kind]
			tile.project = fmt.tprintf("%s (%.0f)", name_to_string(&target.name), math.ceil(project.turns_left))
		}
		append(
			&menu.actions,
			Card_Menu_Action {
				label = "Cancel",
				detail = "No refund",
				enabled = allows.cancel,
				order = Town_Order{town = town_id, slot = slot, action = .Cancel},
			},
		)
	} else {
		for k in allows.offered {
			kind := &game.building_kinds[k]
			label := name_to_string(&kind.name)
			if here != 0 do label = fmt.tprintf("Upgrade to %s", label)
			append(
				&menu.actions,
				Card_Menu_Action {
					label = label,
					detail = cost_of(kind),
					enabled = k in allows.buildable,
					breakdown = card_building_breakdown(game, card, kind, kind.food + kind.food_fertility * town.fertility),
					order = Town_Order{town = town_id, slot = slot, action = .Build, kind = Building_Kind_Id(k)},
				},
			)
		}
		if here != 0 && slot != MAIN_SLOT {
			append(
				&menu.actions,
				Card_Menu_Action {
					label = "Demolish",
					detail = "Next turn",
					enabled = allows.demolish,
					order = Town_Order{town = town_id, slot = slot, action = .Demolish},
				},
			)
		}
	}
	menu.title = tile.name != "" ? tile.name : "Empty slot"
	if append(&card.menus, menu) > 0 do tile.click = Card_Menu_Id(len(card.menus) - 1)
	return
}

// Food is given: it depends on the town
@(private = "file")
card_building_breakdown :: proc(game: ^Game, card: ^Card, kind: ^Building_Kind, food: f32) -> Maybe(int) {
	breakdown := Card_Breakdown {
		description = description_to_string(&kind.description),
	}
	append(&breakdown.terms, Card_Term{"Population", fmt.tprintf("%.0f", kind.population)})
	if food != 0 do append(&breakdown.terms, Card_Term{"Food", fmt.tprintf("%+.0f", food)})
	if kind.income != 0 do append(&breakdown.terms, Card_Term{"Income", fmt.tprintf("%+.1f", kind.income)})
	if kind.upkeep != 0 do append(&breakdown.terms, Card_Term{"Upkeep", fmt.tprintf("%.0f", kind.upkeep)})
	if kind.control != 0 do append(&breakdown.terms, Card_Term{"Control", fmt.tprintf("%.0f", kind.control)})
	if kind.public_order != 0 do append(&breakdown.terms, Card_Term{"Public order", fmt.tprintf("%+.1f", kind.public_order)})
	if kind.food_store != 0 do append(&breakdown.terms, Card_Term{"Food store", fmt.tprintf("%+.0f", kind.food_store)})
	if kind.title_salary_global != 0 do append(&breakdown.terms, Card_Term{"Salary", fmt.tprintf("%.1f", kind.title_salary_global)})
	if kind.title_salary_local != 0 do append(&breakdown.terms, Card_Term{"Local salary", fmt.tprintf("%.1f", kind.title_salary_local)})
	if kind.title_salary_local_share != 0 do append(&breakdown.terms, Card_Term{"Local share", fmt.tprintf("%.0f", kind.title_salary_local_share)})
	if kind.title != 0 {
		title := &game.office_kinds[kind.title]
		append(&breakdown.terms, Card_Term{"Office", name_to_string(&title.name)})
		if title.army_type != 0 do append(&breakdown.terms, Card_Term{"Army", name_to_string(&game.army_types[title.army_type].name)})
	}
	if .Main in kind.flags {
		append(&breakdown.terms, Card_Term{"Size", ICON_TITLES[kind.icon]})
		append(&breakdown.terms, Card_Term{"Slots", fmt.tprint(kind.slots)})
	}
	if append(&card.breakdowns, breakdown) == 0 do return nil
	return len(card.breakdowns) - 1
}

@(private = "file")
tally_add :: proc(breakdowns: ^[dynamic; $N]Card_Breakdown, terms: []Card_Term, total := "", note := "") -> Maybe(int) {
	breakdown := Card_Breakdown {
		note  = note,
		total = total,
	}
	for term in terms do append(&breakdown.terms, term)
	if append(breakdowns, breakdown) == 0 do return nil
	return len(breakdowns) - 1
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

game_cards :: proc(game: ^Game, focus: Piece_Id, tab: Card_Tab, cards: ^Cards) {
	cards^ = {}

	status := &cards.status
	status.title = fmt.tprintf("Turn %d", game.turn)
	status.map_modes = true
	append(&status.fields, Card_Field{label = "Playing", value = faction_title(game, game.player)})
	{
		faction := &game.factions[game.player]
		append(&status.fields, Card_Field{label = "Treasury", value = compact_number(f64(faction.treasury))})
		net := faction.income - faction.upkeep
		append(
			&status.fields,
			Card_Field {
				label = "Income",
				value = fmt.tprintf("%+.1f", net),
				fill = 0.5 + 0.5 * net / max(faction.income, faction.upkeep, 1e-6),
				fill_origin = 0.5,
				breakdown = tally_add(
					&status.breakdowns,
					{{"Income", fmt.tprintf("%.1f", faction.income)}, {"Upkeep", fmt.tprintf("%+.1f", -faction.upkeep)}},
					fmt.tprintf("%+.1f", net),
				),
			},
		)
		append(&status.fields, Card_Field{label = "Food store", value = compact_number(f64(faction.food_store))})
		food_net := faction.food_sent - faction.food_taken
		append(
			&status.fields,
			Card_Field {
				label = "Food",
				value = fmt.tprintf("%+.1f", food_net),
				fill = 0.5 + 0.5 * food_net / max(faction.food_sent, faction.food_taken, 1e-6),
				fill_origin = 0.5,
				breakdown = tally_add(
					&status.breakdowns,
					{{"Sent", fmt.tprintf("%.1f", faction.food_sent)}, {"Taken", fmt.tprintf("%+.1f", -faction.food_taken)}},
					fmt.tprintf("%+.1f", food_net),
				),
			},
		)
	}
	{
		stability := game.factions[game.player].stability
		append(
			&status.fields,
			Card_Field {
				label = "Stability",
				value = fmt.tprintf("%.0f%%", stability),
				fill = stability / 100,
				graded = true,
				breakdown = card_note(status, "Its characters' loyalty, weighted by their influence"),
			},
		)
	}
	append(&status.actions, Card_Action{"End turn", Game_Order(End_Turn_Order{}), game.endable})
	append(&status.actions, Card_Action{"Court", Game_Ask.Court, true})

	// The court
	{
		court := &cards.court
		court.title = fmt.tprintf("Court of %s", faction_title(game, game.player))

		// The greatest influence and wealth, filling the bars
		influence_max, wealth_max: f32 = 1, 1
		for &character, c in game.characters {
			if c == 0 || character.faction != game.player do continue
			influence_max = max(influence_max, character.influence)
			if office := slot_map_get(&game.offices, character.office); office != nil do wealth_max = max(wealth_max, office.wealth)
		}

		for &character, c in game.characters {
			if c == 0 || character.faction != game.player do continue
			row := Court_Row {
				name        = name_to_string(&character.name),
				rank        = character.rank,
				influence   = character.influence,
				age         = character.age,
				temperament = fmt.tprint(character.temperament),
				background  = fmt.tprint(character.background),
				disposition = fmt.tprint(character.disposition),
				character   = Character_Id(c),
			}
			row.rank_breakdown = tally_add(&court.breakdowns, {{"Rank", fmt.tprint(character.rank)}})
			wealth: f32
			row.stats[1] = {
				label  = "Influence",
				value  = fmt.tprintf("%.0f", character.influence),
				fill   = character.influence / influence_max,
			}
			row.stats[2] = {
				label  = "Loyalty",
				value  = fmt.tprintf("%.0f%%", character.loyalty),
				fill   = character.loyalty / 100,
				graded = true,
			}
			if office := slot_map_get(&game.offices, character.office); office != nil {
				kind := &game.office_kinds[office.kind]
				row.office = name_to_string(&office.title)
				row.office_id = character.office
				wealth = office.wealth
				// Wealth only when it adds
				target := [2]Card_Term{{"Office", fmt.tprintf("%.0f", kind.influence)}, {"Wealth", fmt.tprintf("%+.0f", character.influence_target - kind.influence)}}
				terms := target[:math.round(character.influence_target - kind.influence) > 0 ? 2 : 1]
				row.stats[1].breakdown = tally_add(&court.breakdowns, terms, fmt.tprintf("%.0f", character.influence_target))
				switch office.dismissal {
				case .For_Life:
					row.undismissable = "Held for life"
				case .Not_Dismissable:
					row.undismissable = "Not dismissable"
				case .In_Term:
					row.undismissable = fmt.tprintf("Term: %d %s left", office.term_left, office.term_left == 1 ? "turn" : "turns")
				case .Not_Now:
					row.undismissable = "Not now"
				case .Allowed:
					row.dismiss = Dismiss_Order{character.office}
					if .Feudal in kind.flags {
						row.dismiss_breakdown = tally_add(
							&court.breakdowns,
							{{"Each feudal holder", fmt.tprintf("-%d loyalty", FEUDAL_DISMISSAL_LOYALTY)}},
						)
					}
				}
				base := slot_map_get(&game.pieces, office.muster_at)
				if kind.army_type != 0 && base != nil {
					row.army = name_to_string(&game.army_types[kind.army_type].name)
					row.base = name_to_string(&base.name)
					men := office.men
					if army := slot_map_get(&game.pieces, office.army); army != nil do men = army.army.men
					row.men = {
						value  = compact_number(f64(men)),
						fill   = f32(men) / f32(max(office.men_max, 1)),
						graded = true,
					}
				}
			}
			row.stats[0] = {
				label = "Wealth",
				value = fmt.tprintf("%.1f", wealth),
				fill  = wealth / wealth_max,
			}
			append(&court.rows, row)
			court.rank_max = max(court.rank_max, row.rank)
		}
		slice.sort_by(court.rows[:], proc(a, b: Court_Row) -> bool {
			return a.rank != b.rank ? a.rank > b.rank : a.influence > b.influence
		})

		for office_id in game.offices_ranked {
			office := slot_map_get(&game.offices, office_id)
			if office.faction != game.player do continue
			kind := &game.office_kinds[office.kind]
			court.rank_max = max(court.rank_max, kind.rank)
			traits := make([dynamic]string, context.temp_allocator)
			for flag in kind.flags do if flag != .Dismissable do append(&traits, fmt.tprint(flag))
			holder_name := office.holder != 0 ? name_to_string(&game.characters[office.holder].name) : ""
			terms := [3]Card_Term {
				{"Rank", fmt.tprint(kind.rank)},
				{"Influence", fmt.tprintf("%.0f", kind.influence)},
				{"Holder", office.holder != 0 ? holder_name : "Vacant"},
			}
			append(
				&court.offices,
				Court_Office {
					title = name_to_string(&office.title),
					rank = kind.rank,
					holder = office.holder,
					holder_name = holder_name,
					filling = office_id == game.appointment.office,
					traits = strings.join(traits[:], ", ", context.temp_allocator),
					id = office_id,
					breakdown = tally_add(&court.breakdowns, terms[:], note = name_to_string(&office.title)),
				},
			)
		}

		if vacancy := slot_map_get(&game.offices, game.appointment.office); vacancy != nil {
			kind := &game.office_kinds[vacancy.kind]
			court.vacancy.office = game.appointment.office
			court.vacancy.title = name_to_string(&vacancy.title)
			court.vacancy.rank = kind.rank
			court.vacancy.can_appoint = game.appointment.can_appoint
			if kind.army_type != 0 do court.vacancy.army = name_to_string(&game.army_types[kind.army_type].name)
			for candidate in game.appointment.candidates {
				character := &game.characters[candidate.character]
				office_title := "None"
				if office := slot_map_get(&game.offices, character.office); office != nil do office_title = name_to_string(&office.title)
				passes := fmt.tprintf("%d, -%d loyalty each", candidate.passed_over, PASSED_OVER_LOYALTY)
				terms := [3]Card_Term{{"Office", office_title}, {"Rank", fmt.tprint(character.rank)}, {"Passes over", passes}}
				append(
					&court.vacancy.candidates,
					Court_Candidate {
						character = candidate.character,
						name = name_to_string(&character.name),
						order = {game.appointment.office, candidate.character},
						breakdown = tally_add(&court.breakdowns, terms[:candidate.passed_over > 0 ? 3 : 2]),
					},
				)
			}
		}
	}

	if piece := slot_map_get(&game.pieces, focus); piece != nil {
		cards.focus_shown = true
		card := &cards.focus
		card.title = game_piece_title(piece)
		card.tab = tab
		if .Has_Army in piece.flags do card.tabs += {.Army}
		if .Has_Town in piece.flags do card.tabs += {.Town}
		// The chosen tab, or else one the piece has
		if card.tab not_in card.tabs {
			for each in Card_Tab {
				if each in card.tabs {
					card.tab = each
					break
				}
			}
		}
		army := piece.army
		is_army := .Has_Army in piece.flags
		type_field := Card_Field {
			label = "Type",
			value = ICON_TITLES[piece.icon],
		}
		if is_army && army.type != 0 {
			army_type := &game.army_types[army.type]
			type_field.value = name_to_string(&army_type.name)
			described := Card_Breakdown {
				description = description_to_string(&army_type.description),
			}
			if append(&card.breakdowns, described) > 0 do type_field.breakdown = len(card.breakdowns) - 1
		}
		if .Has_Town in piece.flags {
			main := card_slot_tile(game, card, focus, MAIN_SLOT)
			type_field.value = main.name
			type_field.breakdown = main.breakdown
			type_field.click = main.click
		}
		append(&card.fields, type_field)
		append(&card.fields, Card_Field{label = "Faction", value = faction_title(game, piece.owner)})
		append(&card.fields, Card_Field{label = "Culture", value = name_to_string(&game.cultures[piece.culture].name)})
		if title := slot_map_get(&game.offices, army.title); is_army && title != nil && title.army == focus {
			if piece.owner == game.player {
				append(&card.buttons, Card_Action{"Demobilise", Game_Order(Title_Order{army.title, .Demobilise}), true})
			}
		}
		statuses := make([dynamic]string, context.temp_allocator)
		if is_army do for status in army.statuses do append(&statuses, fmt.tprint(status))
		if piece.inside != {} do append(&statuses, "Garrisoning")
		if piece.contains != {} do append(&statuses, "Garrisoned")
		status := "None"
		if len(statuses) > 0 do status = strings.join(statuses[:], ", ", context.temp_allocator)
		append(&card.fields, Card_Field{label = "Status", value = status})
		if is_army {
			names := make([dynamic]string, context.temp_allocator)
			descriptions := make([dynamic]string, context.temp_allocator)
			described: Card_Breakdown
			for trait in game.army_types[army.type].traits {
				each := &game.army_traits[trait]
				modifiers := make([dynamic]string, context.temp_allocator)
				if each.modifiers.agility != 0 do append(&modifiers, fmt.tprintf("Agility %+.0f", each.modifiers.agility))
				if each.modifiers.movement != 0 do append(&modifiers, fmt.tprintf("Movement %+.0f", each.modifiers.movement))
				if each.modifiers.readiness_recovery != 0 {
					append(&modifiers, fmt.tprintf("Readiness recovery %+.0f", each.modifiers.readiness_recovery))
				}
				for prevented in each.modifiers.prevent_status do append(&modifiers, fmt.tprintf("Never %v", prevented))
				append(&names, name_to_string(&each.name))
				append(&descriptions, description_to_string(&each.description))
				append(&described.terms, Card_Term{name_to_string(&each.name), strings.join(modifiers[:], ", ", context.temp_allocator)})
			}
			traits := Card_Field{label = "Traits", value = "None"}
			if len(names) > 0 {
				traits.value = strings.join(names[:], ", ", context.temp_allocator)
				described.description = strings.join(descriptions[:], " ", context.temp_allocator)
				if append(&card.breakdowns, described) > 0 do traits.breakdown = len(card.breakdowns) - 1
			}
			append(&card.fields, traits)
		}
		if piece.domain != nil {
			left := piece.this_turn.movement_left
			per_turn := piece.movement_per_turn
			append(
				&card.fields,
				Card_Field {
					label = "Movement",
					value = compact_number(f64(left)),
					fill = per_turn > 0 ? left / per_turn : 0,
					graded = true,
					breakdown = tally_add(
						&card.breakdowns,
						{
							{"Per turn", compact_number(f64(per_turn))},
							{"Spent", fmt.tprintf("-%s", compact_number(f64(per_turn - left)))},
						},
						compact_number(f64(left)),
					),
				},
			)
		}
		if .Has_Town in piece.flags {
			fertility := piece.town.fertility
			append(
				&card.fields,
				Card_Field {
					label = "Fertility",
					value = fmt.tprintf("%.0f", fertility),
					fill = fertility / FERTILITY_MAX,
					graded = true,
				},
			)

			// Mobilising: the owner's titles here, and at its capital the faction's own
			mobilise := Card_Menu {
				title = "Mobilise",
			}
			titles := slot_map_iterator(&game.offices)
			for office, office_id in slot_map_iterate(&titles) {
				kind := &game.office_kinds[office.kind]
				if office.faction != piece.owner || kind.army_type == 0 || office.muster_at != focus do continue
				army_type := &game.army_types[kind.army_type]
				holder := name_to_string(&game.characters[office.holder].name)
				men := compact_number(f64(office.men))
				detail := fmt.tprintf("%s, %s men", holder, men)
				if office.holder == 0 do detail = fmt.tprintf("Vacant, %s men", men)
				if office.army != {} do detail = fmt.tprintf("%s, in the field", holder)

				breakdown := Card_Breakdown {
					description = description_to_string(&army_type.description),
				}
				append(&breakdown.terms, Card_Term{"Army", name_to_string(&army_type.name)})
				append(&breakdown.terms, Card_Term{"Scope", fmt.tprint(army_type.scope)})
				append(
					&breakdown.terms,
					Card_Term{"Men", fmt.tprintf("%s of %s", men, compact_number(f64(office.men_max)))},
				)
				append(&breakdown.terms, Card_Term{"Pay", fmt.tprintf("%.1f a turn", office.wealth)})
				append(&breakdown.terms, Card_Term{"Proficiency", fmt.tprintf("%.0f%%", army_type.proficiency)})
				append(&breakdown.terms, Card_Term{"Foraging", fmt.tprintf("%.0f%%", army_type.foraging)})
				append(&breakdown.terms, Card_Term{"Agility", fmt.tprintf("%.0f", army_type.agility)})
				for trait in army_type.traits {
					append(&breakdown.terms, Card_Term{"Trait", name_to_string(&game.army_traits[trait].name)})
				}
				action := Card_Menu_Action {
					label   = name_to_string(&kind.name),
					detail  = detail,
					enabled = office.can_mobilise,
					order   = Title_Order{office = office_id, action = .Mobilise},
				}
				if append(&card.breakdowns, breakdown) > 0 do action.breakdown = len(card.breakdowns) - 1
				append(&mobilise.actions, action)
			}
			if len(mobilise.actions) > 0 && append(&card.menus, mobilise) > 0 {
				append(&card.buttons, Card_Action{"Mobilise", Card_Menu_Id(len(card.menus) - 1), true})
			}
		}

		if card.tab == .Town {
			town := &piece.town
			// Population: a balance against the staff its buildings need
			staff_net := town.population - town.staff_needed
			append(
				&card.stats,
				Card_Field {
					label = "Population",
					value = fmt.tprintf("%.0f", town.population),
					fill = 0.5 + 0.5 * staff_net / max(town.population, town.staff_needed, 1e-6),
					fill_origin = 0.5,
					breakdown = tally_add(
						&card.breakdowns,
						{
							{"People", fmt.tprintf("%.1f", town.population)},
							{"Staff needed", fmt.tprintf("%+.1f", -town.staff_needed)},
						},
						fmt.tprintf("%+.1f", staff_net),
					),
				},
			)

			// Balances, from the middle: supply less demand, over the larger of the two
			Balance :: struct {
				label:          string,
				supply, demand: f32,
				terms:          []Card_Term,
			}
			balances := [?]Balance {
				{
					"Food",
					town.food,
					town.food_eaten,
					{{"Produced", fmt.tprintf("%.1f", town.food)}, {"Eaten", fmt.tprintf("%+.1f", -town.food_eaten)}},
				},
				{
					"Income",
					town.income,
					town.upkeep,
					{
						{"To the treasury", fmt.tprintf("%.1f", town.income)},
						{"Upkeep", fmt.tprintf("%+.1f", town.salaries_global - town.upkeep)},
						{"Salaries", fmt.tprintf("%+.1f", -town.salaries_global)},
					},
				},
				{
					"Public order",
					town.public_order,
					town.unrest,
					{{"Order", fmt.tprintf("%.1f", town.public_order)}, {"Unrest", fmt.tprintf("%+.1f", -town.unrest)}},
				},
			}
			for balance in balances {
				net := balance.supply - balance.demand
				append(
					&card.stats,
					Card_Field {
						label = balance.label,
						value = fmt.tprintf("%+.1f", net),
						fill = 0.5 + 0.5 * net / max(balance.supply, balance.demand, 1e-6),
						fill_origin = 0.5,
						breakdown = tally_add(&card.breakdowns, balance.terms, fmt.tprintf("%+.1f", net)),
					},
				)
			}

			append(
				&card.stats,
				Card_Field {
					label = "Wealth",
					value = fmt.tprintf("%.1f", town.wealth),
					breakdown = tally_add(
						&card.breakdowns,
						{
							{"Kept locally", fmt.tprintf("%.1f", town.wealth)},
							{"Salaries", fmt.tprintf("%+.1f", -town.salaries_local)},
						},
						fmt.tprintf("%.1f", town.wealth_shared),
					),
				},
			)
			append(
				&card.stats,
				Card_Field {
					label = "Control",
					value = fmt.tprintf("%.0f%%", town.control),
					fill = town.control / 100,
					graded = true,
				},
			)

			// Two rows: the slots fill the first columns, the rest disabled
			columns := town.slots / 2
			for position in 0 ..< TOWN_SLOTS_MAX {
				row := position / (TOWN_SLOTS_MAX / 2)
				column := position % (TOWN_SLOTS_MAX / 2)
				if column >= columns {
					append(&card.tiles, Card_Tile{disabled = true})
					continue
				}
				append(&card.tiles, card_slot_tile(game, card, focus, row * columns + column))
			}
		} else {
			if piece.general != 0 {
				character := &game.characters[piece.general]
				general := Card_Field {
					label = "General",
					value = name_to_string(&character.name),
				}
				if character.faction == game.player do general.click = piece.general
				append(&card.stats, general)
			}
			if is_army {
				append(
					&card.stats,
					Card_Field {
						label = "Men",
						value = compact_number(f64(army.men)),
						fill = army.men_max > 0 ? f32(army.men) / f32(army.men_max) : 0,
						graded = true,
						breakdown = tally_add(
							&card.breakdowns,
							{{"Men", compact_number(f64(army.men))}, {"Full strength", compact_number(f64(army.men_max))}},
						),
					},
				)
				// Percentages: the bar is out of 100
				percents := [?]struct {
					label: string,
					value: f32,
				} {
					{"Proficiency", army.proficiency},
					{"Readiness", army.readiness},
					{"Supply", army.supply},
				}
				for percent in percents {
					append(
						&card.stats,
						Card_Field {
							label = percent.label,
							value = fmt.tprintf("%.0f%%", percent.value),
							fill = percent.value / 100,
							graded = true,
						},
					)
				}
				efficiency := 100 * army.supply_efficiency
				append(
					&card.stats,
					Card_Field {
						label = "Efficiency",
						value = fmt.tprintf("%.0f%%", efficiency),
						fill = efficiency / 100,
						graded = true,
					},
				)
				append(&card.stats, Card_Field{label = "Source", value = fmt.tprint(army.supply_source)})
			}
		}
	}

	open := &game.interaction
	if open.actor == {} do return

	result := &open.result
	report := &result.report
	names := [2]string{report_string(report, result.names[0]), report_string(report, result.names[1])}
	pieces := [2]^Piece_Data{slot_map_get(&game.pieces, open.actor), slot_map_get(&game.pieces, open.target)}
	attacker := result.attacker
	defender := 1 - attacker
	kind := report_string(report, result.kind_title)
	cards.interaction_shown = true
	card := &cards.interaction
	#partial switch open.stage {
	case .Announce:
		card.title = fmt.tprintf("%s: %s", kind, report_string(report, result.attack_title))
	case .Refused:
		card.title = fmt.tprintf("%s: %s", kind, report_string(report, result.attack_title))
		card_report(card, report)
	case .Report:
		card.title = fmt.tprintf("%s report", kind)
		card_report(card, report)
	case .Outcome:
		card.title = fmt.tprintf("%s: %s", kind, report_string(report, result.outcome_title))
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
				if .Has_Army not_in piece.flags do continue
				army := piece.army
				temperament := army.temperament
				power := fmt.tprintf("%.1f", side.power.total)
				men := Card_Field {
					label = "Men",
					value = compact_number(f64(army.men)),
				}
				if side.men_engaged.total < f32(army.men) {
					engaged := compact_number(f64(side.men_engaged.total))
					men.value = fmt.tprintf("%s of %s", engaged, men.value)
					men.breakdown = card_breakdown(card, &side.men_engaged, engaged)
				}
				append(fields, Card_Field{label = "Commander", value = fmt.tprint(temperament)})
				append(fields, men)
				append(fields, Card_Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
				append(fields, card_tally_field(card, "Power", &side.power, power))
			case .Fall_Back:
				if !result.caught || side_index == result.winner do continue
				men := compact_number(f64(side.pursuit_men.total))
				append(fields, card_tally_field(card, "Men", &side.pursuit_men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f%%", side.pursuit_readiness)})
			case:
				men := compact_number(f64(side.men.total))
				append(fields, Card_Field{label = "Posture", value = report_string(report, side.posture)})
				append(fields, card_tally_field(card, "Men", &side.men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f%%", side.readiness)})
				if side.dissolved do append(fields, Card_Field{label = "Fate", value = "Dissolved"})
			}
		}
	}

	append(&card.actions, Card_Action{"Next", Game_Order(Next_Order{}), game.movement.marches[.Leader].piece == {}})
}
