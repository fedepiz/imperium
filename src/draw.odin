package main

import "core:mem"

DRAW_CLIP_DEPTH_MAX :: 32

Draw_Ctx :: struct {
	list:          ^Render_List,
	// Remaining writable range; consuming slots advances begin and reduces len.
	instance_span: Span,
	// Clip rects stamped on every instance; the bottom entry is the clip given to draw_begin.
	clip_stack:    [DRAW_CLIP_DEPTH_MAX][4]f32,
	clip_depth:    int,
}

// Initializes the writer and clears its assigned instance_span.
// Everything drawn is clipped to clip. Instance ranges must not overlap other writers.
draw_begin :: proc(
	ctx: ^Draw_Ctx,
	list: ^Render_List,
	instance_span: Span,
	clip: [4]f32,
) {
	assert(instance_span.begin >= 0 && instance_span.len >= 0)
	assert(instance_span.begin + instance_span.len <= RENDER_MAX_INSTANCES)
	ctx^ = {
		list          = list,
		instance_span = instance_span,
	}
	ctx.clip_stack[0] = clip
	mem.zero_slice(list.keys[instance_span.begin:instance_span.begin + instance_span.len])
	mem.zero_slice(list.instances[instance_span.begin:instance_span.begin + instance_span.len])
}

// Intersects rect with the current clip and makes it current until the matching pop.
// Excess pushes still advance depth, and keep the deepest clip that fit.
draw_clip_push :: proc(ctx: ^Draw_Ctx, rect: [4]f32) {
	parent := draw_clip_current(ctx)
	ctx.clip_depth += 1
	if ctx.clip_depth < DRAW_CLIP_DEPTH_MAX {
		ctx.clip_stack[ctx.clip_depth] = rect_intersect(rect, parent)
	}
}

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

@(private = "file")
draw_clip_current :: proc(ctx: ^Draw_Ctx) -> [4]f32 {
	return ctx.clip_stack[min(ctx.clip_depth, DRAW_CLIP_DEPTH_MAX - 1)]
}

// A full destination span absorbs additional writes; the renderer still traverses its whole table.
@(private = "file")
draw_instance :: proc(ctx: ^Draw_Ctx, texture: Texture_Id, instance: Render_Instance) {
	if ctx.instance_span.len > 0 {
		index := ctx.instance_span.begin
		ctx.list.keys[index] = {
			texture = texture,
		}
		ctx.list.instances[index] = instance
		ctx.list.instances[index].clip = draw_clip_current(ctx)
		span_advance(&ctx.instance_span)
	}
}

// Draws a sprite from the atlas into rect, tinted; glyphs and images are both sprites.
draw_sprite :: proc(
	ctx: ^Draw_Ctx,
	sprite: Sprite_Id,
	rect: [4]f32,
	tint: [4]f32,
	radii := [Corner]f32{},
	thickness: f32 = 0,
	softness: f32 = 0,
) {
	region := sprite_region(sprite)
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
