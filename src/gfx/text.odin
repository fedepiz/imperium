package gfx

import "core:math"

import "../span"

// Texts built in one frame, and the room for their runs and laid-out pieces
@(private = "file")
TEXT_MAX :: 4096
@(private = "file")
TEXT_RUNS_MAX :: 8192
@(private = "file")
TEXT_PIECES_MAX :: 65536
@(private = "file")
TEXT_BLOB_SIZE :: 1_000_000

// Text may overshoot its room by this much, so text laid out in its own size neither wraps nor truncates
@(private = "file")
TEXT_FIT_SLACK :: 0.01

// What ends a line cut short because the text does not fit its room
@(private = "file")
TEXT_ELLIPSIS :: "..."

// A text built this frame. Id 0 is the empty text.
Text_Id :: distinct u16

// Text in one font and color, or an image one line of that font tall when there is an image.
@(private = "file")
Text_Run :: struct {
	text:      string,
	font:      Font_Id,
	color:     [4]f32,
	image:     Maybe(Image_Id),
	// Opaque to the text layer, 0 for none; text_tag_at finds it under a point
	tag:       u64,
	underline: bool,
}

// One glyph or image, placed relative to the text's top-left corner.
@(private = "file")
Text_Piece :: struct {
	sprite:    Sprite_Id,
	rect:      [4]f32,
	color:     [4]f32,
	// The run's font, tag, and the space the piece answers for under the mouse: its advance, a line tall
	font:      Font_Id,
	tag:       u64,
	cell:      [4]f32,
	// A line under the cell in the piece's color when it has a size; y is from the baseline until the line closes
	underline: [4]f32,
}

// A text's runs, and its layout for the last room asked for
@(private = "file")
Text :: struct {
	runs:      span.Span,
	laid_out:  bool,
	room:      [2]f32,
	pieces:    span.Span,
	size:      [2]f32,
	// Lines past the room's height were left out, and the last one kept ends in an ellipsis
	truncated: bool,
}

// The texts of this frame
@(private = "file")
TEXTS: struct {
	texts:       [TEXT_MAX]Text,
	text_count:  int,
	runs:        [TEXT_RUNS_MAX]Text_Run,
	run_count:   int,
	pieces:      [TEXT_PIECES_MAX]Text_Piece,
	piece_count: int,
	// Run strings are copied here, so callers can build texts from temporaries
	blob:        [TEXT_BLOB_SIZE]byte,
	blob_len:    int,
	// Set between text_new and text_end; the open text's runs begin at open_begin
	open:        bool,
	open_begin:  int,
}

// Forgets every text of the last frame.
text_begin :: proc() {
	assert(!TEXTS.open)
	TEXTS.text_count = 0
	TEXTS.run_count = 0
	TEXTS.piece_count = 0
	TEXTS.blob_len = 0
}

// Opens a new text; runs added until text_end belong to it.
text_new :: proc() {
	assert(!TEXTS.open, "texts cannot be built inside each other")
	TEXTS.open = true
	TEXTS.open_begin = TEXTS.run_count
}

// Adds text in a font and color to the open text, tagged for text_tag_at. A full blob keeps what fits.
text_add :: proc(text: string, font: Font_Id, color: [4]f32, tag: u64 = 0, underline := false) {
	n := copy(TEXTS.blob[TEXTS.blob_len:], text)
	copied := string(TEXTS.blob[TEXTS.blob_len:][:n])
	TEXTS.blob_len += n
	text_add_run({text = copied, font = font, color = color, tag = tag, underline = underline})
}

// Adds an image to the open text, one line of font tall, tinted by color and tagged for text_tag_at.
text_add_image :: proc(
	image: Image_Id,
	font: Font_Id,
	color: [4]f32,
	tag: u64 = 0,
	underline := false,
) {
	text_add_run({font = font, color = color, image = image, tag = tag, underline = underline})
}

// Closes the open text and returns its id.
text_end :: proc() -> Text_Id {
	assert(TEXTS.open)
	TEXTS.open = false
	// Counted before use, so ids start at 1 and 0 stays the empty text, even before the first text_begin.
	TEXTS.text_count += 1
	assert(TEXTS.text_count < TEXT_MAX)
	id := Text_Id(TEXTS.text_count)
	TEXTS.texts[id] = {
		runs = span.from_range(TEXTS.open_begin, TEXTS.run_count),
	}
	return id
}

// A text of one string in one font and color.
text_from_string :: proc(text: string, font: Font_Id, color: [4]f32) -> Text_Id {
	text_new()
	text_add(text, font, color)
	return text_end()
}

@(private = "file")
ROOM_INF :: [2]f32{math.INF_F32, math.INF_F32}

// The size of the text laid out in room: lines no wider than room.x, cut short with an ellipsis below room.y.
// An infinite room leaves that axis unbounded; without one, neither is.
text_measure :: proc(id: Text_Id, room := ROOM_INF) -> [2]f32 {
	return text_laid_out(id, room).size
}

// Whether laying the text out in room left some of it out.
text_truncated :: proc(id: Text_Id, room := ROOM_INF) -> bool {
	return text_laid_out(id, room).truncated
}

// Draws the text laid out in room, its top-left at position, colors multiplied by tint.
text_draw :: proc(
	draw: ^Draw_Ctx,
	id: Text_Id,
	position: [2]f32,
	room := ROOM_INF,
	tint := [4]f32{1, 1, 1, 1},
) {
	text := text_laid_out(id, room)
	for piece in TEXTS.pieces[text.pieces.begin:][:text.pieces.len] {
		if piece.underline.z > 0 {
			underline := piece.underline
			underline.xy += position
			draw_rectangle(draw, underline, piece.color * tint)
		}
		// Blank glyphs of tagged and underlined runs are kept only for their cells.
		if piece.rect.z <= 0 {continue}
		rect := piece.rect
		rect.xy += position
		draw_sprite(draw, piece.sprite, rect, piece.color * tint, flags = {.Snap})
	}
}

// The tag of the run under point, relative to the text's top-left, laid out in room; 0 over untagged text or nothing.
text_tag_at :: proc(id: Text_Id, point: [2]f32, room := ROOM_INF) -> u64 {
	text := text_laid_out(id, room)
	for piece in TEXTS.pieces[text.pieces.begin:][:text.pieces.len] {
		if piece.tag != 0 && rect_contains(piece.cell, point) {
			return piece.tag
		}
	}
	return 0
}

@(private = "file")
text_add_run :: proc(run: Text_Run) {
	assert(TEXTS.open, "runs are added between text_new and text_end")
	assert(TEXTS.run_count < TEXT_RUNS_MAX)
	TEXTS.runs[TEXTS.run_count] = run
	TEXTS.run_count += 1
}

// The text, laid out in room unless it already was. A layout that left nothing out serves any room as wide and at least as tall.
@(private = "file")
text_laid_out :: proc(id: Text_Id, room: [2]f32) -> ^Text {
	text := &TEXTS.texts[id]
	fits :=
		text.laid_out &&
		text.room.x == room.x &&
		!text.truncated &&
		text.size.y <= room.y + TEXT_FIT_SLACK
	if !fits && (!text.laid_out || text.room != room) {
		text.laid_out = true
		text.room = room
		text_layout(text)
	}
	return text
}

// Where the layout of one text stands: the pen, the line being filled, and the last line closed.
@(private = "file")
Text_Pen :: struct {
	text:           ^Text,
	room:           [2]f32,
	// Pen position on the line, from the line's left edge
	x:              f32,
	// Separators seen since the last word, placed only if another word follows on the line, and their run and its tag
	separators:     f32,
	separators_run: int,
	separators_tag: u64,
	// Top of the current line, and where its pieces begin
	line_top:       f32,
	line_begin:     int,
	// The line began because the one before it was full, so separators at its start are dropped
	line_wrapped:   bool,
	// Tallest ascent and descent, and widest gap, of the runs with something on the line
	ascent:         f32,
	descent:        f32,
	line_gap:       f32,
	// The next glyph begins a word, which moves to the next line whole if it does not fit
	word_start:     bool,
	// Anything at all was laid out, so the text has at least one line
	any:            bool,
	// Lines closed so far, and the last one: where its pieces lie, its top and its ascent and descent
	lines:          int,
	last_begin:     int,
	last_end:       int,
	last_top:       f32,
	last_ascent:    f32,
	last_descent:   f32,
	// A line did not fit the room's height; nothing more is laid out
	stopped:        bool,
}

// Breaks the runs into lines at spaces and tabs, splitting words longer than a line between runes.
// Each line sits on one baseline under its tallest run. LF starts a line; CR is ignored.
// The first line past the room's height is left out with everything after it, and the line before it ends in an ellipsis.
@(private = "file")
text_layout :: proc(text: ^Text) {
	pen := Text_Pen {
		text           = text,
		room           = text.room,
		line_begin     = TEXTS.piece_count,
		word_start     = true,
		separators_run = -1,
	}
	text.size = {}
	text.truncated = false
	text.pieces = {TEXTS.piece_count, 0}
	width := text.room.x
	runs := TEXTS.runs[text.runs.begin:][:text.runs.len]

	runs_loop: for run, run_index in runs {
		if image, is_image := run.image.?; is_image {
			// An image is a word of its own, one line of its font tall.
			info := font_info(run.font)
			sprite := sprite_of_image(image)
			source := sprite_region(sprite).source
			height := info.ascent - info.descent
			image_width := source.z * height / source.w if source.w > 0 else 0
			gap := text_pen_word(&pen, image_width, run_index, run.tag)
			if pen.stopped {break runs_loop}
			text_pen_touch(&pen, run.font)
			rect := [4]f32{pen.x, -info.ascent, image_width, height}
			text_pen_piece(&pen, run, sprite, rect, pen.x - gap, image_width + gap)
			pen.x += image_width
			pen.word_start = true
			continue
		}

		for ch, offset in run.text {
			switch ch {
			case '\r':
			case '\n':
				// The newline's font sizes both the line it ends and the one it starts, even when they are empty.
				text_pen_touch(&pen, run.font)
				text_pen_line(&pen, false)
				if pen.stopped {break runs_loop}
				text_pen_touch(&pen, run.font)
				pen.word_start = true
			case ' ', '\t':
				text_pen_touch(&pen, run.font)
				if sprite, found := sprite_of_glyph(run.font, ch); found {
					pen.separators += sprite_glyph(sprite).advance
				}
				pen.separators_run = run_index
				pen.separators_tag = run.tag
				pen.word_start = true
			case:
				sprite, found := sprite_of_glyph(run.font, ch)
				glyph: Sprite_Glyph
				if found {glyph = sprite_glyph(sprite)}
				gap: f32
				if pen.word_start {
					word_width := text_word_width(runs, run_index, offset)
					gap = text_pen_word(&pen, word_width, run_index, run.tag)
					pen.word_start = false
				} else if pen.x > 0 && pen.x + glyph.advance > width + TEXT_FIT_SLACK {
					// A word longer than a line goes on over the next.
					text_pen_line(&pen, true)
				}
				if pen.stopped {break runs_loop}
				text_pen_touch(&pen, run.font)
				// Tagged and underlined runs keep blank glyphs too, so neither the mouse nor the line finds holes.
				if found && (glyph.size.x > 0 || run.tag != 0 || run.underline) {
					rect := [4]f32 {
						pen.x + glyph.offset.x,
						glyph.offset.y,
						glyph.size.x,
						glyph.size.y,
					}
					text_pen_piece(&pen, run, sprite, rect, pen.x - gap, glyph.advance + gap)
				}
				pen.x += glyph.advance
			}
		}
	}

	if pen.any && !pen.stopped {
		text_pen_close(&pen)
	}
	text.pieces.len = TEXTS.piece_count - text.pieces.begin
}

// The width of the word starting at offset in runs[run_index], which may carry on into later runs.
@(private = "file")
text_word_width :: proc(runs: []Text_Run, run_index, offset: int) -> f32 {
	width: f32
	start := offset
	for run in runs[run_index:] {
		if run.image != nil {return width}
		for ch in run.text[start:] {
			switch ch {
			case ' ', '\t', '\n':
				return width
			case '\r':
			case:
				if sprite, found := sprite_of_glyph(run.font, ch); found {
					width += sprite_glyph(sprite).advance
				}
			}
		}
		start = 0
	}
	return width
}

// Makes the line at least as tall as font.
@(private = "file")
text_pen_touch :: proc(pen: ^Text_Pen, font: Font_Id) {
	info := font_info(font)
	pen.ascent = max(pen.ascent, info.ascent)
	pen.descent = min(pen.descent, info.descent)
	pen.line_gap = max(pen.line_gap, info.line_gap)
	pen.any = true
}

// Moves to the next line if a word of word_width would not fit on this one, then places the separators before it.
// Returns how much of that space the word's first cell covers: all of it when it came from the same run, or one of the same tag.
@(private = "file")
text_pen_word :: proc(pen: ^Text_Pen, word_width: f32, run_index: int, tag: u64) -> (gap: f32) {
	if pen.x > 0 && pen.x + pen.separators + word_width > pen.room.x + TEXT_FIT_SLACK {
		text_pen_line(pen, true)
		if pen.stopped {return}
	}
	if pen.x > 0 || !pen.line_wrapped {
		pen.x += pen.separators
		if pen.separators_run == run_index || (tag != 0 && pen.separators_tag == tag) {
			gap = pen.separators
		}
	}
	pen.separators = 0
	return
}

// Ends the line and starts the next below it; wrapped when the line ended because it was full.
@(private = "file")
text_pen_line :: proc(pen: ^Text_Pen, wrapped: bool) {
	text_pen_close(pen)
	if pen.stopped {return}
	pen.line_top += pen.ascent - pen.descent + pen.line_gap
	pen.x, pen.separators = 0, 0
	pen.ascent, pen.descent, pen.line_gap = 0, 0, 0
	pen.line_begin = TEXTS.piece_count
	pen.line_wrapped = wrapped
}

// Puts the line's pieces on its baseline and grows the text around it.
// A line past the room's height, other than the first, is dropped instead and the text is cut short.
@(private = "file")
text_pen_close :: proc(pen: ^Text_Pen) {
	bottom := pen.line_top + pen.ascent - pen.descent
	if pen.lines > 0 && bottom > pen.room.y + TEXT_FIT_SLACK {
		text_pen_truncate(pen)
		return
	}
	baseline := pen.line_top + pen.ascent
	for &piece in TEXTS.pieces[pen.line_begin:TEXTS.piece_count] {
		piece.rect.y += baseline
		piece.cell.y = pen.line_top
		piece.cell.w = pen.ascent - pen.descent
		piece.underline.y += baseline
	}
	pen.text.size.x = max(pen.text.size.x, pen.x)
	pen.text.size.y = bottom
	pen.lines += 1
	pen.last_begin = pen.line_begin
	pen.last_end = TEXTS.piece_count
	pen.last_top = pen.line_top
	pen.last_ascent = pen.ascent
	pen.last_descent = pen.descent
}

// Drops the line being filled, then cuts the last closed line back until an ellipsis fits after it, and adds the ellipsis.
// The ellipsis takes the font, color, tag and underline of the piece it follows.
@(private = "file")
text_pen_truncate :: proc(pen: ^Text_Pen) {
	pen.stopped = true
	pen.text.truncated = true
	TEXTS.piece_count = pen.last_end

	// Pieces dropped for a full table leave nothing to follow; the first run then gives the look.
	like: Text_Piece
	if pen.last_end > pen.last_begin {
		like = TEXTS.pieces[pen.last_end - 1]
	} else if pen.text.runs.len > 0 {
		run := TEXTS.runs[pen.text.runs.begin]
		like = {
			font  = run.font,
			color = run.color,
			tag   = run.tag,
		}
	}
	dot, found := sprite_of_glyph(like.font, '.')
	glyph: Sprite_Glyph
	if found {glyph = sprite_glyph(dot)}
	ellipsis_width := glyph.advance * f32(len(TEXT_ELLIPSIS))

	x: f32
	for TEXTS.piece_count > pen.last_begin {
		last := TEXTS.pieces[TEXTS.piece_count - 1]
		x = last.cell.x + last.cell.z
		if x + ellipsis_width <= pen.room.x + TEXT_FIT_SLACK {break}
		TEXTS.piece_count -= 1
		x = 0
	}

	baseline := pen.last_top + pen.last_ascent
	for _ in TEXT_ELLIPSIS {
		if TEXTS.piece_count >= TEXT_PIECES_MAX {break}
		piece := Text_Piece {
			sprite = dot,
			rect   = {x + glyph.offset.x, baseline + glyph.offset.y, glyph.size.x, glyph.size.y},
			color  = like.color,
			font   = like.font,
			tag    = like.tag,
			cell   = {x, pen.last_top, glyph.advance, pen.last_ascent - pen.last_descent},
		}
		// The line is closed, so the underline it follows is already at its final height.
		if like.underline.z > 0 {
			piece.underline = {x, like.underline.y, glyph.advance, like.underline.w}
		}
		TEXTS.pieces[TEXTS.piece_count] = piece
		TEXTS.piece_count += 1
		x += glyph.advance
	}
	pen.text.size.x = max(pen.text.size.x, x)
}

// Adds a piece of run whose cell spans cell_width from cell_x; its height comes when the line closes.
// A full piece table drops the piece; the size is still right.
@(private = "file")
text_pen_piece :: proc(
	pen: ^Text_Pen,
	run: Text_Run,
	sprite: Sprite_Id,
	rect: [4]f32,
	cell_x, cell_width: f32,
) {
	if TEXTS.piece_count >= TEXT_PIECES_MAX {return}
	piece := Text_Piece {
		sprite = sprite,
		rect   = rect,
		color  = run.color,
		font   = run.font,
		tag    = run.tag,
		cell   = {cell_x, 0, cell_width, 0},
	}
	if run.underline {
		// Thickness and distance below the baseline follow the font's size, in whole pixels.
		em := font_size(run.font)
		thickness := max(1, math.round(em / 16))
		piece.underline = {cell_x, math.round(em / 12), cell_width, thickness}
	}
	TEXTS.pieces[TEXTS.piece_count] = piece
	TEXTS.piece_count += 1
}
