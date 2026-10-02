package game

import "core:fmt"
import "core:math"
import "core:reflect"

import "../gfx"
import "../sim"
import "../tweak"
import "../ui"

// Maximum simulation steps in a frame. Excess time is dropped to avoid slowing down the game.
STEPS_PER_FRAME_MAX :: 4

// Side of the square, in cells, searched for a reachable cell around an unreachable click
CLICK_MOVE_SNAP :: 9

CARD_MARGIN :: [2]f32{20, 20}
CARD_FADED_INK :: [4]f32{MAP_INK.r, MAP_INK.g, MAP_INK.b, 0.6}
// Card button: hovered, pressed
CARD_BUTTON_HOT_PAPER :: [4]f32{0.760, 0.690, 0.545, 1}
CARD_BUTTON_ACTIVE_PAPER :: [4]f32{0.680, 0.610, 0.475, 1}

GAME: struct {
	camera:           Camera,
	// Selected piece: highlighted, reach shown, card shown
	focus:            sim.Piece_Id,
	region_colouring: sim.Region_Colouring_Mode,
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
			GAME.input.order = sim.Move_Focus_To_Piece {
				target = target,
			}
		} else {
			destination := camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor)
			GAME.input.order = sim.Move_Focus_To_Point {
				destination = destination,
				snap        = CLICK_MOVE_SNAP,
			}
		}
	}

	// Region under the cursor
	pointed: sim.Region_Id
	if input.on_map {
		cell := camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor)
		x, y := int(math.floor(cell.x)), int(math.floor(cell.y))
		if x >= 0 && y >= 0 && x < sim.WORLD_WIDTH && y < sim.WORLD_HEIGHT {
			pointed = GAME.scene.ground[y * sim.WORLD_WIDTH + x].region
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
	colourings := reflect.enum_field_names(sim.Region_Colouring_Mode)
	colouring := tweak.choice("Map/Region colouring", int(GAME.region_colouring), colourings)
	GAME.region_colouring = sim.Region_Colouring_Mode(colouring)
	sim.present(GAME.focus, pointed, GAME.region_colouring, &GAME.scene)
	for file, id in GAME.scene.caches {
		if file.fingerprint == GAME.saved[id] do continue
		// Once per fingerprint, so an unwritable folder isn't retried every frame
		GAME.saved[id] = file.fingerprint
		cache_write(cache_path(GAME.folder, id), file)
	}

	map_draw_tick(
		&GAME.scene,
		GAME.region_colouring,
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

@(private = "file")
ask :: proc(what: sim.Card_Ask) {
	switch what {
	case .End_Turn:
		GAME.input.end_turn = true
	case .Conquer:
		GAME.input.conquer = true
	case .Leave_Interaction:
		GAME.input.leave = true
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

// Call between ui.begin() and ui.end(). Cards: status top right, interaction centre, focus bottom left.
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
			ui.spacer(ui.grow())
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
			for field in card.fields {
				if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
					ui.label(field.label, {width = ui.em(7), text_color = CARD_FADED_INK})
					ui.label(field.value)
				}
			}
			for action in card.actions {
				action_style.disabled = !action.enabled
				if ui.button(action.label, action_style).pressed do ask(action.ask)
			}
		}
	}
}
