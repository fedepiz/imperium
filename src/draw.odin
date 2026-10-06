#+private
package main

// Drawing: laid-out things to quads, through the atlas

// A stretch of laid-out glyphs to draw in one font and colour
Draw_Glyphs :: struct {
	// Range of the glyphs given alongside
	begin: int,
	len:   int,
	// Index in Assets.fonts
	font:  int,
	// Where the top-left of the glyphs' text goes, in the unit of their layout
	at:    [2]f32,
	color: [4]u8,
}

// Out: quads, appended to.
// One quad per glyph that has a bitmap, draw by draw, in order. Glyphs that are images are skipped
draw_glyphs :: proc(
	draws: []Draw_Glyphs,
	glyphs: []Text_Glyph,
	assets: ^Assets,
	quads: ^[dynamic; RENDER_QUADS_MAX]Render_Quad,
) {
	for draw in draws {
		font := &assets.fonts[draw.font]
		for glyph in glyphs[draw.begin:][:draw.len] {
			char := int(glyph.char) - FONT_FIRST
			if char < 0 || char >= FONT_GLYPH_COUNT do continue
			size := font.sizes[char]
			// Blank
			if size.x <= 0 do continue
			lo := draw.at + glyph.pen + font.offsets[char]
			hi := lo + size
			append(
				quads,
				Render_Quad {
					rect = {lo.x, lo.y, hi.x, hi.y},
					source = font.sources[char],
					colors = {draw.color, draw.color, draw.color, draw.color},
				},
			)
		}
	}
}
