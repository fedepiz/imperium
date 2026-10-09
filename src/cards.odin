package main

import "core:fmt"

@(private = "file")
PAPER :: [4]f32{0.840, 0.772, 0.620, 1}
@(private = "file")
HOT_PAPER :: [4]f32{0.760, 0.690, 0.545, 1}
@(private = "file")
ACTIVE_PAPER :: [4]f32{0.680, 0.610, 0.475, 1}
@(private = "file")
INK :: [4]f32{0.150, 0.105, 0.070, 1}
@(private = "file")
FADED_INK :: [4]f32{INK.r, INK.g, INK.b, 0.6}

@(private = "file")
SCREEN_MARGIN :: [2]f32{20, 20}
@(private = "file")
LABEL_EM :: 7
@(private = "file")
FIELD_VALUE_EM :: 9
@(private = "file")
STAT_VALUE_EM :: 8
@(private = "file")
LINES_EM :: 26
@(private = "file")
COLUMN_GAP :: 24

cards_ui :: proc(
	cards: ^Cards,
	text_font: Text_Font_Id,
	title_font: Text_Font_Id,
	map_mode: ^Map_Mode,
) -> (
	asks: bit_set[Game_Ask],
) {
	ui_style_push(
		{font = text_font, text_color = INK, width = ui_text_dim(), height = ui_text_dim()},
	)
	defer ui_style_pop()

	if ui_column({width = ui_grow(), height = ui_grow(), padding = SCREEN_MARGIN}) {
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			ui_spacer(ui_grow())
			asks += card_ui("status card", &cards.status, title_font, map_mode)
		}
		ui_spacer(ui_grow())
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			if battle, shown := &cards.battle.?; shown {
				asks += card_ui("battle card", battle, title_font, nil)
			}
			ui_spacer(ui_grow())
			if interaction, shown := &cards.interaction.?; shown {
				asks += card_ui("interaction card", interaction, title_font, nil)
			}
			ui_spacer(ui_grow())
		}
		ui_spacer(ui_grow())
		if focus, shown := &cards.focus.?; shown {
			asks += card_ui("focus card", focus, title_font, nil)
		}
	}
	return
}

@(private = "file")
card_ui :: proc(
	label: string,
	card: ^Card,
	title_font: Text_Font_Id,
	map_mode: ^Map_Mode,
) -> (
	asks: bit_set[Game_Ask],
) {
	panel := UI_Style {
		width      = ui_fit(),
		height     = ui_fit(),
		padding    = [2]f32{16, 12},
		gap        = 6,
		background = PAPER,
		border     = INK,
		thickness  = 1.5,
		radius     = 3,
	}
	action := UI_Style {
		padding           = [2]f32{12, 4},
		background        = PAPER,
		hot_background    = HOT_PAPER,
		active_background = ACTIVE_PAPER,
		border            = INK,
		focus_border      = INK,
		hot_text_color    = INK,
	}

	if ui_panel(label, panel) {
		ui_label(card.title, {font = title_font})
		for line in card.lines do ui_label(line, {width = ui_em(LINES_EM)})

		if ui_row({width = ui_fit(), height = ui_fit(), gap = COLUMN_GAP}) {
			columns := [2][]Card_Field{card.fields[:], card.stats[:]}
			value_widths := [2]f32{FIELD_VALUE_EM, STAT_VALUE_EM}
			for fields, column in columns {
				if len(fields) == 0 do continue
				if ui_column({width = ui_fit(), height = ui_fit(), gap = 6}) {
					for field in fields {
						if ui_row({width = ui_fit(), height = ui_fit(), gap = 12}) {
							ui_label(field.label, {width = ui_em(LABEL_EM), text_color = FADED_INK})
							ui_label(field.value, {width = ui_em(value_widths[column])})
						}
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
			ui_label("Map Mode", {text_color = FADED_INK})
			if ui_row({width = ui_fit(), height = ui_fit()}) {
				for name, mode in MAP_MODE_NAMES {
					style := action
					if mode == map_mode^ {
						style.background = ACTIVE_PAPER
						style.hot_background = ACTIVE_PAPER
					}
					if ui_button(fmt.tprintf("%s##map mode", name), style).pressed do map_mode^ = mode
				}
			}
		}
	}
	return
}
