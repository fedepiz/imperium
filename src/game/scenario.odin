#+private
package game

import "core:c"
import "core:fmt"
import "core:os"
import stbi "vendor:stb/image"

import "../sim"

// Reads a scenario from its folder: one greyscale PNG per layer, WORLD_WIDTH by WORLD_HEIGHT. surface.png is black for
// land, grey for lake and white for sea; elevation.png, trees.png and moisture.png run from 0 to 255 on land. rivers.png
// and roads.png hold, in 16 bits, the id of the way through each land cell. The layers live in the temp allocator. If a
// layer is missing or the wrong size, every layer is left empty.
scenario_read :: proc(folder: string) -> (scenario: sim.Scenario) {
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
	scenario.ways[.River] = pixels[.Rivers]
	scenario.ways[.Road] = pixels[.Roads]
	return
}

// One greyscale layer, WORLD_WIDTH by WORLD_HEIGHT, in 16 bits: an 8-bit image's values are widened, so their high
// byte is the value. The pixels live in the temp allocator.
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
