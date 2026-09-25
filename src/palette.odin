package main

import "core:fmt"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"
import "gfx"
import "tweak"
import "ui"

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
	if key_is_pressed(input, .SPACE) && !ui.keyboard_captured() {
		open = !open
		opening = open
	}
	if ui.key_pressed(.ESCAPE) {
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
		if ui.key_pressed(.DOWN) {
			at = min(at + 1, len(selectable) - 1)
		}
		if ui.key_pressed(.UP) {
			at = max(at - 1, 0)
		}
		s := rows[selectable[at]]
		p.selected = s.id
		if ui.key_pressed(.RETURN) || ui.key_pressed(.KP_ENTER) {
			palette_activate(s)
		}
	}

	// Everything in the palette is in the small font, one and a half lines of it tall.
	small := GLOBAL.fonts[.Small]
	ui.style_push({font = small, height = ui.px(1.5 * gfx.font_size(small))})
	defer ui.style_pop()

	if ui.overlay() {
		if ui.column({width = ui.grow(), height = ui.grow(), padding = [2]f32{0, PALETTE_TOP}}) {
			if ui.row({width = ui.grow(), height = ui.fit()}) {
				ui.spacer(ui.grow())
				ui.style_next(MIDNIGHT_PANEL_STYLE)
				if ui.panel("tweak palette", {width = ui.px(PALETTE_WIDTH)}) {
					// The filter keeps the keyboard while the palette is open.
					if opening || !ui.focused_any() {
						ui.focus("filter")
					}
					ui.input(
						"filter",
						p.filter[:],
						&p.filter_len,
						{width = ui.grow(), padding = PALETTE_WIDGET_PADDING},
					)
					ui.style_next(
						{
							width = ui.grow(),
							height = ui.px(PALETTE_LIST_HEIGHT),
							padding = [2]f32{6, 6},
							gap = 2,
						},
					)
					if ui.scroll_panel("tweaks") {
						for s in rows {
							palette_row(p, s)
						}
					}
				}
				ui.spacer(ui.grow())
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
	ui.style_next(
		{
			width = ui.grow(),
			height = ui.fit(),
			padding = [2]f32{8, 4},
			gap = 8,
			background = background,
			thickness = 0,
		},
	)
	if ui.panel(label, {}, .X) {
		// The name may be cut short, so hovering it shows all of it.
		ui.label_text({{text = name, key = "name"}}, {width = ui.grow()})
		if ui.signal("name").hovered {
			if ui.tooltip(MIDNIGHT_PANEL_STYLE) {
				ui.label(name, {width = ui.text_dim()})
			}
		}
		if ui.row({width = ui.px(PALETTE_WIDGET_WIDTH), height = ui.fit(), gap = 8}) {
			palette_widget(p, s, text)
		}
	}
}

// The widget showing a tweak's text and changing its copy.
palette_widget :: proc(p: ^Palette, s: tweak.Shown, text: string) {
	t := tweak.get(s.id)
	switch s.kind {
	case .Label:
		ui.label(text, {width = ui.grow(), text_color = MIDNIGHT_MUTED})
	case .Button:
		if ui.button(fmt.tprintf("%s###button", text), {width = ui.grow(), padding = PALETTE_WIDGET_PADDING}).pressed {
			tweak.fire(s.id)
		}
	case .Toggle:
		flag := t.flag
		ui.checkbox(
			fmt.tprintf("%s###toggle", text),
			&flag,
			{width = ui.grow(), padding = PALETTE_WIDGET_PADDING},
		)
		if flag != t.flag {
			tweak.set_flag(s.id, flag)
		}
	case .Slider:
		value := t.value
		ui.slider("slider", &value, s.lo, s.hi, {width = ui.grow()})
		ui.label(fmt.tprintf("%.2f", value), {width = ui.em(3)})
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
		ui.combo(
			"choice",
			&selection,
			&open,
			choices,
			{width = ui.grow(), padding = PALETTE_WIDGET_PADDING},
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

