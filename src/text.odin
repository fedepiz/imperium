#+private
package main

// Text geometry: where each character of a text goes, from the characters and their metrics alone.
// No pixels, colours, links or storage. What the caller knows about a run it finds again through
// Text_Glyph.run

// A text may overshoot its room by this much, so a text laid out in its own size neither wraps nor truncates
@(private = "file")
FIT_SLACK :: 0.01

// What ends a line cut short because the text does not fit its room's height
@(private = "file")
ELLIPSIS_CHAR :: '.'
@(private = "file")
ELLIPSIS_COUNT :: 3

// A stretch of text in one font, or an inline image
Text_Run :: struct {
	text:         string,
	// Index into the fonts given with the runs
	font:         int,
	// Not 0: the run is an image, not text. Height: one line of its font. Width: this times the height
	image_aspect: f32,
}

// Metrics of a font. Any unit: the layout comes out in the same one
Text_Font :: struct {
	// Above the baseline, positive
	ascent:   f32,
	// Below the baseline, negative
	descent:  f32,
	// Between the descent of one line and the ascent of the next
	line_gap: f32,
	// advances[i]: pen advance of the character first + i. Other characters take no room and give no glyph
	first:    rune,
	advances: []f32,
	// The box each character's bitmap fills, indexed like advances. offsets: from the pen position on
	// the baseline to its top-left. Zero size, or past the arrays: the character has no bitmap.
	// Only Text_Glyph.ink is made from these: they can be left empty
	offsets:  [][2]f32,
	sizes:    [][2]f32,
}

// A character or image, placed relative to the text's top-left corner. +y down
Text_Glyph :: struct {
	// Index of its run
	run:    int,
	// Byte offset of the character in its run's text. -1: not from the text, a dot of the ellipsis
	offset: int,
	// 0 for an image
	char:   rune,
	// Pen position, on the baseline
	pen:    [2]f32,
	// The box it occupies: from the pen its advance wide, and its line tall
	cell:   Extents,
	// The box its bitmap fills. Zero for a character without one. For an image: its cell
	ink:    Extents,
}

Text_Line :: struct {
	// Its glyphs: a range of the layout's
	glyphs_begin: int,
	glyphs_len:   int,
	top:          f32,
	// Of the tallest font on the line. The baseline is at top + ascent, the bottom at top + ascent - descent
	ascent:       f32,
	descent:      f32,
	width:        f32,
}

Text_Layout :: struct {
	size:        [2]f32,
	// Lines past the room's height were left out, and the last one kept ends in an ellipsis
	truncated:   bool,
	// Entries written to the buffers
	glyph_count: int,
	line_count:  int,
}

// Where a layout stands: the pen, the line being filled, and the last line closed
@(private = "file")
Pen :: struct {
	runs:           []Text_Run,
	fonts:          []Text_Font,
	room:           [2]f32,
	glyphs:         []Text_Glyph,
	lines:          []Text_Line,
	// Glyphs and lines produced so far. Past the buffers they are counted but not stored
	glyph_count:    int,
	line_count:     int,
	size:           [2]f32,
	truncated:      bool,
	// A line did not fit the room's height: nothing more is laid out
	stopped:        bool,
	// Something was laid out, so the text has at least one line
	any:            bool,
	// Pen position on the line, from its left edge
	x:              f32,
	// Separators since the last word. Their glyphs are produced as they come, at the end of the
	// glyphs so far, and dropped if no word follows them on the line
	pending:        f32,
	pending_count:  int,
	pending_begin:  int,
	// The line being filled
	line_top:       f32,
	line_begin:     int,
	// It began because the one before was full: separators at its start are dropped
	line_wrapped:   bool,
	// Run of its first glyph, -1 = none yet
	line_first_run: int,
	// Tallest ascent and descent, and widest gap, of the fonts with something on the line
	ascent:         f32,
	descent:        f32,
	line_gap:       f32,
	// Where the line would be cut for an ellipsis: after the last glyph the ellipsis still fits behind
	cut:            Cut,
	// The last line closed
	last_begin:     int,
	last_top:       f32,
	last_ascent:    f32,
	last_descent:   f32,
	last_first_run: int,
	last_cut:       Cut,
}

@(private = "file")
Cut :: struct {
	valid:       bool,
	// Glyphs kept
	glyph_count: int,
	// Where the ellipsis begins
	x:           f32,
	// The run it follows: the ellipsis is in its font and belongs to it
	run:         int,
}

// Box of a character's bitmap, with the pen at the origin. Empty if it has none
@(private = "file")
ink_of :: proc(font: Text_Font, char: rune) -> Extents {
	index := int(char) - int(font.first)
	if index < 0 || index >= len(font.offsets) || index >= len(font.sizes) do return {}
	size := font.sizes[index]
	if size.x <= 0 || size.y <= 0 do return {}
	offset := font.offsets[index]
	return {offset.x, offset.y, offset.x + size.x, offset.y + size.y}
}

@(private = "file")
advance_of :: proc(font: Text_Font, char: rune) -> (advance: f32, found: bool) {
	index := int(char) - int(font.first)
	if index < 0 || index >= len(font.advances) do return 0, false
	return font.advances[index], true
}

// Out: glyphs, lines.
// Lays the runs out in room: lines no wider than room.x, and none past room.y but the first.
// An infinite room leaves that axis unbounded.
// Lines break at spaces and tabs. Separators at a break are dropped. A word longer than a line is split
// between characters. LF ends a line, CR is ignored. Each line is as tall as the tallest font on it.
// The first line past room.y is left out with all after it, and the line before it is cut to end in "...".
// Glyphs and lines that do not fit their buffers are dropped: size and truncated are still right, so
// empty buffers measure
text_layout :: proc(
	runs: []Text_Run,
	fonts: []Text_Font,
	room: [2]f32,
	glyphs: []Text_Glyph,
	lines: []Text_Line,
) -> Text_Layout {
	// Makes the line at least as tall as font
	touch :: proc(pen: ^Pen, font: Text_Font) {
		pen.ascent = max(pen.ascent, font.ascent)
		pen.descent = min(pen.descent, font.descent)
		pen.line_gap = max(pen.line_gap, font.line_gap)
		pen.any = true
	}

	// Adds a glyph at the pen, advance wide. Its heights come when the line closes: until then its
	// ink is relative to the baseline
	put :: proc(pen: ^Pen, run, offset: int, char: rune, x, advance: f32) {
		if pen.glyph_count < len(pen.glyphs) {
			ink := ink_of(pen.fonts[pen.runs[run].font], char)
			// No bitmap: stays the zero box
			if ink.x_max > ink.x_min {
				ink.x_min += x
				ink.x_max += x
			}
			pen.glyphs[pen.glyph_count] = {
				run = run,
				offset = offset,
				char = char,
				pen = {x, 0},
				cell = {x_min = x, x_max = x + advance},
				ink = ink,
			}
		}
		pen.glyph_count += 1
		if pen.line_first_run < 0 do pen.line_first_run = run
	}

	// After a visible glyph ending at pen.x: the line can be cut here if an ellipsis fits behind it
	cut_here :: proc(pen: ^Pen, run: int) {
		dot, _ := advance_of(pen.fonts[pen.runs[run].font], ELLIPSIS_CHAR)
		if pen.x + dot * ELLIPSIS_COUNT > pen.room.x + FIT_SLACK do return
		pen.cut = {
			valid       = true,
			glyph_count = pen.glyph_count,
			x           = pen.x,
			run         = run,
		}
	}

	// Drops the line being filled, cuts the last closed line at its cut and ends it in an ellipsis
	truncate :: proc(pen: ^Pen) {
		pen.stopped = true
		pen.truncated = true
		cut := pen.last_cut
		if !cut.valid {
			// No glyph leaves room for the ellipsis: it stands alone
			cut = {
				glyph_count = pen.last_begin,
				run         = max(pen.last_first_run, 0),
			}
		}
		pen.glyph_count = cut.glyph_count

		font := pen.fonts[pen.runs[cut.run].font]
		dot, _ := advance_of(font, ELLIPSIS_CHAR)
		ink := ink_of(font, ELLIPSIS_CHAR)
		baseline := pen.last_top + pen.last_ascent
		bottom := baseline - pen.last_descent
		for i in 0 ..< ELLIPSIS_COUNT {
			x := cut.x + f32(i) * dot
			if pen.glyph_count < len(pen.glyphs) {
				pen.glyphs[pen.glyph_count] = {
					run    = cut.run,
					offset = -1,
					char   = ELLIPSIS_CHAR,
					pen    = {x, baseline},
					cell   = {x, pen.last_top, x + dot, bottom},
					ink    = {
						x + ink.x_min,
						baseline + ink.y_min,
						x + ink.x_max,
						baseline + ink.y_max,
					},
				}
			}
			pen.glyph_count += 1
		}
		width := cut.x + dot * ELLIPSIS_COUNT
		if pen.line_count - 1 < len(pen.lines) {
			line := &pen.lines[pen.line_count - 1]
			line.glyphs_len = pen.glyph_count - line.glyphs_begin
			line.width = width
		}
		pen.size.x = max(pen.size.x, width)
	}

	// Closes the line being filled: puts its glyphs on its baseline and grows the text around it.
	// A line past the room's height, other than the first, is dropped and the text truncated
	line_close :: proc(pen: ^Pen) {
		// No word followed them
		if pen.pending_count > 0 do pen.glyph_count = pen.pending_begin
		pen.pending = 0
		pen.pending_count = 0

		bottom := pen.line_top + pen.ascent - pen.descent
		if pen.line_count > 0 && bottom > pen.room.y + FIT_SLACK {
			truncate(pen)
			return
		}
		baseline := pen.line_top + pen.ascent
		for &glyph in pen.glyphs[min(pen.line_begin, len(pen.glyphs)):min(pen.glyph_count, len(pen.glyphs))] {
			glyph.pen.y = baseline
			glyph.cell.y_min = pen.line_top
			glyph.cell.y_max = bottom
			if glyph.char == 0 {
				glyph.ink = glyph.cell
			} else if glyph.ink.x_max > glyph.ink.x_min {
				glyph.ink.y_min += baseline
				glyph.ink.y_max += baseline
			}
		}
		if pen.line_count < len(pen.lines) {
			pen.lines[pen.line_count] = {
				glyphs_begin = pen.line_begin,
				glyphs_len   = pen.glyph_count - pen.line_begin,
				top          = pen.line_top,
				ascent       = pen.ascent,
				descent      = pen.descent,
				width        = pen.x,
			}
		}
		pen.line_count += 1
		pen.size.x = max(pen.size.x, pen.x)
		pen.size.y = bottom

		pen.last_begin = pen.line_begin
		pen.last_top = pen.line_top
		pen.last_ascent = pen.ascent
		pen.last_descent = pen.descent
		pen.last_first_run = pen.line_first_run
		pen.last_cut = pen.cut
	}

	// Ends the line and starts the next below it. wrapped: it ended because it was full
	line_next :: proc(pen: ^Pen, wrapped: bool) {
		line_close(pen)
		if pen.stopped do return
		pen.line_top += pen.ascent - pen.descent + pen.line_gap
		pen.x = 0
		pen.ascent = 0
		pen.descent = 0
		pen.line_gap = 0
		pen.line_begin = pen.glyph_count
		pen.line_wrapped = wrapped
		pen.line_first_run = -1
		pen.cut = {}
	}

	// Before a word: moves to the next line if it does not fit on this one, then settles the
	// separators before it
	word_begin :: proc(pen: ^Pen, width: f32) {
		if pen.x > 0 && pen.x + pen.pending + width > pen.room.x + FIT_SLACK {
			line_next(pen, true)
			if pen.stopped do return
		}
		if pen.pending_count > 0 {
			if pen.x > 0 || !pen.line_wrapped {
				pen.x += pen.pending
			} else {
				// At the start of a wrapped line
				pen.glyph_count = pen.pending_begin
			}
			pen.pending = 0
			pen.pending_count = 0
		}
	}

	// Width of the word starting at offset in runs[run_index]. It may carry on into later runs
	word_width :: proc(
		runs: []Text_Run,
		fonts: []Text_Font,
		run_index, offset: int,
	) -> (
		width: f32,
	) {
		start := offset
		for run in runs[run_index:] {
			if run.image_aspect != 0 do return
			for char in run.text[start:] {
				switch char {
				case ' ', '\t', '\n':
					return
				case '\r':
				case:
					advance, _ := advance_of(fonts[run.font], char)
					width += advance
				}
			}
			start = 0
		}
		return
	}

	pen := Pen {
		runs           = runs,
		fonts          = fonts,
		room           = room,
		glyphs         = glyphs,
		lines          = lines,
		line_first_run = -1,
	}
	word_start := true

	laying: for run, run_index in runs {
		font := fonts[run.font]

		// An image is a word of its own
		if run.image_aspect != 0 {
			width := run.image_aspect * (font.ascent - font.descent)
			word_begin(&pen, width)
			if pen.stopped do break laying
			touch(&pen, font)
			put(&pen, run_index, 0, 0, pen.x, width)
			pen.x += width
			cut_here(&pen, run_index)
			word_start = true
			continue
		}

		for char, offset in run.text {
			switch char {
			case '\r':
			case '\n':
				// The newline's font sizes the line it ends and the one it starts, even when empty
				touch(&pen, font)
				line_next(&pen, false)
				if pen.stopped do break laying
				touch(&pen, font)
				word_start = true
			case ' ', '\t':
				touch(&pen, font)
				advance, found := advance_of(font, char)
				if pen.pending_count == 0 do pen.pending_begin = pen.glyph_count
				if found do put(&pen, run_index, offset, char, pen.x + pen.pending, advance)
				pen.pending += advance
				pen.pending_count += 1
				word_start = true
			case:
				advance, found := advance_of(font, char)
				if word_start {
					word_begin(&pen, word_width(runs, fonts, run_index, offset))
					word_start = false
				} else if pen.x > 0 && pen.x + advance > room.x + FIT_SLACK {
					// A word longer than a line goes on over the next
					line_next(&pen, true)
				}
				if pen.stopped do break laying
				touch(&pen, font)
				if found {
					put(&pen, run_index, offset, char, pen.x, advance)
					pen.x += advance
					cut_here(&pen, run_index)
				}
			}
		}
	}
	if pen.any && !pen.stopped do line_close(&pen)

	return {
		size = pen.size,
		truncated = pen.truncated,
		glyph_count = min(pen.glyph_count, len(glyphs)),
		line_count = min(pen.line_count, len(lines)),
	}
}

