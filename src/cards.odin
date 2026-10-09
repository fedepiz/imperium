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
HOVER_INK :: [4]f32{0.62, 0.24, 0.16, 1}

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
	input: ^Game_Input,
) {
	ui_style_push(
		{font = text_font, text_color = INK, width = ui_text_dim(), height = ui_text_dim()},
	)
	defer ui_style_pop()

	asks: bit_set[Game_Ask]
	if ui_column({width = ui_grow(), height = ui_grow(), padding = SCREEN_MARGIN}) {
		if ui_row({width = ui_grow(), height = ui_fit()}) {
			ui_spacer(ui_grow())
			asks += card_ui("status card", &cards.status, title_font, map_mode)
		}
		ui_spacer(ui_grow())
		if ui_row({width = ui_grow(), height = ui_fit()}) {
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

	if .End_Turn in asks do input.end_turn = true
	if .Next in asks do input.answer = .Next
	if .Conquer in asks do input.answer = .Conquer
	if .Leave in asks do input.answer = .Leave
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
	tooltip := UI_Style {
		width      = ui_fit(),
		height     = ui_fit(),
		padding    = [2]f32{12, 8},
		gap        = 4,
		background = PAPER,
		border     = INK,
		thickness  = 1.5,
		radius     = 3,
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

		for line in card.lines {
			parts := span_slice(card.parts[:], line)
			runs := make([]UI_Text, len(parts), context.temp_allocator)
			for part, i in parts do runs[i] = breakdown_run(part.text, part.breakdown)
			ui_label_text(runs, {width = ui_em(LINES_EM)})
		}

		if ui_row({width = ui_fit(), height = ui_fit(), gap = COLUMN_GAP}) {
			columns := [2][]Card_Field{card.fields[:], card.stats[:]}
			value_widths := [2]f32{FIELD_VALUE_EM, STAT_VALUE_EM}
			for fields, column in columns {
				if len(fields) == 0 do continue
				if ui_column({width = ui_fit(), height = ui_fit(), gap = 6}) {
					for field in fields {
						if ui_row({width = ui_fit(), height = ui_fit(), gap = 12}) {
							ui_label(field.label, {width = ui_em(LABEL_EM), text_color = FADED_INK})
							value := breakdown_run(field.value, field.breakdown)
							ui_label_text({value}, {width = ui_em(value_widths[column])})
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
					if ui_row({width = ui_fit(), height = ui_fit(), gap = 12}) {
						ui_label(term.label, {width = ui_em(LABEL_EM), text_color = FADED_INK})
						ui_label(term.value, {width = ui_em(STAT_VALUE_EM)})
					}
				}
				if breakdown.total != "" {
					rule := UI_Style {
						width      = ui_grow(),
						height     = ui_px(1),
						background = INK,
						thickness  = 0,
					}
					if ui_panel("rule", rule) {}
					if ui_row({width = ui_fit(), height = ui_fit(), gap = 12}) {
						ui_label("Total", {width = ui_em(LABEL_EM), text_color = FADED_INK})
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
