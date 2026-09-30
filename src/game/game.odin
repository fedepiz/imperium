package game

import "core:fmt"
import "core:math"
import "core:reflect"

import "../gfx"
import "../sim"
import "../tweak"
import "../ui"

GAME: struct {
	camera:           Camera,
	// The piece the view is about: its pawn focused, where it can reach shown, and its card
	focus:            sim.Piece_Id,
	// What colour the regions are shown in
	region_colouring: sim.Region_Colouring_Mode,
	// The commands sent to the world at its next step
	commands:         [dynamic; COMMANDS_MAX]sim.Command,
	// What the world showed at its last step
	scene:            sim.Scene,
	// How each piece looks beyond what its pawn says, in the slot of its handle's index
	visuals:          [sim.PAWNS_MAX]Piece_Visual,
	// The folder of the scenario loaded, and the fingerprint of each of its caches as it is saved: see cache_path
	folder:           string,
	saved:            [sim.Cached_File_Id]u64,
}

// How many commands wait for the world's next step; the rest are dropped
COMMANDS_MAX :: 64

// The cells a walking piece covers a second, whatever the ground
MOVEMENT_SPEED :: 10

// The side, in cells, of the square around a clicked point a move looks in for somewhere it can go, when the point
// itself is out of reach
CLICK_MOVE_SNAP :: 9

#assert(
	gfx.RENDER_TERRAIN_WIDTH == sim.WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == sim.WORLD_HEIGHT,
)
#assert(POLYLINE_SMOOTHED_MAX <= gfx.RENDER_LINE_SEGMENTS_MAX)

// Defines the game's images, so call this before sprites_load. The world comes from a scenario, with game_load.
game_init :: proc() {
	sim.init()
	camera_init()
	map_draw_init()
	iconography_init()
	pawns_init(GAME.camera)
}

// Loads the world from a scenario's folder: see scenario_read. If it does not load, the world is left all water, so
// the failure shows, and false is returned. The scenario's caches are rewritten whenever the world holds newer ones:
// see cache_path. The folder's name is kept, so it must outlast the game.
game_load :: proc(folder: string) -> bool {
	scenario := scenario_read(folder)
	GAME.folder = folder
	for file, id in scenario.cached_files do GAME.saved[id] = file.fingerprint
	return sim.load(scenario)
}

// Inputs used by the game module, in logical pixels unless stated
Input :: struct {
	// Size of the view the map fills
	viewport:      [2]f32,
	pixel_density: f32,
	cursor:        [2]f32,
	// The cursor is over the map, not over the ui or outside the window
	on_map:        bool,
	// The button that drags the map is held
	grab:          bool,
	// The button that selects went down this frame, over the map
	left_click:    bool,
	right_click:   bool,
	// Keyboard panning along each axis, from -1 to 1; positive y is down the map
	pan:           [2]f32,
	// Wheel movement this frame, in notches; positive zooms in
	wheel:         f32,
}

// Called every frame
game_tick :: proc(input: Input, dt: f32) {
	camera_tick(input, dt)

	// The left click focuses the pawn under it, or nothing; the right one sends the focus, if it is controlled, to the
	// pawn under it other than itself, or else to the place under it.
	// Picked from the pawns last drawn, which the scene holds until it is presented again
	pawns := GAME.scene.pawns[:]
	if input.left_click do GAME.focus = pawns_pick(pawns, GAME.camera, input.viewport, input.cursor)
	if focus, ok := scene_pawn(GAME.focus);
	   ok && input.right_click && .Controlled in focus.flags {
		target := pawns_pick(pawns, GAME.camera, input.viewport, input.cursor, GAME.focus)
		if target != {} {
			command_send(sim.Move_Focus_To_Piece{target = target})
		} else {
			destination := camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor)
			command_send(sim.Move_Focus_To_Point{destination = destination, snap = CLICK_MOVE_SNAP})
		}
	}

	// The region under the cursor, from the ground last presented
	pointed: sim.Region_Id
	if input.on_map {
		cell := camera_screen_to_world_point(GAME.camera, input.viewport, input.cursor)
		x, y := int(math.floor(cell.x)), int(math.floor(cell.y))
		if x >= 0 && y >= 0 && x < sim.WORLD_WIDTH && y < sim.WORLD_HEIGHT {
			pointed = GAME.scene.ground[y * sim.WORLD_WIDTH + x].region
		}
	}

	sim.step(GAME.commands[:], MOVEMENT_SPEED * dt)
	clear(&GAME.commands)
	colourings := reflect.enum_field_names(sim.Region_Colouring_Mode)
	colouring := tweak.choice("Map/Region colouring", int(GAME.region_colouring), colourings)
	GAME.region_colouring = sim.Region_Colouring_Mode(colouring)
	sim.present(GAME.focus, pointed, GAME.region_colouring, &GAME.scene)
	for file, id in GAME.scene.caches {
		if file.fingerprint == GAME.saved[id] do continue
		// Tried once per fingerprint, so a folder that cannot be written is not retried every frame
		GAME.saved[id] = file.fingerprint
		cache_write(cache_path(GAME.folder, id), file)
	}

	map_draw_tick(&GAME.scene, GAME.region_colouring, GAME.camera, input.viewport, input.pixel_density, dt)
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

// The pawn of the latest scene with the handle, if it has one
@(private = "file")
scene_pawn :: proc(handle: sim.Piece_Id) -> (sim.Pawn, bool) {
	for pawn in GAME.scene.pawns do if pawn.handle == handle do return pawn, true
	return {}, false
}

// Sends a command to the world at its next step
@(private = "file")
command_send :: proc(command: sim.Command) {
	if len(GAME.commands) < COMMANDS_MAX do append(&GAME.commands, command)
}

// Draws the game: the map, then the pawns over it
game_render :: proc(renderer: ^gfx.Renderer) {
	map_draw_render(renderer)
	pawns_render(renderer)
}

// Steps the map to its next view: the map itself, then each raw terrain property in turn
game_next_map_view :: proc() {
	map_draw_next_view()
}

// The cards' space from the edges of the view
CARD_MARGIN :: [2]f32{20, 20}
// The ink a card's field labels are written in
CARD_FADED_INK :: [4]f32{MAP_INK.r, MAP_INK.g, MAP_INK.b, 0.6}
// The paper of a button on a card while hovered, and while held
CARD_BUTTON_HOT_PAPER :: [4]f32{0.760, 0.690, 0.545, 1}
CARD_BUTTON_ACTIVE_PAPER :: [4]f32{0.680, 0.610, 0.475, 1}

// Called between ui.begin() and ui.end(). The scene's cards float over the map on the map's paper: its status cards at
// the top right, its interaction cards in the middle, its focus cards at the bottom left.
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

// Builds the scene's cards at a place: each its title, headed by its medallion if it has a picture, over its fields,
// each its label, faded, in a column as wide for every field, then its value, over its actions, each a button that
// sends its command.
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
					ui.label(field.label, {width = ui.em(5), text_color = CARD_FADED_INK})
					ui.label(field.value)
				}
			}
			for action in card.actions {
				action_style.disabled = !action.enabled
				if ui.button(action.label, action_style).pressed do command_send(action.command)
			}
		}
	}
}
