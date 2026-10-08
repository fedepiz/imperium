package main

import "core:fmt"
import "core:os"

import "core:image"
import _ "core:image/png"
import "core:mem"
import "core:strings"

Assets :: struct {
	// 1 megabye blob
	blob:        [1_000_000]byte,
	image_names: [ASSETS_IMAGES_MAX]string,
	image_rects: [ASSETS_IMAGES_MAX]Extents,
}


// Budgets
ASSETS_IMAGES_MAX :: 4000

// Out: assets. In/out: init, appended to.
// Loads the images listed inside into the images atlas, packed against its info. Pixels are in
// temporary memory
assets_load :: proc(assets: ^Assets, init: ^Render_Init) {
	blob_arena: mem.Arena
	mem.arena_init(&blob_arena, assets.blob[:])
	blob_alloc := mem.arena_allocator(&blob_arena)

	// Phase: Sources. Image slots in this order, image 0 is the default
	image_sources := make([dynamic]string, 0, ASSETS_IMAGES_MAX, context.temp_allocator)
	append(&image_sources, "logo")
	{
		// Terrain marks: terrain/<kind>_<variant>
		Mark_Kind :: struct {
			name:     string,
			variants: int,
		}
		mark_kinds := [?]Mark_Kind {
			{"mountain", 4},
			{"hill", 4},
			{"conifer", 4},
			{"broadleaf", 4},
			{"cypress", 4},
			{"palm", 4},
			{"tuft", 4},
			{"marsh", 4},
			{"dune", 4},
			{"sea", 2},
		}
		for kind in mark_kinds {
			for variant in 0 ..< kind.variants {
				append(&image_sources, fmt.tprintf("terrain/%s_%d", kind.name, variant))
			}
		}

		// Pawns: <set>/<culture>_<icon>, and its silhouette <set>/<culture>_<icon>_fill
		for set in ([?]string{"pawns", "medallions"}) {
			for culture in ([?]string{"roman", "germanic"}) {
				for icon in ([?]string{"town_0", "town_1", "town_2", "town_3", "army"}) {
					append(&image_sources, fmt.tprintf("%s/%s_%s", set, culture, icon))
					append(&image_sources, fmt.tprintf("%s/%s_%s_fill", set, culture, icon))
				}
			}
		}
	}

	assert(len(image_sources) <= ASSETS_IMAGES_MAX)

	// Phase: Images. Decoded to premultiplied RGBA8. A slot that fails stays empty
	image_pixels := make([][]u8, len(image_sources), context.temp_allocator)
	image_sizes := make([][2]int, len(image_sources), context.temp_allocator)
	for name, slot in image_sources {
		assets.image_names[slot] = strings.clone(name, blob_alloc)
		path := fmt.tprintf("assets/gfx/%s.png", name)

		data, data_err := os.read_entire_file_from_path(path, context.temp_allocator)
		if data_err != nil {
			fmt.eprintln("Failed to read", path, data_err)
			continue
		}
		img, img_err := image.load_from_bytes(
			data,
			{.alpha_add_if_missing, .alpha_premultiply},
			context.temp_allocator,
		)
		if img_err != nil {
			fmt.eprintln("Failed to decode", path, img_err)
			continue
		}
		if img.depth != 8 || img.channels != 4 {
			fmt.eprintln("Unsupported pixel format", path, img.depth, img.channels)
			continue
		}

		image_pixels[slot] = img.pixels.buf[:]
		image_sizes[slot] = {img.width, img.height}
	}

	// Phase: Images atlas. Packed, written, and each image's rect kept
	{
		positions := make([][2]int, len(image_sources), context.temp_allocator)
		if !render_atlas_pack(init.atlases[.Images], image_sizes, positions) {
			fmt.eprintln("Images do not fit in their atlas")
			return
		}
		for size, slot in image_sizes {
			pos := positions[slot]
			assets.image_rects[slot] = {
				x_min = f32(pos.x),
				y_min = f32(pos.y),
				x_max = f32(pos.x + size.x),
				y_max = f32(pos.y + size.y),
			}
			if size.x <= 0 || size.y <= 0 do continue
			append(
				&init.writes[.Images],
				Render_Write_Pixels{pos = pos, size = size, pixels = image_pixels[slot]},
			)
		}
	}
}

// Slot of the image loaded under name, as listed in assets_load. Not found: 0, the default image
assets_image_find :: proc(assets: ^Assets, name: string) -> (index: int, found: bool) {
	for image_name, i in assets.image_names {
		if image_name == name do return i, true
	}
	return 0, false
}
