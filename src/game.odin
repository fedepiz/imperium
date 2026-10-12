package main

import "core:fmt"
import img "core:image"
import _ "core:image/png"
import "core:math/linalg"
import "core:os"
import "core:reflect"
import "core:strings"

import tbl "tabula"

MAP_WIDTH :: 1024
MAP_HEIGHT :: 1024
MAP_SIZE: [2]int : {MAP_WIDTH, MAP_HEIGHT}
MAP_CELLS :: MAP_WIDTH * MAP_HEIGHT

NAME_CAPACITY :: 64

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
BUILDING_KINDS_MAX :: 64
// The most building slots a settlement has
TOWN_SLOTS_MAX :: 8

ARMY_FORAGING_DEFAULT :: 40
ARMY_MOBILITY_DEFAULT :: 2

Game :: struct {
	terrain:         Terrain,
	regions:         [REGIONS_MAX]Region,
	pieces:          Slot_Map(Piece_Data, PIECE_MAX, Piece_Id),
	step:            int,
	factions:        [dynamic; FACTIONS_MAX]Faction,
	characters:      [dynamic; CHARACTERS_MAX]Character,
	building_kinds:  [dynamic; BUILDING_KINDS_MAX]Building_Kind,
	turn:            int,
	player:          Faction_Id,
	ending:          bool,
	contacts:        [dynamic; CONTACTS_MAX]Contact,
	interaction:     Interaction,
	movement:        Movement,
	supply_network:  [MAP_CELLS]u8,
	// The playing faction's control over the land, 0..100
	control_network: [MAP_CELLS]u8,
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
	culture:           Map_Culture,
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

Army :: struct {
	men:               int,
	men_max:           int,
	proficiency:       f32,
	readiness:         f32,
	spent:             bool,
	foraging:          f32,
	mobility:          f32,
	// Share of needs met, 0..100
	supply:            f32,
	supply_source:     Supply_Source,
	supply_efficiency: f32,
}

// A settlement's economy
Town :: struct {
	population:           f32,
	// Its region's, copied at load
	fertility:            f32,
	// Its kind's: at most this many buildings
	slots:                int,
	buildings:            [dynamic; TOWN_SLOTS_MAX]Building_Kind_Id,
	// Each step, from its buildings and population. Per turn
	// The population its buildings need as staff, and the share of it they have, 0..1: every output is scaled by it
	staff_needed:         f32,
	staffing:             f32,
	// The food of the building in each slot, here
	slot_food:            [TOWN_SLOTS_MAX]f32,
	food:                 f32,
	food_eaten:           f32,
	labour:               f32,
	labour_used:          f32,
	// Into its owner's treasury: scaled by its control
	income:               f32,
	upkeep:               f32,
	// 0..100: the share of what it sends to the global pool that reaches it. Set with the networks, at load and each
	// turn change
	control:              f32,
	// The population its food feeds
	population_supported: f32,
	features:             bit_set[Feature],
}

Building_Kind_Id :: distinct u8

// Local, on or off: what a town's buildings provide
Feature :: enum u8 {
	Horses,
	Drill,
}

// A kind of building and its effects, per turn, from buildings.txt. A negative flow is consumed
Building_Kind :: struct {
	id:             Name,
	name:           Name,
	// The population it occupies
	population:     f32,
	food:           f32,
	// Food times its town's fertility
	food_fertility: f32,
	labour:         f32,
	// Into its owner's treasury, and out of it
	income:         f32,
	upkeep:         f32,
	// Spread over the land to its owner's towns, less the travel cost. A town's control sums every source's, capped at
	// 100
	control:        f32,
	features:       bit_set[Feature],
}

Piece_Turn :: struct {
	attacked:       bool,
	movement_spent: f32,
}

Supply_Source :: enum u8 {
	Network,
	Foraging,
}

Faction :: struct {
	name:     Name,
	culture:  Map_Culture,
	color:    [3]f32,
	treasury: f32,
	// Each step, from its towns. Per turn
	income:   f32,
	upkeep:   f32,
}

Character :: struct {
	name:        Name,
	temperament: Temperament,
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

Region :: struct {
	id:        Name,
	name:      Name,
	color:     [3]u8,
	capital:   Piece_Id,
	// Scales the food of its farms: 1 poor, 2 ordinary, 3 good, 4 rich
	fertility: f32,
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
		path := fmt.tprintf("assets/scenarios/%s/regions.txt", scenario_name)
		source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		root, _, _ := tbl.parse(transmute(string)source, context.temp_allocator)

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
			path := fmt.tprintf("assets/scenarios/%s/%s.txt", scenario_name, desc.kind_name)
			source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
			root, _, _ := tbl.parse(transmute(string)source, context.temp_allocator)

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
			.River = {lines = &geo_out.rivers, reach = RIVER_DIST_MAX, offsets = &geo_out.to_river},
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

	// Load the building kinds; kind 0 is none
	{
		path := fmt.tprintf("assets/scenarios/%s/buildings.txt", scenario_name)
		source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		root, _, _ := tbl.parse(transmute(string)source, context.temp_allocator)

		append(&game.building_kinds, Building_Kind{})
		for row in root.children {
			assert(row.key == "building")
			// A mistyped effect would read as 0: every key must be a field
			for key in row.children {
				fmt.assertf(reflect.struct_field_by_name(Building_Kind, key.key).type != nil, "%s: no building key %q", path, key.key)
			}

			kind := Building_Kind {
				id             = name_from_string(tbl.get_text(row, "id")),
				name           = name_from_string(tbl.get_text(row, "name")),
				population     = tbl.get_num(row, "population"),
				food           = tbl.get_num(row, "food"),
				food_fertility = tbl.get_num(row, "food_fertility"),
				labour         = tbl.get_num(row, "labour"),
				income         = tbl.get_num(row, "income"),
				upkeep         = tbl.get_num(row, "upkeep"),
				control        = tbl.get_num(row, "control"),
			}
			features := tbl.get_children(row, "features")
			for feature in features {
				kind.features += {enum_from_text(Feature, feature.text)}
			}
			fmt.assertf(append(&game.building_kinds, kind) == 1, "%s: more than %d building kinds", path, BUILDING_KINDS_MAX - 1)
		}
	}

	{
		path := fmt.tprintf("assets/scenarios/%s/pieces.txt", scenario_name)
		source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
		root, _, _ := tbl.parse(transmute(string)source, context.temp_allocator)

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
				piece.icon = enum_from_text(Map_Icon, tbl.get_text(row, "icon"))
				if moves, moving := tbl.get_text(row, "moves"); moving {
					piece.domain = enum_from_text(Pathfind_Domain, moves)
				}
				piece.movement_per_turn = tbl.get_num(row, "per_turn")
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
				append(&kinds, kind)

			case "faction":
				owner := Faction_Id(len(game.factions))
				culture := enum_from_text(Map_Culture, tbl.get_text(row, "culture"))
				append(
					&game.factions,
					Faction {
						name = name_from_string(tbl.get_text(row, "name")),
						culture = culture,
						color = tbl.get_num_array(row, "color", 3) / 255,
						treasury = tbl.get_num(row, "treasury"),
					},
				)

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
						piece.culture = enum_from_text(Map_Culture, own_culture)
					}
					piece.pos = tbl.get_num_array(entry, "at", 2)
					if .Has_Town in piece.flags {
						region := game.terrain.regions[grid_index(cell_of(piece.pos), MAP_SIZE)]
						piece.town.fertility = game.regions[region].fertility
						piece.town.population = tbl.get_num(entry, "population")

						buildings := tbl.get_children(entry, "buildings")
						fmt.assertf(len(buildings) <= piece.town.slots, "%s: more buildings than slots in %s", path, name_to_string(&piece.name))
						for building in buildings {
							kind_id: Building_Kind_Id
							for &kind, k in game.building_kinds {
								if k > 0 && name_to_string(&kind.id) == building.text do kind_id = Building_Kind_Id(k)
							}
							fmt.assertf(kind_id != 0, "%s: no building %q", path, building.text)
							append(&piece.town.buildings, kind_id)
						}
					}

					if general, has_general := tbl.get_text(entry, "general"); has_general {
						character := Character {
							name        = name_from_string(general),
							temperament = .Steady,
						}
						if temperament, has_temperament := tbl.get_text(entry, "temperament");
						   has_temperament {
							character.temperament = enum_from_text(Temperament, temperament)
						}
						piece.general = Character_Id(len(game.characters))
						append(&game.characters, character)
					}

					if men, has_men := tbl.get_num(entry, "men"); has_men {
						army := Army {
							men         = int(men),
							men_max     = int(men),
							proficiency = tbl.get_num(entry, "proficiency"),
							readiness   = 100,
							foraging    = tbl.get_num(entry, "foraging", ARMY_FORAGING_DEFAULT),
							mobility    = tbl.get_num(entry, "mobility", ARMY_MOBILITY_DEFAULT),
							supply      = 100,
						}
						piece.army = army
						piece.flags += {.Has_Army}
					}

					id := slot_map_insert(&game.pieces, piece)

					if capital_of, is_capital := tbl.get_text(entry, "capital_of"); is_capital {
						for &region in game.regions {
							if name_to_string(&region.id) == capital_of do region.capital = id
						}
					}
				}
			}
		}
	}

	success &= len(game.factions) > 1
	game.turn = 1
	game.player = 1
	game_networks_build(game)
	return
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


