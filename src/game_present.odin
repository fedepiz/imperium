package main

import "core:fmt"
import "core:math"
import "core:strings"

CARD_LINES_MAX :: REPORT_LINES_MAX
CARD_PARTS_MAX :: REPORT_PARTS_MAX
CARD_BREAKDOWNS_MAX :: 128
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4
CARD_TILES_MAX :: 16
CARD_TILE_ACTIONS_MAX :: BUILDING_KINDS_MAX

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

// What the focus card shows of a piece
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

// The top of the fertility scale: it fills the bar, and washes the map at its greenest
@(private = "file")
FERTILITY_MAX :: 5

@(private = "file")
REACH_SLOT :: 0
@(private = "file")
FRIEND_ZONES_SLOT :: 1
@(private = "file")
ENEMY_ZONES_SLOT :: 2

// Movers whose march is drawn as an arrow
@(private = "file")
MARCH_ARROWS :: bit_set[Mover]{.Leader, .Chaser}

@(private = "file", rodata)
ICON_TITLES := [Map_Icon]string {
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
	// Share of the whole, 0..1: shown as a bar after the value, filled from fill_origin. An origin above 0 is a balance:
	// below it a shortfall, above it a surplus
	fill:        Maybe(f32),
	fill_origin: f32,
	// The fill colored from bad to good by how full it is
	graded:      bool,
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

// A building slot; no name: empty
Card_Tile :: struct {
	name:      string,
	breakdown: Maybe(int),
	// Not a slot this settlement has
	disabled:  bool,
	// Its project under way, if any
	project:   string,
	// Offered when it is clicked
	actions:   [dynamic; CARD_TILE_ACTIONS_MAX]Card_Tile_Action,
}

// Something to do with a slot: build, upgrade, demolish
Card_Tile_Action :: struct {
	label:     string,
	// Its cost, or what it does
	detail:    string,
	enabled:   bool,
	// What the building it makes does, on hover
	breakdown: Maybe(int),
	// Sent when it is clicked
	order:     Town_Order,
}

Card :: struct {
	title:      string,
	lines:      [dynamic; CARD_LINES_MAX]Span,
	parts:      [dynamic; CARD_PARTS_MAX]Card_Part,
	breakdowns: [dynamic; CARD_BREAKDOWNS_MAX]Card_Breakdown,
	fields:     [dynamic; CARD_FIELDS_MAX]Card_Field,
	stats:      [dynamic; CARD_FIELDS_MAX]Card_Field,
	tiles:      [dynamic; CARD_TILES_MAX]Card_Tile,
	actions:    [dynamic; CARD_ACTIONS_MAX]Card_Action,
	// Tabs the piece has, and the one shown
	tabs:       bit_set[Card_Tab],
	tab:        Card_Tab,
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
	leader_march := &movement.marches[.Leader]
	reach_shown :=
		movement.flood_key != 0 &&
		movement.flooded == focus &&
		movement.flooded != leader_march.piece

	// Political fills the regions in their owners' colours; Control and Fertility outline them, over their washes
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
		capital := slot_map_get(&game.pieces, region.capital)
		if mode == .Political && capital != nil && capital.owner != 0 {
			color = game.factions[capital.owner].color
		}
		frame.regions[id] = {
			color       = color,
			highlighted = frame.region_display != .Hidden && !reach_shown && Region_Id(id) == pointed,
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
		pawn := Map_Pawn {
			pos         = piece.pos,
			icon        = piece.icon,
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

// What a building does, as a breakdown on the card: for a slot's building, and for one that could be built. Food is
// given, as it depends on the town
@(private = "file")
card_building_breakdown :: proc(card: ^Card, kind: ^Building_Kind, food: f32) -> Maybe(int) {
	breakdown: Card_Breakdown
	append(&breakdown.terms, Card_Term{"Population", fmt.tprintf("%.0f", kind.population)})
	if food != 0 do append(&breakdown.terms, Card_Term{"Food", fmt.tprintf("%+.0f", food)})
	if kind.labour != 0 do append(&breakdown.terms, Card_Term{"Labour", fmt.tprintf("%+.0f", kind.labour)})
	if kind.income != 0 do append(&breakdown.terms, Card_Term{"Income", fmt.tprintf("%+.1f", kind.income)})
	if kind.upkeep != 0 do append(&breakdown.terms, Card_Term{"Upkeep", fmt.tprintf("%.0f", kind.upkeep)})
	if kind.control != 0 do append(&breakdown.terms, Card_Term{"Control", fmt.tprintf("%.0f", kind.control)})
	if kind.features != {} {
		names := make([dynamic]string, context.temp_allocator)
		for feature in kind.features do append(&names, fmt.tprint(feature))
		append(&breakdown.terms, Card_Term{"Features", strings.join(names[:], ", ", context.temp_allocator)})
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

game_cards :: proc(game: ^Game, focus: Piece_Id, tab: Card_Tab, cards: ^Cards) {
	cards^ = {}

	status := &cards.status
	status.title = fmt.tprintf("Turn %d", game.turn)
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
				breakdown = card_note(status, fmt.tprintf("%.1f income, %.1f upkeep", faction.income, faction.upkeep)),
			},
		)
	}
	append(&status.actions, Card_Action{"End turn", .End_Turn, game_turn_endable(game)})

	if piece := slot_map_get(&game.pieces, focus); piece != nil {
		card := Card {
			title = game_piece_title(piece),
			tab   = tab,
		}
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
		// The piece, the same on every tab
		army := piece.army
		is_army := .Has_Army in piece.flags
		append(&card.fields, Card_Field{label = "Type", value = ICON_TITLES[piece.icon]})
		append(&card.fields, Card_Field{label = "Faction", value = faction_title(game, piece.owner)})
		append(&card.fields, Card_Field{label = "Culture", value = name_to_string(&game.cultures[piece.culture].name)})
		statuses := make([dynamic]string, context.temp_allocator)
		if is_army && army.spent do append(&statuses, "Spent")
		if piece.inside != {} do append(&statuses, "Garrisoning")
		if piece.contains != {} do append(&statuses, "Garrisoned")
		status := "None"
		if len(statuses) > 0 do status = strings.join(statuses[:], ", ", context.temp_allocator)
		append(&card.fields, Card_Field{label = "Status", value = status})
		if piece.domain != nil {
			left := game_movement_left(piece^)
			per_turn := piece.movement_per_turn
			append(
				&card.fields,
				Card_Field {
					label = "Movement",
					value = compact_number(f64(left)),
					fill = per_turn > 0 ? left / per_turn : 0,
					graded = true,
					breakdown = card_note(&card, fmt.tprintf("%s of %s", compact_number(f64(left)), compact_number(f64(per_turn)))),
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
		}

		// The tab's own section
		if card.tab == .Town {
			town := &piece.town
			// Population: its people, and a balance of them against the staff its buildings need
			staff_net := town.population - town.staff_needed
			append(
				&card.stats,
				Card_Field {
					label = "Population",
					value = fmt.tprintf("%.0f", town.population),
					fill = 0.5 + 0.5 * staff_net / max(town.population, town.staff_needed, 1e-6),
					fill_origin = 0.5,
					breakdown = card_note(
						&card,
						fmt.tprintf("%.1f people, %.0f needed by buildings", town.population, town.staff_needed),
					),
				},
			)

			// Balances, from the middle: supply less demand, over the larger of the two. All of it spare fills the right
			// half; none of the demand met, the left
			Balance :: struct {
				label, note:    string,
				supply, demand: f32,
			}
			balances := [?]Balance {
				{"Food", fmt.tprintf("%.1f produced, %.1f eaten", town.food, town.food_eaten), town.food, town.food_eaten},
				{"Labour", fmt.tprintf("%.0f produced, %.0f used", town.labour, town.labour_used), town.labour, town.labour_used},
				{"Income", fmt.tprintf("%.1f income, %.1f upkeep", town.income, town.upkeep), town.income, town.upkeep},
				// Made up until public order exists
				{"Public order", "2.0 order, 3.5 unrest", 2, 3.5},
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
						breakdown = card_note(&card, balance.note),
					},
				)
			}

			append(
				&card.stats,
				Card_Field {
					label = "Control",
					value = fmt.tprintf("%.0f%%", town.control),
					fill = town.control / 100,
					graded = true,
				},
			)

			feature_names := make([dynamic]string, context.temp_allocator)
			for feature in town.features do append(&feature_names, fmt.tprint(feature))
			features := len(feature_names) > 0 ? strings.join(feature_names[:], ", ", context.temp_allocator) : "None"
			append(&card.stats, Card_Field{label = "Features", value = features})

			// The tiles: two rows, a town's slots filling the first columns of both, the rest disabled. A slot shows its
			// building, with what it does here on hover, or is empty. Clicked, it offers what can be built there
			columns := town.slots / 2
			// Only the playing faction acts on its towns
			acting := piece.owner == game.player
			treasury := game.factions[piece.owner].treasury
			// What building a kind costs, and whether the treasury can pay its coin
			Cost :: struct {
				detail:  string,
				payable: bool,
			}
			cost_of :: proc(kind: ^Building_Kind, treasury: f32) -> Cost {
				detail := fmt.tprintf("%.0f labour a turn, %.0f turns", kind.build_labour, kind.build_turns)
				if kind.build_coin > 0 do detail = fmt.tprintf("%s, %.0f coin", detail, kind.build_coin)
				return {detail, treasury >= kind.build_coin}
			}
			for position in 0 ..< TOWN_SLOTS_MAX {
				row := position / (TOWN_SLOTS_MAX / 2)
				column := position % (TOWN_SLOTS_MAX / 2)
				tile: Card_Tile
				if column >= columns {
					tile.disabled = true
					append(&card.tiles, tile)
					continue
				}
				slot := row * columns + column
				here := town.buildings[slot]
				project := town.projects[slot]
				if here != 0 {
					kind := &game.building_kinds[here]
					tile.name = name_to_string(&kind.name)
					tile.breakdown = card_building_breakdown(&card, kind, town.slot_food[slot])
				}
				if project.active {
					// Under way: its progress, and cancelling
					if project.kind == 0 {
						tile.project = "Demolishing"
					} else {
						target := &game.building_kinds[project.kind]
						tile.project = fmt.tprintf("%s (%.0f)", name_to_string(&target.name), math.ceil(project.turns_left))
					}
					append(
						&tile.actions,
						Card_Tile_Action {
							label = "Cancel",
							detail = "No refund",
							enabled = acting,
							order = {town = focus, slot = slot, action = .Cancel},
						},
					)
				} else if here != 0 {
					kind := &game.building_kinds[here]
					if kind.upgrade != 0 {
						next := &game.building_kinds[kind.upgrade]
						cost := cost_of(next, treasury)
						append(
							&tile.actions,
							Card_Tile_Action {
								label = fmt.tprintf("Upgrade to %s", name_to_string(&next.name)),
								detail = cost.detail,
								enabled = acting && cost.payable && game.culture_buildings[piece.culture][kind.upgrade],
								breakdown = card_building_breakdown(&card, next, next.food + next.food_fertility * town.fertility),
								order = {town = focus, slot = slot, action = .Build, kind = kind.upgrade},
							},
						)
					}
					append(
						&tile.actions,
						Card_Tile_Action {
							label = "Demolish",
							detail = "Next turn",
							enabled = acting,
							order = {town = focus, slot = slot, action = .Demolish},
						},
					)
				} else {
					// The first level of every chain the town's culture can build
					for &kind, k in game.building_kinds {
						if k == 0 || kind.upgraded_from != 0 || !game.culture_buildings[piece.culture][k] do continue
						cost := cost_of(&kind, treasury)
						append(
							&tile.actions,
							Card_Tile_Action {
								label = name_to_string(&kind.name),
								detail = cost.detail,
								enabled = acting && cost.payable,
								breakdown = card_building_breakdown(&card, &kind, kind.food + kind.food_fertility * town.fertility),
								order = {town = focus, slot = slot, action = .Build, kind = Building_Kind_Id(k)},
							},
						)
					}
				}
				append(&card.tiles, tile)
			}
		} else {
			if piece.general != 0 {
				general := name_to_string(&game.characters[piece.general].name)
				append(&card.stats, Card_Field{label = "General", value = general})
			}
			if is_army {
				append(
					&card.stats,
					Card_Field {
						label = "Men",
						value = compact_number(f64(army.men)),
						fill = army.men_max > 0 ? f32(army.men) / f32(army.men_max) : 0,
						graded = true,
						breakdown = card_note(
							&card,
							fmt.tprintf("%s of %s", compact_number(f64(army.men)), compact_number(f64(army.men_max))),
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
		cards.focus = card
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
	card: Card
	#partial switch open.stage {
	case .Announce:
		card.title = fmt.tprintf("%s: %s", kind, report_string(report, result.attack_title))
	case .Refused:
		card.title = fmt.tprintf("%s: %s", kind, report_string(report, result.attack_title))
		card_report(&card, report)
	case .Report:
		card.title = fmt.tprintf("%s report", kind)
		card_report(&card, report)
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
				temperament := game_commander_temperament(game, piece)
				power := fmt.tprintf("%.1f", side.power.total)
				men := Card_Field {
					label = "Men",
					value = compact_number(f64(army.men)),
				}
				if side.men_engaged.total < f32(army.men) {
					engaged := compact_number(f64(side.men_engaged.total))
					men.value = fmt.tprintf("%s of %s", engaged, men.value)
					men.breakdown = card_breakdown(&card, &side.men_engaged, engaged)
				}
				append(fields, Card_Field{label = "Commander", value = fmt.tprint(temperament)})
				append(fields, men)
				append(fields, Card_Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
				append(fields, card_tally_field(&card, "Power", &side.power, power))
			case .Fall_Back:
				if !result.caught || side_index == result.winner do continue
				men := compact_number(f64(side.pursuit_men.total))
				append(fields, card_tally_field(&card, "Men", &side.pursuit_men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f%%", side.pursuit_readiness)})
			case:
				men := compact_number(f64(side.men.total))
				append(fields, Card_Field{label = "Posture", value = report_string(report, side.posture)})
				append(fields, card_tally_field(&card, "Men", &side.men, men))
				append(fields, Card_Field{label = "Readiness", value = fmt.tprintf("%+.0f%%", side.readiness)})
				if side.dissolved do append(fields, Card_Field{label = "Fate", value = "Dissolved"})
			}
		}
	}

	append(&card.actions, Card_Action{"Next", .Next, game.movement.marches[.Leader].piece == {}})
	cards.interaction = card
}
