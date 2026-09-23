package main

// Texts built in one frame, and the room for their runs and laid-out pieces
@(private = "file")
TEXT_MAX :: 4096
@(private = "file")
TEXT_RUNS_MAX :: 8192
@(private = "file")
TEXT_PIECES_MAX :: 65536
@(private = "file")
TEXT_BLOB_SIZE :: 1_000_000

// Words may overshoot the wrap width by this much, so text laid out at its own width never wraps
@(private = "file")
TEXT_WRAP_SLACK :: 0.01

// A text built this frame. Id 0 is the empty text.
Text_Id :: distinct u16

// Text in one font and color, or an image one line of that font tall when image is set.
@(private = "file")
Text_Run :: struct {
	text:  string,
	font:  Font_Id,
	color: [4]f32,
	image: Image_Id,
}

// One glyph or image, placed relative to the text's top-left corner.
@(private = "file")
Text_Piece :: struct {
	sprite: Sprite_Id,
	rect:   [4]f32,
	color:  [4]f32,
}

// A text's runs, and its layout for the last width asked for
@(private = "file")
Text :: struct {
	runs:     Span,
	laid_out: bool,
	width:    f32,
	pieces:   Span,
	size:     [2]f32,
}

Text_Ctx :: struct {
	sprites:     ^Sprites,
	texts:       [TEXT_MAX]Text,
	text_count:  int,
	runs:        [TEXT_RUNS_MAX]Text_Run,
	run_count:   int,
	pieces:      [TEXT_PIECES_MAX]Text_Piece,
	piece_count: int,
	// Run strings are copied here, so callers can build texts from temporaries
	blob:        [TEXT_BLOB_SIZE]byte,
	blob_len:    int,
	// Set between text_start and text_end; the open text's runs begin at open_begin
	open:        bool,
	open_begin:  int,
}

text_init :: proc(ctx: ^Text_Ctx, sprites: ^Sprites) {
	ctx^ = {}
	ctx.sprites = sprites
	ctx.text_count = 1
}

// Forgets every text of the last frame.
text_begin :: proc(ctx: ^Text_Ctx) {
	assert(!ctx.open)
	ctx.text_count = 1
	ctx.run_count = 0
	ctx.piece_count = 0
	ctx.blob_len = 0
}

// Opens a new text; runs added until text_end belong to it.
text_new :: proc(ctx: ^Text_Ctx) {
	assert(!ctx.open, "texts cannot be built inside each other")
	ctx.open = true
	ctx.open_begin = ctx.run_count
}

// Adds text in a font and color to the open text. A full blob keeps what fits.
text_add :: proc(ctx: ^Text_Ctx, text: string, font: Font_Id, color: [4]f32) {
	n := copy(ctx.blob[ctx.blob_len:], text)
	copied := string(ctx.blob[ctx.blob_len:][:n])
	ctx.blob_len += n
	text_add_run(ctx, {text = copied, font = font, color = color})
}

// Adds an image to the open text, one line of font tall and tinted by color.
text_add_image :: proc(ctx: ^Text_Ctx, image: Image_Id, font: Font_Id, color: [4]f32) {
	text_add_run(ctx, {font = font, color = color, image = image})
}

// Closes the open text and returns its id.
text_end :: proc(ctx: ^Text_Ctx) -> Text_Id {
	assert(ctx.open)
	assert(ctx.text_count < TEXT_MAX)
	ctx.open = false
	id := Text_Id(ctx.text_count)
	ctx.text_count += 1
	ctx.texts[id] = {
		runs = span_from_range(ctx.open_begin, ctx.run_count),
	}
	return id
}

// A text of one string in one font and color.
text_from_string :: proc(ctx: ^Text_Ctx, text: string, font: Font_Id, color: [4]f32) -> Text_Id {
	text_new(ctx)
	text_add(ctx, text, font, color)
	return text_end(ctx)
}

// The size of the text broken into lines no wider than width; 0 never breaks.
text_measure :: proc(ctx: ^Text_Ctx, id: Text_Id, width: f32) -> [2]f32 {
	return text_laid_out(ctx, id, width).size
}

// Draws the text broken into lines no wider than width, its top-left at position, colors multiplied by tint.
text_draw :: proc(
	ctx: ^Text_Ctx,
	draw: ^Draw_Ctx,
	id: Text_Id,
	position: [2]f32,
	width: f32,
	tint := [4]f32{1, 1, 1, 1},
) {
	text := text_laid_out(ctx, id, width)
	for piece in ctx.pieces[text.pieces.begin:][:text.pieces.len] {
		rect := piece.rect
		rect.xy += position
		draw_sprite(draw, piece.sprite, rect, piece.color * tint)
	}
}

@(private = "file")
text_add_run :: proc(ctx: ^Text_Ctx, run: Text_Run) {
	assert(ctx.open, "runs are added between text_start and text_end")
	assert(ctx.run_count < TEXT_RUNS_MAX)
	ctx.runs[ctx.run_count] = run
	ctx.run_count += 1
}

// The text, laid out for width unless it already was.
@(private = "file")
text_laid_out :: proc(ctx: ^Text_Ctx, id: Text_Id, width: f32) -> ^Text {
	text := &ctx.texts[id]
	if !text.laid_out || text.width != width {
		text.laid_out = true
		text.width = width
		text_layout(ctx, text)
	}
	return text
}

// Where the layout of one text stands: the pen, and the line being filled.
@(private = "file")
Text_Pen :: struct {
	ctx:        ^Text_Ctx,
	text:       ^Text,
	// Pen position on the line, from the line's left edge
	x:          f32,
	// Separators seen since the last word, placed only if another word follows on the line
	separators: f32,
	// Top of the current line, and where its pieces begin
	line_top:   f32,
	line_begin: int,
	// Tallest ascent and descent, and widest gap, of the runs with something on the line
	ascent:     f32,
	descent:    f32,
	line_gap:   f32,
	// The next glyph begins a word, which moves to the next line whole if it does not fit
	word_start: bool,
	// Anything at all was laid out, so the text has at least one line
	any:        bool,
}

// Breaks the runs into lines at spaces and tabs, splitting words longer than a line between runes.
// Each line sits on one baseline under its tallest run. LF starts a line; CR is ignored.
@(private = "file")
text_layout :: proc(ctx: ^Text_Ctx, text: ^Text) {
	pen := Text_Pen {
		ctx        = ctx,
		text       = text,
		line_begin = ctx.piece_count,
		word_start = true,
	}
	text.size = {}
	text.pieces = {ctx.piece_count, 0}
	width := text.width
	runs := ctx.runs[text.runs.begin:][:text.runs.len]
	sprites := ctx.sprites

	for run, run_index in runs {
		if run.image != 0 {
			// An image is a word of its own, one line of its font tall.
			info := sprites.fonts[run.font].info
			sprite := sprite_of_image(run.image)
			source := sprites.regions[sprite].source
			height := info.ascent - info.descent
			image_width := source.z * height / source.w if source.w > 0 else 0
			text_pen_word(&pen, image_width, width)
			text_pen_touch(&pen, run.font)
			text_pen_piece(&pen, sprite, {pen.x, -info.ascent, image_width, height}, run.color)
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
				text_pen_line(&pen)
				text_pen_touch(&pen, run.font)
				pen.word_start = true
			case:
				sprite, found := sprite_of_glyph(sprites, run.font, ch)
				glyph: Sprite_Glyph
				if found {glyph = sprites.glyphs[sprite]}
				if width > 0 && (ch == ' ' || ch == '\t') {
					text_pen_touch(&pen, run.font)
					pen.separators += glyph.advance
					pen.word_start = true
					continue
				}
				if width > 0 {
					if pen.word_start {
						text_pen_word(&pen, text_word_width(ctx, runs, run_index, offset), width)
						pen.word_start = false
					} else if pen.x > 0 && pen.x + glyph.advance > width + TEXT_WRAP_SLACK {
						// A word longer than a line goes on over the next.
						text_pen_line(&pen)
					}
				}
				text_pen_touch(&pen, run.font)
				if found && glyph.size.x > 0 {
					rect := [4]f32 {
						pen.x + glyph.offset.x,
						glyph.offset.y,
						glyph.size.x,
						glyph.size.y,
					}
					text_pen_piece(&pen, sprite, rect, run.color)
				}
				pen.x += glyph.advance
			}
		}
	}

	if pen.any {
		text_pen_close(&pen)
	}
	text.pieces.len = ctx.piece_count - text.pieces.begin
}

// The width of the word starting at offset in runs[run_index], which may carry on into later runs.
@(private = "file")
text_word_width :: proc(ctx: ^Text_Ctx, runs: []Text_Run, run_index, offset: int) -> f32 {
	width: f32
	start := offset
	for run in runs[run_index:] {
		if run.image != 0 {return width}
		for ch in run.text[start:] {
			switch ch {
			case ' ', '\t', '\n':
				return width
			case '\r':
			case:
				if sprite, found := sprite_of_glyph(ctx.sprites, run.font, ch); found {
					width += ctx.sprites.glyphs[sprite].advance
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
	info := pen.ctx.sprites.fonts[font].info
	pen.ascent = max(pen.ascent, info.ascent)
	pen.descent = min(pen.descent, info.descent)
	pen.line_gap = max(pen.line_gap, info.line_gap)
	pen.any = true
}

// Moves to the next line if a word of word_width would not fit on this one, then places the separators before it.
@(private = "file")
text_pen_word :: proc(pen: ^Text_Pen, word_width, width: f32) {
	if width > 0 && pen.x > 0 && pen.x + pen.separators + word_width > width + TEXT_WRAP_SLACK {
		text_pen_line(pen)
	}
	if pen.x > 0 {
		pen.x += pen.separators
	}
	pen.separators = 0
}

// Ends the line and starts the next below it.
@(private = "file")
text_pen_line :: proc(pen: ^Text_Pen) {
	text_pen_close(pen)
	pen.line_top += pen.ascent - pen.descent + pen.line_gap
	pen.x, pen.separators = 0, 0
	pen.ascent, pen.descent, pen.line_gap = 0, 0, 0
	pen.line_begin = pen.ctx.piece_count
}

// Puts the line's pieces on its baseline and grows the text around it.
@(private = "file")
text_pen_close :: proc(pen: ^Text_Pen) {
	baseline := pen.line_top + pen.ascent
	for &piece in pen.ctx.pieces[pen.line_begin:pen.ctx.piece_count] {
		piece.rect.y += baseline
	}
	pen.text.size.x = max(pen.text.size.x, pen.x)
	pen.text.size.y = pen.line_top + pen.ascent - pen.descent
}

// A full piece table drops the piece; the size is still right.
@(private = "file")
text_pen_piece :: proc(pen: ^Text_Pen, sprite: Sprite_Id, rect: [4]f32, color: [4]f32) {
	ctx := pen.ctx
	if ctx.piece_count < TEXT_PIECES_MAX {
		ctx.pieces[ctx.piece_count] = {sprite, rect, color}
		ctx.piece_count += 1
	}
}

