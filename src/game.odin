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
MAP_CELLS :: MAP_WIDTH * MAP_HEIGHT

NAME_CAPACITY :: 64

WAY_PER_TYPE_MAX :: 256
WAY_LENGTH_MAX :: 1024
WAY_MAX_STEPS_PER_TYPE :: WAY_LENGTH_MAX * 4

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

game_init :: proc(game: ^Game) {

}

Game_Load :: struct {
	success:   bool,
	geography: Render_Terrain,
}

game_load :: proc(game: ^Game, scenario_name: string) -> (out: Game_Load) {
	out.success = true

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
			out.success &= load_map_bitmap_one_channel(path, entry.buf)
		}
	}

	// Load region data: the color of each cell's region, until assigned below
	region_colors := new([MAP_CELLS][3]u8, context.temp_allocator)
	{
		path := fmt.tprintf("assets/scenarios/%s/regions.png", scenario_name)
		out.success &= load_map_bitmap_3_channels(path, region_colors)
	}

	// Load river and road data
	{
		Desc :: struct {
			kind_name: string,
			smoothing: Polyline_Smoothing,
			out:       ^Polylines,
		}
		descs: []Desc = {
			// Rivers: wide curves
			{kind_name = "rivers", smoothing = {cut_iter = 3, cut_ratio = 0.25}, out = &out.geography.rivers},
			// Roads: straight, tight bends
			{kind_name = "roads", smoothing = {cut_iter = 2, cut_ratio = 0.25, cut_max = 1.5}, out = &out.geography.roads},
		}

		lines_in := polylines_make(
			WAY_MAX_STEPS_PER_TYPE,
			WAY_PER_TYPE_MAX,
			context.temp_allocator,
		)


		for desc in descs {
			path := fmt.tprintf("assets/scenarios/%s/%s.txt", scenario_name, desc.kind_name)
			source, _ := os.read_entire_file_from_path(path, context.temp_allocator)
			root, _, _ := tbl.parse(transmute(string)source, context.temp_allocator)

			polylines_clear(&lines_in)


			// Reserve the first line for the zero-way
			polylines_reserve(0, false, &lines_in)

			// Load the data points
			for entry in root.children {
				points_in := tbl.get_children(entry, "points")
				points_out := polylines_reserve(len(points_in), false, &lines_in)
				for pt, i in points_in {
					points_out[i].x = pt.children[0].num
					points_out[i].y = pt.children[1].num
				}
			}

			// Create output for smoothing: each cut doubles the points
			lines_out := polylines_make(
				len(lines_in.points) << uint(desc.smoothing.cut_iter),
				len(lines_in.runs),
				context.temp_allocator,
			)

			// Perform smoothing
			polylines_smooth(lines_in, desc.smoothing, &lines_out)

			desc.out^ = lines_out
		}
	}

	// Prepare geography
	out.geography.elevation = game.terrain.elevation[:]
	out.geography.moisture = game.terrain.moisture[:]

	// Assign water
	{
		out.geography.water = make_slice([]bool, MAP_CELLS, allocator = context.temp_allocator)
		for x, i in game.terrain.surface {
			out.geography.water[i] = x > 0
		}
	}

	// Assign regions: each land cell's color looked up among the regions'. Not found: 0, no region
	{
		for color, i in region_colors^ {
			game.terrain.regions[i] = 0
			if out.geography.water[i] do continue
			game.terrain.regions[i] = u8(region_by_color[color])
		}
		out.geography.regions = game.terrain.regions[:]
	}

	// Classify terrian (Cover)
	out.geography.cover = make_slice(
		[]Render_Cover_Cell,
		MAP_CELLS,
		allocator = context.temp_allocator,
	)
	for i in 0 ..< MAP_CELLS {
		cell: Render_Cover_Cell
		if !out.geography.water[i] {
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
				// Suitability per kind; the best wins, earlier kinds win ties.
				// Left out until rivers and the sea distance exist: Fertile (dry_river, valley), Marsh's delta term
				suits := [Render_Cover]f32 {
					.Open      = 1.0 / 6,
					.Forest    = smoothstep(0.05, 0.75, t),
					.Desert    = smoothstep(0.47, 0.35, m),
					.Steppe    = smoothstep(0.40, 0.47, m) * smoothstep(0.58, 0.48, m),
					.Fertile   = 0,
					.Marsh     = 1.5 * low * smoothstep(0.80, 0.88, m),
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
		out.geography.cover[i] = cell
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
