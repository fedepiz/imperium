#+private
package game

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

import "../sim"
import "../tabula"

// Regions -------------------------------------------------------------------------------------------------------------
// Regions: the pieces the map is cut into, painted cell by cell, each in its own colour

// The files the regions are read from, in a scenario's folder
REGIONS_FILE :: "regions.txt"
REGIONS_IMAGE :: "regions.png"

// Reads the regions from their files in a scenario's folder: the region each cell lies in, and each region's name and
// id-name, all in the temp allocator. regions.txt is tabula: a region row for each region, in the order of their ids
// from 1, holding its id (a word other data names it by, which no other region has), its name and its
// colour, [r, g, b] each from 1 to 255, which no other region has. regions.png is WORLD_WIDTH by WORLD_HEIGHT, each
// cell painted in the colour of the region it lies in; a cell of any other colour, such as black, lies in none. If
// either cannot be read, where and why is shown, and false is returned.
regions_read :: proc(folder: string) -> (cells: []sim.Region_Id, names: []string, ids: []string, ok: bool) {
	fail :: proc(path: string, n: int, message: string) -> bool {
		fmt.eprintfln("%s, region %d: %s", path, n + 1, message)
		return false
	}

	path := fmt.tprintf("%s/%s", folder, REGIONS_FILE)
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read %s: %v", path, err)
		return
	}
	root, error, parsed := tabula.parse(string(source), context.temp_allocator)
	if !parsed {
		fmt.eprintfln("%s:%d:%d: %s", path, error.line, error.column, error.message)
		return
	}
	if len(root.children) > sim.REGIONS_MAX {
		fmt.eprintfln("%s: there are more than %d regions", path, sim.REGIONS_MAX)
		return
	}
	names = make([]string, len(root.children), context.temp_allocator)
	ids = make([]string, len(root.children), context.temp_allocator)
	colours := make([][3]u8, len(root.children), context.temp_allocator)
	for row, n in root.children {
		if row.key != "region" do return nil, nil, nil, fail(path, n, fmt.tprintf("expected a region, not %q", row.key))
		ids[n] = tabula.get_text(row, "id")
		if ids[n] == "" do return nil, nil, nil, fail(path, n, "it needs an id")
		for other, m in ids[:n] {
			if other == ids[n] do return nil, nil, nil, fail(path, n, fmt.tprintf("its id is region %d's", m + 1))
		}
		names[n] = tabula.get_text(row, "name")
		if names[n] == "" do return nil, nil, nil, fail(path, n, "it needs a name")
		colour := tabula.find(row, "colour")
		colour_ok := len(colour.children) == 3
		for value in colour.children do colour_ok &&= .Has_Num in value.flags && value.num >= 1 && value.num <= 255
		if !colour_ok do return nil, nil, nil, fail(path, n, "its colour must be [r, g, b], each from 1 to 255")
		for value, channel in colour.children do colours[n][channel] = u8(value.num)
		for other, m in colours[:n] {
			if other == colours[n] do return nil, nil, nil, fail(path, n, fmt.tprintf("its colour is region %d's", m + 1))
		}
	}

	image_path := fmt.tprintf("%s/%s", folder, REGIONS_IMAGE)
	data, image_err := os.read_entire_file(image_path, context.temp_allocator)
	if image_err != nil {
		fmt.eprintfln("Could not read %s: %v", image_path, image_err)
		return
	}
	width, height, channels: c.int
	pixels := stbi.load_from_memory(raw_data(data), c.int(len(data)), &width, &height, &channels, 3)
	if pixels == nil {
		fmt.eprintfln("Could not decode %s: %s", image_path, stbi.failure_reason())
		return
	}
	defer stbi.image_free(pixels)
	if width != sim.WORLD_WIDTH || height != sim.WORLD_HEIGHT {
		fmt.eprintfln(
			"%s is %dx%d; it should be %dx%d",
			image_path,
			width,
			height,
			sim.WORLD_WIDTH,
			sim.WORLD_HEIGHT,
		)
		return
	}
	// Neighbouring cells are mostly of one colour, so the last colour's region is tried first.
	cells = make([]sim.Region_Id, sim.CELLS_MAX, context.temp_allocator)
	last_colour: [3]u8
	last_region: sim.Region_Id
	for &region, i in cells {
		colour := [3]u8{pixels[3 * i], pixels[3 * i + 1], pixels[3 * i + 2]}
		if colour != last_colour {
			last_colour = colour
			last_region = 0
			for listed, n in colours do if listed == colour {last_region = sim.Region_Id(n + 1); break}
		}
		region = last_region
	}
	return cells, names, ids, true
}
