package sim

import "../span"

// The world ----------------------------------------------------------------------------------------------------------
// The world: how big it is, and the words it is described in

// The world's size, in cells. Cells are indexed y * WORLD_WIDTH + x.
WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT
WORLD_SIZE :: [2]int{WORLD_WIDTH, WORLD_HEIGHT}

// What covers a cell
Surface :: enum u8 {
	Land,
	Lake,
	Sea,
}

WATER :: bit_set[Surface]{.Lake, .Sea}

// Ways run over land from cell to cell, one cell wide. The rules treat their cells as land; the map draws each as a line.
Way_Kind :: enum u8 {
	River,
	Road,
}

// The peoples, each with its own style of drawings
Culture :: enum u8 {
	Roman,
	Germanic,
}

// What a drawing shows.
// Please do not lean on this to tell what a piece is or can do: that belongs to its traits and flags, not to its kind.
Icon :: enum u8 {
	Village,
	Town,
	City,
	Large_City,
	Army,
	Fleet,
	Priest,
	Envoy,
}

// Which piece: its slot, and the slot's generation while the piece is in it. An id with an even generation, like the
// zero id, is nil.
Piece_Id :: struct {
	index:      u16,
	generation: u16,
}

// In ------------------------------------------------------------------------------------------------------------------
// In: what the world starts from, and what is asked of it

// A world to start from, cell by cell. A layer that is not CELLS_MAX long is missing.
Scenario :: struct {
	surface:   []Surface,
	elevation: []u8,
	trees:     []u8,
	moisture:  []u8,
	// For each way kind, the id of the way through each cell, 0 for none
	ways:      [Way_Kind][]u16,
}

// What is asked of the world, applied in order by step
Command :: union {
	Move_To_Point,
	Move_To_Piece,
	End_Turn,
}

// The piece walks to the destination, in cells, along the cheapest way there. Rejected, leaving what is walking as it
// was, when the piece cannot walk there this turn.
Move_To_Point :: struct {
	piece:       Piece_Id,
	destination: [2]f32,
}

// The piece walks to where the target stands, as Move_To_Point.
Move_To_Piece :: struct {
	piece:  Piece_Id,
	target: Piece_Id,
}

// The turn ends and the next begins. Rejected while a piece is walking.
End_Turn :: struct {}

// Out -----------------------------------------------------------------------------------------------------------------
// Out: what the world shows, laid out for what draws it

// How many tokens, arrows, points along arrows, areas and cards a scene holds
TOKENS_MAX :: PIECE_MAX
ARROWS_MAX :: 64
ARROW_POINTS_MAX :: 4096
AREAS_MAX :: 16
CARDS_MAX :: 8
// How many fields and actions a card holds
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4
// The side of the square of cells an area lies within
AREA_SIZE :: PATHFIND_FLOOD_SIZE

// What the world shows: the ground, the tokens standing on it, the arrows and areas over it, and the cards beside it.
// Filled by present; what it holds lasts until the next present.
Scene :: struct {
	// Every cell's ground. Rewritten only when the world's ground changes, which bumps ground_revision.
	ground:          [CELLS_MAX]Ground,
	ground_revision: u32,
	tokens:          [dynamic; TOKENS_MAX]Token,
	// Each arrow is a run of arrow_points, from its tail to its head
	arrows:          [dynamic; ARROWS_MAX]span.Span,
	arrow_points:    [dynamic; ARROW_POINTS_MAX][2]f32,
	areas:           [AREAS_MAX]Area,
	cards:           [dynamic; CARDS_MAX]Card,
}

// A cell as it lies: what covers it, how high, wooded and wet it is, from 0 to 255, and the kinds of way running
// through it
Ground :: struct {
	surface:   Surface,
	elevation: u8,
	trees:     u8,
	moisture:  u8,
	ways:      bit_set[Way_Kind;u8],
}

// A drawing: what it shows, in whose style
Picture :: struct {
	icon:    Icon,
	culture: Culture,
}

// Something standing on the map
Token :: struct {
	// What names it in commands
	handle:  Piece_Id,
	// Where its middle stands, in cells
	pos:     [2]f32,
	picture: Picture,
	// Written under it, unless empty
	label:   string,
	flags:   bit_set[Token_Flag;u8],
}

Token_Flag :: enum u8 {
	// It is the focus given to present
	Focused,
}

// A set of cells within the AREA_SIZE square whose top left cell is corner, drawn in its look. An area with no cells in
// it shows nothing.
Area :: struct {
	// Bumped whenever its cells, its look or where it lies change
	revision: u32,
	look:     u8,
	// It lies on water, rather than on land
	on_water: bool,
	corner:   [2]int,
	// Per cell of the square, row by row, whether it is in the area
	cells:    [AREA_SIZE * AREA_SIZE]bool,
}

// Where a card sits beside the map
Card_Place :: enum u8 {
	// The state of play as a whole
	Status,
	// The focus
	Focus,
}

// A card: its title, headed by its picture if it has one, then its fields, then the actions it offers
Card :: struct {
	place:   Card_Place,
	title:   string,
	picture: Maybe(Picture),
	fields:  [dynamic; CARD_FIELDS_MAX]Field,
	actions: [dynamic; CARD_ACTIONS_MAX]Action,
}

// A named value on a card
Field :: struct {
	label: string,
	value: string,
}

// Something a card offers to do: taking it sends its command, unless it is disabled
Action :: struct {
	label:   string,
	command: Command,
	enabled: bool,
}

// Procedures -----------------------------------------------------------------------------------------------------------

// Readies the world; call once, before load.
init :: proc() {
	world_init()
}

// Starts the world from a scenario, on its first turn, with the test pieces. If a layer is missing, the world is left
// all water, so the failure shows, and false is returned.
load :: proc(scenario: Scenario) -> bool {
	return world_load(scenario)
}

// Applies the commands in order, then moves what is walking on by walk_distance, in cells.
step :: proc(commands: []Command, walk_distance: f32) {
	world_step(commands, walk_distance)
}

// Fills out with what the world shows, around the focus: its token focused, where it can reach while it is not
// walking, and its card. A nil focus is none.
present :: proc(focus: Piece_Id, out: ^Scene) {
	world_present(focus, out)
}
