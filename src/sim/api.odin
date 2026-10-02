package sim

import "../span"

// The world ----------------------------------------------------------------------------------------------------------

// In cells. Cell index = y * WORLD_WIDTH + x.
WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT
WORLD_SIZE :: [2]int{WORLD_WIDTH, WORLD_HEIGHT}

Surface :: enum u8 {
	Land,
	Lake,
	Sea,
}

WATER :: bit_set[Surface]{.Lake, .Sea}

// One cell wide, over land. The sim treats way cells as land; the map draws ways as lines.
Way_Kind :: enum u8 {
	River,
	Road,
}

// Dominant terrain of a land cell; sets movement cost
Terrain_Type :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
	Highland,
	// Impassable except by road
	Mountains,
	// Well-watered open land
	Fields,
}

// Each has its own drawing style
Culture :: enum u8 {
	Roman,
	Germanic,
}

// Visual only: don't use it to decide what a piece can do (use traits).
Icon :: enum u8 {
	Village,
	Town,
	City,
	Large_City,
	Army,
	Fleet,
}

Pathfind_Domain :: enum {
	Land,
	Sea,
}

// Radius in cells, 0 = none
Contact :: struct {
	radius:  f32,
	domains: bit_set[Pathfind_Domain],
}

Piece_Trait :: enum u8 {
	// Can conquer Capturable pieces
	Captures,
	Capturable,
}

Army :: struct {
	// False = no army
	active:           bool,
	// Men
	strength_current: int,
	strength_max:     int,
	// Troop quality, 0..100
	proficiency:      f32,
	// Fatigue, 0..100 (100 = fully rested)
	readiness:        f32,
	// Skill at living off the land, 0..100; times the terrain's yield, it's what foraging brings in
	foraging:         f32,
	// Food carried, in turns of the army's needs, 0..baggage. Supply level = stock / baggage; readiness can't
	// exceed it.
	stock:            f32,
	baggage:          f32,
	// Stock change at the end of its faction's turn, before marching, in turns. Live for the player's armies;
	// others keep the value from their own last turn.
	resupply:            f32,
	// Share of what the place can deliver that reaches this army, 0..1: own men / nearby friendly men. Updated
	// with resupply.
	resupply_efficiency: f32,
}

// 0 = none, 1 = scenario's first region
Region_Id :: distinct u16

REGIONS_MAX :: 4096

// Slot index and generation. Even generation (including the zero id) = nil.
Piece_Id :: struct {
	index:      u16,
	generation: u16,
}

// In ------------------------------------------------------------------------------------------------------------------

// Initial world state. A cell layer whose length isn't CELLS_MAX is treated as missing.
Scenario :: struct {
	surface:         []Surface,
	elevation:       []u8,
	trees:           []u8,
	moisture:        []u8,
	// Per kind, per cell: way id, 0 = none
	ways:            [Way_Kind][]u16,
	// Per cell, 0 = none (water). Names start at region 1.
	regions:         []Region_Id,
	region_names:    []string,
	// Factions in turn order
	factions:        []Scenario_Faction,
	character_names: []string,
	pieces:          []Scenario_Piece,
	// From a previous run, or empty. Used only if the fingerprint matches; otherwise rebuilt.
	cached_files:    [Cached_File_Id]Cached_File,
}

Scenario_Faction :: struct {
	name:    string,
	culture: Culture,
	color:   [4]f32,
}

Scenario_Piece :: struct {
	// May be empty
	name:              string,
	// Index into factions; out of range = none
	owner:             int,
	// In cells
	pos:               [2]f32,
	icon:              Icon,
	culture:           Culture,
	// Nil = can't move
	movement_domain:   Maybe(Pathfind_Domain),
	// Movement points per turn
	movement_per_turn: f32,
	contact:           Contact,
	// Radius in cells; other pieces can't stop overlapping it
	body:              f32,
	// Movement cost multiplier inside its contact zone for enemies (off-road cost × hindrance)
	hindrance:         f32,
	// Supply source value, 0..100; 0 = not a source
	supply:            f32,
	traits:            bit_set[Piece_Trait;u8],
	// 0 = none. At most one capital per region.
	capital_of:        Region_Id,
	// 1-based index into character_names, 0 = none
	general:           int,
	army:              Army,
}

// Derived data saved between runs to speed up loading
Cached_File_Id :: enum {
	Pathfind_Land,
	Pathfind_Sea,
}

// fingerprint = hash of the inputs it was derived from. The caller stores it.
Cached_File :: struct {
	fingerprint: u64,
	data:        []byte,
}

// Fixed sim rate, independent of frame rate
STEPS_PER_SECOND :: 60
STEP_SECONDS :: 1.0 / f32(STEPS_PER_SECOND)

// Each field is read by one phase of world_step, in fixed order
Step_Input :: struct {
	// Selected piece: its reach is flooded, and order moves it
	focus:    Piece_Id,
	order:    Order,
	conquer:  bool,
	leave:    bool,
	end_turn: bool,
}

Order :: union {
	Move_Focus_To_Point,
	Move_Focus_To_Piece,
}

Card_Ask :: enum u8 {
	// Ignored while walking or in an interaction
	End_Turn,
	// Ignored unless the open interaction is conquerable
	Conquer,
	Leave_Interaction,
}

// If destination is out of reach, walks to the nearest reachable cell within a snap-sized square (see
// pathfind_flood_stop). Ignored if there is none, or the focus can't take orders.
Move_Focus_To_Point :: struct {
	// In cells
	destination: [2]f32,
	snap:        int,
}

// Reaching a piece of another faction opens an interaction, which blocks orders until closed
Move_Focus_To_Piece :: struct {
	target: Piece_Id,
}

// Out -----------------------------------------------------------------------------------------------------------------

PAWNS_MAX :: PIECE_MAX
ARROWS_MAX :: 64
ARROW_POINTS_MAX :: 4096
AREAS_MAX :: 16
CIRCLES_MAX :: 512
CARDS_MAX :: 8
CARD_FIELDS_MAX :: 16
CARD_ACTIONS_MAX :: 4
// Side of an area's square, in cells
AREA_SIZE :: PATHFIND_FLOOD_SIZE

// Filled by present; valid until the next present
Scene :: struct {
	// Rewritten only when ground_revision changes
	ground:              [CELLS_MAX]Ground,
	ground_revision:     u32,
	// The playing faction's supply map, 0..100 per cell. Rewritten only when supply_map_revision changes.
	supply_map:          [CELLS_MAX]u8,
	supply_map_revision: u32,
	pawns:               [dynamic; PAWNS_MAX]Pawn,
	// Ranges of arrow_points, tail to head
	arrows:              [dynamic; ARROWS_MAX]span.Span,
	arrow_points:        [dynamic; ARROW_POINTS_MAX][2]f32,
	areas:               [AREAS_MAX]Area,
	circles:             [dynamic; CIRCLES_MAX]Circle,
	cards:               [dynamic; CARDS_MAX]Card,
	// Index 0 = region 1
	regions:             [dynamic; REGIONS_MAX]Region,
	// Save when the fingerprint differs from the saved one
	caches:              [Cached_File_Id]Cached_File,
}

Ground :: struct {
	surface:       Surface,
	// 0..255
	elevation:     u8,
	trees:         u8,
	moisture:      u8,
	ways:          bit_set[Way_Kind;u8],
	type:          Terrain_Type,
	// 0..255
	type_strength: u8,
	region:        Region_Id,
}

Region :: struct {
	name:        string,
	color:       [4]f32,
	// Hovered, no reach shown, and mode isn't Muted
	highlighted: bool,
}

Region_Colouring_Mode :: enum u8 {
	// Capital's faction colour
	Owner,
	// Distinct from neighbours
	Identity,
	// One colour, never highlighted
	Muted,
}

Picture :: struct {
	icon:    Icon,
	culture: Culture,
}

Pawn :: struct {
	handle:  Piece_Id,
	// Centre, in cells
	pos:     [2]f32,
	picture: Picture,
	// Empty = none
	label:   string,
	flags:   bit_set[Pawn_Flag;u8],
}

Pawn_Flag :: enum u8 {
	Focused,
	// Player's piece, and no interaction open
	Controlled,
}

// Cells in an AREA_SIZE square at corner, plus exact circles. Drawn in slot order; circles over all cells.
Area :: struct {
	// Changes with any content; 0 = empty
	revision: u64,
	look:     u8,
	on_water: bool,
	corner:   [2]int,
	// Row-major
	cells:    [AREA_SIZE * AREA_SIZE]bool,
	// Range of Scene.circles
	circles:  span.Span,
}

// In cells
Circle :: struct {
	center: [2]f32,
	radius: f32,
}

Card_Place :: enum u8 {
	// Turn, player
	Status,
	Focus,
	Interaction,
}

Card :: struct {
	place:   Card_Place,
	title:   string,
	picture: Maybe(Picture),
	// Facts that rarely change
	fields:  [dynamic; CARD_FIELDS_MAX]Field,
	// Values that change from turn to turn; shown beside fields
	stats:   [dynamic; CARD_FIELDS_MAX]Field,
	actions: [dynamic; CARD_ACTIONS_MAX]Action,
}

Field :: struct {
	label: string,
	value: string,
}

Action :: struct {
	label:   string,
	ask:     Card_Ask,
	enabled: bool,
}

// Procedures -----------------------------------------------------------------------------------------------------------

// Call once, before load
init :: proc() {
	world_init()
}

// On a missing layer the world is all water and false is returned
load :: proc(scenario: Scenario) -> bool {
	return world_load(scenario)
}

// Advances the sim by STEP_SECONDS
step :: proc(input: Step_Input) {
	world_step(input)
}

// Fills out for drawing. focus and pointed may be nil.
present :: proc(
	focus: Piece_Id,
	pointed: Region_Id,
	region_colouring: Region_Colouring_Mode,
	out: ^Scene,
) {
	world_present(focus, pointed, region_colouring, out)
}
