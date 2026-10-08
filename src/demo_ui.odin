package main

import "core:fmt"

// A small showcase of the widgets, in two looks: Midnight panels, and a Vellum card.
// Built between ui_begin and ui_end

// Fonts the demo uses, as main loads them
@(private = "file")
DEMO_FONT_BODY :: Text_Font_Id(0)
@(private = "file")
DEMO_FONT_HEADING :: Text_Font_Id(1)

Demo_Ui :: struct {
	presses:         int,
	locked:          bool,
	difficulty:      int,
	difficulty_open: bool,
	name:            [64]u8,
	name_len:        int,
	marches:         int,
}

// Midnight colors beyond the ui's base style
@(private = "file")
MIDNIGHT_PANEL :: [4]f32{0.105, 0.125, 0.165, 1}
@(private = "file")
MIDNIGHT_GOLD :: [4]f32{0.9, 0.71, 0.38, 1}
@(private = "file")
MIDNIGHT_MUTED :: [4]f32{0.55, 0.61, 0.7, 1}
@(private = "file")
MIDNIGHT_PRIMARY :: [4]f32{0.23, 0.39, 0.61, 1}
@(private = "file")
MIDNIGHT_DANGER :: [4]f32{0.48, 0.15, 0.19, 1}
// Text drawn on the saturated primary and danger fills
@(private = "file")
MIDNIGHT_TEXT_ON_FILL :: [4]f32{1, 1, 1, 1}

// Globals because UI_Size isn't constant; read-only
@(private = "file")
MIDNIGHT_PANEL_STYLE := UI_Style {
	width      = UI_Size{.Fit, 0, 1},
	height     = UI_Size{.Fit, 0, 1},
	padding    = [2]f32{16, 14},
	gap        = 8,
	background = MIDNIGHT_PANEL,
}
@(private = "file")
MIDNIGHT_HEADING := UI_Style {
	height     = UI_Size{.Text, 0, 1},
	text_color = MIDNIGHT_GOLD,
	font       = DEMO_FONT_HEADING,
}
@(private = "file")
MIDNIGHT_MUTED_TEXT :: UI_Style {
	text_color = MIDNIGHT_MUTED,
}
@(private = "file")
MIDNIGHT_PRIMARY_BUTTON :: UI_Style {
	background = MIDNIGHT_PRIMARY,
	text_color = MIDNIGHT_TEXT_ON_FILL,
}
@(private = "file")
MIDNIGHT_DANGER_BUTTON :: UI_Style {
	background = MIDNIGHT_DANGER,
	text_color = MIDNIGHT_TEXT_ON_FILL,
}

// Vellum: ink on paper, the look of the game's cards
@(private = "file")
VELLUM_PAPER :: [4]f32{0.840, 0.772, 0.620, 1}
@(private = "file")
VELLUM_INK :: [4]f32{0.150, 0.105, 0.070, 1}
@(private = "file")
VELLUM_HOT_PAPER :: [4]f32{0.760, 0.690, 0.545, 1}
@(private = "file")
VELLUM_ACTIVE_PAPER :: [4]f32{0.680, 0.610, 0.475, 1}
@(private = "file")
VELLUM_FADED_INK :: [4]f32{VELLUM_INK.r, VELLUM_INK.g, VELLUM_INK.b, 0.6}

// Pushed around a card: ink, every box sized by its text
@(private = "file")
VELLUM_TEXT := UI_Style {
	text_color = VELLUM_INK,
	width      = UI_Size{.Text, 0, 1},
	height     = UI_Size{.Text, 0, 1},
}
@(private = "file")
VELLUM_CARD := UI_Style {
	width      = UI_Size{.Fit, 0, 1},
	height     = UI_Size{.Fit, 0, 1},
	padding    = [2]f32{16, 12},
	gap        = 6,
	background = VELLUM_PAPER,
	border     = VELLUM_INK,
	thickness  = 1.5,
	radius     = 3,
}
@(private = "file")
VELLUM_ACTION :: UI_Style {
	padding           = [2]f32{12, 4},
	background        = VELLUM_PAPER,
	hot_background    = VELLUM_HOT_PAPER,
	active_background = VELLUM_ACTIVE_PAPER,
	border            = VELLUM_INK,
	focus_border      = VELLUM_INK,
	hot_text_color    = VELLUM_INK,
}

@(private = "file")
DEMO_DIFFICULTIES := []string{"Easy", "Normal", "Hard"}

demo_ui :: proc(demo: ^Demo_Ui) {
	if ui_column({width = ui_grow(), height = ui_grow(), padding = [2]f32{24, 20}, gap = 16}) {
		if ui_column({width = ui_fit(), height = ui_fit(), gap = 2}) {
			demo_label("Imperium", MIDNIGHT_HEADING)
			demo_label("Lorem ipsum dolor sit amet.", MIDNIGHT_MUTED_TEXT)
		}

		if ui_row({width = ui_fit(), height = ui_fit(), gap = 16}) {
			if ui_panel("controls", MIDNIGHT_PANEL_STYLE) {
				demo_label("Controls", MIDNIGHT_HEADING)
				demo_label(fmt.tprintf("Button presses: %d", demo.presses))
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					press := demo_button("Press me", MIDNIGHT_PRIMARY_BUTTON)
					if press.pressed {
						demo.presses += 1
					}
					// Tooltips in tooltips: hover a gold word to open the next one
					if ui_tooltip("press me tip", press.hovered, MIDNIGHT_PANEL_STYLE) {
						demo_label("Lorem ipsum dolor sit amet.")
						demo_label(
							"Consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
							{
								width = ui_em(14),
								height = ui_text_dim(),
								text_color = MIDNIGHT_MUTED,
							},
						)
						ui_label_text(
							{
								{text = "Hover the "},
								{text = "legion", color = MIDNIGHT_GOLD, key = "legion"},
								{text = " for more."},
							},
							{width = ui_text_dim()},
						)
						if ui_tooltip(
							"legion",
							ui_signal("legion").hovered,
							MIDNIGHT_PANEL_STYLE,
						) {
							demo_label("About five thousand men.")
							ui_label_text(
								{
									{text = "Led by a "},
									{text = "legatus", color = MIDNIGHT_GOLD, key = "legatus"},
									{text = "."},
								},
								{width = ui_text_dim()},
							)
							if ui_tooltip(
								"legatus",
								ui_signal("legatus").hovered,
								MIDNIGHT_PANEL_STYLE,
							) {
								demo_label("A senator, appointed by the emperor.")
							}
						}
					}
					if demo_button("Reset", MIDNIGHT_DANGER_BUTTON).pressed {
						demo.presses = 0
					}
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_checkbox("Locked", &demo.locked)
					demo_button("Guarded", {disabled = demo.locked})
				}
				ui_label_text(
					{
						{text = "Sed do eiusmod "},
						{text = "tempor", color = MIDNIGHT_GOLD, key = "tempor"},
						{text = " incididunt."},
					},
					{width = ui_text_dim(), text_color = MIDNIGHT_MUTED},
				)
				if ui_tooltip("tempor tip", ui_signal("tempor").hovered, MIDNIGHT_PANEL_STYLE) {
					ui_label_text(
						{
							{text = "Lorem ipsum "},
							{text = "dolor", color = MIDNIGHT_GOLD, key = "tempor2"},
							{text = " sit amet."},
						},
					)
					if ui_tooltip("nested_tip", true, MIDNIGHT_PANEL_STYLE) {
						demo_button("A button!")
					}
				}
			}

			if ui_panel("styles", MIDNIGHT_PANEL_STYLE) {
				demo_label("Styles", MIDNIGHT_HEADING)
				ui_label_text(
					{
						{text = "Ut enim ad minim "},
						{text = "veniam", color = MIDNIGHT_GOLD, font = DEMO_FONT_HEADING},
						{text = "."},
					},
					{width = ui_text_dim()},
				)
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Ordinary")
					demo_button("Primary", MIDNIGHT_PRIMARY_BUTTON)
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_button("Danger", MIDNIGHT_DANGER_BUTTON)
					demo_button("Unavailable", {disabled = true})
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_label("Difficulty")
					ui_combo(
						"difficulty",
						&demo.difficulty,
						&demo.difficulty_open,
						DEMO_DIFFICULTIES,
						{width = ui_px(120), padding = [2]f32{10, 0}},
					)
				}
				if ui_row({width = ui_fit(), height = ui_fit(), gap = 8}) {
					demo_label("Name")
					ui_input(
						"name",
						demo.name[:],
						&demo.name_len,
						{width = ui_px(160), padding = [2]f32{10, 0}},
					)
				}
				demo_label("Quis nostrud exercitation.", MIDNIGHT_MUTED_TEXT)
			}

			ui_style_next(MIDNIGHT_PANEL_STYLE)
			if ui_scroll_panel("scrolling", {height = ui_px(180)}) {
				demo_label("Scrolling", MIDNIGHT_HEADING)
				for i in 1 ..= 20 {
					demo_button(fmt.tprintf("Entry %d###entry%d", i, i))
				}
			}

			// Vellum: a card, ink on paper
			ui_style_push(VELLUM_TEXT)
			if ui_panel("vellum card", VELLUM_CARD) {
				ui_label("Legio XXII Primigenia", {font = DEMO_FONT_HEADING})
				ui_label("Winters at Mogontiacum.", {text_color = VELLUM_FADED_INK})
				ui_label(fmt.tprintf("Marches ordered: %d", demo.marches))
				if ui_button("March north", VELLUM_ACTION).pressed {
					demo.marches += 1
				}
			}
			ui_style_pop()
		}
	}
}

@(private = "file")
demo_label :: proc(text: string, style := UI_Style{}) {
	ui_style_next({width = ui_text_dim()})
	ui_label(text, style)
}

@(private = "file")
demo_button :: proc(label: string, style := UI_Style{}) -> UI_Signal {
	ui_style_next({width = ui_text_dim(), padding = [2]f32{10, 0}})
	return ui_button(label, style)
}

@(private = "file")
demo_checkbox :: proc(label: string, value: ^bool, style := UI_Style{}) -> UI_Signal {
	ui_style_next({width = ui_fit(), padding = [2]f32{10, 0}})
	return ui_checkbox(label, value, style)
}
