package main

import "core:fmt"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

@(private = "file")
MIDNIGHT_PANEL :: [4]f32{0.105, 0.125, 0.165, 1}
@(private = "file")
MIDNIGHT_MUTED :: [4]f32{0.55, 0.61, 0.7, 1}
@(private = "file")
MIDNIGHT_PRIMARY :: [4]f32{0.23, 0.39, 0.61, 1}

@(private = "file")
PANEL_WIDTH :: 520
@(private = "file")
PANEL_TOP :: 80
@(private = "file")
LIST_HEIGHT :: 360
@(private = "file")
WIDGET_WIDTH :: 200
@(private = "file")
WIDGET_PADDING :: [2]f32{10, 0}
@(private = "file")
ROWS_MAX :: 200

@(private = "file")
TWEAK_UI: struct {
	open:        bool,
	filter:      [64]u8,
	filter_len:  int,
	selected:    Tweak_Id,
	choice_open: Tweak_Id,
}

tweak_ui :: proc(toggled: bool, font: Text_Font_Id) {
	opening := toggled && !TWEAK_UI.open
	if toggled do TWEAK_UI.open = !TWEAK_UI.open
	if ui_key_pressed(.ESCAPE) do TWEAK_UI.open = false
	if !TWEAK_UI.open do return

	filter := string(TWEAK_UI.filter[:TWEAK_UI.filter_len])
	rows: [dynamic; ROWS_MAX]Tweak_Shown
	for shown in tweak_shown() {
		if subsequence_matches(shown.name, filter) do append(&rows, shown)
	}
	slice.sort_by(rows[:], proc(a, b: Tweak_Shown) -> bool {return a.name < b.name})

	selectable: [dynamic; ROWS_MAX]int
	selected_at := 0
	for row, index in rows {
		if row.kind == .Label do continue
		if row.id == TWEAK_UI.selected do selected_at = len(selectable)
		append(&selectable, index)
	}

	TWEAK_UI.selected = 0
	if len(selectable) > 0 {
		if ui_key_pressed(.DOWN) do selected_at = min(selected_at + 1, len(selectable) - 1)
		if ui_key_pressed(.UP) do selected_at = max(selected_at - 1, 0)
		selected := rows[selectable[selected_at]]
		TWEAK_UI.selected = selected.id
		if ui_key_pressed(.RETURN) || ui_key_pressed(.KP_ENTER) {
			tweak := tweak_get(selected.id)
			#partial switch selected.kind {
			case .Button:
				tweak_fire(selected.id)
			case .Toggle:
				tweak_set_flag(selected.id, !tweak.flag)
			case .Choice:
				tweak_set_selection(selected.id, (tweak.selection + 1) % len(selected.choices))
			}
		}
	}

	panel := UI_Style {
		width      = ui_px(PANEL_WIDTH),
		height     = ui_fit(),
		padding    = [2]f32{16, 14},
		gap        = 8,
		background = MIDNIGHT_PANEL,
	}
	tooltip := UI_Style {
		width      = ui_fit(),
		height     = ui_fit(),
		padding    = [2]f32{16, 14},
		background = MIDNIGHT_PANEL,
	}

	ui_style_push({font = font, height = ui_px(1.5 * text_font_metrics(font).size)})
	defer ui_style_pop()

	if ui_overlay() {
		if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{0, PANEL_TOP}}) {
			if ui_row({width = ui_grow(), height = ui_fit()}) {
				ui_spacer(ui_grow())
				if ui_panel("tweaks", panel) {
					if opening || !ui_focused_any() do ui_focus("filter")
					ui_input(
						"filter",
						TWEAK_UI.filter[:],
						&TWEAK_UI.filter_len,
						{width = ui_grow(), padding = WIDGET_PADDING},
					)

					list := UI_Style {
						width   = ui_grow(),
						height  = ui_px(LIST_HEIGHT),
						padding = [2]f32{6, 6},
						gap     = 2,
					}
					if ui_scroll_panel("tweak rows", list) {
						for row in rows {
							row_style := UI_Style {
								width      = ui_grow(),
								height     = ui_fit(),
								padding    = [2]f32{8, 4},
								gap        = 8,
								background = row.id == TWEAK_UI.selected ? MIDNIGHT_PRIMARY : [4]f32{},
								thickness  = 0,
							}
							if ui_panel(row.label, row_style, .X) {
								ui_label_text({{text = row.name, key = "name"}}, {width = ui_grow()})
								if ui_tooltip("full name", ui_signal("name").hovered, tooltip) {
									ui_label(row.name, {width = ui_text_dim()})
								}

								if ui_row({width = ui_px(WIDGET_WIDTH), height = ui_fit(), gap = 8}) {
									tweak := tweak_get(row.id)
									widget := UI_Style {
										width   = ui_grow(),
										padding = WIDGET_PADDING,
									}
									switch row.kind {
									case .Label:
										ui_label(row.text, {width = ui_grow(), text_color = MIDNIGHT_MUTED})
									case .Button:
										button := fmt.tprintf("%s###button", row.text)
										if ui_button(button, widget).pressed do tweak_fire(row.id)
									case .Toggle:
										flag := tweak.flag
										ui_checkbox(fmt.tprintf("%s###toggle", row.text), &flag, widget)
										if flag != tweak.flag do tweak_set_flag(row.id, flag)
									case .Slider:
										value := tweak.value
										ui_slider("slider", &value, row.lo, row.hi, {width = ui_grow()})
										ui_label(fmt.tprintf("%.2f", value), {width = ui_em(3)})
										if value != tweak.value do tweak_set_value(row.id, value)
									case .Choice:
										selection := tweak.selection
										open := TWEAK_UI.choice_open == row.id
										ui_combo("choice", &selection, &open, row.choices, widget)
										if open {
											TWEAK_UI.choice_open = row.id
										} else if TWEAK_UI.choice_open == row.id {
											TWEAK_UI.choice_open = 0
										}
										if selection != tweak.selection {
											tweak_set_selection(row.id, selection)
										}
									}
								}
							}
						}
					}
				}
				ui_spacer(ui_grow())
			}
		}
	}
}

@(private = "file")
subsequence_matches :: proc(text, filter: string) -> bool {
	rest := filter
	for char in text {
		if len(rest) == 0 do break
		wanted, size := utf8.decode_rune_in_string(rest)
		if unicode.to_lower(char) == unicode.to_lower(wanted) do rest = rest[size:]
	}
	return len(rest) == 0
}
