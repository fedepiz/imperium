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
	// Physical pixels per logical pixel the fonts were rasterised for
	pixel_density: f32,
}


// Budgets
ASSETS_IMAGES_MAX :: 4000
ASSETS_ATLAS_SIZE :: 4096
// Images sit on multiples of this in the atlas, at least this far apart
ASSETS_ATLAS_SPACING :: 16

FONTS_MAX :: 8
FONT_FIRST :: 32
FONT_LAST :: 126
FONT_GLYPH_COUNT :: FONT_LAST - FONT_FIRST + 1

// Glyph data is one array per property, indexed by character - FONT_FIRST.
Font :: struct {
	// As listed in assets_load. size: em height in logical pixels
	name:     string,
	size:     u16,
	// Logical pixels. descent is negative
	ascent:   f32,
	descent:  f32,
	line_gap: f32,
	// Pen advance after each glyph, in logical pixels
	advances: [FONT_GLYPH_COUNT]f32,
	// From the pen position on the baseline to each glyph's top-left, in logical pixels
	offsets:  [FONT_GLYPH_COUNT][2]f32,
	// Each glyph's size when drawn, in logical pixels. Zero for blank glyphs
	sizes:    [FONT_GLYPH_COUNT][2]f32,
	// Each glyph's rect in the atlas, in physical pixels: sizes * Assets.pixel_density
	sources:  [FONT_GLYPH_COUNT]Extents,
}

Assets_Loaded :: struct {
	// RGBA8 premultiplied, per image slot
	pixels: [ASSETS_IMAGES_MAX][]u8,
}

// Out: assets, out.
// Loads the images and fonts listed inside, and lays them out in the atlas
assets_load :: proc(
	assets: ^Assets,
	// Physical pixels per logical pixel of the window. Glyphs are rasterised at font size * this
	pixel_density: f32,
	out: ^Assets_Loaded,
) {
	assets.pixel_density = pixel_density > 0 ? pixel_density : 1

	blob_arena: mem.Arena
	mem.arena_init(&blob_arena, assets.blob[:])
	blob_alloc := mem.arena_allocator(&blob_arena)

	sizes := make([][2]int, ASSETS_IMAGES_MAX, context.temp_allocator)

	// doing work in-line before extraction
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

	Font_Source :: struct {
		name: string,
		// Pixel height
		size: u16,
	}
	font_sources := [?]Font_Source{{"aniron", 18}, {"forgotten_uncial", 22}}
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
	for source, font_index in font_sources {
		name := source.name
		font := &assets.fonts[font_index]
		font.name = strings.clone(name, blob_alloc)
		font.size = source.size
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

		// Font units to physical pixels. Metrics are stored in logical pixels
		density := assets.pixel_density
		scale := stbtt.ScaleForPixelHeight(&info, f32(source.size) * density)
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
		font.ascent = f32(ascent) * scale / density
		font.descent = f32(descent) * scale / density
		font.line_gap = f32(line_gap) * scale / density

		for codepoint in FONT_FIRST ..= FONT_LAST {
			slot := id
			id += 1
			assert(slot < ASSETS_IMAGES_MAX)
			glyph := codepoint - FONT_FIRST

			advance, bearing: c.int
			stbtt.GetCodepointHMetrics(&info, rune(codepoint), &advance, &bearing)
			font.advances[glyph] = f32(advance) * scale / density

			// Glyph box relative to the pen, empty for whitespace
			x0, y0, x1, y1: c.int
			stbtt.GetCodepointBitmapBox(&info, rune(codepoint), scale, scale, &x0, &y0, &x1, &y1)
			w, h := x1 - x0, y1 - y0
			font.offsets[glyph] = [2]f32{f32(x0), f32(y0)} / density
			if w <= 0 || h <= 0 do continue
			font.sizes[glyph] = [2]f32{f32(w), f32(h)} / density

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

	// Layout. Packed at sizes rounded up to the spacing, so every position is a multiple of it
	spaced := make([][2]int, len(sizes), context.temp_allocator)
	for size, i in sizes {
		spaced[i] = (size + ASSETS_ATLAS_SPACING - 1) / ASSETS_ATLAS_SPACING * ASSETS_ATLAS_SPACING
	}
	positions := make([][2]int, len(sizes), context.temp_allocator)
	if !shelf_pack({ASSETS_ATLAS_SIZE, ASSETS_ATLAS_SIZE}, spaced, ASSETS_ATLAS_SPACING, positions) {
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
		for &source, glyph in font.sources {
			source = assets.image_rects[font_first_slot[font_index] + glyph]
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

// Index of the font loaded under name at size, as listed in assets_load. Not found: 0, the default font
assets_font_find :: proc(assets: ^Assets, name: string, size: u16) -> (index: int, found: bool) {
	for font, i in assets.fonts {
		if font.name == name && font.size == size do return i, true
	}
	return 0, false
}
