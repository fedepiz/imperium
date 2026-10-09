package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:os"

import stbtt "vendor:stb/truetype"

// Text: fonts rasterised once, at load, into the glyph atlas, and where text goes when drawn.
// Characters FIRST_CHAR to LAST_CHAR have glyphs. Any other is measured and drawn as FALLBACK_CHAR

// The text system as a whole
TEXT: struct {
	fonts:         [TEXT_FONTS_MAX]Font,
	// Fonts loaded: the sources given to text_load, including any that failed
	font_count:    int,
	// Physical pixels per logical pixel the fonts were rasterised for
	pixel_density: f32,
	// This frame's texts, until text_reset.
	// A text is a span of parts and a span of glyphs
	texts:         [dynamic; TEXT_TEXTS_MAX]Text,
	parts:         [dynamic; TEXT_PARTS_MAX]Text_Part,
	glyphs:        [dynamic; TEXT_GLYPHS_MAX]Text_Glyph,
}

TEXT_FONTS_MAX :: 8
// Per frame. Every text has at least one part
TEXT_TEXTS_MAX :: 1 << 14
TEXT_PARTS_MAX :: 1 << 15
TEXT_GLYPHS_MAX :: 1 << 18

#assert(TEXT_PARTS_MAX >= TEXT_TEXTS_MAX)
// Indices stored in Text_Id and Text_Glyph.part
#assert(TEXT_TEXTS_MAX <= 1 << 16)
#assert(TEXT_PARTS_MAX <= 1 << 16)

// A font's index in the sources given to text_load. 0 is the default
Text_Font_Id :: distinct u8

Text_Source :: struct {
	// Under assets/fonts, without .ttf
	filename: string,
	// Pixel height, from the highest ascent to the lowest descent, logical pixels
	size:     u16,
}

// A text of this frame: its index in TEXT.texts
Text_Id :: distinct u16

// A piece of a text in one font and colour, as given to text_make
Text_Part :: struct {
	text:  string,
	font:  Text_Font_Id,
	// Straight RGBA, 0..1
	color: [4]f32,
	// Metadata tag
	tag:   u64,
	underline: bool,
}

// A character of a text as kept, once shaped. Blanks included
Text_Glyph :: struct {
	// Pen position at its start, from the text's start, logical pixels. Kerned
	x:     f32,
	// Index in its font's glyph tables
	glyph:   u8,
	// A newline: drawn and measured as a space, and ends a line in text_wrap
	newline: bool,
	// Its part: index in TEXT.parts
	part:    u16,
}

@(private = "file")
Text :: struct {
	// Of TEXT.parts and TEXT.glyphs
	parts:   Span,
	glyphs:  Span,
	// Pen position of its first glyph, subtracted when placing. 0, but for a line made by text_wrap
	x0:      f32,
	// From x0 to the pen position after its last glyph: its width on one line, logical pixels
	width:   f32,
	// Of the tallest of its parts' fonts, logical pixels. descent is negative
	ascent:  f32,
	descent: f32,
}

@(private = "file")
FIRST_CHAR :: ' '
@(private = "file")
LAST_CHAR :: '~'
@(private = "file")
FALLBACK_CHAR :: '?'
@(private = "file")
CHARS :: int(LAST_CHAR - FIRST_CHAR) + 1

// A write per glyph
#assert(TEXT_FONTS_MAX * CHARS <= RENDER_ATLAS_WRITES_MAX)

// Per glyph tables are indexed by glyph_of(char)
@(private = "file")
Font :: struct {
	// As in its Text_Source
	size:     u16,
	// Logical pixels. descent is negative
	ascent:   f32,
	descent:  f32,
	line_gap: f32,
	// Pen advance after each glyph, in logical pixels
	advances: [CHARS]f32,
	// From the pen position on the baseline to each glyph's top-left, in logical pixels
	offsets:  [CHARS][2]f32,
	// Each glyph's size when drawn, in logical pixels. Zero for blank glyphs
	sizes:    [CHARS][2]f32,
	// Each glyph's rect in the glyph atlas, in texels: sizes * TEXT.pixel_density
	sources:  [CHARS]Extents,
	// kerning[a][b]: added to the advance of glyph a when glyph b follows it, in logical pixels
	kerning:  [CHARS][CHARS]f32,
	// Width of "...": three dots, kerned, in logical pixels
	ellipsis: f32,
}

// Index of char's glyph in a font's tables. A char without a glyph has FALLBACK_CHAR's
@(private = "file")
glyph_of :: proc(char: rune) -> int {
	if char < FIRST_CHAR || char > LAST_CHAR do return int(FALLBACK_CHAR - FIRST_CHAR)
	return int(char - FIRST_CHAR)
}

// Out: out, appended to. Fills TEXT.
// Rasterises each source at its size * pixel_density into the glyph atlas, and keeps its metrics,
// kerning and glyph rects. A font's Text_Font_Id is its index in sources. A font that fails to load
// stays empty
text_load :: proc(sources: []Text_Source, pixel_density: f32, out: ^Render_Init) {
	assert(len(sources) <= TEXT_FONTS_MAX)
	TEXT = {}
	TEXT.font_count = len(sources)
	TEXT.pixel_density = pixel_density > 0 ? pixel_density : 1
	density := TEXT.pixel_density

	// Phase: Rasterise. Each font's metrics, glyph coverage and kerning. Coverage and sizes per font,
	// then glyph: index font * CHARS + glyph
	pixels := make([][]u8, len(sources) * CHARS, context.temp_allocator)
	sizes := make([][2]int, len(sources) * CHARS, context.temp_allocator)
	for source, index in sources {
		font := &TEXT.fonts[index]
		font.size = source.size

		path := fmt.tprintf("assets/fonts/%s.ttf", source.filename)
		data, data_err := os.read_entire_file_from_path(path, context.temp_allocator)
		info: stbtt.fontinfo
		if data_err != nil || !stbtt.InitFont(&info, raw_data(data), 0) {
			fmt.eprintln("Failed to load font", path)
			continue
		}

		// Font units to physical pixels. What is kept is in logical pixels
		scale := stbtt.ScaleForPixelHeight(&info, f32(source.size) * density)
		ascent, descent, line_gap: c.int
		stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
		font.ascent = f32(ascent) * scale / density
		font.descent = f32(descent) * scale / density
		font.line_gap = f32(line_gap) * scale / density

		// Glyphs: advance, placement and coverage
		for glyph in 0 ..< CHARS {
			char := FIRST_CHAR + rune(glyph)

			advance, bearing: c.int
			stbtt.GetCodepointHMetrics(&info, char, &advance, &bearing)
			font.advances[glyph] = f32(advance) * scale / density

			// Glyph box relative to the pen, empty for whitespace
			x0, y0, x1, y1: c.int
			stbtt.GetCodepointBitmapBox(&info, char, scale, scale, &x0, &y0, &x1, &y1)
			w, h := x1 - x0, y1 - y0
			font.offsets[glyph] = [2]f32{f32(x0), f32(y0)} / density
			if w <= 0 || h <= 0 do continue
			font.sizes[glyph] = [2]f32{f32(w), f32(h)} / density

			coverage := make([]u8, w * h, context.temp_allocator)
			stbtt.MakeCodepointBitmap(&info, raw_data(coverage), w, h, w, scale, scale, char)
			pixels[index * CHARS + glyph] = coverage
			sizes[index * CHARS + glyph] = {int(w), int(h)}
		}

		// Kerning: every pair of glyphs
		for glyph in 0 ..< CHARS {
			for next in 0 ..< CHARS {
				kern := stbtt.GetCodepointKernAdvance(
					&info,
					FIRST_CHAR + rune(glyph),
					FIRST_CHAR + rune(next),
				)
				font.kerning[glyph][next] = f32(kern) * scale / density
			}
		}

		// Ellipsis
		dot := glyph_of('.')
		font.ellipsis = 3 * font.advances[dot] + 2 * font.kerning[dot][dot]
	}

	// Phase: Pack. Into the glyph atlas, each glyph's rect kept in its font
	positions := make([][2]int, len(sizes), context.temp_allocator)
	if !render_atlas_pack(out.atlases[.Glyphs], sizes, positions) {
		fmt.eprintln("Glyphs do not fit in their atlas")
		return
	}
	for size, i in sizes {
		pos := positions[i]
		TEXT.fonts[i / CHARS].sources[i % CHARS] = {
			x_min = f32(pos.x),
			y_min = f32(pos.y),
			x_max = f32(pos.x + size.x),
			y_max = f32(pos.y + size.y),
		}
		if size.x <= 0 || size.y <= 0 do continue
		append(
			&out.writes[.Glyphs],
			Render_Write_Pixels{pos = pos, size = size, pixels = pixels[i]},
		)
	}

	text_reset()
}

text_reset :: proc() {
	clear(&TEXT.glyphs)
	clear(&TEXT.parts)
	clear(&TEXT.texts)
	// Entry 0 is no text, so a zero Text_Id means none
	append(&TEXT.texts, Text{})
}

text_make :: proc(parts: []Text_Part) -> Text_Id {
	if (len(TEXT.texts) == cap(TEXT.texts)) do return {}
	id := Text_Id(len(TEXT.texts))

	text: Text
	text.parts.begin = len(TEXT.parts)
	text.glyphs.begin = len(TEXT.glyphs)

	pen: f32
	for part in parts {
		assert(int(part.font) < TEXT.font_count)
		if part.text == "" || len(TEXT.parts) == cap(TEXT.parts) do continue

		font := &TEXT.fonts[part.font]
		text.ascent = max(text.ascent, font.ascent)
		text.descent = min(text.descent, font.descent)

		// Create glyph data
		previous := -1
		part_id := u16(len(TEXT.parts))
		for c in part.text {
			if len(TEXT.glyphs) == cap(TEXT.glyphs) do break
			// Newlines, tabs and carriage returns are spaces. A newline is also marked, for text_wrap
			blank := c == '\n' || c == '\t' || c == '\r'
			glyph := glyph_of(blank ? ' ' : c)
			if previous >= 0 do pen += font.kerning[previous][glyph]
			previous = glyph

			append(
				&TEXT.glyphs,
				Text_Glyph{x = pen, glyph = u8(glyph), newline = c == '\n', part = part_id},
			)
			text.glyphs.len += 1
			pen += font.advances[glyph]
		}

		// Close up the part. Its string is the caller's, so it is not kept
		stored := part
		stored.text = ""
		append(&TEXT.parts, stored)
		text.parts.len += 1
	}
	text.width = pen

	append(&TEXT.texts, text)
	return id
}

// A font's size, as in its Text_Source, and its ascent and descent. Logical pixels, descent negative
Text_Metrics :: struct {
	size:    f32,
	ascent:  f32,
	descent: f32,
}

text_font_metrics :: proc(font: Text_Font_Id) -> Text_Metrics {
	f := &TEXT.fonts[font]
	return {f32(f.size), f.ascent, f.descent}
}

// Width, and height from the tallest ascent to the lowest descent, in logical pixels
text_size :: proc(text: Text_Id) -> [2]f32 {
	t := TEXT.texts[text]
	return {t.width, t.ascent - t.descent}
}

// Tag of the part under x, measured from the text's left. A glyph covers its advance, so a space
// inside a part counts as that part. 0: none, or outside the text
text_tag_at :: proc(text: Text_Id, x: f32) -> u64 {
	t := TEXT.texts[text]
	for glyph in span_slice(TEXT.glyphs[:], t.glyphs) {
		if x >= glyph.x - t.x0 && x < glyph_end(glyph) - t.x0 do return TEXT.parts[glyph.part].tag
	}
	return 0
}

// Out: lines, appended to.
// The text broken into lines no wider than width, each its own text: a span of the text's glyphs,
// nothing shaped again. Breaks at spaces, which are dropped, and at newlines. A word wider than a line
// keeps its own line and overflows. Every line has the text's ascent and descent. Lines past either
// capacity are dropped
text_wrap :: proc(text: Text_Id, width: f32, lines: ^[dynamic; $N]Text_Id) {
	t := TEXT.texts[text]
	glyphs := span_slice(TEXT.glyphs[:], t.glyphs)
	space := u8(glyph_of(' '))

	// Glyphs [begin, end) as a line
	line_add :: proc(t: Text, glyphs: []Text_Glyph, begin, end: int, lines: ^[dynamic; $N]Text_Id) {
		if len(TEXT.texts) == cap(TEXT.texts) || len(lines) == cap(lines) do return
		line := Text {
			glyphs  = {t.glyphs.begin + begin, end - begin},
			ascent  = t.ascent,
			descent = t.descent,
		}
		if end > begin {
			first := glyphs[begin]
			last := glyphs[end - 1]
			line.parts = {int(first.part), int(last.part) - int(first.part) + 1}
			line.x0 = first.x
			line.width = glyph_end(last) - first.x
		}
		append(lines, Text_Id(len(TEXT.texts)))
		append(&TEXT.texts, line)
	}

	// Greedy: a line ends at its last space before a glyph would cross width, or at a newline.
	// begin: the line's first glyph. after: the glyph after its last space, -1 = none yet
	begin := 0
	after := -1
	for i := 0; i < len(glyphs); i += 1 {
		glyph := glyphs[i]
		if glyph.newline {
			line_add(t, glyphs, begin, i, lines)
			begin = i + 1
			after = -1
			continue
		}
		if glyph.glyph == space {
			// Spaces at the start of a line are dropped
			if i == begin {
				begin += 1
				continue
			}
			after = i + 1
			continue
		}
		if after > begin && glyph_end(glyph) - glyphs[begin].x > width {
			// The line ends at its last space, trailing spaces dropped
			end := after - 1
			for end > begin && glyphs[end - 1].glyph == space do end -= 1
			line_add(t, glyphs, begin, end, lines)
			begin = after
			after = -1
			// The glyph is laid out again, as part of the next line
			i = begin - 1
		}
	}
	end := len(glyphs)
	for end > begin && glyphs[end - 1].glyph == space do end -= 1
	line_add(t, glyphs, begin, end, lines)
}

// Pen position after glyph, kerning to the next excluded
@(private = "file")
glyph_end :: proc(glyph: Text_Glyph) -> f32 {
	return glyph.x + TEXT.fonts[TEXT.parts[glyph.part].font].advances[glyph.glyph]
}

// A text may be this much wider than max_width without being cut
@(private = "file")
FIT_SLACK :: 0.01

// Out: quads, appended to.
// The text's glyphs as quads of the glyph atlas, the top-left of its line at pos: its baseline is
// pos.y + its ascent. Wider than max_width: cut after the last character that leaves room for "...",
// which follows in that character's font and colour. Spaces before it are dropped.
// snap: each glyph's top-left on a whole physical pixel, for text drawn at its rasterised size.
// clip: as Render_Quad.clip. Quads past the capacity are dropped
text_quads :: proc(
	text: Text_Id,
	pos: [2]f32,
	max_width: f32,
	snap: bool,
	clip: Extents,
	quads: ^[dynamic; $N]Render_Quad,
) {
	t := TEXT.texts[text]
	glyphs := span_slice(TEXT.glyphs[:], t.glyphs)
	// Glyph x to the pen position from pos
	baseline := pos + {-t.x0, t.ascent}
	space := u8(glyph_of(' '))

	// Phase: Cut. How many glyphs are kept, and the part "..." takes its font and colour from.
	// It fits: all of them, and no "..."
	kept := len(glyphs)
	ellipsis_part := -1
	if t.width > max_width + FIT_SLACK && t.parts.len > 0 {
		ellipsis_part = t.parts.begin
		for kept > 0 {
			glyph := glyphs[kept - 1]
			font := &TEXT.fonts[TEXT.parts[glyph.part].font]
			end := glyph_end(glyph) - t.x0
			if glyph.glyph != space && end + font.ellipsis <= max_width {
				ellipsis_part = int(glyph.part)
				break
			}
			kept -= 1
		}
	}

	// Phase: Glyphs. Blank ones only moved the pen
	for glyph in glyphs[:kept] {
		part := TEXT.parts[glyph.part]
		font := &TEXT.fonts[part.font]
		pen := baseline + {glyph.x, 0}
		if quad, drawn := glyph_quad(font, int(glyph.glyph), pen, part.color, snap, clip); drawn {
			append(quads, quad)
		}
	}

	run_start := 0
	for run_start < kept {
		run_part := glyphs[run_start].part
		run_end := run_start + 1
		for run_end < kept && glyphs[run_end].part == run_part do run_end += 1
		part := TEXT.parts[run_part]
		if part.underline {
			size := f32(TEXT.fonts[part.font].size)
			thickness := max(1, math.round(size / 16))
			lo := baseline + {glyphs[run_start].x, math.round(size / 12)}
			hi := baseline + {glyph_end(glyphs[run_end - 1]), math.round(size / 12) + thickness}
			if snap {
				lo = linalg.round(lo * TEXT.pixel_density) / TEXT.pixel_density
				hi = linalg.round(hi * TEXT.pixel_density) / TEXT.pixel_density
			}
			c := linalg.clamp(part.color, 0, 1) * 255 + 0.5
			bytes := [4]u8{u8(c.r), u8(c.g), u8(c.b), u8(c.a)}
			append(
				quads,
				Render_Quad {
					rect = {lo.x, lo.y, hi.x, hi.y},
					clip = clip,
					colors = {bytes, bytes, bytes, bytes},
				},
			)
		}
		run_start = run_end
	}

	// Phase: Ellipsis. Three dots from the end of the last glyph kept
	if ellipsis_part >= 0 {
		part := TEXT.parts[ellipsis_part]
		font := &TEXT.fonts[part.font]
		pen := baseline
		if kept > 0 do pen.x += glyph_end(glyphs[kept - 1])
		dot := glyph_of('.')
		for _ in 0 ..< 3 {
			if quad, drawn := glyph_quad(font, dot, pen, part.color, snap, clip); drawn {
				append(quads, quad)
			}
			pen.x += font.advances[dot] + font.kerning[dot][dot]
		}
	}
}

// A glyph's quad, its pen at pen on the baseline. color: straight RGBA, 0..1.
// Not drawn: a blank glyph, which has no quad
@(private = "file")
glyph_quad :: proc(
	font: ^Font,
	glyph: int,
	pen: [2]f32,
	color: [4]f32,
	snap: bool,
	clip: Extents,
) -> (
	quad: Render_Quad,
	drawn: bool,
) {
	size := font.sizes[glyph]
	if size.x <= 0 || size.y <= 0 do return
	lo := pen + font.offsets[glyph]
	if snap do lo = linalg.round(lo * TEXT.pixel_density) / TEXT.pixel_density
	c := linalg.clamp(color, 0, 1) * 255 + 0.5
	bytes := [4]u8{u8(c.r), u8(c.g), u8(c.b), u8(c.a)}
	quad = {
		rect = {lo.x, lo.y, lo.x + size.x, lo.y + size.y},
		clip = clip,
		colors = {bytes, bytes, bytes, bytes},
		source = font.sources[glyph],
		atlas = .Glyphs,
	}
	return quad, true
}
