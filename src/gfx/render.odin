package gfx

import "core:fmt"
import gl "vendor:OpenGL"

RENDER_MAX_INSTANCES :: 8192 * 2

Texture_Id :: distinct u16

// Tightly packed, top-to-bottom RGBA8 pixels. Storage is owned by the caller.
Bitmap :: struct {
	pixels: [][4]u8,
	width:  int,
	height: int,
}

// What batches a render instance: consecutive instances sharing it draw in one call.
Render_Key :: struct {
	texture: Texture_Id,
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

// The largest terrain the map pass draws, in cells
RENDER_TERRAIN_WIDTH :: 1024
RENDER_TERRAIN_HEIGHT :: 1024
RENDER_TERRAIN_CELLS :: RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT

// Which terrain property the map shows cell by cell instead of drawing the map. The values match the map shader's debug_mode.
Render_Terrain_Debug :: enum i32 {
	Map,
	Surface,
	Elevation,
	Trees,
	Moisture,
	// The hill shading alone, over land
	Relief,
}

// How the map is drawn. Colors use straight RGBA; only RGB is used.
Render_Terrain_Style :: struct {
	paper:         [4]f32,
	paper_stain:   [4]f32,
	ink:           [4]f32,
	sea_color:     [4]f32,
	forest_color:  [4]f32,
	sea_tint:      f32,
	forest_tint:   f32,
	// Coast line width in logical pixels, and how far the coast wanders from the cells, in cells
	coast_width:   f32,
	wobble:        f32,
	// River line width in logical pixels, where a river reaches the lowlands; it thins toward its sources.
	river_width:   f32,
	// Hill shading. light points toward the light: x east, y south (down the map), z up; it need not be unit length.
	// relief_height is how many cells tall the highest ground stands: more makes every slope steeper.
	// Slopes facing away from the light darken toward shade_color, and slopes facing it lighten toward white, the more
	// the further they turn, scaled by relief_shade and relief_light. Level ground keeps its color.
	light:         [3]f32,
	relief_height: f32,
	shade_color:   [4]f32,
	relief_shade:  f32,
	relief_light:  f32,
}

// How far around a river its offsets reach, in cells. Cells farther away hold RENDER_RIVER_FAR.
RENDER_RIVER_REACH :: 4
RENDER_RIVER_FAR :: [2]f32{RENDER_RIVER_REACH, RENDER_RIVER_REACH}

// Everything the map pass draws from. Cells are indexed y * RENDER_TERRAIN_WIDTH + x, with cell (0, 0) at the top left.
Render_Terrain :: struct {
	// Bumped whenever cells or coast change; the renderer uploads them again only then.
	revision:   u32,
	// The terrain as the rules see it, one texel per cell: surface (land, river, lake, sea as 0, 85, 170, 255),
	// elevation, trees, moisture.
	cells:      [RENDER_TERRAIN_CELLS][4]u8,
	// Derived from the cells: signed distance to the coast, in cells, positive on land.
	coast:      [RENDER_TERRAIN_CELLS]f32,
	// Derived from the cells: from the middle of each cell to the nearest point of a river line, in cells.
	river:      [RENDER_TERRAIN_CELLS][2]f32,
	// Derived from the cells: elevation from 0 to 1, smoothed so its slopes can be shaded. Water holds the elevation of
	// the land around it, so the coast does not shade as a cliff.
	relief:     [RENDER_TERRAIN_CELLS]f32,
	// The cell at the middle of the view, and logical pixels per cell
	center:     [2]f32,
	zoom:       f32,
	debug_mode: Render_Terrain_Debug,
	// The map shades its hills from the relief; off, the land is flat paper.
	shading:    bool,
	style:      Render_Terrain_Style,
}

// Where the map shader's uniforms live, looked up once when its program links.
@(private = "file")
Render_Terrain_Uniforms :: struct {
	grid, center, zoom, view_size, pixel_density, debug_mode:      i32,
	paper, paper_stain, ink, sea_color, forest_color:              i32,
	sea_tint, forest_tint, coast_width, wobble, river_width:       i32,
	light, relief_height, shade_color, relief_shade, relief_light: i32,
	shading:                                                       i32,
}

Renderer :: struct {
	program, vao, vbo, white_texture: u32,
	view_uniform:                     i32,
	// Logical window dimensions, matching SDL mouse coordinates.
	view_size:                        [2]f32,
	// Physical pixels per logical pixel; zero is taken as one.
	pixel_density:                    f32,
	// Borrowed OpenGL texture handles. Slot zero always means untextured.
	textures:                         [65536]u32,
	// The map pass: its program, an empty vertex array for its one triangle, and its textures
	terrain_program:                  u32,
	terrain_vao:                      u32,
	terrain_cells:                    u32,
	terrain_coast:                    u32,
	terrain_river:                    u32,
	terrain_relief:                   u32,
	terrain_uniforms:                 Render_Terrain_Uniforms,
	// The terrain revision the textures hold, once anything has been uploaded
	terrain_revision:                 u32,
	terrain_uploaded:                 bool,
}

// Draws the map over the whole view. Cells, coast, rivers and relief are uploaded again only when the revision has
// changed.
render_terrain :: proc(renderer: ^Renderer, terrain: ^Render_Terrain) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 || terrain.zoom <= 0 {
		return
	}

	if !renderer.terrain_uploaded || renderer.terrain_revision != terrain.revision {
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
		gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_cells)
		gl.TexSubImage2D(
			gl.TEXTURE_2D,
			0,
			0,
			0,
			RENDER_TERRAIN_WIDTH,
			RENDER_TERRAIN_HEIGHT,
			gl.RGBA,
			gl.UNSIGNED_BYTE,
			raw_data(terrain.cells[:]),
		)
		gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_coast)
		gl.TexSubImage2D(
			gl.TEXTURE_2D,
			0,
			0,
			0,
			RENDER_TERRAIN_WIDTH,
			RENDER_TERRAIN_HEIGHT,
			gl.RED,
			gl.FLOAT,
			raw_data(terrain.coast[:]),
		)
		gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_river)
		gl.TexSubImage2D(
			gl.TEXTURE_2D,
			0,
			0,
			0,
			RENDER_TERRAIN_WIDTH,
			RENDER_TERRAIN_HEIGHT,
			gl.RG,
			gl.FLOAT,
			raw_data(terrain.river[:]),
		)
		gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_relief)
		gl.TexSubImage2D(
			gl.TEXTURE_2D,
			0,
			0,
			0,
			RENDER_TERRAIN_WIDTH,
			RENDER_TERRAIN_HEIGHT,
			gl.RED,
			gl.FLOAT,
			raw_data(terrain.relief[:]),
		)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		renderer.terrain_revision = terrain.revision
		renderer.terrain_uploaded = true
	}

	// The map is opaque and covers everything drawn before it.
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.SCISSOR_TEST)
	gl.Disable(gl.BLEND)
	gl.UseProgram(renderer.terrain_program)
	gl.BindVertexArray(renderer.terrain_vao)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_cells)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_coast)
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_river)
	gl.ActiveTexture(gl.TEXTURE3)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_relief)

	u := &renderer.terrain_uniforms
	style := &terrain.style
	density := renderer.pixel_density if renderer.pixel_density > 0 else 1
	gl.Uniform2f(u.grid, RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT)
	gl.Uniform2f(u.center, terrain.center.x, terrain.center.y)
	gl.Uniform1f(u.zoom, terrain.zoom)
	gl.Uniform2f(u.view_size, renderer.view_size.x, renderer.view_size.y)
	gl.Uniform1f(u.pixel_density, density)
	gl.Uniform1i(u.debug_mode, i32(terrain.debug_mode))
	gl.Uniform3f(u.paper, style.paper.r, style.paper.g, style.paper.b)
	gl.Uniform3f(u.paper_stain, style.paper_stain.r, style.paper_stain.g, style.paper_stain.b)
	gl.Uniform3f(u.ink, style.ink.r, style.ink.g, style.ink.b)
	gl.Uniform3f(u.sea_color, style.sea_color.r, style.sea_color.g, style.sea_color.b)
	gl.Uniform3f(u.forest_color, style.forest_color.r, style.forest_color.g, style.forest_color.b)
	gl.Uniform1f(u.sea_tint, style.sea_tint)
	gl.Uniform1f(u.forest_tint, style.forest_tint)
	gl.Uniform1f(u.coast_width, style.coast_width)
	gl.Uniform1f(u.wobble, style.wobble)
	gl.Uniform1f(u.river_width, style.river_width)
	gl.Uniform3f(u.light, style.light.x, style.light.y, style.light.z)
	gl.Uniform1f(u.relief_height, style.relief_height)
	gl.Uniform3f(u.shade_color, style.shade_color.r, style.shade_color.g, style.shade_color.b)
	gl.Uniform1f(u.relief_shade, style.relief_shade)
	gl.Uniform1f(u.relief_light, style.relief_light)
	gl.Uniform1i(u.shading, i32(terrain.shading))

	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.ActiveTexture(gl.TEXTURE2)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.BindVertexArray(0)
	gl.UseProgram(0)
}

// src, dst and clip are [x, y, width, height], with a top-left origin.
// src uses texture pixels; dst, clip, radii and softness use logical pixels.
// Textures should have their top row at v=0. Colors use straight alpha.
// Instances draw in the order they sit in the list.
render_list :: proc(renderer: ^Renderer, list: ^Render_List) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 {
		return
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
	gl.BufferData(
		gl.ARRAY_BUFFER,
		size_of(list.instances),
		raw_data(list.instances[:]),
		gl.STREAM_DRAW,
	)

	for first := 0; first < RENDER_MAX_INSTANCES; {
		// Untextured instances sample nothing, so they join a batch of any texture; the first textured one picks it.
		batch_texture: Texture_Id
		end := first
		for end < RENDER_MAX_INSTANCES {
			texture := list.keys[end].texture
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
	gl.DeleteTextures(1, &renderer.terrain_cells)
	gl.DeleteTextures(1, &renderer.terrain_coast)
	gl.DeleteTextures(1, &renderer.terrain_river)
	gl.DeleteTextures(1, &renderer.terrain_relief)
	gl.DeleteVertexArrays(1, &renderer.terrain_vao)
	gl.DeleteProgram(renderer.terrain_program)
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
	return render_terrain_init(renderer)
}

// Links the map program and makes its textures, with storage for the largest terrain and nothing in them yet.
@(private = "file")
render_terrain_init :: proc(renderer: ^Renderer) -> bool {
	vertex := render_compile_shader(gl.VERTEX_SHADER, RENDER_MAP_VERTEX_SOURCE)
	if vertex == 0 do return false
	defer gl.DeleteShader(vertex)
	fragment := render_compile_shader(gl.FRAGMENT_SHADER, RENDER_MAP_FRAGMENT_SOURCE)
	if fragment == 0 do return false
	defer gl.DeleteShader(fragment)
	program := gl.CreateProgram()
	gl.AttachShader(program, vertex)
	gl.AttachShader(program, fragment)
	gl.LinkProgram(program)
	ok: i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &ok)
	if ok == 0 {
		log: [4096]u8
		length: i32
		gl.GetProgramInfoLog(program, len(log), &length, &log[0])
		fmt.eprintf("Renderer map program linking failed: %s\n", string(log[:length]))
		gl.DeleteProgram(program)
		return false
	}
	renderer.terrain_program = program

	u := &renderer.terrain_uniforms
	u.grid = gl.GetUniformLocation(program, "grid")
	u.center = gl.GetUniformLocation(program, "center")
	u.zoom = gl.GetUniformLocation(program, "zoom")
	u.view_size = gl.GetUniformLocation(program, "view_size")
	u.pixel_density = gl.GetUniformLocation(program, "pixel_density")
	u.debug_mode = gl.GetUniformLocation(program, "debug_mode")
	u.paper = gl.GetUniformLocation(program, "paper")
	u.paper_stain = gl.GetUniformLocation(program, "paper_stain")
	u.ink = gl.GetUniformLocation(program, "ink")
	u.sea_color = gl.GetUniformLocation(program, "sea_color")
	u.forest_color = gl.GetUniformLocation(program, "forest_color")
	u.sea_tint = gl.GetUniformLocation(program, "sea_tint")
	u.forest_tint = gl.GetUniformLocation(program, "forest_tint")
	u.coast_width = gl.GetUniformLocation(program, "coast_width")
	u.wobble = gl.GetUniformLocation(program, "wobble")
	u.river_width = gl.GetUniformLocation(program, "river_width")
	u.light = gl.GetUniformLocation(program, "light")
	u.relief_height = gl.GetUniformLocation(program, "relief_height")
	u.shade_color = gl.GetUniformLocation(program, "shade_color")
	u.relief_shade = gl.GetUniformLocation(program, "relief_shade")
	u.relief_light = gl.GetUniformLocation(program, "relief_light")
	u.shading = gl.GetUniformLocation(program, "shading")
	gl.UseProgram(program)
	gl.Uniform1i(gl.GetUniformLocation(program, "cells"), 0)
	gl.Uniform1i(gl.GetUniformLocation(program, "coast"), 1)
	gl.Uniform1i(gl.GetUniformLocation(program, "river"), 2)
	gl.Uniform1i(gl.GetUniformLocation(program, "relief"), 3)
	gl.UseProgram(0)

	// The map's one triangle has no vertex data, but core profile still wants a vertex array bound.
	gl.GenVertexArrays(1, &renderer.terrain_vao)

	// Cells and coast are filtered between cells: that makes the coast smooth and the washes soft. The debug views read
	// cells with texelFetch, which ignores filtering, so they still show each cell exactly. Rivers are read cell by
	// cell and blended in the shader. Relief is filtered too, and kept at full precision: the shader takes its slope
	// from small differences.
	gl.GenTextures(1, &renderer.terrain_cells)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_cells)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		RENDER_TERRAIN_WIDTH,
		RENDER_TERRAIN_HEIGHT,
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		nil,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenTextures(1, &renderer.terrain_coast)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_coast)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.R16F,
		RENDER_TERRAIN_WIDTH,
		RENDER_TERRAIN_HEIGHT,
		0,
		gl.RED,
		gl.FLOAT,
		nil,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenTextures(1, &renderer.terrain_river)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_river)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RG16F,
		RENDER_TERRAIN_WIDTH,
		RENDER_TERRAIN_HEIGHT,
		0,
		gl.RG,
		gl.FLOAT,
		nil,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.GenTextures(1, &renderer.terrain_relief)
	gl.BindTexture(gl.TEXTURE_2D, renderer.terrain_relief)
	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.R32F,
		RENDER_TERRAIN_WIDTH,
		RENDER_TERRAIN_HEIGHT,
		0,
		gl.RED,
		gl.FLOAT,
		nil,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
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

// The map pass: one triangle covering the view, drawn before the render list.
@(private = "file")
RENDER_MAP_VERTEX_SOURCE: cstring = `#version 330 core
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
`

// Positions are in cells: the world is grid cells wide and tall, with cell (0, 0) at the top left.
// cells holds the terrain as the rules see it, one texel per cell: surface, elevation, trees, moisture. texelFetch reads
// a cell exactly; texture blends neighbouring cells.
// coast holds the signed distance to the coast in cells, positive on land, blended between cells.
// river holds, per cell, the offset from its middle to the nearest point of a river line.
// relief holds the smoothed elevation, from 0 to 1, blended between cells.
@(private = "file")
RENDER_MAP_FRAGMENT_SOURCE: cstring = `#version 330 core
uniform sampler2D cells;
uniform sampler2D coast;
uniform sampler2D river;
uniform sampler2D relief;
uniform vec2 grid;
// The cell at the middle of the view, and logical pixels per cell
uniform vec2 center;
uniform float zoom;
uniform vec2 view_size;
uniform float pixel_density;
// 0 draws the map; 1 to 4 show surface, elevation, trees and moisture cell by cell; 5 shows the hill shading
uniform int debug_mode;
uniform vec3 paper;
uniform vec3 paper_stain;
uniform vec3 ink;
uniform vec3 sea_color;
uniform vec3 forest_color;
uniform float sea_tint;
uniform float forest_tint;
// Coast line width in logical pixels, and how far the coast wanders from the cells, in cells
uniform float coast_width;
uniform float wobble;
// River line width in logical pixels in the lowlands
uniform float river_width;
// Hill shading: toward the light (x east, y south, z up), how many cells tall the highest ground stands, and how
// strongly slopes darken toward shade_color or lighten toward white
uniform vec3 light;
uniform float relief_height;
uniform vec3 shade_color;
uniform float relief_shade;
uniform float relief_light;
// Nonzero shades the hills on the map; the relief debug view shows the shading either way.
uniform int shading;
out vec4 out_color;

float hash(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
float value_noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash(i), b = hash(i + vec2(1, 0)), c = hash(i + vec2(0, 1)), d = hash(i + vec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// Four octaves of value noise, in 0..1
float fbm(vec2 p) {
    float sum = 0.0, weight = 0.5;
    for (int i = 0; i < 4; i++) { sum += weight * value_noise(p); p *= 2.03; weight *= 0.5; }
    return sum / 0.9375;
}
// Coverage of a line of half width half_w at distance dist, both in device pixels; thinner lines fade instead of vanishing.
float line_aa(float dist, float half_w) {
    float hw = max(half_w, 0.5);
    return (1.0 - smoothstep(hw - 0.6, hw + 0.6, dist)) * min(1.0, half_w / 0.5);
}

// Vellum: large stains fixed to the world, and a fine grain fixed to the screen.
vec3 paper_at(vec2 p) {
    float stain = smoothstep(0.35, 0.85, fbm(p * 0.02 + 3.1)) * 0.85 + (fbm(p * 0.09 + 11.3) - 0.5) * 0.2;
    vec3 c = mix(paper, paper_stain, clamp(stain, 0.0, 1.0));
    return c * (1.0 - (hash(floor(gl_FragCoord.xy)) - 0.5) * 0.035);
}

// Distance from p to the nearest river line, in cells. Each of the four cells around p knows its nearest river point;
// blending them is exact along a straight river. Where they see different rivers, blending would draw a false river
// between the two, so the nearest of their points is taken instead.
float river_distance(vec2 p) {
    vec2 q = p - 0.5;
    vec2 base = floor(q), f = q - base;
    vec2 n[4];
    for (int k = 0; k < 4; k++) {
        vec2 c = base + vec2(k & 1, k >> 1);
        n[k] = c + 0.5 + texelFetch(river, clamp(ivec2(c), ivec2(0), ivec2(grid) - 1), 0).rg;
    }
    float spread = max(max(distance(n[0], n[1]), distance(n[2], n[3])), max(distance(n[0], n[2]), distance(n[1], n[3])));
    if (spread < 2.0) return distance(p, mix(mix(n[0], n[1], f.x), mix(n[2], n[3], f.x), f.y));
    return min(min(distance(p, n[0]), distance(p, n[1])), min(distance(p, n[2]), distance(p, n[3])));
}

// How much the ground at p turns toward the light, next to level ground: negative on slopes facing away. The slope is
// taken across two cells of the blended relief, so it changes smoothly rather than cell by cell.
float relief_at(vec2 p) {
    float dx = texture(relief, (p + vec2(1.0, 0.0)) / grid).r - texture(relief, (p - vec2(1.0, 0.0)) / grid).r;
    float dy = texture(relief, (p + vec2(0.0, 1.0)) / grid).r - texture(relief, (p - vec2(0.0, 1.0)) / grid).r;
    vec3 n = normalize(vec3(-0.5 * relief_height * vec2(dx, dy), 1.0));
    vec3 l = normalize(light);
    return dot(n, l) - l.z;
}

vec3 debug_color(vec4 cell, vec2 p) {
    // Land, river, lake, sea
    int surface = int(cell.r * 3.0 + 0.5);
    bool water = surface >= 2;
    if (debug_mode == 1) {
        if (surface == 0) return vec3(0.85, 0.8, 0.65);
        if (surface == 1) return vec3(0.2, 0.6, 0.55);
        if (surface == 2) return vec3(0.35, 0.6, 0.85);
        return vec3(0.25, 0.45, 0.7);
    }
    if (water) return vec3(0.12, 0.2, 0.3);
    if (debug_mode == 2) return vec3(cell.g);
    if (debug_mode == 3) return mix(vec3(0.85, 0.8, 0.65), vec3(0.15, 0.4, 0.15), cell.b);
    if (debug_mode == 5) return vec3(clamp(0.6 + relief_at(p), 0.0, 1.0));
    return mix(vec3(0.8, 0.65, 0.4), vec3(0.3, 0.5, 0.75), cell.a);
}

void main() {
    // Screen position in logical pixels, from the top left like the rest of the renderer
    vec2 screen = vec2(gl_FragCoord.x, view_size.y * pixel_density - gl_FragCoord.y) / pixel_density;
    vec2 p = center + (screen - view_size * 0.5) / zoom;
    // Device pixels per cell: line widths and anti-aliasing are measured in these.
    float px = zoom * pixel_density;

    if (any(lessThan(p, vec2(0.0))) || any(greaterThanEqual(p, grid))) {
        out_color = vec4(paper * 0.72, 1.0);
        return;
    }

    vec3 col;
    if (debug_mode > 0) {
        col = debug_color(texelFetch(cells, ivec2(floor(p)), 0), p);
        // Cell edges, once cells are big enough to tell apart
        vec2 g = fract(p);
        float edge = min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y)) * px;
        col = mix(col, vec3(0.0), (1.0 - smoothstep(0.0, 1.0, edge)) * 0.3 * smoothstep(4.0, 8.0, px));
    } else {
        vec4 cell = texture(cells, p / grid);
        // The coast wanders a little from the cells, as if drawn by hand.
        float d = texture(coast, p / grid).r + wobble * (fbm(p * 0.45 + 7.7) - 0.5) * 1.6;
        float land = smoothstep(-0.5 / px, 0.5 / px, d);
        col = paper_at(p);
        // The sea wash is strongest along the coast.
        vec3 sea = col * mix(vec3(1.0), sea_color, sea_tint * (0.65 + 0.35 * exp(min(d, 0.0) / 5.0)));
        vec3 ground = col * mix(vec3(1.0), forest_color, cell.b * forest_tint);
        col = mix(sea, ground, land);

        // Hill shading, lit from the same side as the drawn marks. Only the land is shaded.
        if (shading != 0) {
            float lit = relief_at(p);
            col = mix(col, col * shade_color, clamp(-lit * relief_shade, 0.0, 1.0) * land);
            col = mix(col, vec3(1.0), clamp(lit * relief_light, 0.0, 1.0) * land);
        }

        // Rivers: a faint wash either side and a line that thins toward the hills, both stopping at the shore. The line
        // never grows past a third of a cell, so rivers fade out as the map zooms away.
        float r = river_distance(p) + wobble * (fbm(p * 0.6 + 3.3) - 0.5) * 0.5;
        col = mix(col, col * sea_color, sea_tint * 0.5 * (1.0 - smoothstep(0.0, 1.2, r)) * land);
        float river_half = min(river_width * 0.5 * pixel_density * mix(1.0, 0.4, smoothstep(0.2, 0.8, cell.g)), px / 6.0);
        col = mix(col, mix(ink, sea_color, 0.3), line_aa(r * px, river_half) * land);

        float width = coast_width * 0.5 * pixel_density * (0.8 + 0.4 * value_noise(p * 0.8));
        col = mix(col, ink, line_aa(abs(d) * px, width));
    }

    // The sheet darkens toward its edges.
    vec2 m = min(p, grid - p);
    col *= mix(0.84, 1.0, smoothstep(0.0, 12.0, min(m.x, m.y)));
    out_color = vec4(col, 1.0);
}
`
