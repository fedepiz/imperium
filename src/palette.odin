package main

import "core:fmt"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"
import "gfx"
import "tweak"

// A list of this frame's tweaks floating over everything while tweak is open, filtered by what is typed on top.
Palette :: struct {
	filter:      [64]u8,
	filter_len:  int,
	// The row Up, Down and Enter act on
	selected:    tweak.Id,
	// The choice whose list is open
	choice_open: tweak.Id,
}

PALETTE_WIDTH :: 520
PALETTE_LIST_HEIGHT :: 360
// The column the widgets sit in, right of the names
PALETTE_WIDGET_WIDTH :: 200
// Space around the text in the widgets, which sets where it starts
PALETTE_WIDGET_PADDING :: [2]f32{10, 0}
// Most rows shown at once
PALETTE_ROWS_MAX :: 200
// Space between the top of the window and the palette
PALETTE_TOP :: 80

palette_build :: proc(p: ^Palette, input: Input) {
	// Space opens and closes it unless the ui takes the keys, and Escape in the filter closes it.
	open := tweak.is_open()
	opening := false
	if key_is_pressed(input, .SPACE) && !ui_keyboard_captured() {
		open = !open
		opening = open
	}
	if ui_key_pressed(.ESCAPE) {
		open = false
	}
	tweak.set_open(open)
	if !open {return}

	// The rows: the tweaks matching the filter, the first ones declared up to the cap, by label
	filter := string(p.filter[:p.filter_len])
	rows: [dynamic; PALETTE_ROWS_MAX]tweak.Shown
	for s in tweak.shown() {
		if len(rows) == PALETTE_ROWS_MAX {break}
		if palette_matches(tweak.display(tweak.shown_label(s)), filter) {
			append(&rows, s)
		}
	}
	slice.sort_by(rows[:], proc(a, b: tweak.Shown) -> bool {
		return tweak.display(tweak.shown_label(a)) < tweak.display(tweak.shown_label(b))
	})

	// The rows Up, Down and Enter move through, labels aside
	selectable: [dynamic; PALETTE_ROWS_MAX]int
	at := 0
	for s, i in rows {
		if s.kind == .Label {continue}
		if s.id == p.selected {
			at = len(selectable)
		}
		append(&selectable, i)
	}
	p.selected = 0
	if len(selectable) > 0 {
		if ui_key_pressed(.DOWN) {
			at = min(at + 1, len(selectable) - 1)
		}
		if ui_key_pressed(.UP) {
			at = max(at - 1, 0)
		}
		s := rows[selectable[at]]
		p.selected = s.id
		if ui_key_pressed(.RETURN) || ui_key_pressed(.KP_ENTER) {
			palette_activate(s)
		}
	}

	// Everything in the palette is in the small font, one and a half lines of it tall.
	small := gfx.Font_Id(Font_Name.Small)
	ui_style_push({font = small, height = ui_px(1.5 * gfx.font_size(small))})
	defer ui_style_pop()

	if ui_overlay() {
		if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{0, PALETTE_TOP}}) {
			if ui_row({width = ui_grow(), height = ui_fit()}) {
				ui_spacer(ui_grow())
				ui_style_next(MIDNIGHT_PANEL_STYLE)
				if ui_panel("tweak palette", {width = ui_px(PALETTE_WIDTH)}) {
					// The filter keeps the keyboard while the palette is open.
					if opening || !ui_focused_any() {
						ui_focus("filter")
					}
					ui_input(
						"filter",
						p.filter[:],
						&p.filter_len,
						{width = ui_grow(), padding = PALETTE_WIDGET_PADDING},
					)
					ui_style_next(
						{
							width = ui_grow(),
							height = ui_px(PALETTE_LIST_HEIGHT),
							padding = [2]f32{6, 6},
							gap = 2,
						},
					)
					if ui_scroll_panel("tweaks") {
						for s in rows {
							palette_row(p, s)
						}
					}
				}
				ui_spacer(ui_grow())
			}
		}
	}
}

// What Enter does to a row: fires a button, flips a toggle, steps a choice.
palette_activate :: proc(s: tweak.Shown) {
	t := tweak.get(s.id)
	#partial switch s.kind {
	case .Button:
		tweak.fire(s.id)
	case .Toggle:
		tweak.set_flag(s.id, !t.flag)
	case .Choice:
		if s.choices.len > 0 {
			tweak.set_selection(s.id, (t.selection + 1) % s.choices.len)
		}
	}
}

// A tweak's name on the left, and on the right its widget, on a background while selected.
palette_row :: proc(p: ^Palette, s: tweak.Shown) {
	label := tweak.shown_label(s)
	name := tweak.display(label)
	text := tweak.shown_text(s)
	background := MIDNIGHT_PRIMARY if s.id == p.selected else [4]f32{}
	ui_style_next(
		{
			width = ui_grow(),
			height = ui_fit(),
			padding = [2]f32{8, 4},
			gap = 8,
			background = background,
			thickness = 0,
		},
	)
	if ui_panel(label, {}, .X) {
		// The name may be cut short, so hovering it shows all of it.
		ui_label_text({{text = name, key = "name"}}, {width = ui_grow()})
		if ui_signal("name").hovered {
			if ui_tooltip(MIDNIGHT_PANEL_STYLE) {
				ui_label(name, {width = ui_text_dim()})
			}
		}
		if ui_row({width = ui_px(PALETTE_WIDGET_WIDTH), height = ui_fit(), gap = 8}) {
			palette_widget(p, s, text)
		}
	}
}

// The widget showing a tweak's text and changing its copy.
palette_widget :: proc(p: ^Palette, s: tweak.Shown, text: string) {
	t := tweak.get(s.id)
	switch s.kind {
	case .Label:
		ui_label(text, {width = ui_grow(), text_color = MIDNIGHT_MUTED})
	case .Button:
		if ui_button(fmt.tprintf("%s###button", text), {width = ui_grow(), padding = PALETTE_WIDGET_PADDING}).pressed {
			tweak.fire(s.id)
		}
	case .Toggle:
		flag := t.flag
		ui_checkbox(
			fmt.tprintf("%s###toggle", text),
			&flag,
			{width = ui_grow(), padding = PALETTE_WIDGET_PADDING},
		)
		if flag != t.flag {
			tweak.set_flag(s.id, flag)
		}
	case .Slider:
		value := t.value
		ui_slider("slider", &value, s.lo, s.hi, {width = ui_grow()})
		ui_label(fmt.tprintf("%.2f", value), {width = ui_em(3)})
		if value != t.value {
			tweak.set_value(s.id, value)
		}
	case .Choice:
		choices := make([]string, s.choices.len, context.temp_allocator)
		for &choice, i in choices {
			choice = tweak.shown_choice(s, i)
		}
		selection := t.selection
		open := p.choice_open == s.id
		ui_combo(
			"choice",
			&selection,
			&open,
			choices,
			{width = ui_grow(), padding = PALETTE_WIDGET_PADDING},
		)
		if open {
			p.choice_open = s.id
		} else if p.choice_open == s.id {
			p.choice_open = 0
		}
		if selection != t.selection {
			tweak.set_selection(s.id, selection)
		}
	}
}

// Every rune of filter appears in text in order, whatever the case.
palette_matches :: proc(text, filter: string) -> bool {
	rest := filter
	for ch in text {
		if len(rest) == 0 {break}
		want, n := utf8.decode_rune_in_string(rest)
		if unicode.to_lower(ch) == unicode.to_lower(want) {
			rest = rest[n:]
		}
	}
	return len(rest) == 0
}

