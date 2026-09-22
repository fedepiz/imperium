package main

import "core:mem"

DRAW_CLIP_DEPTH_MAX :: 32

// A half-open index range [begin, begin + len).
Span :: struct {
	begin: int,
	len:   int,
}

span_from_range :: proc(begin, end: int) -> Span {
	return {begin, end - begin}
}

span_from_array :: proc(array: ^[$N]$T) -> Span {
	return {0, len(array^)}
}

span_advance :: proc(span: ^Span) {
	if span.len > 0 {
		span.begin += 1
		span.len -= 1
	}
}

Draw_Ctx :: struct {
	render:        ^Render_Data,
	sprites:       ^Sprites,
	// Remaining writable ranges; consuming slots advances begin and reduces len.
	instance_span: Span,
	clip_span:     Span,
	layer:         u16,
	clip_stack:    [DRAW_CLIP_DEPTH_MAX]Clip_Id,
	clip_depth:    int, // Zero means unclipped.
}

// Initializes the writer and clears its assigned instance_span.
// Reserves clip_span for clip records; clip_span.begin must be nonzero.
// Resets the clip stack. Instance and clip ranges must not overlap other writers.
draw_begin :: proc(
	ctx: ^Draw_Ctx,
	render: ^Render_Data,
	sprites: ^Sprites,
	instance_span, clip_span: Span,
) {
	assert(instance_span.begin >= 0 && instance_span.len >= 0)
	assert(instance_span.begin + instance_span.len <= RENDER_MAX_INSTANCES)
	assert(clip_span.begin > 0 && clip_span.len >= 0)
	assert(clip_span.begin + clip_span.len <= RENDER_MAX_CLIPS)
	ctx^ = {
		render        = render,
		sprites       = sprites,
		instance_span = instance_span,
		clip_span     = clip_span,
	}
	mem.zero_slice(render.keys[instance_span.begin:instance_span.begin + instance_span.len])
	mem.zero_slice(render.instances[instance_span.begin:instance_span.begin + instance_span.len])
	mem.zero_slice(render.clips[clip_span.begin:clip_span.begin + clip_span.len])
}

// Intersects rect with the current clip and pushes a new clip-table record.
// Excess pushes still advance depth; exhausted storage preserves the current clip.
draw_clip_push :: proc(ctx: ^Draw_Ctx, rect: [4]f32) {
	parent := draw_clip_current(ctx)
	depth := ctx.clip_depth
	ctx.clip_depth += 1
	if depth < DRAW_CLIP_DEPTH_MAX {
		ctx.clip_stack[depth] = parent
		if ctx.clip_span.len > 0 {
			lo := [2]f32{rect.x, rect.y}
			hi := lo + [2]f32{max(rect.z, 0), max(rect.w, 0)}
			if parent != 0 {
				p := ctx.render.clips[parent]
				lo = {max(lo.x, p.x), max(lo.y, p.y)}
				hi = {min(hi.x, p.x + p.z), min(hi.y, p.y + p.w)}
			}
			id := Clip_Id(ctx.clip_span.begin)
			ctx.render.clips[id] = {lo.x, lo.y, max(hi.x - lo.x, 0), max(hi.y - lo.y, 0)}
			ctx.clip_stack[depth] = id
			span_advance(&ctx.clip_span)
		}
	}
}

// Restores the parent clip without reclaiming records referenced by earlier draws.
draw_clip_pop :: proc(ctx: ^Draw_Ctx) {
	ctx.clip_depth = max(ctx.clip_depth - 1, 0)
}

// Rectangles use [x, y, width, height] in logical pixels. Colors use straight RGBA.
draw_rectangle :: proc(
	ctx: ^Draw_Ctx,
	rect: [4]f32,
	color: [4]f32,
	radius: f32 = 0,
	thickness: f32 = 0,
	softness: f32 = 0,
) {
	instance := Render_Instance {
		dst       = rect,
		thickness = thickness,
		softness  = softness,
	}
	for corner in Corner {
		instance.color[corner] = color
		instance.radii[corner] = radius
	}
	draw_instance(ctx, 0, instance)
}

// Border lies inside rect. Nonpositive widths produce a neutral instance.
draw_rectangle_lines :: proc(
	ctx: ^Draw_Ctx,
	rect: [4]f32,
	color: [4]f32,
	thickness: f32,
	radius: f32 = 0,
	softness: f32 = 0,
) {
	if thickness > 0 {
		draw_rectangle(ctx, rect, color, radius, thickness, softness)
	} else {
		draw_instance(ctx, 0, {})
	}
}

draw_image :: proc(
	ctx: ^Draw_Ctx,
	image: Image_Id,
	rect: [4]f32,
	tint: [4]f32,
	radii := [Corner]f32{},
	thickness: f32 = 0,
	softness: f32 = 0,
) {
	draw_sprite(ctx, sprite_of_image(image), rect, tint, radii, thickness, softness)
}

// Position is the logical top-left of the text block; returns its logical size.
draw_text :: proc(
	ctx: ^Draw_Ctx,
	font: Font_Id,
	text: string,
	position: [2]f32,
	color: [4]f32,
) -> [2]f32 {
	return draw_text_internal(ctx, font, text, position, color, 0)
}

// Word wrapping at spaces/tabs, splitting oversized words between runes.
// Line-edge separators are omitted. Nonpositive width means no automatic wrapping.
draw_text_wrapped :: proc(
	ctx: ^Draw_Ctx,
	font: Font_Id,
	text: string,
	position: [2]f32,
	width: f32,
	color: [4]f32,
) -> [2]f32 {
	return draw_text_internal(ctx, font, text, position, color, width)
}

@(private = "file")
draw_clip_current :: proc(ctx: ^Draw_Ctx) -> Clip_Id {
	return(
		ctx.clip_stack[min(ctx.clip_depth, DRAW_CLIP_DEPTH_MAX) - 1] if ctx.clip_depth > 0 else 0 \
	)
}

// A full destination span absorbs additional writes; the renderer still traverses its whole table.
@(private = "file")
draw_instance :: proc(ctx: ^Draw_Ctx, texture: Texture_Id, instance: Render_Instance) {
	if ctx.instance_span.len > 0 {
		index := ctx.instance_span.begin
		ctx.render.keys[index] = {
			layer   = ctx.layer,
			texture = texture,
			clip    = draw_clip_current(ctx),
		}
		ctx.render.instances[index] = instance
		span_advance(&ctx.instance_span)
	}
}

@(private = "file")
draw_sprite :: proc(
	ctx: ^Draw_Ctx,
	sprite: Sprite_Id,
	rect: [4]f32,
	tint: [4]f32,
	radii := [Corner]f32{},
	thickness: f32 = 0,
	softness: f32 = 0,
) {
	region := ctx.sprites.regions[sprite]
	instance: Render_Instance
	if region.source.z > 0 && region.source.w > 0 {
		instance = {
			src       = region.source,
			dst       = rect,
			radii     = radii,
			thickness = thickness,
			softness  = softness,
		}
		for corner in Corner {instance.color[corner] = tint}
	}
	draw_instance(ctx, region.texture, instance)
}

@(private = "file")
draw_text_internal :: proc(
	ctx: ^Draw_Ctx,
	font: Font_Id,
	text: string,
	position: [2]f32,
	color: [4]f32,
	width: f32,
) -> (
	size: [2]f32,
) {
	assert(int(font) < FONTS_MAX)
	if len(text) == 0 {return}
	info := ctx.sprites.fonts[font].info
	size.y = info.ascent - info.descent
	line_height := size.y + info.line_gap
	baseline := position.y + info.ascent
	line_width, separator_width: f32
	word_start := true
	for ch, offset in text {
		switch ch {
		case '\r':
		case '\n':
			size.x = max(size.x, line_width)
			size.y += line_height
			baseline += line_height
			line_width, separator_width = 0, 0
			word_start = true
		case:
			sprite, found := sprite_of_glyph(ctx.sprites, font, ch)
			glyph: Sprite_Glyph
			if found {glyph = ctx.sprites.glyphs[sprite]}
			if width > 0 {
				if ch == ' ' || ch == '\t' {
					separator_width += glyph.advance
					word_start = true
					continue
				}
				advance := glyph.advance
				if word_start {
					advance = 0
					for next in text[offset:] {
						if next == ' ' || next == '\t' || next == '\n' {break}
						if next == '\r' {continue}
						if id, ok := sprite_of_glyph(ctx.sprites, font, next); ok {
							advance += ctx.sprites.glyphs[id].advance
						}
					}
				}
				if line_width > 0 && line_width + separator_width + advance > width {
					size.x = max(size.x, line_width)
					size.y += line_height
					baseline += line_height
					line_width = 0
				}
				if line_width > 0 {line_width += separator_width}
				separator_width = 0
				word_start = false
			}
			if found {
				draw_sprite(
					ctx,
					sprite,
					{
						position.x + line_width + glyph.offset.x,
						baseline + glyph.offset.y,
						glyph.size.x,
						glyph.size.y,
					},
					color,
				)
			}
			line_width += glyph.advance
		}
	}
	size.x = max(size.x, line_width)
	return
}
