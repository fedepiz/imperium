package main

import "core:c"
import "core:fmt"
import "core:os"

import "core:image"
import _ "core:image/png"
import "core:mem"
import "core:strings"
import stbtt "vendor:stb/truetype"

Assets :: struct {
	// 1 megabye blob
	blob:        [1_000_000]byte,
	image_names: [ASSETS_IMAGES_MAX]string,
	image_rects: [ASSETS_IMAGES_MAX]Extents,
	fonts:       [FONTS_MAX]Font,
}


// Budgets
ASSETS_IMAGES_MAX :: 4000
ASSETS_ATLAS_SIZE :: 2048

FONTS_MAX :: 8
FONT_FIRST :: 32
FONT_LAST :: 126
FONT_GLYPH_COUNT :: FONT_LAST - FONT_FIRST + 1

Glyph :: struct {
	// Rect in the atlas
	source:  Extents,
	// From pen position on the baseline to the glyph's top-left
	offset:  [2]f32,
	// Pen advance after this glyph
	advance: f32,
}

Font :: struct {
	ascent:   f32,
	descent:  f32,
	line_gap: f32,
	glyphs:   [FONT_GLYPH_COUNT]Glyph,
}

Assets_Loaded :: struct {
	// RGBA8 premultiplied, per image slot
	pixels: [ASSETS_IMAGES_MAX][]u8,
}

assets_load :: proc(assets: ^Assets, out: ^Assets_Loaded) {
	blob_arena: mem.Arena
	mem.arena_init(&blob_arena, assets.blob[:])
	blob_alloc := mem.arena_allocator(&blob_arena)

	sizes := make([][2]int, ASSETS_IMAGES_MAX, context.temp_allocator)

	// doing work in-line before extraction
	image_sources: []string = {
		"logo",
		"terrain/mountain_0", "terrain/mountain_1", "terrain/mountain_2", "terrain/mountain_3",
		"terrain/hill_0", "terrain/hill_1", "terrain/hill_2", "terrain/hill_3",
		"terrain/conifer_0", "terrain/conifer_1", "terrain/conifer_2", "terrain/conifer_3",
		"terrain/broadleaf_0", "terrain/broadleaf_1", "terrain/broadleaf_2", "terrain/broadleaf_3",
		"terrain/cypress_0", "terrain/cypress_1", "terrain/cypress_2", "terrain/cypress_3",
		"terrain/palm_0", "terrain/palm_1", "terrain/palm_2", "terrain/palm_3",
		"terrain/tuft_0", "terrain/tuft_1", "terrain/tuft_2", "terrain/tuft_3",
		"terrain/marsh_0", "terrain/marsh_1", "terrain/marsh_2", "terrain/marsh_3",
		"terrain/dune_0", "terrain/dune_1", "terrain/dune_2", "terrain/dune_3",
		"terrain/sea_0", "terrain/sea_1",
	}
	font_sources: []string = {"aniron"}
	assert(len(font_sources) <= FONTS_MAX)

	// Slots are handed out in order, image 0 is the default
	id := 0

	// Images
	for name in image_sources {
		slot := id
		id += 1
		assert(slot < ASSETS_IMAGES_MAX)
		assets.image_names[slot] = strings.clone(name, blob_alloc)
		path := fmt.tprintf("assets/gfx/%s.png", name)

		// Decode to premultiplied RGBA
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

		out.pixels[slot] = img.pixels.buf[:]
		sizes[slot] = {img.width, img.height}
	}

	// Fonts, glyphs take consecutive slots, font 0 is the default
	font_first_slot: [FONTS_MAX]int
	for name, font_index in font_sources {
		font := &assets.fonts[font_index]
		font_first_slot[font_index] = id

		data, data_err := os.read_entire_file_from_path(
			fmt.tprintf("assets/fonts/%s.ttf", name),
			context.temp_allocator,
		)
		info: stbtt.fontinfo
		if data_err != nil || !stbtt.InitFont(&info, raw_data(data), 0) {
			fmt.eprintln("Failed to load font", name)
			id += FONT_GLYPH_COUNT
			continue
		}

		scale := stbtt.ScaleForPixelHeight(&info, 18)
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
		font.ascent = f32(ascent) * scale
		font.descent = f32(descent) * scale
		font.line_gap = f32(line_gap) * scale

		for codepoint in FONT_FIRST ..= FONT_LAST {
			slot := id
			id += 1
			assert(slot < ASSETS_IMAGES_MAX)
			glyph := &font.glyphs[codepoint - FONT_FIRST]

			advance, bearing: c.int
			stbtt.GetCodepointHMetrics(&info, rune(codepoint), &advance, &bearing)
			glyph.advance = f32(advance) * scale

			// Glyph box relative to the pen, empty for whitespace
			x0, y0, x1, y1: c.int
			stbtt.GetCodepointBitmapBox(&info, rune(codepoint), scale, scale, &x0, &y0, &x1, &y1)
			w, h := x1 - x0, y1 - y0
			glyph.offset = {f32(x0), f32(y0)}
			if w <= 0 || h <= 0 do continue

			// Rasterise coverage into temporary memory
			coverage := make([]u8, w * h, context.temp_allocator)
			stbtt.MakeCodepointBitmap(
				&info,
				raw_data(coverage),
				w,
				h,
				w,
				scale,
				scale,
				rune(codepoint),
			)

			// Coverage to premultiplied white
			pixels := make([]u8, w * h * 4, context.temp_allocator)
			for alpha, i in coverage {
				pixels[i * 4 + 0] = alpha
				pixels[i * 4 + 1] = alpha
				pixels[i * 4 + 2] = alpha
				pixels[i * 4 + 3] = alpha
			}
			out.pixels[slot] = pixels
			sizes[slot] = {int(w), int(h)}
		}
	}

	// Layout
	positions := make([][2]int, len(sizes), context.temp_allocator)
	if !shelf_pack({ASSETS_ATLAS_SIZE, ASSETS_ATLAS_SIZE}, sizes, 2, positions) {
		fmt.eprintln("Images do not fit in the atlas")
		return
	}

	for i in 0 ..< ASSETS_IMAGES_MAX {
		pos := positions[i]
		size := sizes[i]
		assets.image_rects[i] = {
			x_min = f32(pos.x),
			y_min = f32(pos.y),
			x_max = f32(pos.x + size.x),
			y_max = f32(pos.y + size.y),
		}
	}

	// Glyphs pick up their atlas rect
	for font_index in 0 ..< len(font_sources) {
		font := &assets.fonts[font_index]
		for &glyph, i in font.glyphs {
			glyph.source = assets.image_rects[font_first_slot[font_index] + i]
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
