package main

import "core:fmt"
import img "core:image"
import _ "core:image/png"
import "core:math/linalg"
import "core:os"

import tbl "tabula"

REGIONS_MAX :: 256

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
BASIN_DIST_MAX :: 24

Game :: struct {
	terrain: Terrain,
	ways:    [Way_Type][WAY_PER_TYPE_MAX]Way,
	regions: [REGIONS_MAX]Region,
}

Region_Id :: distinct u8

Name :: struct {
	buffer: [NAME_CAPACITY]u8,
}

Way_Type :: enum {
	River,
	Road,
}

Way :: struct {
	name: Name,
}

name_from_string :: proc(txt: string) -> (name: Name, ok: bool) #optional_ok {
	count := copy_from_string(name.buffer[:], txt)
	ok = count == len(txt)
	return
}

Region :: struct {
	id:    Name,
	name:  Name,
	color: [3]u8,
}

game_init :: proc(game: ^Game) {}

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
			lines: ^Render_Courses,
			reach: f32,
		}

		descs: [Way_Type]Desc = {
			.River = {lines = &geo_out.rivers, reach = RIVER_DIST_MAX},
			.Road = {lines = &geo_out.roads, reach = ROAD_DIST_MAX},
		}

		for desc, kind in descs {
			offsets := new([MAP_CELLS][2]f32, context.temp_allocator)

			// Must initialise offsets with high value, as the stamp algorithm only
			// *reduces* distances
			for &p in offsets {
				p.x = desc.reach
			}

			polylines_stamp(desc.lines, desc.reach, MAP_SIZE, offsets[:], nil)

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

	return
}

Terrain :: struct {
	elevation: [MAP_CELLS]u8,
	moisture:  [MAP_CELLS]u8,
	surface:   [MAP_CELLS]u8,
	trees:     [MAP_CELLS]u8,
	regions:   [MAP_CELLS]u8,
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

game_tick :: proc(game: ^Game) {}
