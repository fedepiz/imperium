package game

import "core:fmt"

import "../gfx"
import "../sim"
import "../ui"
import "../util"

// Maximum simulation steps in a frame. Excess time is dropped to avoid slowing down the game.
STEPS_PER_FRAME_MAX :: 4

// Side of the square, in cells, searched for a reachable cell around an unreachable click
CLICK_MOVE_SNAP :: 9

CARD_MARGIN :: [2]f32{20, 20}
CARD_FADED_INK :: [4]f32{MAP_INK.r, MAP_INK.g, MAP_INK.b, 0.6}
// Card columns, in em; fixed so cards don't resize as values change. Stats are the shorter right-hand values.
CARD_LABEL_EM :: 7
CARD_VALUE_EM :: 9
CARD_STAT_EM :: 8
// Width of a card's paragraphs, in em; they wrap
CARD_LINES_EM :: 26
// Numbers with a breakdown, while hovered
CARD_HOVER_INK :: [4]f32{0.62, 0.24, 0.16, 1}
// Between the fields and stats columns, in pixels
CARD_COLUMN_GAP :: 24

Map_Mode :: enum u8 {
	// Regions in their owner's colour
	Control,
	// Muted regions, and the player's supply map
	Supply,
	// Muted regions
	Plain,
}

// Width of each map mode button, in em
MAP_MODE_BUTTON_EM :: 5

// What each map mode shows
MAP_MODE_LABELS := [Map_Mode]string {
	.Control = "Control",
	.Supply  = "Supply",
	.Plain   = "Plain",
}
MAP_MODE_REGIONS := [Map_Mode]sim.Region_Colouring_Mode {
	.Control = .Owner,
	.Supply  = .Muted,
	.Plain   = .Muted,
}
MAP_MODE_SUPPLY :: bit_set[Map_Mode]{.Supply}

// Card button: hovered, pressed
CARD_BUTTON_HOT_PAPER :: [4]f32{0.760, 0.690, 0.545, 1}
CARD_BUTTON_ACTIVE_PAPER :: [4]f32{0.680, 0.610, 0.475, 1}

GAME: struct {
	camera:           Camera,
	// Selected piece: highlighted, reach shown, card shown
	focus:            sim.Piece_Id,
	map_mode:         Map_Mode,
	// Input for the next sim step
	input:            sim.Step_Input,
	// Time not yet simulated, in seconds
	unstepped:        f32,
	// Output of the last present
	scene:            sim.Scene,
	// Indexed by pawn handle index
	visuals:          [sim.PAWNS_MAX]Piece_Visual,
	// Scenario folder, and the fingerprint of each cache last written to it
	folder:           string,
	saved:            [sim.Cached_File_Id]u64,
}

#assert(
	gfx.RENDER_TERRAIN_WIDTH == sim.WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == sim.WORLD_HEIGHT,
)
#assert(POLYLINE_SMOOTHED_MAX <= gfx.RENDER_LINE_SEGMENTS_MAX)

// Call before sprites_load: defines the game's images.
game_init :: proc() {
	sim.init()
	camera_init()
	map_draw_init()
	iconography_init()
	pawns_init(GAME.camera)
}

// On failure the world is all water and false is returned. folder must outlive the game.
game_load :: proc(folder: string) -> bool {
	scenario := scenario_read(folder)
	GAME.folder = folder
	for file, id in scenario.cached_files do GAME.saved[id] = file.fingerprint
	return sim.load(scenario)
}

// In logical pixels unless stated
Input :: struct {
	viewport:      [2]f32,
	pixel_density: f32,
	cursor:        [2]f32,
	// Cursor is over the map, not over the ui or outside the window
	on_map:        bool,
	// Map drag button held
	grab:          bool,
	// Pressed this frame, over the map
	left_click:    bool,
	right_click:   bool,
	// -1..1 per axis; +y is down
	pan:           [2]f32,
	// Notches this frame; + zooms in
	wheel:         f32,
}

game_tick :: proc(input: Input, dt: f32) {
	camera_tick(input, dt)

	// Left click: select. Right click: move the selected piece to a pawn or a point.
	pawns := GAME.scene.pawns[:]
	if input.left_click do GAME.focus = pawns_pick(pawns, GAME.camera, input.viewport, input.cursor)
	if focus, ok := scene_pawn(GAME.focus); ok && input.right_click && .Controlled in focus.flags {
		target := pawns_pick(pawns, GAME.camera, input.viewport, input.cursor, GAME.focus)
		if target != {} {
			GAME.input.order = sim.Move_To_Piece {
				piece  = GAME.focus,
				target = target,
			}
		} else {
			destination := camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor)
			GAME.input.order = sim.Move_To_Point {
				piece       = GAME.focus,
				destination = destination,
				snap        = CLICK_MOVE_SNAP,
			}
		}
	}

	// Region under the cursor
	pointed: sim.Region_Id
	if input.on_map {
		cell := util.cell_of(camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor))
		if util.grid_contains(cell, sim.WORLD_SIZE) {
			pointed = GAME.scene.ground[util.grid_index(cell, sim.WORLD_SIZE)].region
		}
	}

	// Fixed-step update
	GAME.unstepped = min(GAME.unstepped + dt, STEPS_PER_FRAME_MAX * sim.STEP_SECONDS)
	for GAME.unstepped >= sim.STEP_SECONDS {
		GAME.unstepped -= sim.STEP_SECONDS
		GAME.input.focus = GAME.focus
		sim.step(GAME.input)
		GAME.input = {}
	}
	// Map mode
	region_colouring := MAP_MODE_REGIONS[GAME.map_mode]
	supply_shown := GAME.map_mode in MAP_MODE_SUPPLY
	sim.present(GAME.focus, pointed, region_colouring, &GAME.scene)
	for file, id in GAME.scene.caches {
		if file.fingerprint == GAME.saved[id] do continue
		// Once per fingerprint, so an unwritable folder isn't retried every frame
		GAME.saved[id] = file.fingerprint
		cache_write(cache_path(GAME.folder, id), file)
	}

	map_draw_tick(
		&GAME.scene,
		region_colouring,
		supply_shown,
		GAME.camera,
		input.viewport,
		input.pixel_density,
		dt,
	)
	visuals_tick(GAME.visuals[:], GAME.scene.pawns[:], dt)
	pawns_draw(
		GAME.scene.pawns[:],
		GAME.visuals[:],
		GAME.camera,
		input.viewport,
		input.pixel_density,
		dt,
	)
}

@(private = "file")
scene_pawn :: proc(handle: sim.Piece_Id) -> (sim.Pawn, bool) {
	for pawn in GAME.scene.pawns do if pawn.handle == handle do return pawn, true
	return {}, false
}

// While the run keyed by the breakdown is hovered, a tooltip of its note, terms, a rule and the total. 0 = none.
@(private = "file")
breakdown_hover :: proc(card: ^sim.Card, breakdown: int, style: ui.Style) {
	if breakdown == 0 || !ui.signal(fmt.tprintf("breakdown %d", breakdown)).hovered do return
	shown := &card.breakdowns[breakdown - 1]
	if ui.tooltip(style) {
		if shown.note != "" do ui.label(shown.note)
		for term in shown.terms {
			if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
				ui.label(term.label, {width = ui.em(CARD_LABEL_EM), text_color = CARD_FADED_INK})
				ui.label(term.value, {width = ui.em(CARD_STAT_EM)})
			}
		}
		if shown.total != "" {
			ui.panel("rule", {width = ui.grow(), height = ui.px(1), background = MAP_INK, thickness = 0})
			if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
				ui.label("Total", {width = ui.em(CARD_LABEL_EM), text_color = CARD_FADED_INK})
				ui.label(shown.total, {width = ui.em(CARD_STAT_EM)})
			}
		}
	}
}

@(private = "file")
ask :: proc(what: sim.Card_Ask) {
	switch what {
	case .End_Turn:
		GAME.input.end_turn = true
	case .Conquer:
		GAME.input.answer = .Conquer
	case .Leave:
		GAME.input.answer = .Leave
	case .Next:
		GAME.input.answer = .Next
	}
}

game_render :: proc(renderer: ^gfx.Renderer) {
	map_draw_render(renderer)
	pawns_render(renderer)
}

// Cycles the map view: normal, then each raw terrain layer
game_next_map_view :: proc() {
	map_draw_next_view()
}

// Call between ui.begin() and ui.end(). Cards: status top right, interaction left, focus bottom left.
game_ui :: proc() {
	ui.style_push(
		{
			font = font_id(.Text),
			text_color = MAP_INK,
			width = ui.text_dim(),
			height = ui.text_dim(),
		},
	)
	defer ui.style_pop()
	if ui.column({width = ui.grow(), height = ui.grow(), padding = CARD_MARGIN}) {
		if ui.row({width = ui.grow(), height = ui.fit()}) {
			ui.spacer(ui.grow())
			cards_build(.Status)
		}
		ui.spacer(ui.grow())
		if ui.row({width = ui.grow(), height = ui.fit()}) {
			cards_build(.Interaction)
			ui.spacer(ui.grow())
		}
		ui.spacer(ui.grow())
		cards_build(.Focus)
	}
}

@(private = "file")
cards_build :: proc(place: sim.Card_Place) {
	style := ui.Style {
		width      = ui.fit(),
		height     = ui.fit(),
		padding    = [2]f32{16, 12},
		gap        = 6,
		background = MAP_PAPER,
		border     = MAP_INK,
		thickness  = 1.5,
		radius     = 3,
	}
	action_style := ui.Style {
		padding           = [2]f32{12, 4},
		background        = MAP_PAPER,
		hot_background    = CARD_BUTTON_HOT_PAPER,
		active_background = CARD_BUTTON_ACTIVE_PAPER,
		border            = MAP_INK,
		focus_border      = MAP_INK,
		hot_text_color    = MAP_INK,
	}
	tooltip_style := ui.Style {
		width      = ui.fit(),
		height     = ui.fit(),
		padding    = [2]f32{12, 8},
		gap        = 4,
		background = MAP_PAPER,
		border     = MAP_INK,
		thickness  = 1.5,
		radius     = 3,
	}
	count := 0
	for &card in GAME.scene.cards {
		if card.place != place do continue
		count += 1
		if ui.panel(fmt.tprintf("%v card %d", place, count), style) {
			if picture, ok := card.picture.?; ok {
				title := [?]ui.Text {
					{
						image = icon_image(picture.icon, .Medallion, picture.culture),
						color = [4]f32{1, 1, 1, 1},
					},
					{text = " "},
					{text = card.title},
				}
				ui.label_text(title[:], {font = font_id(.Title)})
			} else {
				ui.label(card.title, {font = font_id(.Title)})
			}
			// Paragraphs; a number with a breakdown shows it on hover
			for line in card.lines {
				parts := card.parts[line.begin:][:line.len]
				texts: [dynamic; sim.CARD_PARTS_MAX]ui.Text
				for part in parts {
					text := ui.Text {
						text = part.text,
					}
					if part.breakdown > 0 {
						text.key = fmt.tprintf("breakdown %d", part.breakdown)
						text.hot_color = CARD_HOVER_INK
						text.underline = true
					}
					append(&texts, text)
				}
				ui.label_text(texts[:], {width = ui.em(CARD_LINES_EM)})
				for part in parts do breakdown_hover(&card, part.breakdown, tooltip_style)
			}
			// Fields, and stats beside them
			if ui.row({width = ui.fit(), height = ui.fit(), gap = CARD_COLUMN_GAP}) {
				columns := [2][]sim.Field{card.fields[:], card.stats[:]}
				value_em := [2]f32{CARD_VALUE_EM, CARD_STAT_EM}
				for fields, column in columns {
					if len(fields) == 0 do continue
					if ui.column({width = ui.fit(), height = ui.fit(), gap = 6}) {
						for field in fields {
							if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
								ui.label(field.label, {width = ui.em(CARD_LABEL_EM), text_color = CARD_FADED_INK})
								value := ui.Text {
									text = field.value,
								}
								if field.breakdown > 0 {
									value.key = fmt.tprintf("breakdown %d", field.breakdown)
									value.hot_color = CARD_HOVER_INK
									value.underline = true
								}
								ui.label_text({value}, {width = ui.em(value_em[column])})
								breakdown_hover(&card, field.breakdown, tooltip_style)
							}
						}
					}
				}
			}
			for action in card.actions {
				action_style.disabled = !action.enabled
				if ui.button(action.label, action_style).pressed do ask(action.ask)
			}
			// Map modes, on the status card: the selected one looks pressed
			if card.place == .Status {
				ui.label("Map Mode", {text_color = CARD_FADED_INK})
				if ui.row({width = ui.fit(), height = ui.fit(), gap = 0}) {
					font := font_id(.Text)
					width := MAP_MODE_BUTTON_EM * gfx.font_size(font)
					mode_style := action_style
					mode_style.disabled = false
					mode_style.width = ui.px(width)
					for label, mode in MAP_MODE_LABELS {
						style := mode_style
						style.padding = [2]f32{max(0, (width - gfx.text_advance(label, font)) / 2), 2}
						if mode == GAME.map_mode {
							style.background = CARD_BUTTON_ACTIVE_PAPER
							style.hot_background = CARD_BUTTON_ACTIVE_PAPER
						}
						if ui.button(fmt.tprintf("%s##map mode", label), style).pressed do GAME.map_mode = mode
					}
				}
			}
		}
	}
}
