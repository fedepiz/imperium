package main

import "core:fmt"

@(private = "file")
HOT_PAPER_SHADE :: 0.9
@(private = "file")
ACTIVE_PAPER_SHADE :: 0.8
@(private = "file")
FADED_INK_ALPHA :: 0.6
@(private = "file")
HOVER_INK :: [4]f32{0.62, 0.24, 0.16, 1}
// Good and bad, as fills: the Germanic wash and the Roman roofs
@(private = "file")
GOOD_INK :: [4]f32{0.47, 0.58, 0.47, 1}
@(private = "file")
BAD_INK :: [4]f32{0.70, 0.40, 0.29, 1}
// Halfway between them on a graded bar: a yellow ochre
@(private = "file")
MIDDLE_INK :: [4]f32{0.76, 0.62, 0.32, 1}
// A balance bar's notch stands out of its halves by this much above and below, and apart from them by the gap
@(private = "file")
NOTCH_STAND_OUT :: 3
@(private = "file")
NOTCH_GAP :: 2

@(private = "file")
SCREEN_MARGIN :: [2]f32{20, 20}
@(private = "file")
LABEL_EM :: 6
@(private = "file")
FIELD_VALUE_EM :: 7
@(private = "file")
STAT_VALUE_EM :: 7
@(private = "file")
LINES_EM :: 26
@(private = "file")
COLUMN_GAP :: 16
// Between a label and its value
@(private = "file")
LABEL_GAP :: 8
// A value with a bar: the number, then the bar
@(private = "file")
NUMBER_EM :: 3
@(private = "file")
BAR_EM :: 4
@(private = "file")
BAR_HEIGHT :: 10
@(private = "file")
FIELD_GAP :: 6
// Rows of the tallest focus card, a field army's stats; every focus card is this tall
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
	map_mode: ^Map_Mode,
	tab: ^Card_Tab,
	input: ^Game_Input,
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

	asks: bit_set[Game_Ask]
	if ui_column({width = ui_grow(), height = ui_grow(), padding = SCREEN_MARGIN}) {
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			ui_spacer(ui_grow())
			asks += card_ui("status card", &cards.status, text_font, title_font, colors, map_mode, nil)
		}
		ui_spacer(ui_grow())
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			if interaction, shown := &cards.interaction.?; shown {
				asks += card_ui("interaction card", interaction, text_font, title_font, colors, nil, nil)
			}
			ui_spacer(ui_grow())
		}
		ui_spacer(ui_grow())
		if focus, shown := &cards.focus.?; shown {
			asks += card_ui("focus card", focus, text_font, title_font, colors, nil, tab)
		}
	}

	if .End_Turn in asks do input.end_turn = true
	if .Next in asks do input.answer = .Next
}

@(private = "file")
card_ui :: proc(
	label: string,
	card: ^Card,
	text_font: Text_Font_Id,
	title_font: Text_Font_Id,
	colors: Card_Colors,
	map_mode: ^Map_Mode,
	tab: ^Card_Tab,
) -> (
	asks: bit_set[Game_Ask],
) {
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
	action := UI_Style {
		padding           = [2]f32{12, 4},
		background        = colors.paper,
		hot_background    = colors.hot_paper,
		active_background = colors.active_paper,
		border            = colors.ink,
		focus_border      = colors.ink,
		hot_text_color    = colors.ink,
	}
	tooltip := UI_Style {
		width      = ui_fit(),
		height     = ui_fit(),
		padding    = [2]f32{12, 8},
		gap        = 4,
		background = colors.paper,
		border     = colors.ink,
		thickness  = 1.5,
		radius     = 3,
	}
	// Framed: the padding keeps the fill inside the border, even when full
	meter := UI_Style {
		width        = ui_em(BAR_EM),
		height       = ui_px(BAR_HEIGHT),
		padding      = [2]f32{2, 2},
		background   = colors.paper,
		border       = colors.ink,
		thickness    = 1,
		radius       = 1,
		// The fill
		focus_border = colors.faded_ink,
	}
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

	if ui_panel(label, panel) {
		ui_label(card.title, {font = title_font})

		// Every tab, always; those the piece lacks disabled
		if tab != nil {
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
					if ui_button(fmt.tprintf("%s##card tab", name), style).pressed do tab^ = each
				}
			}
		}

		for line in card.lines {
			parts := span_slice(card.parts[:], line)
			runs := make([]UI_Text, len(parts), context.temp_allocator)
			for part, i in parts do runs[i] = breakdown_run(part.text, part.breakdown)
			ui_label_text(runs, {width = ui_em(LINES_EM)})
		}

		// Fields, stats and tiles side by side. The focus card's body keeps one height, so switching pieces or
		// tabs only changes its width
		body := UI_Style {
			width  = ui_fit(),
			height = ui_fit(),
			gap    = COLUMN_GAP,
		}
		metrics := text_font_metrics(text_font)
		line_height := metrics.ascent - metrics.descent
		if tab != nil do body.height = ui_px(FOCUS_ROWS * line_height + (FOCUS_ROWS - 1) * FIELD_GAP)
		if ui_row(body) {
			columns := [2][]Card_Field{card.fields[:], card.stats[:]}
			value_widths := [2]f32{FIELD_VALUE_EM, STAT_VALUE_EM}
			for fields, column in columns {
				if len(fields) == 0 do continue
				if ui_column({width = ui_fit(), height = ui_fit(), gap = FIELD_GAP}) {
					for field in fields {
						if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
							ui_label(field.label, {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
							if fill, has_fill := field.fill.?; has_fill {
								// The number, then the bar, centred on the line; the bar opens the breakdown's tooltip
								ui_label(field.value, {width = ui_em(NUMBER_EM)})
								key: string
								if index, has_breakdown := field.breakdown.?; has_breakdown do key = breakdown_key(index)
								style := meter
								height: f32 = BAR_HEIGHT
								if field.fill_origin > 0 {
									// A balance: its notch cuts through and stands out, its fill colored by the side
									height += 2 * NOTCH_STAND_OUT
									style.height = ui_px(height)
									style.padding = [2]f32{2, NOTCH_STAND_OUT}
									style.gap = NOTCH_GAP
									style.focus_border = fill < field.fill_origin ? BAD_INK : GOOD_INK
								}
								if field.graded {
									// Bad to ochre over the lower half, ochre to good over the upper
									t := clamp(fill, 0, 1)
									style.focus_border =
										t < 0.5 ? BAD_INK + (MIDDLE_INK - BAD_INK) * (2 * t) : MIDDLE_INK + (GOOD_INK - MIDDLE_INK) * (2 * t - 1)
								}
								centre := [2]f32{0, (line_height - height) / 2}
								if ui_column({width = ui_fit(), height = ui_fit(), padding = centre}) {
									ui_meter(key, fill, field.fill_origin, style)
								}
							} else {
								value := breakdown_run(field.value, field.breakdown)
								ui_label_text({value}, {width = ui_em(value_widths[column])})
							}
						}
					}
				}
			}

			// Tiles in rows sharing the body's height; one with a breakdown is keyed by it, so hovering it
			// opens the breakdown's tooltip
			if len(card.tiles) > 0 {
				if ui_column({width = ui_fit(), height = ui_grow(), gap = TILE_GAP}) {
					for row_start := 0; row_start < len(card.tiles); row_start += TILES_PER_ROW {
						if ui_row({width = ui_fit(), height = ui_grow(), gap = TILE_GAP}) {
							for card_tile, offset in card.tiles[row_start:min(row_start + TILES_PER_ROW, len(card.tiles))] {
								// Panels are clickable, so every tile needs a key
								key := fmt.tprintf("%s tile %d", label, row_start + offset)
								if index, has_breakdown := card_tile.breakdown.?; has_breakdown {
									key = breakdown_key(index)
								}
								style := tile
								if card_tile.name == "" do style.border = colors.faded_ink
								if ui_panel(key, style) {
									if card_tile.name != "" do ui_label(card_tile.name, {width = ui_grow(), text_align = .Center})
								}
							}
						}
					}
				}
			}
		}

		for &breakdown, index in card.breakdowns {
			key := breakdown_key(index)
			if ui_tooltip(fmt.tprintf("breakdown tip %d", index), ui_signal(key).hovered, tooltip) {
				if breakdown.note != "" do ui_label(breakdown.note)
				for term in breakdown.terms {
					if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
						ui_label(term.label, {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
						ui_label(term.value, {width = ui_em(STAT_VALUE_EM)})
					}
				}
				if breakdown.total != "" {
					rule := UI_Style {
						width      = ui_grow(),
						height     = ui_px(1),
						background = colors.ink,
						thickness  = 0,
					}
					if ui_panel("rule", rule) {}
					if ui_row({width = ui_fit(), height = ui_fit(), gap = LABEL_GAP}) {
						ui_label("Total", {width = ui_em(LABEL_EM), text_color = colors.faded_ink})
						ui_label(breakdown.total, {width = ui_em(STAT_VALUE_EM)})
					}
				}
			}
		}

		for card_action in card.actions {
			style := action
			style.disabled = !card_action.enabled
			if ui_button(card_action.label, style).pressed do asks += {card_action.ask}
		}

		if map_mode != nil {
			ui_label("Map Mode", {text_color = colors.faded_ink})
			if ui_row({width = ui_fit(), height = ui_fit()}) {
				for name, mode in MAP_MODE_NAMES {
					style := action
					if mode == map_mode^ {
						style.background = colors.active_paper
						style.hot_background = colors.active_paper
					}
					if ui_button(fmt.tprintf("%s##map mode", name), style).pressed do map_mode^ = mode
				}
			}
		}
	}
	return
}
