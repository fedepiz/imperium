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

// What a land cell mostly is, which sets how hard it is to cross. Each land cell has one, and how strongly it has it;
// open land has none.
Terrain_Type :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
	// Mountain country
	Highland,
	// Too high to cross but by road
	Mountains,
	// Open, well-watered land: fields and pasture
	Fields,
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

// Where a piece can walk, each with its own ways across the world
Pathfind_Domain :: enum {
	Land,
	Sea,
}

// Radius in cells, 0 for none, and the movement domains it reaches
Contact :: struct {
	radius:  f32,
	domains: bit_set[Pathfind_Domain],
}

// What a piece can do in an interaction with a piece it walked to, and what can be done to it there
Piece_Trait :: enum u8 {
	// It can conquer a piece that can be captured
	Captures,
	// A piece that captures can conquer it
	Capturable,
}

// Which region of the map a cell lies in: 1 for the scenario's first region, 0 for none
Region_Id :: distinct u16

// The most regions a scenario can have
REGIONS_MAX :: 4096

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
	surface:      []Surface,
	elevation:    []u8,
	trees:        []u8,
	moisture:     []u8,
	// For each way kind, the id of the way through each cell, 0 for none
	ways:         [Way_Kind][]u16,
	// The region each cell lies in, 0 for none, and each region's name, from region 1. Water lies in no region.
	regions:      []Region_Id,
	region_names: []string,
	// The factions, in the order they play, and the pieces the world starts with
	factions:     []Scenario_Faction,
	pieces:       []Scenario_Piece,
	// What a scene's caches held in an earlier run, or empty. Each is taken only if its fingerprint matches what the
	// world would derive it from now; otherwise it is derived again.
	cached_files: [Cached_File_Id]Cached_File,
}

// A faction as the world starts with it
Scenario_Faction :: struct {
	name:    string,
	culture: Culture,
	// What it holds is shown in
	color:   [4]f32,
}

// A piece as the world starts with it. Its owner is an index into the scenario's factions; any other owner is none.
Scenario_Piece :: struct {
	// May be empty
	name:              string,
	owner:             int,
	// Where it stands, in cells
	pos:               [2]f32,
	icon:              Icon,
	culture:           Culture,
	// Nil for a piece that does not walk
	movement_domain:   Maybe(Pathfind_Domain),
	// The cost it can spend walking each turn
	movement_per_turn: f32,
	contact:           Contact,
	// Radius in cells; no other piece stops overlapping it
	body:              f32,
	traits:            bit_set[Piece_Trait;u8],
	// The region it is the capital of, 0 for none. A region has at most one.
	capital_of:        Region_Id,
}

// What the world can save between runs, to spare deriving it at load
Cached_File_Id :: enum {
	Pathfind_Land,
	Pathfind_Sea,
}

// Bytes the world derived, stamped with a fingerprint of what they were derived from. Where they are kept is up to the
// caller; the world only reads them from a scenario and shows them in a scene.
Cached_File :: struct {
	fingerprint: u64,
	data:        []byte,
}

// What is asked of the world, applied in order by step
Command :: union {
	Move_Focus_To_Point,
	Move_Focus_To_Piece,
	End_Turn,
	Conquer,
	Leave_Interaction,
}

// The focus, as last presented, walks to the destination, in cells, along the cheapest way there within the reach
// shown. When it cannot walk there this turn, it walks instead to the nearest cell it can, looked for in the square
// snap cells on a side around the destination: see pathfind_flood_stop. Rejected, leaving what is walking as it was,
// if there is none, as always with snap 0, or if the focus cannot walk or does not take orders.
Move_Focus_To_Point :: struct {
	destination: [2]f32,
	snap:        int,
}

// The focus, as last presented, walks to where the target stands, as Move_Focus_To_Point. Reaching a target of
// another faction opens an interaction with it, and no piece takes orders until the interaction is closed.
Move_Focus_To_Piece :: struct {
	target: Piece_Id,
}

// The player's faction ends its part of the turn, and the next faction plays. Rejected unless the turn could end as
// last presented: nothing walking and no interaction open.
End_Turn :: struct {}

// The open interaction's piece takes the one it met for its faction, closing the interaction. Rejected unless an
// interaction is open and it can conquer: see Piece_Trait.
Conquer :: struct {}

// Closes the open interaction, doing nothing. Rejected unless an interaction is open.
Leave_Interaction :: struct {}

// Out -----------------------------------------------------------------------------------------------------------------
// Out: what the world shows, laid out for what draws it

// How many pawns, arrows, points along arrows, areas and cards a scene holds
PAWNS_MAX :: PIECE_MAX
ARROWS_MAX :: 64
ARROW_POINTS_MAX :: 4096
AREAS_MAX :: 16
CIRCLES_MAX :: 512
CARDS_MAX :: 8
// How many fields and actions a card holds
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4
// The side of the square of cells an area lies within
AREA_SIZE :: PATHFIND_FLOOD_SIZE

// What the world shows: the ground, the pawns standing on it, the arrows and areas over it, and the cards beside it.
// Filled by present; what it holds lasts until the next present.
Scene :: struct {
	// Every cell's ground. Rewritten only when the world's ground changes, which bumps ground_revision.
	ground:          [CELLS_MAX]Ground,
	ground_revision: u32,
	pawns:           [dynamic; PAWNS_MAX]Pawn,
	// Each arrow is a run of arrow_points, from its tail to its head
	arrows:          [dynamic; ARROWS_MAX]span.Span,
	arrow_points:    [dynamic; ARROW_POINTS_MAX][2]f32,
	areas:           [AREAS_MAX]Area,
	// The areas' circles; each area's are a run of them
	circles:         [dynamic; CIRCLES_MAX]Circle,
	cards:           [dynamic; CARDS_MAX]Card,
	// Each region, from region 1
	regions:         [dynamic; REGIONS_MAX]Region,
	// What the world holds that can be saved, to hand back in a later scenario. Worth saving when the fingerprint is not
	// that of the saved one.
	caches:          [Cached_File_Id]Cached_File,
}

// A cell as it lies: what covers it, how high, wooded and wet it is, from 0 to 255, and the kinds of way running
// through it
Ground :: struct {
	surface:       Surface,
	elevation:     u8,
	trees:         u8,
	moisture:      u8,
	ways:          bit_set[Way_Kind;u8],
	type:          Terrain_Type,
	// From 0 to 255
	type_strength: u8,
	region:        Region_Id,
}

// A region of the map: its name, and the colour it is shown in, as the colouring mode has it
Region :: struct {
	name:        string,
	color:       [4]f32,
	// It is pointed at, in a mode that highlights, while no reach is shown
	highlighted: bool,
}

// What colour regions are shown in
Region_Colouring_Mode :: enum u8 {
	// Its capital's faction's
	Owner,
	// Its own, apart from its neighbours'
	Identity,
	// All one colour, never highlighted
	Muted,
}

// A drawing: what it shows, in whose style
Picture :: struct {
	icon:    Icon,
	culture: Culture,
}

// Something standing on the map
Pawn :: struct {
	// What names it in commands
	handle:  Piece_Id,
	// Where its middle stands, in cells
	pos:     [2]f32,
	picture: Picture,
	// Written under it, unless empty
	label:   string,
	flags:   bit_set[Pawn_Flag;u8],
}

Pawn_Flag :: enum u8 {
	// It is the focus given to present
	Focused,
	// The player can give it orders: it is the player's, and no interaction is open
	Controlled,
}

// Cells within the AREA_SIZE square whose top left cell is corner, and circles, drawn in its look. Circles are drawn
// exactly, over every area's cells, in slot order.
Area :: struct {
	// Changes whenever its cells, corner, surface or circles change; 0 while it has neither cells nor circles
	revision: u64,
	look:     u8,
	// It lies on water, rather than on land
	on_water: bool,
	corner:   [2]int,
	// Per cell of the square, row by row, whether it is in the area
	cells:    [AREA_SIZE * AREA_SIZE]bool,
	// Its run of the scene's circles
	circles:  span.Span,
}

// In cells
Circle :: struct {
	center: [2]f32,
	radius: f32,
}

// Where a card sits beside the map
Card_Place :: enum u8 {
	// The state of play as a whole
	Status,
	// The focus
	Focus,
	// The open interaction, which orders wait on
	Interaction,
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

// Starts a fresh world from a scenario, on its first turn, with its factions and pieces. If a layer is missing, the world is left
// all water, so the failure shows, and false is returned.
load :: proc(scenario: Scenario) -> bool {
	return world_load(scenario)
}

// Applies the commands in order, then moves what is walking on by walk_distance, in cells.
step :: proc(commands: []Command, walk_distance: f32) {
	world_step(commands, walk_distance)
}

// Fills out with what the world shows, around the focus: its pawn focused, where it can reach while it is not
// walking, and its card; the open interaction's card; the regions coloured as the mode has them; and the pointed region
// highlighted while that reach is not shown, unless the mode is muted. A nil focus or pointed region is none.
present :: proc(focus: Piece_Id, pointed: Region_Id, region_colouring: Region_Colouring_Mode, out: ^Scene) {
	world_present(focus, pointed, region_colouring, out)
}
