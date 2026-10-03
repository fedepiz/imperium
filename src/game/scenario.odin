#+private
package game

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import stbi "vendor:stb/image"

import "../sim"

// Layers are WORLD_WIDTH x WORLD_HEIGHT greyscale PNGs, in the temp allocator. surface.png: black land, grey lake,
// white sea. On any failure every layer is left empty.
scenario_read :: proc(folder: string) -> (scenario: sim.Scenario) {
	Layer :: enum {
		Surface,
		Elevation,
		Trees,
		Moisture,
	}
	names := [Layer]string {
		.Surface   = "surface",
		.Elevation = "elevation",
		.Trees     = "trees",
		.Moisture  = "moisture",
	}
	pixels: [Layer][]u16
	for name, layer in names {
		loaded, ok := scenario_read_layer(fmt.tprintf("%s/%s.png", folder, name))
		if !ok do return {}
		pixels[layer] = loaded
	}

	scenario.surface = make([]sim.Surface, sim.CELLS_MAX, context.temp_allocator)
	scenario.elevation = make([]u8, sim.CELLS_MAX, context.temp_allocator)
	scenario.trees = make([]u8, sim.CELLS_MAX, context.temp_allocator)
	scenario.moisture = make([]u8, sim.CELLS_MAX, context.temp_allocator)
	for i in 0 ..< sim.CELLS_MAX {
		surface := u8(pixels[.Surface][i] >> 8)
		scenario.surface[i] = sim.Surface(min((int(surface) + 64) / 128, int(max(sim.Surface))))
		scenario.elevation[i] = u8(pixels[.Elevation][i] >> 8)
		scenario.trees[i] = u8(pixels[.Trees][i] >> 8)
		scenario.moisture[i] = u8(pixels[.Moisture][i] >> 8)
	}
	ways, ways_ok := ways_load(folder)
	if !ways_ok do return {}
	scenario.ways = ways
	regions, region_names, region_ids, regions_ok := regions_read(folder)
	if !regions_ok do return {}
	scenario.regions = regions
	scenario.region_names = region_names
	factions, characters, pieces, pieces_ok := pieces_load(folder, region_ids)
	if !pieces_ok do return {}
	scenario.factions = factions
	scenario.characters = characters
	scenario.pieces = pieces
	for &file, id in scenario.cached_files do file = cache_read(cache_path(folder, id))
	return
}

CACHE_FOLDER :: "cache"

// File layout: fingerprint, then data
cache_path :: proc(folder: string, id: sim.Cached_File_Id) -> string {
	return fmt.tprintf("%s/%s_%v.cache", CACHE_FOLDER, os.base(folder), id)
}

// Temp allocator. Empty if missing or truncated.
cache_read :: proc(path: string) -> (file: sim.Cached_File) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < size_of(file.fingerprint) do return
	copy(mem.ptr_to_bytes(&file.fingerprint), data)
	file.data = data[size_of(file.fingerprint):]
	return
}

cache_write :: proc(path: string, file: sim.Cached_File) -> bool {
	// Errors surface when creating the file
	_ = os.make_directory(CACHE_FOLDER)
	f, err := os.create(path)
	if err != nil {
		fmt.eprintfln("Could not write cache %q: %v", path, err)
		return false
	}
	defer os.close(f)
	fingerprint := file.fingerprint
	_, err = os.write(f, mem.ptr_to_bytes(&fingerprint))
	if err == nil do _, err = os.write(f, file.data)
	if err != nil {
		fmt.eprintfln("Could not write cache %q: %v", path, err)
		return false
	}
	return true
}

// 16-bit greyscale (8-bit images widened, value in the high byte), temp allocator
@(private = "file")
scenario_read_layer :: proc(path: string) -> (pixels: []u16, ok: bool) {
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
	if width != sim.WORLD_WIDTH || height != sim.WORLD_HEIGHT {
		fmt.eprintfln(
			"Terrain layer %q is %dx%d; it should be %dx%d",
			path,
			width,
			height,
			sim.WORLD_WIDTH,
			sim.WORLD_HEIGHT,
		)
		return
	}
	pixels = make([]u16, sim.CELLS_MAX, context.temp_allocator)
	copy(pixels, loaded[:sim.CELLS_MAX])
	return pixels, true
}
