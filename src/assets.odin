package main

import "core:fmt"
import "core:image"
import _ "core:image/png"
import "core:os"

// Budgets
ASSETS_IMAGES_MAX :: 4000

// Out: init, appended to; rects.
// Loads the images at paths, under assets/gfx without .png, into the images atlas, packed against its
// info. rects[i]: the atlas rect of paths[i], empty when it failed to load. Pixels are in temporary memory
assets_load :: proc(paths: []string, init: ^Render_Init, rects: []Extents) {
	assert(len(paths) <= ASSETS_IMAGES_MAX && len(rects) == len(paths))

	// Phase: Images. Decoded to premultiplied RGBA8. A slot that fails stays empty
	image_pixels := make([][]u8, len(paths), context.temp_allocator)
	image_sizes := make([][2]int, len(paths), context.temp_allocator)
	for name, slot in paths {
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
		positions := make([][2]int, len(paths), context.temp_allocator)
		if !render_atlas_pack(init.atlases[.Images], image_sizes, positions) {
			fmt.eprintln("Images do not fit in their atlas")
			return
		}
		for size, slot in image_sizes {
			pos := positions[slot]
			rects[slot] = {
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
