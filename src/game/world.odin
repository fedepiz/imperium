package game

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import stbi "vendor:stb/image"

import "../gfx"
import "../ui"

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT
WORLD_SIZE :: [2]int{WORLD_WIDTH, WORLD_HEIGHT}


PIECE_MAX :: 1024

WORLD: struct {
	camera:      Camera,
	atlas:       Atlas,
	// Every slot a piece can be in
	pieces:      [PIECE_MAX]Piece,
	// The slots with no piece in them, the next to be used last
	pieces_free: [dynamic; PIECE_MAX]u16,
	// The piece described on the card, and drawn with a pulsing tint
	selected:    Piece_Id,
	movement:    Movement,
}

Move_Plan :: struct {
	// The plan's sequence number, bumped every time the plan is updated.
	seq_num: u32,
	subject: Piece_Id,
	target:  Piece_Id,
	path:    [dynamic; PATH_MAX_LEN][2]f32,
	cost:    [dynamic; PATH_MAX_LEN]f32,
}

@(private = "file")
move_plan_raw :: proc(
	subject_id: Piece_Id,
	destination: [2]f32,
	target: Piece_Id,
	plan: ^Move_Plan,
) {
	plan.seq_num += 1
	subject := piece_get(subject_id)
	if subject != nil {
		plan.subject = subject_id
		plan.target = target
		has_path := pathfind_trace(subject.pos, .Land, destination, {}, &plan.path, &plan.cost)
		if !has_path {
			fmt.eprintfln("No way over land from %v to %v", subject.pos, destination)
		}
	}
}

move_plan_to :: proc(subject: Piece_Id, target_id: Piece_Id, plan: ^Move_Plan) {
	target := piece_get(target_id)
	if target != nil {
		move_plan_raw(subject, target.pos, target_id, plan)
	}
}

move_plan_to_point :: proc(subject: Piece_Id, destination: [2]f32, plan: ^Move_Plan) {
	move_plan_raw(subject, destination, {}, plan)
}

// A piece walking to a place along the cheapest way there
Movement :: struct {
	plan:    Move_Plan,
	// The sequence number of the movement advance state
	seq_num: u32,
	// The point of the way being walked towards
	next:    int,
}

// How much cost a walking piece spends a second: the cells it covers on ground of cost 1
MOVEMENT_SPEED :: 4

#assert(gfx.RENDER_TERRAIN_WIDTH == WORLD_WIDTH && gfx.RENDER_TERRAIN_HEIGHT == WORLD_HEIGHT)
#assert(len(Way_Kind) == gfx.RENDER_WAY_KINDS)
#assert(POLYLINE_SMOOTHED_MAX <= gfx.RENDER_WAY_SEGMENTS_MAX)

Atlas :: struct {
	// Bumped whenever the terrain changes, so what is derived from it can be rebuilt
	revision: u32,
	terrain:  [CELLS_MAX]Terrain,
}

Terrain :: struct {
	surface:   Surface,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
	// For each way kind, which way is this cell assigned to. (Way_Id = 0 is nil)
	way:       [Way_Kind]Way_Id,
}

// What covers a cell
Surface :: enum u8 {
	Land,
	Lake,
	Sea,
}

// Ways run over land from cell to cell, one cell wide. The rules treat their cells as land; the map draws each as a line.
Way_Kind :: enum u8 {
	River,
	Road,
}

// Which way of its kind runs through a cell. Id 0 is none.
Way_Id :: distinct u16

WATER :: bit_set[Surface]{.Lake, .Sea}

// Defines the world's images, so call this before sprites_load. The terrain comes from a scenario, with world_load.
world_init :: proc() {
	camera_init()
	map_draw_init()
	iconography_init()
	pawns_init(WORLD.camera)
	for index := PIECE_MAX - 1; index >= 0; index -= 1 do append(&WORLD.pieces_free, u16(index))
}

// Loads a scenario's terrain from its folder: one greyscale PNG per property, WORLD_WIDTH by WORLD_HEIGHT.
// surface.png is black for land, grey for lake and white for sea; elevation.png, trees.png and moisture.png run from 0
// to 255 on land. rivers.png and roads.png hold, in 16 bits, the id of the way through each land cell.
// If a layer is missing or the wrong size, the world is left all water, so the failure shows, and false is returned.
world_load :: proc(scenario: string) -> bool {
	terrain := &WORLD.atlas.terrain
	Layer :: enum {
		Surface,
		Elevation,
		Trees,
		Moisture,
		Rivers,
		Roads,
	}
	names := [Layer]string {
		.Surface   = "surface",
		.Elevation = "elevation",
		.Trees     = "trees",
		.Moisture  = "moisture",
		.Rivers    = "rivers",
		.Roads     = "roads",
	}
	ok := true
	for name, layer in names {
		path := fmt.tprintf("%s/%s.png", scenario, name)
		pixels, loaded := world_load_layer(path)
		if !loaded {
			ok = false
			break
		}
		for value, i in pixels {
			byte := u8(value >> 8)
			switch layer {
			case .Surface:
				terrain[i].surface = Surface(min((int(byte) + 64) / 128, int(max(Surface))))
			case .Elevation:
				terrain[i].elevation = byte
			case .Trees:
				terrain[i].trees = byte
			case .Moisture:
				terrain[i].moisture = byte
			case .Rivers:
				terrain[i].way[.River] = Way_Id(value)
			case .Roads:
				terrain[i].way[.Road] = Way_Id(value)
			}
		}
	}
	if !ok do for &cell in terrain do cell = {
		surface = .Sea,
	}
	// Water cells carry nothing else.
	for &cell in terrain do if cell.surface in WATER do cell = {
		surface = cell.surface,
	}
	// Land
	{
		OFF_ROAD_COST :: 1
		ROAD_COST :: 0.4

		grid := pathfind_build_begin(.Land)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.way[.Road] != 0 ? ROAD_COST : cell.surface == .Land ? OFF_ROAD_COST : 0
		}
		pathfind_build_end(.Land)
	}
	// Sea
	{
		grid := pathfind_build_begin(.Sea)
		for cell, i in WORLD.atlas.terrain {
			grid[i] = cell.surface == .Land ? 0 : 1
		}
		pathfind_build_end(.Sea)
	}
	WORLD.atlas.revision += 1
	world_load_test_pieces()
	return ok
}

// One greyscale layer, WORLD_WIDTH by WORLD_HEIGHT, in 16 bits: an 8-bit image's values are widened, so their high
// byte is the value. The pixels live in the temp allocator.
@(private = "file")
world_load_layer :: proc(path: string) -> (pixels: []u16, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read terrain layer %q: %v", path, err)
		return
	}
	width, height, channels: c.int
	loaded := stbi.load_16_from_memory(
		raw_data(data),
		c.int(len(data)),
		&width,
		&height,
		&channels,
		1,
	)
	if loaded == nil {
		fmt.eprintfln("Could not decode terrain layer %q: %s", path, stbi.failure_reason())
		return
	}
	defer stbi.image_free(loaded)
	if width != WORLD_WIDTH || height != WORLD_HEIGHT {
		fmt.eprintfln(
			"Terrain layer %q is %dx%d; it should be %dx%d",
			path,
			width,
			height,
			WORLD_WIDTH,
			WORLD_HEIGHT,
		)
		return
	}
	pixels = make([]u16, CELLS_MAX, context.temp_allocator)
	copy(pixels, loaded[:CELLS_MAX])
	return pixels, true
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
world_tick :: proc(input: Input, dt: f32) {

	// Handle movement: the subject spends a steady cost a second walking the way, from where it stands towards the next
	// point, and stops moving at its end
	{
		mov := &WORLD.movement
		if mov.plan.subject != {} {
			subject := piece_get(mov.plan.subject)
			is_over: bool
			if subject == nil {
				is_over = true
			} else {
				// This is a fresh plan
				if mov.plan.seq_num != mov.seq_num {
					mov.next = 0
					mov.seq_num = mov.plan.seq_num
				}

				budget := MOVEMENT_SPEED * dt
				for budget > 0 && mov.next < len(mov.plan.path) {
					target, cost := mov.plan.path[mov.next], mov.plan.cost[mov.next]
					price := linalg.distance(subject.pos, target) * cost
					if budget < price {
						subject.pos += linalg.normalize(target - subject.pos) * budget / cost
						break
					}
					budget -= price
					subject.pos = target
					mov.next += 1
				}

				is_over = mov.next >= len(mov.plan.path)
			}

			if is_over {
				mov.plan.subject = {}
				mov.plan.target = {}
				mov.next = 0
			}
		}
	}

	camera_tick(input, dt)
	map_draw_tick(&WORLD.atlas, WORLD.camera, input.viewport, input.pixel_density)

	if input.left_click do WORLD.selected = pawns_pick(WORLD.camera, input.viewport, input.cursor)

	if input.right_click {
		if WORLD.selected != {} {
			target := pawns_pick(WORLD.camera, input.viewport, input.cursor)
			if target != {} {
				move_plan_to(WORLD.selected, target, &WORLD.movement.plan)
			} else {
				destination := camera_screen_to_world_point(
					WORLD.camera,
					input.viewport,
					input.cursor,
				)
				move_plan_to_point(WORLD.selected, destination, &WORLD.movement.plan)
			}
		}
	}

	pawns_begin(WORLD.camera, input.viewport, input.pixel_density, dt)
	for piece, index in WORLD.pieces {
		if !piece_alive(piece) do continue
		id := piece_id(index)
		pawns_add(id, piece.pos, piece.icon, piece.culture, piece.name, id == WORLD.selected)
	}
	pawns_end()
}

// Test pieces in late-Roman Italy and Germanic lands north of the Alps, in place of whatever pieces there were
@(private = "file")
world_load_test_pieces :: proc() {
	Test_Piece :: struct {
		pos:     [2]f32,
		icon:    Icon,
		name:    string,
		culture: Culture,
	}
	@(static, rodata)
	TEST_PIECES := [?]Test_Piece {
		{{342, 432}, .Large_City, "Roma", .Roman},
		{{296, 374}, .Large_City, "Mediolanum", .Roman},
		{{351, 400}, .City, "Ravenna", .Roman},
		{{412, 462}, .City, "Tarentum", .Roman},
		{{367, 369}, .Town, "Aquileia", .Roman},
		{{367, 449}, .Town, "Neapolis", .Roman},
		{{330, 401}, .Town, "Florentia", .Roman},
		{{296, 391}, .Town, "Genua", .Roman},
		{{327, 374}, .Town, "Verona", .Roman},
		{{260, 379}, .Town, "Segusio", .Roman},
		{{394, 506}, .Town, "Rhegium", .Roman},
		{{385, 527}, .Town, "Syracusae", .Roman},
		{{334, 419}, .Army, "", .Roman},
		{{353, 455}, .Fleet, "", .Roman},
		{{355, 393}, .Fleet, "", .Roman},
		{{350, 430}, .Priest, "", .Roman},
		{{306, 382}, .Envoy, "", .Roman},
		{{300, 300}, .Large_City, "Alamannia", .Germanic},
		{{332, 318}, .City, "Castra Regina", .Germanic},
		{{270, 322}, .Town, "Brisiacum", .Germanic},
		{{285, 285}, .Village, "", .Germanic},
		{{316, 342}, .Army, "", .Germanic},
		{{292, 340}, .Envoy, "", .Germanic},
	}
	// What each test piece is, by its icon
	@(static, rodata)
	TEST_TITLES := [Icon]string {
		.Village    = "Village",
		.Town       = "Town",
		.City       = "City",
		.Large_City = "Large City",
		.Army       = "Army",
		.Fleet      = "Fleet",
		.Priest     = "Priest",
		.Envoy      = "Envoy",
	}
	for piece, index in WORLD.pieces do if piece_alive(piece) do piece_despawn(piece_id(index))
	// The Roman army walks to Neapolis.
	for piece in TEST_PIECES {
		piece_spawn(
			{
				pos = piece.pos,
				icon = piece.icon,
				culture = piece.culture,
				name = piece.name,
				title = TEST_TITLES[piece.icon],
			},
		)
	}
}

// Draws the world: the map, then the pawns over it
world_render :: proc(renderer: ^gfx.Renderer) {
	map_draw_render(renderer)
	pawns_render(renderer)
}

// Steps the map to its next view: the map itself, then each raw terrain property in turn
world_next_map_view :: proc() {
	map_draw_next_view()
}

// The selected piece's card: the ink its property names are written in, and its space from the edges of the view
PIECE_CARD_FADED_INK :: [4]f32{MAP_INK.r, MAP_INK.g, MAP_INK.b, 0.6}
PIECE_CARD_MARGIN :: [2]f32{20, 20}

// Called between ui.begin() and ui.end(). The selected piece is described on a card of the map's paper at the bottom
// left of the view: its medallion and name, or what it is when it has none, over what it is.
world_ui :: proc() {
	piece := piece_get(WORLD.selected)
	if piece == nil do return

	ui.style_push(
		{
			font = font_id(.Text),
			text_color = MAP_INK,
			width = ui.text_dim(),
			height = ui.text_dim(),
		},
	)
	defer ui.style_pop()
	if ui.column({width = ui.grow(), height = ui.grow(), padding = PIECE_CARD_MARGIN}) {
		ui.spacer(ui.grow())
		card := ui.Style {
			width      = ui.fit(),
			height     = ui.fit(),
			padding    = [2]f32{16, 12},
			gap        = 6,
			background = MAP_PAPER,
			border     = MAP_INK,
			thickness  = 1.5,
			radius     = 3,
		}
		if ui.panel("selected piece", card) {
			title := [?]ui.Text {
				{
					image = icon_image(piece.icon, .Medallion, piece.culture),
					color = [4]f32{1, 1, 1, 1},
				},
				{text = " "},
				{text = piece.name != "" ? piece.name : piece.title},
			}
			ui.label_text(title[:], {font = font_id(.Title)})
			piece_card_row("Type", piece.title)
			piece_card_row("Culture", fmt.tprintf("%v", piece.culture))
		}
	}

	// A property on the card: its name, faded, in a column as wide for every row, then its value
	piece_card_row :: proc(name, value: string) {
		if ui.row({width = ui.fit(), height = ui.fit(), gap = 12}) {
			ui.label(name, {width = ui.em(5), text_color = PIECE_CARD_FADED_INK})
			ui.label(value)
		}
	}
}

// The peoples, each with its own style of drawings
Culture :: enum u8 {
	Roman,
	Germanic,
}

// A thing of the game's that stands on the map, drawn as a pawn
Piece :: struct {
	// Bumped as the slot takes a piece and as it frees it: odd while there is a piece in the slot, even while it is
	// free. Ids to earlier pieces go stale. Set by piece_spawn.
	generation: u16,
	// Where it stands, in cells
	pos:        [2]f32,
	icon:       Icon,
	culture:    Culture,
	name:       string,
	title:      string,
}

// Which piece: its slot, and the slot's generation while the piece is in it. An id with an even generation, like the
// zero id, is nil.
Piece_Id :: struct {
	index:      u16,
	generation: u16,
}

// Puts a piece in a free slot, returning its id, or nil when every slot is full
piece_spawn :: proc(piece: Piece) -> Piece_Id {
	index, ok := pop_safe(&WORLD.pieces_free)
	if !ok do return {}
	slot := &WORLD.pieces[index]
	generation := slot.generation + 1
	slot^ = piece
	slot.generation = generation
	return {index, generation}
}

// Frees a piece's slot. A stale or nil id does nothing.
piece_despawn :: proc(id: Piece_Id) {
	piece := piece_get(id)
	if piece == nil do return
	piece.generation += 1
	append(&WORLD.pieces_free, id.index)
}

// The piece an id is to, or nil when the id is stale or nil
piece_get :: proc(id: Piece_Id) -> ^Piece {
	piece := &WORLD.pieces[id.index]
	if id.generation & 1 == 0 || piece.generation != id.generation do return nil
	return piece
}

// There is a piece in the slot
piece_alive :: proc(piece: Piece) -> bool {
	return piece.generation & 1 == 1
}

// The id of the piece in a slot
piece_id :: proc(index: int) -> Piece_Id {
	return {u16(index), WORLD.pieces[index].generation}
}

