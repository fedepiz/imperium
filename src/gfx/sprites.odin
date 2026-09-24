package gfx

import "core:c"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import stbi "vendor:stb/image"
import stbrp "vendor:stb/rect_pack"
import stbtt "vendor:stb/truetype"

ATLAS_MAX :: 32
FONTS_MAX :: 32
FONT_GLYPHS_MAX :: 256
IMAGES_MAX :: 10_000
SPRITES_MAX :: IMAGES_MAX + FONTS_MAX * FONT_GLYPHS_MAX

Atlas_Id :: distinct u8

Font_Id :: distinct u8
Image_Id :: distinct u16
Sprite_Id :: distinct u16

// The atlas: every font and image, loaded once by sprites_load
@(private = "file")
SPRITES: struct {
	fonts:   [FONTS_MAX]Font_Desc,
	images:  [IMAGES_MAX]Image_Desc,
	regions: [SPRITES_MAX]Sprite_Region,
	glyphs:  [SPRITES_MAX]Sprite_Glyph,
	// Set by sprites_load; everything that reads the atlas needs it first
	loaded:  bool,
}

// Logical description of an image
Image_Desc :: struct {
	// Literal, outlives everything
	name:  string,
	// Atlas where the image will be batched in.
	// 0 is the default shared atlas.
	atlas: Atlas_Id,
}

Sprite_Region :: struct {
	texture: Texture_Id,
	source:  [4]f32,
}

Sprite_Glyph :: struct {
	// Position and size relative to the text pen's baseline.
	offset:  [2]f32,
	size:    [2]f32,
	advance: f32,
}

Font_Desc :: struct {
	// Asset basename: assets/fonts/<name>.ttf. The string outlives this table.
	name:       string,
	// Canonical pixel height, measured from ascent to descent.
	size:       u16,
	// Atlas where this font's glyphs will be batched.
	atlas:      Atlas_Id,
	// Sorted by sprites_load. Zero marks an unused entry.
	codepoints: [FONT_GLYPHS_MAX]rune,
	// Loaded font information
	info:       Font_Info,
}

Font_Info :: struct {
	ascent:   f32,
	descent:  f32,
	line_gap: f32,
}

@(private = "file")
Sprite_Loaded_Font :: struct {
	info:  stbtt.fontinfo,
	// Font units to texture pixels: glyphs are rasterized at the window's pixel density
	scale: f32,
}

@(private = "file")
Sprite_Atlas_Item :: struct {
	atlas:  Atlas_Id,
	width:  int,
	height: int,
}

@(private = "file")
Sprite_Load_Workspace :: struct {
	images:           []Bitmap,
	fonts:            []Sprite_Loaded_Font,
	items:            []Sprite_Atlas_Item,
	rect_storage:     []stbrp.Rect,
	nodes:            []stbrp.Node,
	glyph_pixels:     []u8,
	max_texture_size: int,
}

// Defines printable ASCII by default. The codepoint table can be edited before loading.
sprites_font_define :: proc(id: Font_Id, name: string, size: u16) {
	if id < FONTS_MAX {
		font := &SPRITES.fonts[id]
		assert(len(font.name) == 0)
		font.name = name
		font.size = size
		for codepoint in 32 ..< 127 {
			font.codepoints[codepoint - 32] = rune(codepoint)
		}
	}
}

sprites_image_define :: proc(id: Image_Id, name: string) {
	SPRITES.images[id] = {
		name = name,
	}
}

// Startup load. Only derived metrics/regions and GPU textures survive a temp reset.
// Image glyph metrics may be supplied by the caller for inline icons.
sprites_load :: proc(renderer: ^Renderer, pixel_density: f32) {
	workspace := Sprite_Load_Workspace {
		images = make([]Bitmap, IMAGES_MAX, context.temp_allocator),
		fonts  = make([]Sprite_Loaded_Font, FONTS_MAX, context.temp_allocator),
		items  = make([]Sprite_Atlas_Item, SPRITES_MAX, context.temp_allocator),
	}
	atlas_is_used: [ATLAS_MAX]bool
	mem.zero_slice(SPRITES.regions[:])
	mem.zero_slice(SPRITES.glyphs[IMAGES_MAX:])

	for image, image_index in SPRITES.images {
		if image.name == "" {continue}
		assert(int(image.atlas) < ATLAS_MAX)
		filename := fmt.tprintf("assets/gfx/%v.png", image.name)
		file_data, err := os.read_entire_file(filename, context.temp_allocator)
		if err != nil {
			fmt.eprintf("WARNING: Could not load image file %q: %v\n", filename, err)
			continue
		}
		if len(file_data) == 0 || len(file_data) > int(max(c.int)) {
			fmt.eprintf(
				"WARNING: Could not load image file %q: unsupported file size (%d bytes)\n",
				filename,
				len(file_data),
			)
			continue
		}

		width, height, channels: c.int
		pixels := stbi.load_from_memory(
			raw_data(file_data),
			c.int(len(file_data)),
			&width,
			&height,
			&channels,
			4,
		)
		if pixels == nil {
			fmt.eprintf(
				"WARNING: Could not decode image file %q: %s\n",
				filename,
				stbi.failure_reason(),
			)
			continue
		}
		workspace.images[image_index] = {
			(cast([^][4]u8)pixels)[:int(width) * int(height)],
			int(width),
			int(height),
		}
		workspace.items[image_index] = {
			atlas  = image.atlas,
			width  = int(width),
			height = int(height),
		}
		atlas_is_used[image.atlas] = true
	}

	max_glyph_pixels := 0
	for &desc, font_index in SPRITES.fonts {
		slice.sort(desc.codepoints[:])
		desc.info = {}
		if desc.name == "" {continue}
		assert(int(desc.atlas) < ATLAS_MAX)
		if desc.size == 0 {continue}
		path := fmt.tprintf("assets/fonts/%s.ttf", desc.name)
		file_data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintf("WARNING: Could not load font file %q: %v\n", path, err)
			continue
		}
		if len(file_data) == 0 {
			fmt.eprintf("WARNING: Could not load font file %q: empty file\n", path)
			continue
		}
		font_offset := stbtt.GetFontOffsetForIndex(raw_data(file_data), 0)
		if font_offset < 0 {
			fmt.eprintf("WARNING: Could not load font file %q: no supported font found\n", path)
			continue
		}

		loaded := &workspace.fonts[font_index]
		if !stbtt.InitFont(&loaded.info, raw_data(file_data), font_offset) {
			fmt.eprintf("WARNING: Could not load font file %q: font initialization failed\n", path)
			continue
		}
		loaded.scale = stbtt.ScaleForPixelHeight(&loaded.info, f32(desc.size) * pixel_density)

		// Metrics are measured in texture pixels and kept in logical ones.
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&loaded.info, &ascent, &descent, &line_gap)
		desc.info = {
			ascent   = f32(ascent) * loaded.scale / pixel_density,
			descent  = f32(descent) * loaded.scale / pixel_density,
			line_gap = f32(line_gap) * loaded.scale / pixel_density,
		}

		for codepoint, codepoint_index in desc.codepoints {
			if codepoint == 0 {
				continue
			}
			sprite_index := IMAGES_MAX + font_index * FONT_GLYPHS_MAX + codepoint_index
			sprite := Sprite_Id(sprite_index)
			glyph := font_glyph_metrics(loaded, codepoint)
			SPRITES.glyphs[sprite] = {
				offset  = glyph.offset / pixel_density,
				size    = glyph.size / pixel_density,
				advance = glyph.advance / pixel_density,
			}
			width, height := int(glyph.size.x), int(glyph.size.y)
			if width == 0 || height == 0 {
				continue
			}
			workspace.items[sprite] = {
				atlas  = desc.atlas,
				width  = width,
				height = height,
			}
			max_glyph_pixels = max(max_glyph_pixels, width * height)
			atlas_is_used[desc.atlas] = true
		}
	}

	// Reuse packing and raster scratch across atlas batches.
	workspace.max_texture_size = render_max_texture_size()
	workspace.rect_storage = make([]stbrp.Rect, SPRITES_MAX, context.temp_allocator)
	workspace.nodes = make([]stbrp.Node, workspace.max_texture_size, context.temp_allocator)
	workspace.glyph_pixels = make([]u8, max_glyph_pixels, context.temp_allocator)
	for used, atlas_index in atlas_is_used {
		if !used {continue}
		sprites_load_atlas(renderer, Atlas_Id(atlas_index), &workspace)
	}
	SPRITES.loaded = true

	// Release image memory
	for image in workspace.images {
		if image.pixels != nil {
			stbi.image_free(raw_data(image.pixels))
		}
	}
}

// The glyph in texture pixels.
@(private = "file")
font_glyph_metrics :: proc(font: ^Sprite_Loaded_Font, codepoint: rune) -> Sprite_Glyph {
	x0, y0, x1, y1, advance: c.int
	stbtt.GetCodepointBitmapBox(&font.info, codepoint, font.scale, font.scale, &x0, &y0, &x1, &y1)
	stbtt.GetCodepointHMetrics(&font.info, codepoint, &advance, nil)
	return {
		offset = {f32(x0), f32(y0)},
		size = {f32(x1 - x0), f32(y1 - y0)},
		advance = f32(advance) * font.scale,
	}
}

@(private = "file")
sprites_pack_rectangles :: proc(rects: []stbrp.Rect, nodes: []stbrp.Node, max_size: int) -> int {
	max_dimension := 0
	for rect in rects {
		max_dimension = max(max_dimension, int(rect.w), int(rect.h))
	}
	size := 64
	for size < min(max_dimension, max_size) {
		size *= 2
	}
	size = min(size, max_size)
	for {
		pack_context: stbrp.Context
		stbrp.init_target(
			&pack_context,
			c.int(size),
			c.int(size),
			raw_data(nodes),
			c.int(len(nodes)),
		)
		if stbrp.pack_rects(&pack_context, raw_data(rects), c.int(len(rects))) != 0 {return size}
		if size == max_size {return 0}
		size = min(size * 2, max_size)
	}
}

@(private = "file")
sprites_load_atlas :: proc(
	renderer: ^Renderer,
	atlas: Atlas_Id,
	workspace: ^Sprite_Load_Workspace,
) {
	rect_count := 0
	for item, i in workspace.items {
		if item.atlas != atlas || item.width == 0 || item.height == 0 {continue}
		width, height := item.width + 2, item.height + 2
		workspace.rect_storage[rect_count] = {
			id = c.int(i),
			w  = stbrp.Coord(width),
			h  = stbrp.Coord(height),
		}
		rect_count += 1
	}
	rects := workspace.rect_storage[:rect_count]
	atlas_size := sprites_pack_rectangles(rects, workspace.nodes, workspace.max_texture_size)
	if atlas_size == 0 {return}

	bitmap := Bitmap {
		pixels = make([][4]u8, atlas_size * atlas_size, context.temp_allocator),
		width  = atlas_size,
		height = atlas_size,
	}
	texture_id := Texture_Id(u16(atlas) + 1)
	for rect in rects {
		item := workspace.items[rect.id]
		x, y := int(rect.x) + 1, int(rect.y) + 1
		SPRITES.regions[rect.id] = {
			texture = texture_id,
			source  = {f32(x), f32(y), f32(item.width), f32(item.height)},
		}
		if rect.id < IMAGES_MAX {
			sprites_copy_image(bitmap, x, y, workspace.images[rect.id])
		} else {
			font := (int(rect.id) - IMAGES_MAX) / FONT_GLYPHS_MAX
			slot := (int(rect.id) - IMAGES_MAX) % FONT_GLYPHS_MAX
			sprites_rasterize_glyph(
				bitmap,
				x,
				y,
				item,
				&workspace.fonts[font],
				SPRITES.fonts[font].codepoints[slot],
				workspace.glyph_pixels,
			)
		}
	}

	render_create_atlas_texture(renderer, texture_id, bitmap)
}

@(private = "file")
sprites_copy_image :: proc(atlas: Bitmap, x, y: int, image: Bitmap) {
	for row := -1; row <= image.height; row += 1 {
		for column := -1; column <= image.width; column += 1 {
			source :=
				clamp(row, 0, image.height - 1) * image.width + clamp(column, 0, image.width - 1)
			atlas.pixels[(y + row) * atlas.width + x + column] = image.pixels[source]
		}
	}
}

@(private = "file")
sprites_rasterize_glyph :: proc(
	atlas: Bitmap,
	x, y: int,
	item: Sprite_Atlas_Item,
	font: ^Sprite_Loaded_Font,
	codepoint: rune,
	scratch: []u8,
) {
	glyph := scratch[:item.width * item.height]
	mem.zero_slice(glyph)
	stbtt.MakeCodepointBitmap(
		&font.info,
		raw_data(glyph),
		c.int(item.width),
		c.int(item.height),
		c.int(item.width),
		font.scale,
		font.scale,
		codepoint,
	)
	for row := -1; row <= item.height; row += 1 {
		for column := -1; column <= item.width; column += 1 {
			coverage: u8
			if row >= 0 && row < item.height && column >= 0 && column < item.width {
				coverage = glyph[row * item.width + column]
			}
			atlas.pixels[(y + row) * atlas.width + x + column] = {255, 255, 255, coverage}
		}
	}
}

// Where a sprite sits in its atlas.
sprite_region :: proc(sprite: Sprite_Id) -> Sprite_Region {
	assert(SPRITES.loaded, "sprites_load comes first")
	return SPRITES.regions[sprite]
}

// Where a glyph's sprite sits on the pen, and how far it moves it.
sprite_glyph :: proc(sprite: Sprite_Id) -> Sprite_Glyph {
	assert(SPRITES.loaded, "sprites_load comes first")
	return SPRITES.glyphs[sprite]
}

// A font's ascent, descent and line gap.
font_info :: proc(font: Font_Id) -> Font_Info {
	assert(SPRITES.loaded, "sprites_load comes first")
	return SPRITES.fonts[font].info
}

// A font's size in pixels: one em.
font_size :: proc(font: Font_Id) -> f32 {
	assert(SPRITES.loaded, "sprites_load comes first")
	return f32(SPRITES.fonts[font].size)
}

sprite_of_image :: proc(image: Image_Id) -> Sprite_Id {
	assert(int(image) < IMAGES_MAX)
	return Sprite_Id(image)
}

sprite_of_glyph :: proc(font: Font_Id, ch: rune) -> (sprite: Sprite_Id, ok: bool) #optional_ok {
	assert(SPRITES.loaded, "sprites_load comes first")
	assert(int(font) < FONTS_MAX)
	index, found := slice.binary_search(SPRITES.fonts[font].codepoints[:], ch)
	if !found {
		return {}, false
	}

	sprite_index := IMAGES_MAX + int(font) * FONT_GLYPHS_MAX + index
	return Sprite_Id(sprite_index), true
}
