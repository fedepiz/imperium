package main

import "core:fmt"
import img "core:image"
import _ "core:image/png"
import "core:math/linalg"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"

import tbl "tabula"

MAP_WIDTH :: 1024
MAP_HEIGHT :: 1024
MAP_SIZE: [2]int : {MAP_WIDTH, MAP_HEIGHT}
MAP_CELLS :: MAP_WIDTH * MAP_HEIGHT

NAME_CAPACITY :: 64
DESCRIPTION_CAPACITY :: 512

WAY_PER_TYPE_MAX :: 256
WAY_LENGTH_MAX :: 1024
WAY_MAX_STEPS_PER_TYPE :: WAY_LENGTH_MAX * 4

// Rivers: wide curves
RIVER_SMOOTHING :: Polyline_Smoothing {
	cut_iter  = 3,
	cut_ratio = 0.25,
}
// Roads: straight, tight bends
ROAD_SMOOTHING :: Polyline_Smoothing {
	cut_iter  = 2,
	cut_ratio = 0.25,
	cut_max   = 1.5,
}
SEA_LANE_SMOOTHING :: Polyline_Smoothing {
	cut_iter  = 4,
	cut_ratio = 0.25,
}

RIVER_DIST_MAX :: 12
ROAD_DIST_MAX :: 1.5

// Movement cost of entering a cell, by its cover. 0: impassable
@(rodata)
MOVE_COSTS := [Render_Cover]f32 {
	.Open      = 1,
	.Forest    = 2,
	.Desert    = 1.5,
	.Steppe    = 1,
	.Fertile   = 1,
	.Marsh     = 2.5,
	.Highland  = 3,
	.Mountains = 0,
	.Fields    = 1,
}
// Entering a road cell, whatever its cover
ROAD_COST :: 0.4
// A road crosses the cells whose centre is this near it: half a cell's diagonal
ROAD_CELL_REACH :: 0.71
#assert(ROAD_CELL_REACH <= ROAD_DIST_MAX)
BASIN_DIST_MAX :: 24

REGIONS_MAX :: 256
PIECE_MAX :: 1024
FACTIONS_MAX :: 16
CHARACTERS_MAX :: 1024
FACTION_CHARACTERS_MAX :: 128
BUILDING_KINDS_MAX :: 64
CULTURES_MAX :: 16
ARMY_TYPES_MAX :: 32
ARMY_TRAITS_MAX :: 64
TOWN_SLOTS_MAX :: 8
// The main building's slot follows the ordinary ones
MAIN_SLOT :: TOWN_SLOTS_MAX
TOWN_SLOT_COUNT :: TOWN_SLOTS_MAX + 1
BEACHES_MAX :: 128
SEA_LANES_MAX :: 256
SEA_LANE_POINTS_MAX :: 1 << 14
// Armies this near a beach stand at it
BEACH_RADIUS :: 2.5
OFFICE_KINDS_MAX :: 64
// The most offices one faction's court shows
FACTION_OFFICES_MAX :: 64
OFFICES_MAX :: FACTIONS_MAX * FACTION_OFFICES_MAX
CULTURE_NAMES_MAX :: 256
// Per vacancy: new characters are made up to MIN, and at most MAX shown
CANDIDATES_MIN :: 3
CANDIDATES_MAX :: 5
PASSED_OVER_LOYALTY :: 10
FEUDAL_DISMISSAL_LOYALTY :: 10

ARMY_FORAGING_DEFAULT :: 40
ARMY_AGILITY_DEFAULT :: 2

Game :: struct {
	terrain:            Terrain,
	regions:            [REGIONS_MAX]Region,
	pieces:             Slot_Map(Piece_Data, PIECE_MAX, Piece_Id),
	step:               int,
	factions:           [dynamic; FACTIONS_MAX]Faction,
	characters:         [dynamic; CHARACTERS_MAX]Character,
	building_kinds:     [dynamic; BUILDING_KINDS_MAX]Building_Kind,
	cultures:           [dynamic; CULTURES_MAX]Culture,
	culture_buildings:  [CULTURES_MAX][BUILDING_KINDS_MAX]bool,
	// 0: none
	army_traits:        [dynamic; ARMY_TRAITS_MAX]Army_Trait,
	army_types:         [dynamic; ARMY_TYPES_MAX]Army_Type,
	// pieces.txt's army kind
	army_template:      Piece_Data,
	turn:               int,
	player:             Faction_Id,
	ending:             bool,
	// Each step, once battle and movement are done. Can_move: no battle, not ending. Endable: nothing under way, and no
	// vacancy
	under_way:          bit_set[Under_Way],
	can_move:           bool,
	endable:            bool,
	contacts:           [dynamic; CONTACTS_MAX]Contact,
	interaction:        Interaction,
	movement:           Movement,
	supply_network:     [MAP_CELLS]u8,
	// The playing faction's, 0..100
	control_network:    [MAP_CELLS]u8,
	// 0: none
	beaches:            [dynamic; BEACHES_MAX]Beach,
	// 0: none
	sea_lanes:          [dynamic; SEA_LANES_MAX]Sea_Lane,
	// Run l - 1: lane l's, from its from beach
	sea_lane_curves:    Polylines(SEA_LANE_POINTS_MAX, SEA_LANES_MAX),
	office_kinds:       [dynamic; OFFICE_KINDS_MAX]Office_Kind,
	offices:            Slot_Map(Office, OFFICES_MAX, Office_Id),
	// Each step: highest rank first, a faction's own offices first within a rank
	offices_ranked:     [dynamic; OFFICES_MAX]Office_Id,
	appointment:        Appointment,
}

Under_Way :: enum u8 {
	March,
	Contact,
	Battle,
	Ending,
}

Beach_Id :: distinct u8

Sea_Lane_Id :: distinct u8

Beach :: struct {
	id:     Name,
	pos:    [2]f32,
	region: Region_Id,
}

Sea_Lane :: struct {
	from:   Beach_Id,
	to:     Beach_Id,
	// In cells, along its curve
	length: f32,
}

Region_Id :: distinct u8

Piece_Id :: distinct Slot_Map_Key

Faction_Id :: distinct u8

Character_Id :: distinct u16

Name :: struct {
	buffer: [NAME_CAPACITY]u8,
}

Piece_Flag :: enum {
	Captures,
	Capturable,
	Can_Enter,
	Can_Contain,
	Has_Army,
	Fortified,
	Shares_Supply,
	Has_Town,
}

Piece_Data :: struct {
	flags:             bit_set[Piece_Flag],
	name:              Name,
	pos:               [2]f32,
	icon:              Map_Icon,
	culture:           Culture_Id,
	owner:             Faction_Id,
	general:           Character_Id,
	domain:            Maybe(Pathfind_Domain),
	movement_per_turn: f32,
	this_turn:         Piece_Turn,
	contact_radius:    f32,
	contact_domains:   bit_set[Pathfind_Domain],
	body_radius:       f32,
	hindrance:         f32,
	supply_production: f32,
	inside:            Piece_Id,
	contains:          Piece_Id,
	army:              Army,
	town:              Town,
}

Army_Status :: enum u8 {
	Spent,
	// After a still turn outside enemy zones, until it moves or fights
	Resting,
	// After a voyage, until a turn without one
	Seasick,
}

Army_Modifiers :: struct {
	agility:            f32,
	// Points a turn
	movement:           f32,
	// A turn, when not resting
	readiness_recovery: f32,
	prevent_status:     bit_set[Army_Status],
}

army_modifiers_combine :: proc(a, b: Army_Modifiers) -> Army_Modifiers {
	return {
		agility = a.agility + b.agility,
		movement = a.movement + b.movement,
		readiness_recovery = a.readiness_recovery + b.readiness_recovery,
		prevent_status = a.prevent_status + b.prevent_status,
	}
}

Army_Trait :: struct {
	id:          Name,
	name:        Name,
	modifiers:   Army_Modifiers,
	description: Description,
}

Army :: struct {
	men:               int,
	men_max:           int,
	proficiency:       f32,
	readiness:         f32,
	statuses:          bit_set[Army_Status],
	foraging:          f32,
	agility:            f32,
	readiness_recovery: f32,
	prevent_status:     bit_set[Army_Status],
	// Share of needs met, 0..100
	supply:            f32,
	supply_source:     Supply_Source,
	supply_efficiency: f32,
	// None: a garrison, or its title destroyed
	type:              Army_Type_Id,
	title:             Office_Id,
	// A local army reinforces only there. 0: global
	home:              Region_Id,
	// Each step: its general's
	temperament:       Temperament,
}

Town :: struct {
	population:           f32,
	// Its region's
	fertility:            f32,
	// Its main building's
	slots:                int,
	// The main building last. 0: empty
	buildings:            [TOWN_SLOT_COUNT]Building_Kind_Id,
	projects:             [TOWN_SLOT_COUNT]Project,
	// Each step
	titles:               [TOWN_SLOT_COUNT]Office_Id,
	building_orders:      [TOWN_SLOT_COUNT]Building_Orders,
	// Each step, per turn. Staffing: 0..1, scaling every output
	staff_needed:         f32,
	staffing:             f32,
	slot_food:            [TOWN_SLOT_COUNT]f32,
	food:                 f32,
	food_eaten:           f32,
	// Split by control: the controlled share to the treasury, the rest kept as local wealth
	income:               f32,
	wealth:               f32,
	upkeep:               f32,
	// Global salaries are part of upkeep. The wealth left after local ones is shared by the titles' weights
	salaries_global:      f32,
	salaries_local:       f32,
	wealth_shared:        f32,
	shares:               f32,
	// 0..100: the share of global outputs reaching the pool. Set with the networks
	control:              f32,
	public_order:         f32,
	unrest:               f32,
	// To and from the central store, scaled by control
	food_sent:            f32,
	food_taken:           f32,
	population_supported: f32,
}

Building_Kind_Id :: distinct u8

Building_Flag :: enum u8 {
	// Built in the main slot only, and nothing else is
	Main,
}

Office_Kind_Id :: distinct u8

Office_Id :: distinct Slot_Map_Key

Office_Flag :: enum u8 {
	// Held for life
	Eternal,
	// Once its term is served
	Dismissable,
	// Dismissing one costs every feudal holder of the faction loyalty
	Feudal,
}

Office_Kind :: struct {
	id:           Name,
	name:         Name,
	rank:         int,
	influence:    f32,
	// Turns before its holder can be promoted or dismissed
	term:         int,
	flags:        bit_set[Office_Flag],
	// 0: none
	army_type:    Army_Type_Id,
	// A faction office's, paid out of the treasury
	salary:       f32,
	// A faction office's share of its faction's income, 0..1, paid out of the treasury besides its salary
	income_share: f32,
}

// A building's office elapses when its town is lost, and is destroyed then or once its army leaves the field
Office :: struct {
	kind:         Office_Kind_Id,
	faction:      Faction_Id,
	// "Kind of Town", or a faction office's kind name
	title:        Name,
	// None: a faction office
	town:         Piece_Id,
	slot:         int,
	building:     Building_Kind_Id,
	holder:       Character_Id,
	term_left:    int,
	// While demobilised; while mobilised the army has them
	men:          int,
	// Each step: its town held by another faction
	elapsed:      bool,
	// None: demobilised
	army:         Piece_Id,
	// Each step. Wealth: paid to its holder per turn, 0 while vacant or elapsed. Men_max: wealth times the type's rate
	wealth:       f32,
	men_max:      int,
	// Each step. Muster_at: its town, or its faction's capital
	muster_at:    Piece_Id,
	dismissal:    Office_Dismissal,
	can_mobilise: bool,
}

// Each step. Offered: what fits and the culture builds. Buildable: of those, what can be ordered now
Building_Orders :: struct {
	offered:   bit_set[0 ..< BUILDING_KINDS_MAX],
	buildable: bit_set[0 ..< BUILDING_KINDS_MAX],
	demolish:  bool,
	cancel:    bool,
}

Office_Dismissal :: enum u8 {
	Allowed,
	For_Life,
	Not_Dismissable,
	In_Term,
	// Not its faction's turn, or something under way
	Not_Now,
}

Project :: struct {
	active:     bool,
	// 0: demolishing
	kind:       Building_Kind_Id,
	turns_left: f32,
}

Culture_Id :: distinct u8

Army_Type_Id :: distinct u8

// Local: tied to the home region it was mobilised in
Army_Scope :: enum u8 {
	Global,
	Local,
}

Army_Type :: struct {
	id:          Name,
	name:        Name,
	scope:       Army_Scope,
	men_per_wealth: f32,
	// At full strength
	proficiency: f32,
	foraging:    f32,
	agility:     f32,
	traits:      bit_set[0 ..< ARMY_TRAITS_MAX],
	description: Description,
}

Culture :: struct {
	id:    Name,
	name:  Name,
	look:  Culture_Look,
	names: [dynamic; CULTURE_NAMES_MAX]Name,
}

// Each step. None: every office is held
Appointment :: struct {
	office:      Office_Id,
	candidates:  [dynamic; CANDIDATES_MAX]Candidate,
	can_appoint: bool,
}

// Passed over: the candidates above him, ranked higher
Candidate :: struct {
	character:   Character_Id,
	passed_over: int,
}

// Effects per turn. A negative flow is consumed
Building_Kind :: struct {
	id:             Name,
	name:           Name,
	// Staff it needs
	population:     f32,
	food:           f32,
	// Times its town's fertility
	food_fertility: f32,
	income:         f32,
	upkeep:         f32,
	// Radiated over the land, less travel cost. A town sums what reaches it, up to 100
	control:        f32,
	// Negative: unrest
	public_order:   f32,
	// Into the central store, scaled by control. Negative: taken out of it
	food_store:     f32,
	// Paid to its title's holder: global from the treasury, local from its town's wealth. Share: its weight in what is left
	title_salary_global:      f32,
	title_salary_local:       f32,
	title_salary_local_share: f32,
	flags:          bit_set[Building_Flag],
	// Named after its town. 0: none
	title:          Office_Kind_Id,
	// A main building's, copied onto its settlement
	icon:           Map_Icon,
	slots:          int,
	supply:         f32,
	hindrance:      f32,
	contact:        f32,
	body:           f32,
	build_coin:     f32,
	build_turns:    f32,
	description:    Description,
	// 0: none. Upgraded_from 0: a chain's first level
	upgrade:        Building_Kind_Id,
	upgraded_from:  Building_Kind_Id,
}

Piece_Turn :: struct {
	attacked:      bool,
	moved_land:    bool,
	moved_sea:     bool,
	fought:        bool,
	// From its movement per turn at each turn change
	movement_left: f32,
}

Supply_Source :: enum u8 {
	Network,
	Foraging,
}

Faction :: struct {
	name:       Name,
	culture:    Culture_Id,
	color:      [3]f32,
	treasury:   f32,
	food_store: f32,
	// Where its own offices' armies mobilise
	capital:    Piece_Id,
	// Each step. Stability 0..100: loyalty weighted by influence
	stability:  f32,
	characters: int,
	// Each step, per turn
	income:     f32,
	upkeep:     f32,
	food_sent:  f32,
	food_taken: f32,
}

Character :: struct {
	name:        Name,
	faction:     Faction_Id,
	// In turns
	age:         int,
	// Never lowered
	rank:        int,
	influence:   f32,
	// 0..100
	loyalty:     f32,
	temperament: Temperament,
	background:  Background,
	disposition: Disposition,
	// Each step
	office:           Office_Id,
	influence_target: f32,
}

Background :: enum u8 {
	Soldier,
	Official,
	Aristocrat,
	Courtier,
	Churchman,
	Federate,
}

Disposition :: enum u8 {
	Ambitious,
	Devout,
	Proud,
	Greedy,
	Loyal,
}

Way_Type :: enum {
	River,
	Road,
}

name_from_string :: proc(txt: string) -> (name: Name, ok: bool) #optional_ok {
	count := copy_from_string(name.buffer[:], txt)
	ok = count == len(txt)
	return
}

name_to_string :: proc(name: ^Name) -> string {
	return strings.truncate_to_byte(string(name.buffer[:]), 0)
}

Description :: struct {
	buffer: [DESCRIPTION_CAPACITY]u8,
}

description_from_string :: proc(txt: string) -> (description: Description, ok: bool) #optional_ok {
	count := copy_from_string(description.buffer[:], txt)
	ok = count == len(txt)
	return
}

description_to_string :: proc(description: ^Description) -> string {
	return strings.truncate_to_byte(string(description.buffer[:]), 0)
}

Region :: struct {
	id:        Name,
	name:      Name,
	color:     [3]u8,
	capital:   Piece_Id,
	// 1 poor .. 4 rich
	fertility: f32,
	// Each step: its capital's owner. 0: none
	owner:     Faction_Id,
}

// Out: game, geography
game_load :: proc(
	game: ^Game,
	scenario_name: string,
	geo_out: ^Render_Geography,
) -> (
	success: bool,
) {
	success = true

	// Load regions from tabula file
	{
		root, _ := scenario_file(scenario_name, "regions.txt")

		assert(len(root.children) < REGIONS_MAX - 1)
		for idx in 0 ..< len(root.children) {
			entry := root.children[idx]
			assert(entry.key == "region")

			id := tbl.get_text(entry, "id")
			name := tbl.get_text(entry, "name")
			colors := tbl.get_num_array(entry, "color", 3)

			region: ^Region = &game.regions[idx + 1]
			region.id = name_from_string(id)
			region.name = name_from_string(name)
			region.color = linalg.array_cast(colors, u8)
			region.fertility = tbl.get_num(entry, "fertility")
		}
	}

	// Populate the region map
	region_by_color := make_map_cap(map[[3]u8]Region_Id, REGIONS_MAX, context.temp_allocator)
	for i in 0 ..< len(game.regions) {
		region := game.regions[i]
		// Skip unused regions
		if i > 0 && region.color == {} do continue
		map_insert(&region_by_color, region.color, Region_Id(i))
	}

	// Load the raw terrain files
	{
		Entry :: struct {
			name: string,
			buf:  ^[MAP_CELLS]u8,
		}

		entries: []Entry = {
			{"elevation", &game.terrain.elevation},
			{"moisture", &game.terrain.moisture},
			{"trees", &game.terrain.trees},
			{"surface", &game.terrain.surface},
		}

		for entry in entries {
			path := fmt.tprintf("assets/scenarios/%s/%s.png", scenario_name, entry.name)
			success &= load_map_bitmap_one_channel(path, entry.buf)
		}
	}

	// Load region data: the color of each cell's region, until assigned below
	region_colors := new([MAP_CELLS][3]u8, context.temp_allocator)
	{
		path := fmt.tprintf("assets/scenarios/%s/regions.png", scenario_name)
		success &= load_map_bitmap_3_channels(path, region_colors)
	}

	// Process river and road data

	{
		Desc :: struct {
			kind_name:    string,
			smoothing:    Polyline_Smoothing,
			polyline_out: ^Render_Courses,
		}
		descs: []Desc = {
			{kind_name = "rivers", smoothing = RIVER_SMOOTHING, polyline_out = &geo_out.rivers},
			{kind_name = "roads", smoothing = ROAD_SMOOTHING, polyline_out = &geo_out.roads},
		}

		lines_in := new(
			Polylines(WAY_MAX_STEPS_PER_TYPE, WAY_PER_TYPE_MAX),
			context.temp_allocator,
		)

		for desc in descs {
			// Load in the data from the way description file
			root, _ := scenario_file(scenario_name, fmt.tprintf("%s.txt", desc.kind_name))

			polylines_clear(lines_in)

			// Load the data points
			for entry in root.children {
				points_in := tbl.get_children(entry, "points")
				points_out := polylines_reserve(len(points_in), false, lines_in)
				for pt, i in points_in {
					points_out[i] = {pt.children[0].num, pt.children[1].num} + 0.5
				}
			}

			// Perform smoothing: each cut doubles the points
			polylines_clear(desc.polyline_out)
			polylines_smooth(lines_in, desc.smoothing, desc.polyline_out)
		}
	}

	// Calculate signed distance field to river
	ways_sdf := new([Way_Type][MAP_CELLS]f32, context.temp_allocator)
	{
		Desc :: struct {
			lines:   ^Render_Courses,
			reach:   f32,
			offsets: ^[MAP_CELLS][2]f32,
		}

		descs: [Way_Type]Desc = {
			.River = {
				lines = &geo_out.rivers,
				reach = RIVER_DIST_MAX,
				offsets = &geo_out.to_river,
			},
			.Road = {lines = &geo_out.roads, reach = ROAD_DIST_MAX, offsets = &geo_out.to_road},
		}

		for desc, kind in descs {
			offsets := desc.offsets
			reach := max(desc.reach, RENDER_TERRAIN_COURSE_REACH)

			// Must initialise offsets with high value, as the stamp algorithm only
			// *reduces* distances
			for &p in offsets {
				p.x = reach
			}

			polylines_stamp(desc.lines, reach, MAP_SIZE, offsets[:], nil)

			for v, i in offsets {
				ways_sdf[kind][i] = linalg.length(v)
			}
		}
	}

	// Prepare geography
	geo_out.elevation = game.terrain.elevation
	geo_out.moisture = game.terrain.moisture

	// Assign water
	sea_mask := new([MAP_CELLS]bool, context.temp_allocator)
	{
		for x, i in game.terrain.surface {
			geo_out.water[i] = x > 0
			sea_mask[i] = x == 255
		}
	}

	// Calculate distance to sea
	sea_sdf := new([MAP_CELLS]f32, context.temp_allocator)
	distance_transform(sea_mask[:], MAP_SIZE, sea_sdf[:])

	// Calculate basin depth: mean land elevation around each cell, minus its own. > 0 in basins and valleys
	basin := new([MAP_CELLS]f32, context.temp_allocator)
	{
		// Water adds neither elevation nor land, so the mean is over land only
		land_elevation := new([MAP_CELLS]f32, context.temp_allocator)
		land := new([MAP_CELLS]f32, context.temp_allocator)
		for x, i in game.terrain.elevation {
			if geo_out.water[i] do continue
			land_elevation[i] = f32(x) / 255
			land[i] = 1
		}

		elevation_around := new([MAP_CELLS]f32, context.temp_allocator)
		land_around := new([MAP_CELLS]f32, context.temp_allocator)
		box_sum(land_elevation[:], MAP_SIZE, BASIN_DIST_MAX, elevation_around[:])
		box_sum(land[:], MAP_SIZE, BASIN_DIST_MAX, land_around[:])

		// Land only. land_around counts the cell itself, so it is at least 1
		for e, i in land_elevation {
			if land[i] == 0 do continue
			basin[i] = elevation_around[i] / land_around[i] - e
		}
	}

	// Assign regions: each land cell's color looked up among the regions'. Not found: 0, no region
	{
		for color, i in region_colors^ {
			game.terrain.regions[i] = 0
			if geo_out.water[i] do continue
			game.terrain.regions[i] = u8(region_by_color[color])
		}
		geo_out.regions = game.terrain.regions
	}

	// Beaches and sea lanes
	{
		root, path := scenario_file(scenario_name, "sea_lanes.txt")
		lines_in := new(Polylines(SEA_LANE_POINTS_MAX >> uint(SEA_LANE_SMOOTHING.cut_iter), SEA_LANES_MAX), context.temp_allocator)
		append(&game.beaches, Beach{})
		for row in root.children {
			if row.key != "beach" do continue
			row_check(row, Beach, path, {"at"})
			beach := Beach {
				id  = name_from_string(tbl.get_text(row, "id")),
				pos = tbl.get_num_array(row, "at", 2) + 0.5,
			}
			beach.region = Region_Id(game.terrain.regions[grid_index(cell_of(beach.pos), MAP_SIZE)])
			fmt.assertf(append(&game.beaches, beach) == 1, "%s: more than %d beaches", path, BEACHES_MAX - 1)
		}
		append(&game.sea_lanes, Sea_Lane{})
		for row in root.children {
			if row.key != "lane" do continue
			row_check(row, Sea_Lane, path, {"points"})
			lane: Sea_Lane
			ends := [2]string{tbl.get_text(row, "from"), tbl.get_text(row, "to")}
			ids := [2]^Beach_Id{&lane.from, &lane.to}
			for end, e in ends {
				for &beach, b in game.beaches do if b > 0 && name_to_string(&beach.id) == end do ids[e]^ = Beach_Id(b)
				fmt.assertf(ids[e]^ != 0, "%s: no beach %q", path, end)
			}
			points_in := tbl.get_children(row, "points")
			points, fits := polylines_reserve(len(points_in) + 2, false, lines_in)
			fmt.assertf(fits, "%s: more than %d lane points", path, cap(lines_in.points))
			points[0] = game.beaches[lane.from].pos
			for point, i in points_in do points[i + 1] = {point.children[0].num, point.children[1].num} + 0.5
			points[len(points) - 1] = game.beaches[lane.to].pos
			fmt.assertf(append(&game.sea_lanes, lane) == 1, "%s: more than %d lanes", path, SEA_LANES_MAX - 1)
		}
		polylines_clear(&game.sea_lane_curves)
		polylines_smooth(lines_in, SEA_LANE_SMOOTHING, &game.sea_lane_curves)
		polylines_clear(&geo_out.sea_lanes)
		for run, r in game.sea_lane_curves.runs {
			curve := game.sea_lane_curves.points[run.begin:][:run.len]
			lane := &game.sea_lanes[r + 1]
			for i in 1 ..< len(curve) do lane.length += linalg.distance(curve[i - 1], curve[i])
			copy(polylines_reserve(run.len, false, &geo_out.sea_lanes), curve)
		}
	}

	// Classify terrian (Cover)
	for i in 0 ..< MAP_CELLS {
		cell: Render_Cover_Cell
		if !geo_out.water[i] {
			elevation := game.terrain.elevation[i]
			moisture := game.terrain.moisture[i]
			trees := game.terrain.trees[i]

			e := f32(elevation) / 255
			m := f32(moisture) / 255
			t := f32(trees) / 255

			if e >= 0.85 {
				// Mountains: full strength, nothing else scored
				cell = {.Mountains, 255}
			} else {
				low := smoothstep(0.22, 0.12, e)
				// Dry land near a river
				dry_river := smoothstep(0.62, 0.52, m) * smoothstep(5, 1.5, ways_sdf[.River][i])
				// Near both a river and the sea
				delta := smoothstep(6, 2, ways_sdf[.River][i]) * smoothstep(16, 6, sea_sdf[i])
				// Moist land near a river, lower than the land around it
				valley :=
					smoothstep(0.55, 0.65, m) *
					smoothstep(12, 4, ways_sdf[.River][i]) *
					smoothstep(0.02, 0.07, basin[i])
				// Suitability per kind; the best wins, earlier kinds win ties
				suits := [Render_Cover]f32 {
					.Open      = 1.0 / 6,
					.Forest    = smoothstep(0.05, 0.75, t),
					.Desert    = smoothstep(0.47, 0.35, m),
					.Steppe    = smoothstep(0.40, 0.47, m) * smoothstep(0.58, 0.48, m),
					.Fertile   = 1.3 * max(dry_river, valley),
					.Marsh     = 1.5 * low * max(delta, smoothstep(0.80, 0.88, m)),
					.Highland  = 1.2 * smoothstep(0.55, 1.0, e),
					.Mountains = 0,
					.Fields    = 0.6 * smoothstep(0.52, 0.62, m) * smoothstep(0.3, 0.1, t),
				}
				best := Render_Cover.Open
				for suit, kind in suits do if suit > suits[best] do best = kind
				// Open keeps strength 0
				if best != .Open do cell = {best, u8(clamp(suits[best], 0, 1) * 255 + 0.5)}
			}
		}
		geo_out.cover[i] = cell
	}

	// "Flatten" mountains where roads pass
	for &cell, idx in geo_out.cover {
		if cell.kind == .Mountains && ways_sdf[.Road][idx] < ROAD_DIST_MAX do cell.kind = .Highland
	}
	game.terrain.cover = geo_out.cover

	// Cells crossed by a road
	for &road, i in game.terrain.road do road = ways_sdf[.Road][i] < ROAD_CELL_REACH

	// Pathfinding: the cost of entering each cell, by land and by sea
	{
		// Land: by cover, or along a road. Water is impassable
		land := pathfind_grid(.Land)
		for cell, i in geo_out.cover {
			land[i] =
				geo_out.water[i] ? 0 : game.terrain.road[i] ? ROAD_COST : MOVE_COSTS[cell.kind]
		}

		sea := pathfind_grid(.Sea)
		for water, i in geo_out.water do sea[i] = water ? 1 : 0
	}

	// Army traits; 0 is none
	{
		root, path := scenario_file(scenario_name, "army_traits.txt")

		append(&game.army_traits, Army_Trait{})
		for row in root.children {
			assert(row.key == "army_trait")
			row_check(row, Army_Modifiers, path, {"id", "name", "description"})
			id, has_id := tbl.get_text(row, "id")
			name, has_name := tbl.get_text(row, "name")
			description, has_description := tbl.get_text(row, "description")
			fmt.assertf(has_id && has_name && has_description, "%s: a trait lacks its id, name or description", path)

			trait := Army_Trait {
				id = name_from_string(id),
				name = name_from_string(name),
				modifiers = {
					agility = tbl.get_num(row, "agility"),
					movement = tbl.get_num(row, "movement"),
					readiness_recovery = tbl.get_num(row, "readiness_recovery"),
				},
			}
			prevented := tbl.get_children(row, "prevent_status")
			for status in prevented {
				trait.modifiers.prevent_status += {enum_from_text(Army_Status, status.text)}
			}
			description_ok: bool
			trait.description, description_ok = description_from_string(description)
			fmt.assertf(description_ok, "%s: description of %q longer than %d bytes", path, id, DESCRIPTION_CAPACITY)
			fmt.assertf(append(&game.army_traits, trait) == 1, "%s: more than %d traits", path, ARMY_TRAITS_MAX - 1)
		}
	}

	// Army types; 0 is none, with the defaults
	{
		root, path := scenario_file(scenario_name, "army_types.txt")

		append(&game.army_types, Army_Type{foraging = ARMY_FORAGING_DEFAULT, agility = ARMY_AGILITY_DEFAULT})
		for row in root.children {
			assert(row.key == "army_type")
			row_check(row, Army_Type, path, required = true, skipped = {"foraging", "agility", "traits"})

			army_type := Army_Type {
				id          = name_from_string(tbl.get_text(row, "id")),
				name        = name_from_string(tbl.get_text(row, "name")),
				scope       = enum_from_text(Army_Scope, tbl.get_text(row, "scope")),
				men_per_wealth = tbl.get_num(row, "men_per_wealth"),
				proficiency = tbl.get_num(row, "proficiency"),
				foraging    = tbl.get_num(row, "foraging", ARMY_FORAGING_DEFAULT),
				agility     = tbl.get_num(row, "agility", ARMY_AGILITY_DEFAULT),
			}
			traits := tbl.get_children(row, "traits")
			for trait_text in traits {
				trait := 0
				for &each, t in game.army_traits do if t > 0 && name_to_string(&each.id) == trait_text.text do trait = t
				fmt.assertf(trait != 0, "%s: no trait %q", path, trait_text.text)
				army_type.traits += {trait}
			}
			description_ok: bool
			army_type.description, description_ok = description_from_string(tbl.get_text(row, "description"))
			fmt.assertf(description_ok, "%s: description of %q longer than %d bytes", path, tbl.get_text(row, "id"), DESCRIPTION_CAPACITY)
			fmt.assertf(
				append(&game.army_types, army_type) == 1,
				"%s: more than %d army types",
				path,
				ARMY_TYPES_MAX - 1,
			)
		}
	}

	// Office kinds; 0 is none
	{
		root, path := scenario_file(scenario_name, "offices.txt")

		append(&game.office_kinds, Office_Kind{})
		for row in root.children {
			assert(row.key == "office")
			row_check(row, Office_Kind, path)
			office := Office_Kind {
				id           = name_from_string(tbl.get_text(row, "id")),
				name         = name_from_string(tbl.get_text(row, "name")),
				rank         = int(tbl.get_num(row, "rank")),
				influence    = tbl.get_num(row, "influence"),
				term         = int(tbl.get_num(row, "term")),
				salary       = tbl.get_num(row, "salary"),
				income_share = tbl.get_num(row, "income_share"),
			}
			flags := tbl.get_children(row, "flags")
			for flag in flags {
				office.flags += {enum_from_text(Office_Flag, flag.text)}
			}
			if type_text, has_army := tbl.get_text(row, "army_type"); has_army {
				for &army_type, a in game.army_types {
					if a > 0 && name_to_string(&army_type.id) == type_text do office.army_type = Army_Type_Id(a)
				}
				fmt.assertf(office.army_type != 0, "%s: no army type %q", path, type_text)
			}
			fmt.assertf(append(&game.office_kinds, office) == 1, "%s: more than %d office kinds", path, OFFICE_KINDS_MAX - 1)
		}
	}

	// Building kinds; 0 is none
	{
		root, path := scenario_file(scenario_name, "buildings.txt")

		append(&game.building_kinds, Building_Kind{})
		// Upgrades by id, resolved once every kind is in
		upgrades := make([dynamic]string, 0, len(root.children) + 1, context.temp_allocator)
		append(&upgrades, "")
		for row in root.children {
			assert(row.key == "building")
			row_check(row, Building_Kind, path)

			kind := Building_Kind {
				id             = name_from_string(tbl.get_text(row, "id")),
				name           = name_from_string(tbl.get_text(row, "name")),
				population     = tbl.get_num(row, "population"),
				food           = tbl.get_num(row, "food"),
				food_fertility = tbl.get_num(row, "food_fertility"),
				income         = tbl.get_num(row, "income"),
				upkeep         = tbl.get_num(row, "upkeep"),
				control        = tbl.get_num(row, "control"),
				public_order   = tbl.get_num(row, "public_order"),
				food_store     = tbl.get_num(row, "food_store"),
				title_salary_global      = tbl.get_num(row, "title_salary_global"),
				title_salary_local       = tbl.get_num(row, "title_salary_local"),
				title_salary_local_share = tbl.get_num(row, "title_salary_local_share"),
				build_coin     = tbl.get_num(row, "build_coin"),
				build_turns    = tbl.get_num(row, "build_turns"),
				slots          = int(tbl.get_num(row, "slots")),
				supply         = tbl.get_num(row, "supply"),
				hindrance      = tbl.get_num(row, "hindrance"),
				contact        = tbl.get_num(row, "contact"),
				body           = tbl.get_num(row, "body"),
			}
			if icon, has_icon := tbl.get_text(row, "icon"); has_icon do kind.icon = enum_from_text(Map_Icon, icon)
			fmt.assertf(kind.slots <= TOWN_SLOTS_MAX, "%s: more than %d slots", path, TOWN_SLOTS_MAX)
			description_ok: bool
			kind.description, description_ok = description_from_string(tbl.get_text(row, "description"))
			fmt.assertf(description_ok, "%s: description of %q longer than %d bytes", path, tbl.get_text(row, "id"), DESCRIPTION_CAPACITY)
			building_flags := tbl.get_children(row, "flags")
			for flag in building_flags {
				kind.flags += {enum_from_text(Building_Flag, flag.text)}
			}
			if title, titled := tbl.get_text(row, "title"); titled {
				for &office, o in game.office_kinds {
					if o > 0 && name_to_string(&office.id) == title do kind.title = Office_Kind_Id(o)
				}
				fmt.assertf(kind.title != 0, "%s: no office %q", path, title)
			}
			fmt.assertf(
				append(&game.building_kinds, kind) == 1,
				"%s: more than %d building kinds",
				path,
				BUILDING_KINDS_MAX - 1,
			)
			append(&upgrades, tbl.get_text(row, "upgrade"))
		}

		for upgrade, k in upgrades {
			if upgrade == "" do continue
			for &other, o in game.building_kinds {
				if o > 0 && name_to_string(&other.id) == upgrade do game.building_kinds[k].upgrade = Building_Kind_Id(o)
			}
			next := game.building_kinds[k].upgrade
			fmt.assertf(next != 0, "%s: no building %q to upgrade into", path, upgrade)
			game.building_kinds[next].upgraded_from = Building_Kind_Id(k)
		}
	}

	// Cultures; 0 is none
	{
		root, path := scenario_file(scenario_name, "cultures.txt")

		append(&game.cultures, Culture{})
		for row in root.children {
			assert(row.key == "culture")
			culture_id := Culture_Id(len(game.cultures))
			culture := Culture {
				id   = name_from_string(tbl.get_text(row, "id")),
				name = name_from_string(tbl.get_text(row, "name")),
				look = enum_from_text(Culture_Look, tbl.get_text(row, "look")),
			}
			names := tbl.get_children(row, "names")
			for name in names {
				fmt.assertf(append(&culture.names, name_from_string(name.text)) == 1, "%s: more than %d names", path, CULTURE_NAMES_MAX)
			}
			fmt.assertf(
				append(&game.cultures, culture) == 1,
				"%s: more than %d cultures",
				path,
				CULTURES_MAX - 1,
			)

			buildings := tbl.get_children(row, "buildings")
			for building in buildings {
				found := false
				for &kind, k in game.building_kinds {
					if k == 0 || name_to_string(&kind.id) != building.text do continue
					game.culture_buildings[culture_id][k] = true
					found = true
				}
				fmt.assertf(found, "%s: no building %q", path, building.text)
			}
		}
	}

	// Applied once the start step has made the offices
	Holding :: struct {
		character: Character_Id,
		kind:      Office_Kind_Id,
		town:      string,
		men:       int,
	}
	holdings := make([dynamic]Holding, context.temp_allocator)
	Army_Title :: struct {
		army: Piece_Id,
		kind: Office_Kind_Id,
		town: string,
	}
	army_titles := make([dynamic]Army_Title, context.temp_allocator)

	{
		root, path := scenario_file(scenario_name, "pieces.txt")

		Kind :: struct {
			name:  string,
			piece: Piece_Data,
		}
		kinds := make([dynamic]Kind, 0, len(root.children), context.temp_allocator)

		append(&game.factions, Faction{})
		append(&game.characters, Character{})

		for row in root.children {
			switch row.key {
			case "kind":
				kind := Kind {
					name = tbl.get_text(row, "name"),
				}
				piece := &kind.piece
				// A settlement's from its main building
				if icon, has_icon := tbl.get_text(row, "icon"); has_icon do piece.icon = enum_from_text(Map_Icon, icon)
				if moves, moving := tbl.get_text(row, "moves"); moving {
					piece.domain = enum_from_text(Pathfind_Domain, moves)
				}
				piece.movement_per_turn = tbl.get_num(row, "per_turn")
				piece.this_turn.movement_left = piece.movement_per_turn
				piece.contact_radius = tbl.get_num(row, "contact")
				contact_on := tbl.get_children(row, "contact_on")
				for domain in contact_on {
					piece.contact_domains += {enum_from_text(Pathfind_Domain, domain.text)}
				}
				piece.body_radius = tbl.get_num(row, "body")
				piece.hindrance = tbl.get_num(row, "hindrance", 1)
				piece.supply_production = tbl.get_num(row, "supply")
				piece.town.slots = int(tbl.get_num(row, "slots"))
				assert(piece.town.slots <= TOWN_SLOTS_MAX)
				traits := tbl.get_children(row, "traits")
				for flag in traits {
					piece.flags += {enum_from_text(Piece_Flag, flag.text)}
				}
				if kind.name == "army" do game.army_template = kind.piece
				append(&kinds, kind)

			case "faction":
				owner := Faction_Id(len(game.factions))
				culture: Culture_Id
				culture_text := tbl.get_text(row, "culture")
				for &known, c in game.cultures do if c > 0 && name_to_string(&known.id) == culture_text do culture = Culture_Id(c)
				fmt.assertf(culture != 0, "%s: no culture %q", path, culture_text)
				append(
					&game.factions,
					Faction {
						name = name_from_string(tbl.get_text(row, "name")),
						culture = culture,
						color = tbl.get_num_array(row, "color", 3) / 255,
						treasury = tbl.get_num(row, "treasury"),
						food_store = tbl.get_num(row, "food_store"),
					},
				)

				faction_offices := tbl.get_children(row, "offices")
				for name in faction_offices {
					kind: Office_Kind_Id
					for &office, o in game.office_kinds {
						if o > 0 && name_to_string(&office.id) == name.text do kind = Office_Kind_Id(o)
					}
					fmt.assertf(kind != 0, "%s: no office %q", path, name.text)
					slot_map_insert(&game.offices, Office{kind = kind, faction = owner, title = game.office_kinds[kind].name})
				}
				capital := tbl.get_text(row, "capital")
				fmt.assertf(capital != "", "%s: no capital for %s", path, tbl.get_text(row, "name"))

				for entry in row.children {
					if entry.key != "piece" do continue

					kind_name := tbl.get_text(entry, "kind")
					piece: Piece_Data
					kind_found := false
					for kind in kinds {
						if kind.name != kind_name do continue
						piece = kind.piece
						kind_found = true
					}
					fmt.assertf(kind_found, "%s: no piece kind %q", path, kind_name)

					piece.name = name_from_string(tbl.get_text(entry, "name"))
					piece.owner = owner
					piece.culture = culture
					if own_culture, has_own := tbl.get_text(entry, "culture"); has_own {
						piece.culture = 0
						for &known, c in game.cultures do if c > 0 && name_to_string(&known.id) == own_culture do piece.culture = Culture_Id(c)
						fmt.assertf(piece.culture != 0, "%s: no culture %q", path, own_culture)
					}
					piece.pos = tbl.get_num_array(entry, "at", 2)
					if .Has_Town in piece.flags {
						region := game.terrain.regions[grid_index(cell_of(piece.pos), MAP_SIZE)]
						piece.town.fertility = game.regions[region].fertility
						piece.town.population = tbl.get_num(entry, "population")

						main_text := tbl.get_text(entry, "main")
						main_id: Building_Kind_Id
						for &kind, k in game.building_kinds {
							if k > 0 && name_to_string(&kind.id) == main_text do main_id = Building_Kind_Id(k)
						}
						fmt.assertf(main_id != 0 && .Main in game.building_kinds[main_id].flags, "%s: no main building %q", path, main_text)
						piece.town.buildings[MAIN_SLOT] = main_id

						buildings := tbl.get_children(entry, "buildings")
						fmt.assertf(
							len(buildings) <= game.building_kinds[main_id].slots,
							"%s: more buildings than slots in %s",
							path,
							name_to_string(&piece.name),
						)
						for building, slot in buildings {
							kind_id: Building_Kind_Id
							for &kind, k in game.building_kinds {
								if k > 0 && name_to_string(&kind.id) == building.text do kind_id = Building_Kind_Id(k)
							}
							fmt.assertf(kind_id != 0, "%s: no building %q", path, building.text)
							fmt.assertf(.Main not_in game.building_kinds[kind_id].flags, "%s: %q is a main building", path, building.text)
							piece.town.buildings[slot] = kind_id
						}
					}


					// A title's army, or a settlement's garrison
					title_kind: Office_Kind_Id
					if title_text, titled := tbl.get_text(entry, "title"); titled {
						for &office_kind, o in game.office_kinds {
							if o > 0 && name_to_string(&office_kind.id) == title_text do title_kind = Office_Kind_Id(o)
						}
						fmt.assertf(title_kind != 0, "%s: no office %q", path, title_text)
						type_id := game.office_kinds[title_kind].army_type
						fmt.assertf(type_id != 0, "%s: office %q has no army", path, title_text)
						army_type := &game.army_types[type_id]
						men, has_men := tbl.get_num(entry, "men")
						fmt.assertf(has_men, "%s: no men for %s", path, tbl.get_text(entry, "name"))
						piece.army = {
							men         = int(men),
							men_max     = int(men),
							proficiency = army_type.proficiency,
							readiness   = 100,
							foraging    = army_type.foraging,
							supply      = 100,
							type        = type_id,
						}
						// Home: where it starts
						if army_type.scope == .Local {
							piece.army.home = Region_Id(game.terrain.regions[grid_index(cell_of(piece.pos), MAP_SIZE)])
						}
						piece.flags += {.Has_Army}
					} else if men, has_men := tbl.get_num(entry, "men"); has_men {
						piece.army = {
							men         = int(men),
							men_max     = int(men),
							proficiency = tbl.get_num(entry, "proficiency"),
							readiness   = 100,
							foraging    = tbl.get_num(entry, "foraging", ARMY_FORAGING_DEFAULT),
							supply      = 100,
						}
						piece.flags += {.Has_Army}
					}

					id := slot_map_insert(&game.pieces, piece)
					if title_kind != 0 do append(&army_titles, Army_Title{id, title_kind, tbl.get_text(entry, "of")})
					if name_to_string(&piece.name) == capital do game.factions[owner].capital = id

					if capital_of, is_capital := tbl.get_text(entry, "capital_of"); is_capital {
						for &region in game.regions {
							if name_to_string(&region.id) == capital_of do region.capital = id
						}
					}
				}
				fmt.assertf(game.factions[owner].capital != {}, "%s: no piece %q, capital of %s", path, capital, tbl.get_text(row, "name"))
			}
		}
	}


	// Characters
	{
		root, path := scenario_file(scenario_name, "characters.txt")

		counts: [FACTIONS_MAX]int
		for row in root.children {
			assert(row.key == "character")
			row_check(row, Character, path, {"of", "men"}, true, {"office", "influence_target"})

			faction_name := tbl.get_text(row, "faction")
			faction: Faction_Id
			for &known, f in game.factions do if f > 0 && name_to_string(&known.name) == faction_name do faction = Faction_Id(f)
			fmt.assertf(faction != 0, "%s: no faction %q", path, faction_name)
			character := Character {
				name        = name_from_string(tbl.get_text(row, "name")),
				faction     = faction,
				age         = int(tbl.get_num(row, "age")),
				rank        = int(tbl.get_num(row, "rank")),
				influence   = tbl.get_num(row, "influence"),
				loyalty     = tbl.get_num(row, "loyalty"),
				temperament = enum_from_text(Temperament, tbl.get_text(row, "temperament")),
				background  = enum_from_text(Background, tbl.get_text(row, "background")),
				disposition = enum_from_text(Disposition, tbl.get_text(row, "disposition")),
			}
			id := Character_Id(len(game.characters))
			fmt.assertf(append(&game.characters, character) == 1, "%s: more than %d characters", path, CHARACTERS_MAX - 1)

			if office_text, holds := tbl.get_text(row, "office"); holds {
				kind: Office_Kind_Id
				for &office_kind, o in game.office_kinds {
					if o > 0 && name_to_string(&office_kind.id) == office_text do kind = Office_Kind_Id(o)
				}
				fmt.assertf(kind != 0, "%s: no office %q", path, office_text)
				fmt.assertf(character.rank >= game.office_kinds[kind].rank, "%s: %q is below his office's rank", path, tbl.get_text(row, "name"))
				append(&holdings, Holding{id, kind, tbl.get_text(row, "of"), int(tbl.get_num(row, "men"))})
			}
			counts[faction] += 1
			fmt.assertf(counts[faction] <= FACTION_CHARACTERS_MAX, "%s: more than %d characters of %s", path, FACTION_CHARACTERS_MAX, faction_name)
		}
	}

	game.turn = 1
	game.player = 1

	// Start step: makes the building offices
	start_events := new([dynamic; GAME_EVENTS_MAX]Game_Event, context.temp_allocator)
	game_step(game, {}, {}, start_events)

	// The scenario's office holders, and armies' titles
	{
		for holding in holdings {
			faction := game.characters[holding.character].faction
			held: ^Office
			offices := slot_map_iterator(&game.offices)
			for office in slot_map_iterate(&offices) {
				if office.kind != holding.kind || office.faction != faction || office.holder != 0 do continue
				town := slot_map_get(&game.pieces, office.town)
				matches := holding.town != "" ? town != nil && name_to_string(&town.name) == holding.town : town == nil
				if matches {
					held = office
					break
				}
			}
			name := name_to_string(&game.characters[holding.character].name)
			fmt.assertf(held != nil, "characters.txt: no vacant %s for %q", name_to_string(&game.office_kinds[holding.kind].id), name)
			held.holder = holding.character
			held.men = holding.men
		}

		taken: [OFFICES_MAX]bool
		for linked in army_titles {
			army := slot_map_get(&game.pieces, linked.army)
			offices := slot_map_iterator(&game.offices)
			for office, office_id in slot_map_iterate(&offices) {
				if office.kind != linked.kind || office.faction != army.owner || taken[office_id.index] do continue
				town := slot_map_get(&game.pieces, office.town)
				matches := linked.town != "" ? town != nil && name_to_string(&town.name) == linked.town : town == nil
				if !matches do continue
				army.army.title = office_id
				taken[office_id.index] = true
				break
			}
			fmt.assertf(army.army.title != {}, "pieces.txt: no free title for %s", name_to_string(&army.name))
		}
	}

	fmt.assertf(
		game.army_template.icon == .Army,
		"pieces.txt: no army kind, which mobilised armies start from",
	)
	success &= len(game.factions) > 1
	// Settle the derived records
	game_step(game, {}, {}, start_events)
	return
}

// Parsed, with its path for errors
@(private = "file")
scenario_file :: proc(scenario_name, file: string) -> (root: tbl.Row, path: string) {
	path = fmt.tprintf("assets/scenarios/%s/%s", scenario_name, file)
	source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	root, _, _ = tbl.parse(transmute(string)source, context.temp_allocator)
	return
}

// Every key one of T's fields or an extra, as a mistyped key would read as 0. Required: every field given but the
// skipped
@(private = "file")
row_check :: proc(row: tbl.Row, $T: typeid, path: string, extra: []string = {}, required := false, skipped: []string = {}) {
	for key in row.children {
		known := reflect.struct_field_by_name(T, key.key).type != nil || slice.contains(extra, key.key)
		fmt.assertf(known, "%s: no %v key %q", path, typeid_of(T), key.key)
	}
	if !required do return
	row_name := tbl.get_text(row, "id")
	if row_name == "" do row_name = tbl.get_text(row, "name")
	for field in reflect.struct_field_names(T) {
		if slice.contains(skipped, field) do continue
		_, given := tbl.find(row, field)
		fmt.assertf(given, "%s: %q lacks %q", path, row_name, field)
	}
}

@(private = "file")
enum_from_text :: proc($T: typeid, text: string) -> T {
	value, ok := reflect.enum_from_name(T, text)
	fmt.assertf(ok, "%q is not a %v", text, typeid_of(T))
	return value
}

Terrain :: struct {
	elevation: [MAP_CELLS]u8,
	moisture:  [MAP_CELLS]u8,
	surface:   [MAP_CELLS]u8,
	trees:     [MAP_CELLS]u8,
	regions:   [MAP_CELLS]u8,
	cover:     [MAP_CELLS]Render_Cover_Cell,
	road:      [MAP_CELLS]bool,
}

@(private = "file")
load_map_bitmap_one_channel :: proc(file: string, out: ^[MAP_CELLS]u8) -> bool {
	// Load the bitmap data to scratch memory
	image, err := img.load_from_file(file, allocator = context.temp_allocator)
	if err != nil do return false
	// Extract first pixel per channel to get values
	pixels := image.pixels.buf[:]
	assert(len(pixels) == MAP_CELLS * image.channels)
	for i in 0 ..< MAP_CELLS {
		out[i] = pixels[i * image.channels]
	}
	return true
}

@(private = "file")
load_map_bitmap_3_channels :: proc(file: string, out: ^[MAP_CELLS][3]u8) -> bool {
	// Load the bitmap data to scratch memory
	image, err := img.load_from_file(file, allocator = context.temp_allocator)
	if err != nil do return false
	// Extract first pixel per channel to get values
	pixels := image.pixels.buf[:]
	assert(image.channels >= 3)
	assert(len(pixels) == MAP_CELLS * image.channels)
	for i in 0 ..< MAP_CELLS {
		for j in 0 ..< 3 {
			out[i][j] = pixels[i * image.channels + j]
		}
	}
	return true
}
