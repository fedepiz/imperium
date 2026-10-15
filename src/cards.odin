package main

import "core:fmt"
import "core:math"

@(private = "file")
HOT_PAPER_SHADE :: 0.9
@(private = "file")
ACTIVE_PAPER_SHADE :: 0.8
@(private = "file")
FADED_INK_ALPHA :: 0.6
@(private = "file")
HOVER_INK :: [4]f32{0.62, 0.24, 0.16, 1}
// The Germanic wash and the Roman roofs
@(private = "file")
GOOD_INK :: [4]f32{0.47, 0.58, 0.47, 1}
@(private = "file")
BAD_INK :: [4]f32{0.70, 0.40, 0.29, 1}
// Yellow ochre, between them
@(private = "file")
MIDDLE_INK :: [4]f32{0.76, 0.62, 0.32, 1}
// A bar's part about to go, or come
@(private = "file")
LOSS_INK :: [4]f32{0.70, 0.40, 0.29, 0.45}
@(private = "file")
GAIN_INK :: [4]f32{0.47, 0.58, 0.47, 0.45}
// A status about to come, or go
@(private = "file")
COMING_INK :: [4]f32{0.47, 0.58, 0.47, 0.9}
@(private = "file")
GOING_INK :: [4]f32{0.70, 0.40, 0.29, 0.9}
// A balance bar's notch: how far it stands out of its halves, and its gap
@(private = "file")
NOTCH_STAND_OUT :: 3
@(private = "file")
NOTCH_GAP :: 2

@(private = "file")
SCREEN_MARGIN :: [2]f32{20, 20}
Court_View :: struct {
	open:     bool,
	// Last frame's, drawn highlighted. 0: none
	hovered:  Character_Id,
	// Clicked or opened on, with his office, highlighted until closed. Reveal: scrolled to once
	selected: Character_Id,
	reveal:   bool,
	office:   Office_Id,
}

@(private = "file")
COURT_MARGIN :: [2]f32{60, 40}
@(private = "file")
COURT_GAP :: 24
@(private = "file")
AI_REPORT_GOAL_EM :: 16
@(private = "file")
AI_REPORT_ARMY_EM :: 11
@(private = "file")
AI_REPORT_ORDER_SQUARE :: 10
@(private = "file")
AI_REPORT_BLINK_HZ :: 2
@(private = "file")
COURT_ENTRY_LINES :: 3
@(private = "file")
COURT_ENTRY_PADDING :: 8
@(private = "file")
COURT_ENTRY_GAP :: 8
@(private = "file")
COURT_RANK_SQUARE :: 9
@(private = "file")
COURT_RANK_GAP :: 3
@(private = "file")
COURT_RANK_STRIP_GAP :: 6
// The pyramid wraps past COURT_OFFICES_PER_ROW
@(private = "file")
COURT_OFFICES_PER_ROW :: 6
@(private = "file")
COURT_OFFICE_TILE :: 32
@(private = "file")
COURT_OFFICE_GAP :: 4
@(private = "file")
COURT_RANK_LABEL_EM :: 4
@(private = "file")
COURT_NAME_EM :: 13
@(private = "file")
COURT_ARMY_EM :: 8
@(private = "file")
COURT_TRAIT_EM :: 6
@(private = "file")
LABEL_EM :: 6
// Every map mode button's width
@(private = "file")
MAP_MODE_BUTTON_EM :: 5.5
@(private = "file")
FIELD_VALUE_EM :: 11
@(private = "file")
STAT_VALUE_EM :: CHARACTER_VALUE_EM
@(private = "file")
COLUMN_SLACK_EM :: 1
@(private = "file")
LIST_EM :: 8
@(private = "file")
AIMED_VALUE_EM :: 9
@(private = "file")
VALUE_EMS :: [2]f32{FIELD_VALUE_EM, STAT_VALUE_EM}
// Wide enough for an army's name
@(private = "file")
REPORT_VALUE_EM :: 12
// Wide enough for a name
@(private = "file")
CHARACTER_VALUE_EM :: 10
@(private = "file")
LINES_EM :: 26
@(private = "file")
COLUMN_GAP :: 16
@(private = "file")
LABEL_GAP :: 8
@(private = "file")
NUMBER_EM :: 3
@(private = "file")
BAR_EM :: 4
@(private = "file")
BAR_HEIGHT :: 10
@(private = "file")
FIELD_GAP :: 6
// Rows of the tallest focus card; every focus card is this tall
@(private = "file")
FOCUS_ROWS :: 7
@(private = "file")
TILE_WIDTH_EM :: 6
@(private = "file")
TILE_GAP :: 6
@(private = "file")
TILES_PER_ROW :: 4
@(private = "file")
TAB_EM :: 6
// Tooltip descriptions wrap to it
@(private = "file")
DESCRIPTION_EM :: 20
// A menu's button width, and the rows shown before it scrolls
@(private = "file")
MENU_BUTTON_EM :: 13
@(private = "file")
MENU_ROWS_MAX :: 8

Cards_View :: struct {
	map_mode: Map_Mode,
	tab:      Card_Tab,
	menu:     Maybe(Card_Menu_Id),
	court:    Court_View,
	// Asked this frame
	ai_turn:   bool,
	// Shown
	ai_report: bool,
}

@(private = "file")
Card_Theme :: struct {
	text_font:   Text_Font_Id,
	title_font:  Text_Font_Id,
	colors:      Card_Colors,
	line_height: f32,
	button:      UI_Style,
	tooltip:     UI_Style,
	// The padding keeps the fill inside the border; its focus border is the fill
	meter:       UI_Style,
	// Over the map: the court, the AI report
	window:      UI_Style,
}

@(private = "file")
Card_Colors :: struct {
	paper:        [4]f32,
	hot_paper:    [4]f32,
	active_paper: [4]f32,
	ink:          [4]f32,
	faded_ink:    [4]f32,
}

cards_ui :: proc(
	cards: ^Cards,
	text_font: Text_Font_Id,
	title_font: Text_Font_Id,
	paper: [3]f32,
	ink: [3]f32,
	seconds: f32,
	view: ^Cards_View,
	input: ^Game_Order,
) {
	opaque :: proc(rgb: [3]f32) -> [4]f32 {
		return {rgb.r, rgb.g, rgb.b, 1}
	}
	colors := Card_Colors {
		paper        = opaque(paper),
		hot_paper    = opaque(paper * HOT_PAPER_SHADE),
		active_paper = opaque(paper * ACTIVE_PAPER_SHADE),
		ink          = opaque(ink),
		faded_ink    = {ink.r, ink.g, ink.b, FADED_INK_ALPHA},
	}
	ui_style_push(
		{font = text_font, text_color = colors.ink, width = ui_text_dim(), height = ui_text_dim()},
	)
	defer ui_style_pop()
	metrics := text_font_metrics(text_font)
	theme := Card_Theme {
		text_font = text_font,
		title_font = title_font,
		colors = colors,
		line_height = metrics.ascent - metrics.descent,
		button = {
			padding = [2]f32{12, 4},
			background = colors.paper,
			hot_background = colors.hot_paper,
			active_background = colors.active_paper,
			border = colors.ink,
			focus_border = colors.ink,
			hot_text_color = colors.ink,
		},
		tooltip = {
			width = ui_fit(),
			height = ui_fit(),
			padding = [2]f32{12, 8},
			gap = 4,
			background = colors.paper,
			border = colors.ink,
			thickness = 1.5,
			radius = 3,
		},
		meter = {
			width = ui_em(BAR_EM),
			height = ui_px(BAR_HEIGHT),
			padding = [2]f32{2, 2},
			background = colors.paper,
			border = colors.ink,
			thickness = 1,
			radius = 1,
			focus_border = colors.faded_ink,
		},
		window = {
			width = ui_grow(),
			height = ui_grow(),
			padding = [2]f32{24, 18},
			gap = 10,
			background = colors.paper,
			border = colors.ink,
			thickness = 1.5,
			radius = 3,
		},
	}

	asks: bit_set[Game_Ask]
	order: Game_Order
	if ui_column({width = ui_grow(), height = ui_grow(), padding = SCREEN_MARGIN}) {
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			if cards.interaction_shown {
				asks += card_ui("interaction card", &cards.interaction, theme, {REPORT_VALUE_EM, REPORT_VALUE_EM}, view, &order)
			}
			ui_spacer(ui_grow())
			asks += card_ui("status card", &cards.status, theme, VALUE_EMS, view, &order)
		}
		ui_spacer(ui_grow())
		if cards.focus_shown {
			asks += card_ui("focus card", &cards.focus, theme, VALUE_EMS, view, &order)
		}
	}

	court := &view.court
	if court.open do court_ui(&cards.court, theme, court, &order)
	if view.ai_report do ai_report_ui(&cards.ai_report, theme, seconds, view)
	if order != nil do input^ = order
	if .Court in asks {
		court.open = !court.open
		court.selected = 0
		court.office = {}
	}
	if .AI_Turn in asks do view.ai_turn = true
	if .AI_Report in asks do view.ai_report = !view.ai_report
}

@(private = "file")
card_ui :: proc(
	label: string,
	card: ^Card,
	theme: Card_Theme,
	value_ems: [2]f32,
	view: ^Cards_View,
	order: ^Game_Order,
) -> (
	asks: bit_set[Game_Ask],
) {
	colors := theme.colors
	menu := &view.menu
	court_view := &view.court
	panel := UI_Style {
		width      = ui_fit(),
		height     = ui_fit(),
		padding    = [2]f32{16, 12},
		gap        = 6,
		background = colors.paper,
		border     = colors.ink,
		thickness  = 1.5,
		radius     = 3,
	}
	action := theme.button
	tooltip := theme.tooltip
	tile := UI_Style {
		width      = ui_em(TILE_WIDTH_EM),
		height     = ui_grow(),
		padding    = [2]f32{8, 6},
		background = colors.paper,
		border     = colors.ink,
		thickness  = 1,
		radius     = 2,
	}
	breakdown_key :: proc(index: int) -> string {
		return fmt.tprintf("breakdown %d", index)
	}
	breakdown_run :: proc(text: string, breakdown: Maybe(int)) -> UI_Text {
		index, has_breakdown := breakdown.?
		if !has_breakdown do return {text = text}
		return {text = text, key = breakdown_key(index), hot_color = HOVER_INK, underline = true}
	}
	take :: proc(
		click: Card_Click,
		asks: ^bit_set[Game_Ask],
		order: ^Game_Order,
		menu: ^Maybe(Card_Menu_Id),
		court_view: ^Court_View,
	) {
		switch clicked in click {
		case Game_Ask:
			asks^ += {clicked}
		case Game_Order:
			if order != nil do order^ = clicked
		case Card_Menu_Id:
			if menu != nil {
				open, is_open := menu^.?
				if is_open && open == clicked do menu^ = nil
				else do menu^ = clicked
			}
		case Character_Id:
			if court_view != nil {
				court_view.open = true
				court_view.selected = clicked
				court_view.reveal = true
			}
		}
	}

	if ui_panel(label, panel) {
		ui_label(card.title, {font = theme.title_font})

		// Every tab, always; those the piece lacks disabled
		if card.tabs != {} {
			if ui_row({width = ui_fit(), height = ui_fit()}) {
				for name, each in CARD_TAB_NAMES {
					style := action
					style.width = ui_em(TAB_EM)
					style.text_align = .Center
					style.disabled = each not_in card.tabs
					if each == card.tab {
						style.background = colors.active_paper
						style.hot_background = colors.active_paper
					}
					if ui_button(fmt.tprintf("%s##card tab", name), style).pressed do view.tab = each
				}
			}
		}

		for line in card.lines {
			parts := span_slice(card.parts[:], line)
			runs := make([]UI_Text, len(parts), context.temp_allocator)
			for part, i in parts do runs[i] = breakdown_run(part.text, part.breakdown)
			ui_label_text(runs, {width = ui_em(LINES_EM)})
		}

		// What opens each menu, which is drawn under it
		anchors: [CARD_MENUS_MAX]string

		// The focus card keeps one height, so switching pieces only changes its width
		body := UI_Style {
			width  = ui_fit(),
			height = ui_fit(),
			gap    = COLUMN_GAP,
		}
		line_height := theme.line_height
		if card.tabs != {} {
			// Room for a button row
			body_height := FOCUS_ROWS * line_height + (FOCUS_ROWS - 1) * FIELD_GAP + 2 * action.padding.?.y
			body.height = ui_px(body_height)
			// Tiles keep their size
			tile.height = ui_px((body_height - TILE_GAP) / 2)
		}
		if ui_row(body) {
			columns := [2][]Card_Field{card.fields[:], card.stats[:]}
			for fields, column in columns {
				if len(fields) == 0 do continue
				width := ui_em(LABEL_EM + value_ems[column] + COLUMN_SLACK_EM)
				if ui_column({width = width, height = ui_fit(), gap = FIELD_GAP}) {
					for &field, f in fields {
						// Keyed by its breakdown for hovering; a button needs a key either way
						key: string
						if index, has_breakdown := field.breakdown.?; has_breakdown do key = breakdown_key(index)
						else if field.click != nil do key = fmt.tprintf("%s field %d %d", label, column, f)
						ease_key := field.eased ? fmt.tprintf("%s field ease %d %d", label, column, f) : ""
						if field_ui(&field, theme, value_ems[column], key, ease_key).pressed do take(field.click, &asks, order, menu, court_view)
						if id, opens := field.click.(Card_Menu_Id); opens do anchors[id] = fmt.tprintf("%s###%s", field.value, key)
					}
					if column == 0 {
						for button, b in card.buttons {
							key := fmt.tprintf("%s###%s button %d", button.label, label, b)
							style := action
							style.disabled = !button.enabled
							if ui_button(key, style).pressed do take(button.click, &asks, order, menu, court_view)
							if id, opens := button.click.(Card_Menu_Id); opens do anchors[id] = key
						}
					}
				}
			}

			if .Army in card.tabs && card.tab == .Army {
				lists := [2]struct {
					title:   string,
					entries: []Card_Part,
				}{{"Status", card.statuses[:]}, {"Traits", card.traits[:]}}
				if ui_column({width = ui_em(LIST_EM), height = ui_grow(), gap = FIELD_GAP}) {
					for list in lists {
						if ui_column({width = ui_grow(), height = ui_grow(), gap = FIELD_GAP}) {
							ui_label(list.title, {text_color = colors.faded_ink})
							if len(list.entries) == 0 do ui_label("None")
							for entry in list.entries {
								style := UI_Style{height = ui_px(line_height)}
								if entry.change == .Coming do style.text_color = COMING_INK
								if entry.change == .Going do style.text_color = GOING_INK
								ui_label_text({breakdown_run(entry.text, entry.breakdown)}, style)
							}
						}
					}
				}
				if ui_column({width = ui_em(LABEL_EM + AIMED_VALUE_EM + COLUMN_SLACK_EM), height = ui_grow(), gap = FIELD_GAP}) {
					if card.aimed_title != "" do ui_label(card.aimed_title, {text_color = colors.faded_ink})
					for &field in card.aimed do field_ui(&field, theme, AIMED_VALUE_EM, "", "")
				}
			}

			// A tile keyed by its breakdown opens its tooltip on hover
			tile_ui :: proc(card_tile: ^Card_Tile, key: string, style: UI_Style, colors: Card_Colors) {
				style := style
				if card_tile.name == "" do style.border = colors.faded_ink
				if card_tile.disabled {
					style.disabled = true
					style.background = colors.active_paper
				}
				if ui_panel(key, style) {
					if card_tile.name != "" do ui_label(card_tile.name, {width = ui_grow(), text_align = .Center})
					if card_tile.project != "" {
						ui_label(card_tile.project, {width = ui_grow(), text_align = .Center, text_color = colors.faded_ink})
					}
				}
			}
			if len(card.tiles) > 0 {
				if ui_row({width = ui_fit(), height = ui_fit(), gap = TILE_GAP}) {
					grid := min(len(card.tiles), TOWN_SLOTS_MAX)
					if ui_column({width = ui_fit(), height = ui_fit(), gap = TILE_GAP}) {
						for row_start := 0; row_start < grid; row_start += TILES_PER_ROW {
							if ui_row({width = ui_fit(), height = ui_fit(), gap = TILE_GAP}) {
								for index in row_start ..< min(row_start + TILES_PER_ROW, grid) {
									card_tile := &card.tiles[index]
									// Panels are clickable, so every tile needs a key
									key := fmt.tprintf("%s tile %d", label, index)
									if breakdown, has_breakdown := card_tile.breakdown.?; has_breakdown do key = breakdown_key(breakdown)
									tile_ui(card_tile, key, tile, colors)
									if ui_signal(key).pressed do take(card_tile.click, &asks, order, menu, court_view)
									if id, opens := card_tile.click.(Card_Menu_Id); opens do anchors[id] = key
								}
							}
						}
					}
				}
			}
		}

		// The open menu, under what opened it
		open_id := -1
		if menu != nil {
			if id, is_open := menu^.?; is_open && int(id) < len(card.menus) do open_id = int(id)
		}
		if open_id >= 0 {
			open_menu := &card.menus[open_id]
			open := true
			if ui_popup("card menu", anchors[open_id], &open, tooltip) {
				ui_label(open_menu.title, {text_color = colors.faded_ink})
				// A scrolling column past MENU_ROWS_MAX
				menu_rows :: proc(
					actions: []Card_Menu_Action,
					breakdowns: []Card_Breakdown,
					button: UI_Style,
					tooltip: UI_Style,
					colors: Card_Colors,
					open: ^bool,
					order: ^Game_Order,
				) {
					for item, i in actions {
						if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
							style := button
							style.width = ui_em(MENU_BUTTON_EM)
							style.disabled = !item.enabled
							signal := ui_button(fmt.tprintf("%s##tile action %d", item.label, i), style)
							if signal.pressed {
								open^ = false
								if item.order != nil do order^ = item.order
							}
							ui_label(item.detail, {text_color = colors.faded_ink})
							if index, has_breakdown := item.breakdown.?; has_breakdown {
								if ui_tooltip(fmt.tprintf("tile action tip %d", i), signal.hovered, tooltip) {
									breakdown_ui(&breakdowns[index], colors)
								}
							}
						}
					}
				}
				if len(open_menu.actions) > MENU_ROWS_MAX {
					button_height := line_height + 2 * action.padding.?.y
					list := UI_Style {
						width      = ui_fit(),
						height     = ui_px(MENU_ROWS_MAX * button_height + (MENU_ROWS_MAX - 1) * FIELD_GAP),
						gap        = FIELD_GAP,
						background = colors.paper,
						border     = colors.faded_ink,
					}
					// The bar's track and thumb
					ui_style_push({background = colors.active_paper, border = colors.ink})
					defer ui_style_pop()
					if ui_scroll_panel("tile menu list", list) {
						menu_rows(open_menu.actions[:], card.breakdowns[:], action, tooltip, colors, &open, order)
					}
				} else {
					if ui_column({width = ui_fit(), height = ui_fit(), gap = FIELD_GAP}) {
						menu_rows(open_menu.actions[:], card.breakdowns[:], action, tooltip, colors, &open, order)
					}
				}
			}
			if !open do menu^ = nil
		}

		// No hover tooltips while a menu is open
		menu_open := open_id >= 0
		for &breakdown, index in card.breakdowns {
			key := breakdown_key(index)
			if ui_tooltip(fmt.tprintf("breakdown tip %d", index), ui_signal(key).hovered && !menu_open, tooltip) {
				breakdown_ui(&breakdown, colors)
			}
		}

		rows := 0
		for card_action in card.actions do rows = max(rows, card_action.row + 1)
		for row in 0 ..< rows {
			if ui_row({width = ui_fit(), height = ui_fit()}) {
				for card_action in card.actions {
					if card_action.row != row do continue
					style := action
					style.disabled = !card_action.enabled
					if ui_button(card_action.label, style).pressed do take(card_action.click, &asks, order, menu, court_view)
				}
			}
		}

		if card.map_modes {
			ui_label("Map Mode", {text_color = colors.faded_ink})
			for row in 0 ..< MAP_MODE_ROWS {
				if ui_row({width = ui_fit(), height = ui_fit()}) {
					for name, mode in MAP_MODE_NAMES {
						if MAP_MODE_ROW[mode] != row do continue
						style := action
						style.width = ui_em(MAP_MODE_BUTTON_EM)
						style.text_align = .Center
						if mode == view.map_mode {
							style.background = colors.active_paper
							style.hot_background = colors.active_paper
						}
						if ui_button(fmt.tprintf("%s##map mode", name), style).pressed do view.map_mode = mode
					}
				}
			}
		}
	}
	return
}

// The description under a rule of its own if anything came before
@(private = "file")
breakdown_ui :: proc(breakdown: ^Card_Breakdown, colors: Card_Colors) {
	rule := UI_Style {
		width      = ui_grow(),
		height     = ui_px(1),
		background = colors.ink,
		thickness  = 0,
	}
	if breakdown.note != "" do ui_label(breakdown.note)
	for term in breakdown.terms {
		if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
			ui_label(term.label, {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
			ui_label(term.value, {width = ui_em(STAT_VALUE_EM)})
		}
	}
	if breakdown.total != "" {
		if ui_panel("rule", rule) {}
		if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
			ui_label("Total", {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
			ui_label(breakdown.total, {width = ui_em(STAT_VALUE_EM)})
		}
	}
	if breakdown.description != "" {
		if breakdown.note != "" || len(breakdown.terms) > 0 || breakdown.total != "" {
			if ui_panel("description rule", rule) {}
		}
		ui_label(breakdown.description, {width = ui_em(DESCRIPTION_EM)})
	}
}

// A field's row: its label, if any, then its value as a bar after its number, a button, or one line of text. Keyed:
// the bar or the text hovers, and a button needs it. Ease key: an eased bar's
@(private = "file")
field_ui :: proc(field: ^Card_Field, theme: Card_Theme, value_em: f32, key: string, ease_key: string) -> (signal: UI_Signal) {
	if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
		if field.label != "" do ui_label(field.label, {width = ui_em(LABEL_EM), text_color = theme.colors.faded_ink})
		if fill, has_fill := field.fill.?; has_fill {
			// The other end: the change ahead, else the value it left easing to its fill
			change := field.change
			if ease_key != "" {
				left := ui_anim(ease_key, fill, fill)
				if _, changing := change.?; !changing do change = left
			}
			other := change.? or_else fill
			ui_label(field.value, {width = ui_em(NUMBER_EM)})
			style := theme.meter
			height: f32 = BAR_HEIGHT
			if field.fill_origin > 0 {
				// A balance: the notch stands out, the fill coloured by its side
				height += 2 * NOTCH_STAND_OUT
				style.height = ui_px(height)
				style.padding = [2]f32{2, NOTCH_STAND_OUT}
				style.gap = NOTCH_GAP
				style.focus_border = fill < field.fill_origin ? BAD_INK : GOOD_INK
			}
			if field.graded do style.focus_border = graded_ink(fill)
			centre := [2]f32{0, (theme.line_height - height) / 2}
			if ui_column({width = ui_fit(), height = ui_fit(), padding = centre}) {
				signal = ui_meter(key, fill, field.fill_origin, style, change, other < fill ? LOSS_INK : GAIN_INK)
			}
		} else if field.click != nil {
			// A character's name gets more room
			style := theme.button
			style.width = ui_em(value_em)
			if _, is_character := field.click.(Character_Id); is_character do style.width = ui_em(CHARACTER_VALUE_EM)
			style.height = ui_px(theme.line_height + 2 * theme.button.padding.?.y)
			signal = ui_button(fmt.tprintf("%s###%s", field.value, key), style)
		} else {
			run := UI_Text {
				text = field.value,
			}
			if key != "" do run = {text = field.value, key = key, hot_color = HOVER_INK, underline = true}
			// One line, cut short rather than wrapped
			signal = ui_label_text({run}, {width = ui_em(value_em), height = ui_px(theme.line_height)})
		}
	}
	return
}

// Bad to ochre below half, ochre to good above
@(private = "file")
graded_ink :: proc(t: f32) -> [4]f32 {
	t := clamp(t, 0, 1)
	return t < 0.5 ? BAD_INK + (MIDDLE_INK - BAD_INK) * (2 * t) : MIDDLE_INK + (GOOD_INK - MIDDLE_INK) * (2 * t - 1)
}

// A row per plan: its goal, its army, what became of it, its score with its terms when hovered
@(private = "file")
ai_report_ui :: proc(report: ^AI_Report, theme: Card_Theme, seconds: f32, view: ^Cards_View) {
	colors := theme.colors
	// Its order: red, not chosen; empty, not ordered yet; blinking, under way; green, done
	order_box := UI_Style {
		width     = ui_px(AI_REPORT_ORDER_SQUARE),
		height    = ui_px(AI_REPORT_ORDER_SQUARE),
		border    = colors.ink,
		thickness = 1,
		radius    = 1,
	}
	blink_on := math.mod(seconds * AI_REPORT_BLINK_HZ, 1) < 0.5
	if ui_overlay() {
		if ui_column({width = ui_grow(), height = ui_grow(), padding = COURT_MARGIN}) {
			if ui_panel("ai report", theme.window) {
				if ui_row({width = ui_grow(), height = ui_fit()}) {
					ui_label(report.title, {font = theme.title_font})
					ui_spacer(ui_grow())
					if ui_button("Close###ai report close", theme.button).pressed do view.ai_report = false
				}
				ui_label(report.decision, {text_color = colors.faded_ink})
				// The bar's track and thumb in paper and ink
				ui_style_push({background = colors.active_paper, border = colors.ink})
				list := UI_Style {
					width      = ui_grow(),
					height     = ui_grow(),
					gap        = FIELD_GAP,
					background = colors.paper,
					border     = colors.paper,
				}
				if ui_scroll_panel("ai report rows", list) {
					if len(report.rows) == 0 do ui_label("No plans yet", {text_color = colors.faded_ink})
					for &row, i in report.rows {
						text := row.chosen ? colors.ink : colors.faded_ink
						if ui_row({width = ui_grow(), height = ui_fit(), gap = COURT_GAP}) {
							ui_label(row.goal, {width = ui_em(AI_REPORT_GOAL_EM), text_color = text})
							ui_label(row.army, {width = ui_em(AI_REPORT_ARMY_EM), text_color = text})
							box := order_box
							switch row.order {
							case .Not_Chosen:
								box.background = BAD_INK
							case .Pending:
								box.background = colors.paper
							case .Under_Way:
								box.background = blink_on ? GOOD_INK : colors.paper
							case .Done:
								box.background = GOOD_INK
							}
							if ui_panel(fmt.tprintf("ai report order %d", i), box) {}
							ui_label(row.status, {width = ui_grow(), text_color = text})
							index, tipped := row.score.breakdown.?
							key := tipped ? fmt.tprintf("ai report score %d", i) : ""
							field_ui(&row.score, theme, STAT_VALUE_EM, key, "")
							if !tipped do continue
							if ui_tooltip(fmt.tprintf("ai report tip %d", i), ui_signal(key).hovered, theme.tooltip) {
								breakdown_ui(&report.breakdowns[index], colors)
							}
						}
					}
				}
				ui_style_pop()
			}
		}
	}
}

@(private = "file")
court_ui :: proc(court: ^Court, theme: Card_Theme, view: ^Court_View, order: ^Game_Order) {
	colors := theme.colors
	title_font := theme.title_font
	// Hovered this frame, highlighted next
	hovered: Character_Id
	defer view.hovered = hovered
	button := theme.button
	tooltip := theme.tooltip
	// The portrait as tall as the entry's lines
	line_height := theme.line_height
	inner_height := COURT_ENTRY_LINES * line_height + (COURT_ENTRY_LINES - 1) * FIELD_GAP
	entry := UI_Style {
		width      = ui_grow(),
		height     = ui_fit(),
		padding    = [2]f32{COURT_ENTRY_PADDING, COURT_ENTRY_PADDING},
		gap        = COURT_GAP,
		background = colors.paper,
		border     = colors.faded_ink,
		thickness  = 1,
		radius     = 2,
	}
	portrait := UI_Style {
		width      = ui_px(inner_height),
		height     = ui_px(inner_height),
		background = colors.active_paper,
		border     = colors.faded_ink,
		thickness  = 1,
		radius     = 2,
	}
	lines := UI_Style {
		width  = ui_fit(),
		height = ui_fit(),
		gap    = FIELD_GAP,
	}
	office_tile := UI_Style {
		width      = ui_px(COURT_OFFICE_TILE),
		height     = ui_px(COURT_OFFICE_TILE),
		background = colors.active_paper,
		border     = colors.ink,
		thickness  = 1,
		radius     = 2,
	}
	rank_square := UI_Style {
		width        = ui_px(COURT_RANK_SQUARE),
		height       = ui_px(COURT_RANK_SQUARE),
		background   = colors.paper,
		border       = colors.ink,
		thickness    = 1,
		radius       = 1,
		focus_border = MIDDLE_INK,
	}

	if ui_overlay() {
		if ui_column({width = ui_grow(), height = ui_grow(), padding = COURT_MARGIN}) {
			if ui_panel("court", theme.window) {
				if ui_row({width = ui_grow(), height = ui_fit()}) {
					ui_label(court.title, {font = title_font})
					ui_spacer(ui_grow())
					if ui_button("Close###court close", button).pressed {
						view.open = false
						view.selected = 0
						view.office = {}
					}
				}

				if ui_row({width = ui_grow(), height = ui_grow(), gap = COURT_GAP}) {
					// The entries scroll; the bar's track and thumb in paper and ink
					ui_style_push({background = colors.active_paper, border = colors.ink})
					list := UI_Style {
						width      = ui_grow(),
						height     = ui_grow(),
						gap        = COURT_ENTRY_GAP,
						background = colors.paper,
						border     = colors.paper,
					}
					defer view.reveal = false
					if ui_scroll_panel("court entries", list) {
						for &row, i in court.rows {
							entry_key := fmt.tprintf("court entry %d", i)
							// Lit: its border darker and thicker, eased
							selected := view.selected != 0 && row.character == view.selected
							if selected && view.reveal do ui_scroll_to(entry_key)
							// Its portrait and rank strip included
							clicked := false
							lit := ui_anim(fmt.tprintf("court entry lit %d", i), row.character == view.hovered || selected ? 1 : 0)
							entry_style := entry
							entry_style.border = colors.faded_ink + (colors.ink - colors.faded_ink) * lit
							entry_style.thickness = 1 + lit
							if ui_panel(entry_key, entry_style, .X) {
								if ui_row({width = ui_fit(), height = ui_fit(), gap = COURT_RANK_STRIP_GAP}) {
									portrait_key := fmt.tprintf("court portrait %d", i)
									if ui_panel(portrait_key, portrait) {}
									if ui_signal(portrait_key).hovered do hovered = row.character
									clicked |= ui_signal(portrait_key).pressed
									// Rank: squares up to the court's highest, filled from the bottom; hovered, the number
									rank_key := fmt.tprintf("court rank %d", i)
									squares_height := f32(court.rank_max) * COURT_RANK_SQUARE + f32(max(court.rank_max - 1, 0)) * COURT_RANK_GAP
									rank_strip := UI_Style {
										width      = ui_fit(),
										height     = ui_px(inner_height),
										padding    = [2]f32{0, (inner_height - squares_height) / 2},
										gap        = COURT_RANK_GAP,
										background = colors.paper,
										border     = colors.paper,
									}
									if ui_panel(rank_key, rank_strip) {
										for square in 0 ..< court.rank_max {
											ui_meter("", court.rank_max - square <= row.rank ? 1 : 0, 0, rank_square)
										}
									}
									if ui_signal(rank_key).hovered do hovered = row.character
									clicked |= ui_signal(rank_key).pressed
									if index, tipped := row.rank_breakdown.?; tipped {
										if ui_tooltip(fmt.tprintf("court rank tip %d", i), ui_signal(rank_key).hovered, tooltip) {
											breakdown_ui(&court.breakdowns[index], colors)
										}
									}
								}
								if ui_column(lines) {
									ui_label(row.name, {width = ui_em(COURT_NAME_EM)})
									if row.office != "" {
										ui_label(row.office, {width = ui_em(COURT_NAME_EM)})
									} else {
										ui_label("No office", {width = ui_em(COURT_NAME_EM), text_color = colors.faded_ink})
									}
									ui_label(fmt.tprintf("Age %d", row.age), {width = ui_em(COURT_NAME_EM), text_color = colors.faded_ink})
								}
								if ui_column(lines) {
									// Only those with a breakdown keyed: a keyed bar takes clicks, counted as the entry's
									for &stat, s in row.stats {
										index, tipped := stat.breakdown.?
										key := tipped ? fmt.tprintf("court stat %d %d", i, s) : ""
										field_ui(&stat, theme, STAT_VALUE_EM, key, "")
										if !tipped do continue
										clicked |= ui_signal(key).pressed
										if ui_tooltip(fmt.tprintf("court stat tip %d %d", i, s), ui_signal(key).hovered, tooltip) {
											breakdown_ui(&court.breakdowns[index], colors)
										}
									}
								}
								if ui_column({width = ui_em(COURT_ARMY_EM), height = ui_fit(), gap = FIELD_GAP}) {
									if row.army != "" {
										ui_label(row.army, {width = ui_em(COURT_ARMY_EM)})
										field_ui(&row.men, theme, STAT_VALUE_EM, "", "")
										ui_label(fmt.tprintf("at %s", row.base), {width = ui_em(COURT_ARMY_EM), text_color = colors.faded_ink})
									} else {
										ui_label("No army", {width = ui_em(COURT_ARMY_EM), text_color = colors.faded_ink})
									}
								}
								if ui_column(lines) {
									ui_label(row.temperament, {width = ui_em(COURT_TRAIT_EM)})
									ui_label(row.background, {width = ui_em(COURT_TRAIT_EM)})
									ui_label(row.disposition, {width = ui_em(COURT_TRAIT_EM)})
								}
							}
							if ui_signal(entry_key).hovered do hovered = row.character
							// Clicked: him and his office selected; again, neither
							if clicked || ui_signal(entry_key).pressed {
								view.selected = selected ? 0 : row.character
								view.office = selected ? {} : row.office_id
								view.reveal = false
							}
						}
					}
					ui_style_pop()

					// A held office shows its holder's initial, a vacant one is black
					pyramid_width: f32 = COURT_OFFICES_PER_ROW * COURT_OFFICE_TILE + (COURT_OFFICES_PER_ROW - 1) * COURT_OFFICE_GAP
					// The pyramid over two thirds, the actions under it
					if ui_column({width = ui_fit(), height = ui_grow(), gap = COURT_GAP}) {
						if ui_column({width = ui_fit(), height = ui_grow(2), gap = COURT_OFFICE_GAP * 2}) {
							for rank := court.rank_max; rank >= 0; rank -= 1 {
								ranked := make([dynamic]int, context.temp_allocator)
								for &office, o in court.offices do if office.rank == rank do append(&ranked, o)
								if len(ranked) == 0 do continue
								for line_start := 0; line_start < len(ranked); line_start += COURT_OFFICES_PER_ROW {
									line := ranked[line_start:min(line_start + COURT_OFFICES_PER_ROW, len(ranked))]
									if ui_row({width = ui_fit(), height = ui_fit(), gap = COURT_OFFICE_GAP}) {
										rank_label := line_start == 0 ? fmt.tprintf("Rank %d", rank) : ""
										ui_label(rank_label, {width = ui_em(COURT_RANK_LABEL_EM), text_color = colors.faded_ink})
										if ui_row({width = ui_px(pyramid_width), height = ui_fit(), gap = COURT_OFFICE_GAP}) {
											ui_spacer(ui_grow())
											for o in line {
												office := &court.offices[o]
												key := fmt.tprintf("court office %d", o)
												holder := office.holder
												// Lit: lighter, its border thicker
												highlighted := holder != 0 && (holder == view.hovered || holder == view.selected)
												highlighted ||= office.id == view.office
												lit := ui_anim(fmt.tprintf("court office lit %d", o), highlighted ? 1 : 0)
												style := office_tile
												style.background = colors.active_paper + (colors.hot_paper - colors.active_paper) * lit
												if holder == 0 do style.background = colors.ink
												// The vacancy being filled, in ochre
												if office.filling do style.background = MIDDLE_INK
												style.thickness = 1 + lit
												if ui_panel(key, style) {
													if holder != 0 do ui_label(office.holder_name[:1], {width = ui_grow(), text_align = .Center})
												}
												if ui_signal(key).hovered do hovered = holder
												// Clicked: it and its holder selected; again, neither
												if ui_signal(key).pressed {
													chosen := view.office != office.id
													view.office = chosen ? office.id : {}
													view.selected = chosen ? holder : 0
												}
												if index, tipped := office.breakdown.?; tipped {
													if ui_tooltip(fmt.tprintf("court office tip %d", o), ui_signal(key).hovered, tooltip) {
														breakdown_ui(&court.breakdowns[index], colors)
													}
												}
											}
											ui_spacer(ui_grow())
										}
									}
								}
							}
						}
						// Actions: the vacancy's candidates; with none, the selection's traits and Dismiss
						actions := UI_Style {
							width      = ui_grow(),
							height     = ui_grow(1),
							padding    = [2]f32{12, 8},
							gap        = FIELD_GAP,
							background = colors.paper,
							border     = colors.faded_ink,
							thickness  = 1,
							radius     = 2,
						}
						if ui_panel("court actions", actions) {
							vacancy := &court.vacancy
							chosen: ^Court_Row
							for &row in court.rows do if view.selected != 0 && row.character == view.selected do chosen = &row
							// A selected character keeps his current office selected
							if chosen != nil do view.office = chosen.office_id
							shown: ^Court_Office
							for &office in court.offices do if view.office != {} && office.id == view.office do shown = &office
							if vacancy.office == {} && chosen == nil && shown == nil {
								ui_label("No vacancies", {width = ui_grow(), text_color = colors.faded_ink})
								ui_label("Click a character or an office", {width = ui_grow(), text_color = colors.faded_ink})
							} else if vacancy.office == {} {
								if chosen != nil do ui_label(chosen.name, {width = ui_grow()})
								if shown != nil {
									ui_label(shown.title, {width = ui_grow(), text_color = chosen != nil ? colors.faded_ink : colors.ink})
									if chosen == nil do ui_label("Vacant", {width = ui_grow(), text_color = colors.faded_ink})
									if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
										ui_label("Traits", {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
										ui_label(shown.traits != "" ? shown.traits : "None")
									}
								} else {
									ui_label("No office", {width = ui_grow(), text_color = colors.faded_ink})
								}
								if chosen != nil && shown != nil {
									style := button
									style.width = ui_grow()
									dismiss, can_dismiss := chosen.dismiss.?
									style.disabled = !can_dismiss
									signal := ui_button("Dismiss###court dismiss", style)
									if signal.pressed && can_dismiss do order^ = dismiss
									if index, tipped := chosen.dismiss_breakdown.?; tipped {
										if ui_tooltip("court dismiss tip", signal.hovered, tooltip) do breakdown_ui(&court.breakdowns[index], colors)
									}
									if !can_dismiss {
										ui_label(chosen.undismissable, {width = ui_grow(), text_color = colors.faded_ink})
									}
								}
							} else {
								ui_label(fmt.tprintf("Appoint: %s", vacancy.title), {width = ui_grow()})
								about := fmt.tprintf("Rank %d", vacancy.rank)
								if vacancy.army != "" do about = fmt.tprintf("Rank %d, commands %s", vacancy.rank, vacancy.army)
								ui_label(about, {width = ui_grow(), text_color = colors.faded_ink})
								for candidate, c in vacancy.candidates {
									style := button
									style.width = ui_grow()
									style.disabled = !vacancy.can_appoint
									signal := ui_button(fmt.tprintf("%s###court candidate %d", candidate.name, c), style)
									if signal.hovered do hovered = candidate.character
									if signal.pressed do order^ = candidate.order
									if index, tipped := candidate.breakdown.?; tipped {
										if ui_tooltip(fmt.tprintf("court candidate tip %d", c), signal.hovered, tooltip) {
											breakdown_ui(&court.breakdowns[index], colors)
										}
									}
								}
							}
						}
					}
				}
			}
		}
	}
}
