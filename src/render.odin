package main

import "core:fmt"
import "core:slice"
import gl "vendor:OpenGL"

RENDER_MAX_INSTANCES :: 8192

Texture_Id :: distinct u16

// Tightly packed, top-to-bottom RGBA8 pixels. Storage is owned by the caller.
Bitmap :: struct {
	pixels: [][4]u8,
	width:  int,
	height: int,
}

// Core information relating to a render instance.
// Small and compact.
Render_Key :: struct {
	// Layer is stronger then sequence. Draw in sorted order, by (layer, sequence)
	layer:    u16,
	sequence: u16,
	// Ids into 'batch' parameters.
	// Batch on breaks in this.
	texture:  Texture_Id,
}

Corner :: enum {
	Top_Left,
	Top_Right,
	Bot_Right,
	Bot_Left,
}

Render_Instance :: struct {
	src:       [4]f32,
	dst:       [4]f32,
	// Only the part of dst inside clip is drawn.
	clip:      [4]f32,
	color:     [Corner][4]f32,
	radii:     [Corner]f32,
	softness:  f32,
	thickness: f32, // Zero fills the shape; positive widths draw an inward border.
}

Render_List :: struct {
	keys:      [RENDER_MAX_INSTANCES]Render_Key,
	instances: [RENDER_MAX_INSTANCES]Render_Instance,
}

Renderer :: struct {
	program, vao, vbo, white_texture:                              u32,
	view_uniform: i32,
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

// src, dst and clip are [x, y, width, height], with a top-left origin.
// src uses texture pixels; dst, clip, radii and softness use logical pixels.
// Textures should have their top row at v=0. Colors use straight alpha.
render :: proc(renderer: ^Renderer, list: Render_List) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 {
		return
	}
	for key, i in list.keys {
		renderer.order[i] = {key, i}
	}
	slice.sort_by(renderer.order[:], proc(a, b: Render_Order) -> bool {
		if a.key.layer != b.key.layer do return a.key.layer < b.key.layer
		if a.key.sequence != b.key.sequence do return a.key.sequence < b.key.sequence
		return a.index < b.index
	})
	for entry, i in renderer.order {
		renderer.sorted[i] = list.instances[entry.index]
	}

	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendEquation(gl.FUNC_ADD)
	gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	gl.UseProgram(renderer.program)
	gl.Uniform2f(renderer.view_uniform, renderer.view_size.x, renderer.view_size.y)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindVertexArray(renderer.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, renderer.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(renderer.sorted), raw_data(renderer.sorted[:]), gl.STREAM_DRAW)

	for first := 0; first < RENDER_MAX_INSTANCES; {
		// Untextured instances sample nothing, so they join a batch of any texture; the first textured one picks it.
		batch_texture: Texture_Id
		end := first
		for end < RENDER_MAX_INSTANCES {
			texture := renderer.order[end].key.texture
			if texture != 0 {
				if batch_texture == 0 {
					batch_texture = texture
				} else if texture != batch_texture {
					break
				}
			}
			end += 1
		}
		texture := renderer.textures[batch_texture]
		assert(batch_texture == 0 || texture != 0, "Texture ID has no registered OpenGL texture")
		if batch_texture == 0 do texture = renderer.white_texture
		gl.BindTexture(gl.TEXTURE_2D, texture)
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
	offsets := [10]uintptr {
		offset_of(Render_Instance, src),
		offset_of(Render_Instance, dst),
		offset_of(Render_Instance, clip),
		offset_of(Render_Instance, color),
		offset_of(Render_Instance, color) + 16,
		offset_of(Render_Instance, color) + 32,
		offset_of(Render_Instance, color) + 48,
		offset_of(Render_Instance, radii),
		offset_of(Render_Instance, softness),
		offset_of(Render_Instance, thickness),
	}
	for offset, i in offsets {
		components: i32 = 4
		if i >= 8 do components = 1
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

render_destroy :: proc(renderer: ^Renderer) {
	gl.DeleteTextures(1, &renderer.white_texture)
	gl.DeleteBuffers(1, &renderer.vbo)
	gl.DeleteVertexArrays(1, &renderer.vao)
	gl.DeleteProgram(renderer.program)
}

render_max_texture_size :: proc() -> int {
	size: i32
	gl.GetIntegerv(gl.MAX_TEXTURE_SIZE, &size)
	return int(size)
}

render_create_atlas_texture :: proc(renderer: ^Renderer, id: Texture_Id, bitmap: Bitmap) {
	assert(id != 0)
	assert(bitmap.width > 0 && bitmap.height > 0)
	assert(len(bitmap.pixels) == bitmap.width * bitmap.height)
	assert(renderer.textures[id] == 0, "Texture ID is already registered")

	texture: u32
	gl.GenTextures(1, &texture)
	gl.BindTexture(gl.TEXTURE_2D, texture)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(bitmap.width),
		i32(bitmap.height),
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(bitmap.pixels),
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	renderer.textures[id] = texture
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

render_init :: proc(renderer: ^Renderer) -> bool {
	vertex := render_compile_shader(gl.VERTEX_SHADER, RENDER_VERTEX_SOURCE)
	if vertex == 0 do return false
	defer gl.DeleteShader(vertex)
	fragment := render_compile_shader(gl.FRAGMENT_SHADER, RENDER_FRAGMENT_SOURCE)
	if fragment == 0 do return false
	defer gl.DeleteShader(fragment)
	renderer.program = gl.CreateProgram()
	gl.AttachShader(renderer.program, vertex)
	gl.AttachShader(renderer.program, fragment)
	gl.LinkProgram(renderer.program)
	ok: i32
	gl.GetProgramiv(renderer.program, gl.LINK_STATUS, &ok)
	if ok == 0 {
		log: [4096]u8
		length: i32
		gl.GetProgramInfoLog(renderer.program, len(log), &length, &log[0])
		fmt.eprintf("Renderer program linking failed: %s\n", string(log[:length]))
		gl.DeleteProgram(renderer.program)
		renderer.program = 0
		return false
	}
	renderer.view_uniform = gl.GetUniformLocation(renderer.program, "view_size")
	gl.UseProgram(renderer.program)
	gl.Uniform1i(gl.GetUniformLocation(renderer.program, "image"), 0)
	gl.UseProgram(0)
	gl.GenVertexArrays(1, &renderer.vao)
	gl.GenBuffers(1, &renderer.vbo)
	// Keep the sampler complete even when the shader takes the untextured path.
	gl.GenTextures(1, &renderer.white_texture)
	gl.BindTexture(gl.TEXTURE_2D, renderer.white_texture)
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
layout(location=2) in vec4 clip;
layout(location=3) in vec4 color_tl;
layout(location=4) in vec4 color_tr;
layout(location=5) in vec4 color_br;
layout(location=6) in vec4 color_bl;
layout(location=7) in vec4 radii;
layout(location=8) in float softness;
layout(location=9) in float inst_thickness;
uniform vec2 view_size;
out vec2 position;
out vec2 local_position;
flat out vec4 rect_src;
flat out vec2 rect_size;
flat out vec4 colors[4];
flat out vec4 corner_radii;
flat out float edge_softness;
flat out float thickness;
const vec2 corners[6] = vec2[6](
    vec2(0,0), vec2(1,0), vec2(1,1),
    vec2(0,0), vec2(1,1), vec2(0,1));
void main() {
    // The quad shrinks to its part inside the clip; nothing inside moves, as local_position stays relative to dst.
    vec2 lo = max(dst.xy, clip.xy);
    vec2 hi = max(min(dst.xy + dst.zw, clip.xy + clip.zw), lo);
    position = mix(lo, hi, corners[gl_VertexID]);
    local_position = position - dst.xy;
    gl_Position = vec4(position / view_size * vec2(2,-2) + vec2(-1,1), 0, 1);
    rect_src = src;
    rect_size = dst.zw;
    colors[0] = color_tl; colors[1] = color_tr;
    colors[2] = color_br; colors[3] = color_bl;
    corner_radii = radii;
    edge_softness = softness;
    thickness = inst_thickness;
}
`

@(private = "file")
RENDER_FRAGMENT_SOURCE: cstring = `#version 330 core
uniform sampler2D image;
in vec2 local_position;
flat in vec4 rect_src;
flat in vec2 rect_size;
flat in vec4 colors[4];
flat in vec4 corner_radii;
flat in float edge_softness;
flat in float thickness;
out vec4 out_color;
float rect_sdf(vec2 p, vec2 half_size, float radius) {
    return length(max(abs(p) - half_size + radius, 0.0)) - radius;
}
void main() {
    vec2 t = local_position / rect_size;
    vec4 color = mix(mix(colors[0], colors[1], t.x),
                     mix(colors[3], colors[2], t.x), t.y);
    // Only instances with a source rect sample; the rest ignore whatever texture their batch binds.
    if (rect_src.z > 0.0) {
        vec2 uv = (rect_src.xy + t * rect_src.zw) / vec2(textureSize(image, 0));
        color *= texture(image, uv);
    }
    vec2 half_size = rect_size * 0.5;
    vec2 p = local_position - half_size;
    float r = p.y < 0.0 ? (p.x < 0.0 ? corner_radii.x : corner_radii.y)
                        : (p.x < 0.0 ? corner_radii.w : corner_radii.z);
    r = clamp(r, 0.0, min(half_size.x, half_size.y));
    // Inset the shape to fit a 2*softness fade inside the supplied quad.
    float softness = max(edge_softness, 0.0);
    float feather = max(2.0 * softness, 0.0001);
    vec2 shape_half_size = half_size - vec2(2.0 * softness);
    float border = 1.0;
    if (thickness > 0.0) {
        float inner = rect_sdf(p, shape_half_size - vec2(thickness), max(r - thickness, 0.0));
        border = smoothstep(0.0, feather, inner);
    }
    // Plain image/text quads use texture coverage without an additional edge fade.
    float corner = 1.0;
    if (r > 0.0 || softness > 0.75) {
        float outer = rect_sdf(p, shape_half_size, r);
        corner = 1.0 - smoothstep(0.0, feather, outer);
    }
    out_color = vec4(color.rgb, color.a * corner * border);
}
`
