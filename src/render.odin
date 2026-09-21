package odin

import "core:fmt"
import "core:slice"
import gl "vendor:OpenGL"

RENDER_MAX_INSTANCES :: 8912
RENDER_MAX_CLIPS :: 1024

Texture_Id :: distinct u16
Clip_Id :: distinct u16

// Core information relating to a render instance.
// Small and compact.
Render_Key :: struct {
	// Layer is stronger then sequence. Draw in sorted order, by (layer, sequence)
	layer:    u16,
	sequence: u16,
	// Ids into 'batch' parameters.
	// Batch on breaks in this.
	texture:  Texture_Id,
	clip:     Clip_Id,
}

Corner :: enum {
	Top_Left,
	Top_Right,
	Bot_Right,
	Bot_Left,
}

Render_Instance :: struct {
	src:      [4]f32,
	dst:      [4]f32,
	color:    [Corner][4]f32,
	radii:    [Corner]f32,
	softness: f32,
}

Render_Data :: struct {
	keys:      [RENDER_MAX_INSTANCES]Render_Key,
	instances: [RENDER_MAX_INSTANCES]Render_Instance,
	clips:     [RENDER_MAX_CLIPS][4]f32,
}

Render_Ctx :: struct {
	program, vao, vbo, white_texture:                              u32,
	view_uniform, clip_uniform, clipped_uniform, textured_uniform: i32,
	// Logical window dimensions, matching SDL mouse coordinates.
	view_size:                                                     [2]f32,
	// Borrowed OpenGL texture handles. Slot zero always means untextured.
	textures:                                                      [65536]u32,
	order:                                                         [RENDER_MAX_INSTANCES]Render_Order,
	sorted:                                                        [RENDER_MAX_INSTANCES]Render_Instance,
}

@(private = "file")
Render_Order :: struct {
	key:   Render_Key,
	index: int,
}

// src, dst and clips are [x, y, width, height], with a top-left origin.
// src uses texture pixels; dst, clips, radii and softness use logical pixels.
// Textures should have their top row at v=0. Colors use straight alpha.
render :: proc(ctx: ^Render_Ctx, data: Render_Data) {
	if ctx.view_size.x <= 0 || ctx.view_size.y <= 0 {
		return
	}
	for key, i in data.keys {
		ctx.order[i] = {key, i}
	}
	slice.sort_by(ctx.order[:], proc(a, b: Render_Order) -> bool {
		if a.key.layer != b.key.layer do return a.key.layer < b.key.layer
		if a.key.sequence != b.key.sequence do return a.key.sequence < b.key.sequence
		return a.index < b.index
	})
	for entry, i in ctx.order {
		ctx.sorted[i] = data.instances[entry.index]
	}

	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendEquation(gl.FUNC_ADD)
	gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(ctx.program)
	gl.Uniform2f(ctx.view_uniform, ctx.view_size.x, ctx.view_size.y)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindVertexArray(ctx.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, ctx.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(ctx.sorted), raw_data(ctx.sorted[:]), gl.STREAM_DRAW)

	for first := 0; first < RENDER_MAX_INSTANCES; {
		key := ctx.order[first].key
		end := first + 1
		for end < RENDER_MAX_INSTANCES &&
		    ctx.order[end].key.texture == key.texture &&
		    ctx.order[end].key.clip == key.clip {
			end += 1
		}
		assert(int(key.clip) < RENDER_MAX_CLIPS, "Clip ID out of range")
		texture := ctx.textures[key.texture]
		assert(key.texture == 0 || texture != 0, "Texture ID has no registered OpenGL texture")
		if key.texture == 0 do texture = ctx.white_texture
		gl.BindTexture(gl.TEXTURE_2D, texture)
		gl.Uniform1i(ctx.textured_uniform, i32(key.texture != 0))
		gl.Uniform1i(ctx.clipped_uniform, i32(key.clip != 0))
		clip := data.clips[key.clip]
		gl.Uniform4f(ctx.clip_uniform, clip.x, clip.y, clip.z, clip.w)
		render_bind_instances(first)
		gl.DrawArraysInstanced(gl.TRIANGLES, 0, 6, i32(end - first))
		first = end
	}
	gl.BindVertexArray(0)
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.UseProgram(0)
}

@(private = "file")
render_bind_instances :: proc(first: int) {
	offsets := [8]uintptr {
		offset_of(Render_Instance, src),
		offset_of(Render_Instance, dst),
		offset_of(Render_Instance, color),
		offset_of(Render_Instance, color) + 16,
		offset_of(Render_Instance, color) + 32,
		offset_of(Render_Instance, color) + 48,
		offset_of(Render_Instance, radii),
		offset_of(Render_Instance, softness),
	}
	for offset, i in offsets {
		components: i32 = 4
		if i == 7 do components = 1
		gl.VertexAttribPointer(
			u32(i),
			components,
			gl.FLOAT,
			gl.FALSE,
			i32(size_of(Render_Instance)),
			uintptr(first * size_of(Render_Instance)) + offset,
		)
		gl.EnableVertexAttribArray(u32(i))
		gl.VertexAttribDivisor(u32(i), 1)
	}
}

render_destroy :: proc(ctx: ^Render_Ctx) {
	gl.DeleteTextures(1, &ctx.white_texture)
	gl.DeleteBuffers(1, &ctx.vbo)
	gl.DeleteVertexArrays(1, &ctx.vao)
	gl.DeleteProgram(ctx.program)
}

@(private = "file")
render_compile_shader :: proc(kind: u32, source: cstring) -> u32 {
	shader := gl.CreateShader(kind)
	text := source
	gl.ShaderSource(shader, 1, &text, nil)
	gl.CompileShader(shader)
	ok: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &ok)
	if ok == 0 {
		log: [4096]u8
		length: i32
		gl.GetShaderInfoLog(shader, len(log), &length, &log[0])
		fmt.eprintf("Renderer shader compilation failed: %s\n", string(log[:length]))
		gl.DeleteShader(shader)
		return 0
	}
	return shader
}

render_init :: proc(ctx: ^Render_Ctx) -> bool {
	vertex := render_compile_shader(gl.VERTEX_SHADER, RENDER_VERTEX_SOURCE)
	if vertex == 0 do return false
	defer gl.DeleteShader(vertex)
	fragment := render_compile_shader(gl.FRAGMENT_SHADER, RENDER_FRAGMENT_SOURCE)
	if fragment == 0 do return false
	defer gl.DeleteShader(fragment)
	ctx.program = gl.CreateProgram()
	gl.AttachShader(ctx.program, vertex)
	gl.AttachShader(ctx.program, fragment)
	gl.LinkProgram(ctx.program)
	ok: i32
	gl.GetProgramiv(ctx.program, gl.LINK_STATUS, &ok)
	if ok == 0 {
		log: [4096]u8
		length: i32
		gl.GetProgramInfoLog(ctx.program, len(log), &length, &log[0])
		fmt.eprintf("Renderer program linking failed: %s\n", string(log[:length]))
		gl.DeleteProgram(ctx.program)
		ctx.program = 0
		return false
	}
	ctx.view_uniform = gl.GetUniformLocation(ctx.program, "view_size")
	ctx.clip_uniform = gl.GetUniformLocation(ctx.program, "clip_rect")
	ctx.clipped_uniform = gl.GetUniformLocation(ctx.program, "clipped")
	ctx.textured_uniform = gl.GetUniformLocation(ctx.program, "textured")
	gl.UseProgram(ctx.program)
	gl.Uniform1i(gl.GetUniformLocation(ctx.program, "image"), 0)
	gl.UseProgram(0)
	gl.GenVertexArrays(1, &ctx.vao)
	gl.GenBuffers(1, &ctx.vbo)
	// Keep the sampler complete even when the shader takes the untextured path.
	gl.GenTextures(1, &ctx.white_texture)
	gl.BindTexture(gl.TEXTURE_2D, ctx.white_texture)
	white := [4]u8{255, 255, 255, 255}
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, &white)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return true
}

@(private = "file")
RENDER_VERTEX_SOURCE: cstring = `#version 330 core
layout(location=0) in vec4 src;
layout(location=1) in vec4 dst;
layout(location=2) in vec4 color_tl;
layout(location=3) in vec4 color_tr;
layout(location=4) in vec4 color_br;
layout(location=5) in vec4 color_bl;
layout(location=6) in vec4 radii;
layout(location=7) in float softness;
uniform vec2 view_size;
out vec2 position;
out vec2 local_position;
flat out vec4 rect_src;
flat out vec2 rect_size;
flat out vec4 colors[4];
flat out vec4 corner_radii;
flat out float edge_softness;
const vec2 corners[6] = vec2[6](
    vec2(0,0), vec2(1,0), vec2(1,1),
    vec2(0,0), vec2(1,1), vec2(0,1));
void main() {
    local_position = corners[gl_VertexID] * dst.zw;
    position = dst.xy + local_position;
    gl_Position = vec4(position / view_size * vec2(2,-2) + vec2(-1,1), 0, 1);
    rect_src = src;
    rect_size = dst.zw;
    colors[0] = color_tl; colors[1] = color_tr;
    colors[2] = color_br; colors[3] = color_bl;
    corner_radii = radii;
    edge_softness = softness;
}
`

@(private = "file")
RENDER_FRAGMENT_SOURCE: cstring = `#version 330 core
uniform sampler2D image;
uniform bool textured;
uniform bool clipped;
uniform vec4 clip_rect;
in vec2 position;
in vec2 local_position;
flat in vec4 rect_src;
flat in vec2 rect_size;
flat in vec4 colors[4];
flat in vec4 corner_radii;
flat in float edge_softness;
out vec4 out_color;
void main() {
    if (clipped && (any(lessThan(position, clip_rect.xy)) ||
                    any(greaterThanEqual(position, clip_rect.xy + clip_rect.zw)))) discard;
    vec2 t = local_position / rect_size;
    vec4 color = mix(mix(colors[0], colors[1], t.x),
                     mix(colors[3], colors[2], t.x), t.y);
    if (textured) {
        vec2 uv = (rect_src.xy + t * rect_src.zw) / vec2(textureSize(image, 0));
        color *= texture(image, uv);
    }
    vec2 half_size = rect_size * 0.5;
    vec2 p = local_position - half_size;
    float r = p.y < 0.0 ? (p.x < 0.0 ? corner_radii.x : corner_radii.y)
                        : (p.x < 0.0 ? corner_radii.w : corner_radii.z);
    r = clamp(r, 0.0, min(half_size.x, half_size.y));
    vec2 q = abs(p) - half_size + r;
    float distance_to_edge = length(max(q, 0.0)) + min(max(q.x,q.y),0.0) - r;
    // Fade inward so geometry stays inside the destination rectangle.
    float feather = max(max(edge_softness, 0.0), fwidth(distance_to_edge));
    float coverage = 1.0 - smoothstep(-max(feather, 0.0001), 0.0, distance_to_edge);
    out_color = vec4(color.rgb, color.a * coverage);
}
`
