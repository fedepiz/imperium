#+private
package main

import "base:runtime"

import "core:fmt"

import sdl "vendor:sdl3"

import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

// Prepended to every shader
@(private = "file")
VIEW_SHADER :: #load("view.wgsl", string)

@(private = "file")
QUAD_SHADER :: VIEW_SHADER + #load("quad.wgsl", string)

@(private = "file")
GROUND_SHADER :: VIEW_SHADER + #load("ground.wgsl", string)

@(private = "file")
STROKE_SHADER :: VIEW_SHADER + #load("stroke.wgsl", string)


// Budgets
RENDER_IMAGES_MAX :: 4000
// Largest texture every WebGPU device supports
RENDER_ATLAS_SIZE_MAX :: 8192

RENDER_QUADS_MAX :: 1 << 16
RENDER_PASS_MAX :: 256

// Ground size in cells. 1 world unit = 1 cell
RENDER_GROUND_WIDTH :: 1024
RENDER_GROUND_HEIGHT :: 1024
// Categories of the ground's category layer
RENDER_GROUND_CATEGORIES :: 256
// Strokes of the ground
RENDER_GROUND_STROKES :: 2
// Line segments per stroke
RENDER_GROUND_STROKE_SEGMENTS_MAX :: 1 << 16

// Value of the strokes target where no segment is near, in cells
@(private = "file")
STROKE_FAR :: 1000

// Native Min. The binding's enum lacks webgpu.h's Undefined, so its values are one less than native
@(private = "file")
BLEND_MIN :: wgpu.BlendOperation(4)


Renderer_Flag :: enum {
	Ready,
}

Renderer :: struct {
	flags:           bit_set[Renderer_Flag],
	window:          ^sdl.Window,
	instance:        wgpu.Instance,
	adapter:         wgpu.Adapter,
	surface:         wgpu.Surface,
	device:          wgpu.Device,
	queue:           wgpu.Queue,
	format:          Surface_Format,
	// Cached window size
	window_size:     [2]i32,
	// Quad pass data
	quad_pipeline:   wgpu.RenderPipeline,
	quad_buffer:     wgpu.Buffer,
	// View uniforms per space. Group 0 of every pipeline
	view_layout:     wgpu.BindGroupLayout,
	view_buffers:    [Render_Space]wgpu.Buffer,
	view_groups:     [Render_Space]wgpu.BindGroup,
	// Linear filter, clamp to edge. Used by the atlas and the ground grids
	sampler:         wgpu.Sampler,
	// Images
	atlas_texture:   wgpu.Texture,
	atlas_view:      wgpu.TextureView,
	atlas_group:     wgpu.BindGroup,
	// Ground pass data. ground_group is group 1: uniforms, sampler, grids
	ground_pipeline: wgpu.RenderPipeline,
	ground_uniforms: wgpu.Buffer,
	ground_grids:    [Ground_Grid]Texture,
	// RENDER_GROUND_CATEGORIES x 2 texels. Row 0: wash colour, wash. Row 1: pattern, pattern ink
	ground_category_looks: Texture,
	ground_layout:   wgpu.BindGroupLayout,
	// Recreated on resize: it binds strokes_target and sprites_target
	ground_group:    wgpu.BindGroup,
	// Strokes. Per stroke: a segment buffer, drawn every frame as distances into one channel of
	// strokes_target
	stroke_pipelines: [RENDER_GROUND_STROKES]wgpu.RenderPipeline,
	stroke_buffers:   [RENDER_GROUND_STROKES]wgpu.Buffer,
	stroke_counts:    [RENDER_GROUND_STROKES]u32,
	// Window-sized, recreated on resize. Channel i: distance to stroke i's nearest segment, in cells
	strokes_target:   Texture,
	// Window-sized, recreated on resize. Quads of passes with target = .Ground, premultiplied
	sprites_target:   Texture,
}

// Instance of the stroke pipeline, in cells
@(private = "file")
Stroke_Segment :: struct {
	a: [2]f32,
	b: [2]f32,
}

@(private = "file")
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

// Bindings of the ground group: uniforms, sampler, grids, category looks, strokes target,
// sprites target
@(private = "file")
GROUND_BINDING_CATEGORY_LOOKS :: 2 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_STROKES_TARGET :: 3 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_SPRITES_TARGET :: 4 + len(Ground_Grid)
@(private = "file")
GROUND_BINDINGS :: 5 + len(Ground_Grid)

@(private = "file")
STROKES_TARGET_FORMAT :: wgpu.TextureFormat.RGBA16Float
#assert(RENDER_GROUND_STROKES <= 4)

@(private = "file")
Ground_Grid_Format :: struct {
	format:     wgpu.TextureFormat,
	// Bytes per texel
	texel_size: int,
}

@(private = "file", rodata)
GROUND_GRID_FORMATS := [Ground_Grid]Ground_Grid_Format {
	.Value  = {.R8Unorm, 1},
	.Divide = {.R16Float, 2},
	.Taper    = {.R8Unorm, 1},
	.Category = {.RG8Unorm, 2},
}

// Per-cell textures read by the ground shader. Binding = 2 + Ground_Grid
@(private = "file")
Ground_Grid :: enum {
	Value,
	Divide,
	Taper,
	Category,
}

// Must match struct Ground in ground.wgsl.
// WGSL vec3f: align 16, size 12. Each [3]f32 is followed by one f32 (scalar or padding)
@(private = "file")
Ground_Uniform :: struct {
	base_color:        [3]f32,
	stain_amount:      f32,
	base_stain:        [3]f32,
	category_jitter:   f32,
	divide_shallow:    [3]f32,
	divide_tint:       f32,
	divide_deep:       [3]f32,
	divide_wobble:     f32,
	divide_line_color: [3]f32,
	divide_line_width: f32,
	value_low:         [3]f32,
	value_strength:    f32,
	value_high:        [3]f32,
	value_clip:        i32,
	// Grid size in cells
	grid:              [2]f32,
	divide_depth_from: f32,
	divide_depth_full: f32,
	category_pattern:  [3]f32,
	category_strength: f32,
	strokes:           [RENDER_GROUND_STROKES]Stroke_Uniform,
}
#assert(size_of(Ground_Uniform) == 144 + 48 * RENDER_GROUND_STROKES)

// Must match struct Stroke in ground.wgsl. Field use per kind: see the Render_Ground_Stroke variants
@(private = "file")
Stroke_Uniform :: struct {
	color:      [3]f32,
	width:      f32,
	fill:       [3]f32,
	strength:   f32,
	kind:       Stroke_Kind,
	clip:       i32,
	edge_width: f32,
	wander:     f32,
}

@(private = "file")
Stroke_Kind :: enum i32 {
	None,
	Line,
	Double,
}

// Must match struct View in view.wgsl
@(private = "file")
View_Uniform :: struct {
	size:   [2]f32,
	center: [2]f32,
	zoom:          f32,
	pixel_density: f32,
}

@(private = "file")
Surface_Format :: struct {
	surface: wgpu.TextureFormat,
	view:    wgpu.TextureFormat,
}

// In order of preference
@(private = "file")
SURFACE_FORMATS :: [?]Surface_Format {
	{.BGRA8Unorm, .BGRA8Unorm},
	{.RGBA8Unorm, .RGBA8Unorm},
	{.BGRA8UnormSrgb, .BGRA8Unorm},
	{.RGBA8UnormSrgb, .RGBA8Unorm},
}

renderer_init :: proc(
	window: ^sdl.Window,
	// Atlas size and, per image, its rect in the atlas and RGBA8 premultiplied pixels
	atlas_size: [2]int,
	extents: []Extents,
	pixels: [][]u8,
) -> (
	out: Renderer,
) {
	assert(window != nil)
	assert(len(extents) == len(pixels))
	assert(len(extents) <= RENDER_IMAGES_MAX)
	assert(atlas_size.x <= RENDER_ATLAS_SIZE_MAX && atlas_size.y <= RENDER_ATLAS_SIZE_MAX)

	out.window = window
	// Create instance
	out.instance = wgpu.CreateInstance()
	if out.instance == nil {
		fmt.eprintfln("wgpu instance creation failed")
		return
	}

	// Create surface
	out.surface = sdl3glue.GetSurface(out.instance, window)
	if out.surface == nil {
		fmt.eprintln("wgpu surface creation failed")
		return
	}

	// Create adapter
	on_adapter :: proc "c" (
		status: wgpu.RequestAdapterStatus,
		adapter: wgpu.Adapter,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		(^bool)(userdata2)^ = true
		if status != .Success {
			fmt.eprintln("wgpu adapter request failed:", message)
			return
		}
		(^wgpu.Adapter)(userdata1)^ = adapter
	}

	adapter_done: bool
	wgpu.InstanceRequestAdapter(
		out.instance,
		&{compatibleSurface = out.surface},
		{
			mode = .AllowProcessEvents,
			callback = on_adapter,
			userdata1 = &out.adapter,
			userdata2 = &adapter_done,
		},
	)

	for !adapter_done do wgpu.InstanceProcessEvents(out.instance)
	if out.adapter == nil do return

	info, info_status := wgpu.AdapterGetInfo(out.adapter)
	if info_status == .Success {
		fmt.println("GPU:", info.device, "|backend:", info.backendType)
		wgpu.AdapterInfoFreeMembers(info)
	}

	// Create device & queue
	on_device :: proc "c" (
		status: wgpu.RequestDeviceStatus,
		device: wgpu.Device,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		(^bool)(userdata2)^ = true
		if status != .Success {
			fmt.eprintln("wgpu device request failed:", message)
			return
		}
		(^wgpu.Device)(userdata1)^ = device
	}

	// Print validation errors: wgpu drops them when no callback is set
	on_error :: proc "c" (
		device: ^wgpu.Device,
		type: wgpu.ErrorType,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		fmt.eprintfln("wgpu error (%v): %s", type, message)
	}

	device_done: bool
	wgpu.AdapterRequestDevice(
		out.adapter,
		&{uncapturedErrorCallbackInfo = {callback = on_error}},
		{
			mode = .AllowProcessEvents,
			callback = on_device,
			userdata1 = &out.device,
			userdata2 = &device_done,
		},
	)
	for !device_done do wgpu.InstanceProcessEvents(out.instance)
	if out.device == nil do return

	out.queue = wgpu.DeviceGetQueue(out.device)

	// Capabilities
	{
		capabilities, status := wgpu.SurfaceGetCapabilities(out.surface, out.adapter)
		defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)
		if status != .Success || capabilities.formatCount == 0 {
			fmt.eprintln("wgpu surface capability query failed")
			return
		}
		found := false
		search: for candidate in SURFACE_FORMATS {
			for format in capabilities.formats[:capabilities.formatCount] {
				if format == candidate.surface {
					out.format = candidate
					found = true
					break search
				}
			}
		}
		if !found {
			fmt.eprintln("No supported surface format")
			return
		}
	}

	quad_module := wgpu.DeviceCreateShaderModule(
		out.device,
		&{
			nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = QUAD_SHADER},
			label = "quad",
		},
	)
	defer wgpu.ShaderModuleRelease(quad_module)

	// Explicit bind group layouts: groups of an auto layout cannot be shared between pipelines
	out.view_layout = wgpu.DeviceCreateBindGroupLayout(
		out.device,
		&{
			label = "view",
			entryCount = 1,
			entries = &wgpu.BindGroupLayoutEntry {
				binding = 0,
				visibility = {.Vertex, .Fragment},
				buffer = {type = .Uniform, minBindingSize = size_of(View_Uniform)},
			},
		},
	)
	atlas_layout_entries := [?]wgpu.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	atlas_layout := wgpu.DeviceCreateBindGroupLayout(
		out.device,
		&{
			label = "atlas",
			entryCount = len(atlas_layout_entries),
			entries = &atlas_layout_entries[0],
		},
	)
	defer wgpu.BindGroupLayoutRelease(atlas_layout)

	quad_group_layouts := [?]wgpu.BindGroupLayout{out.view_layout, atlas_layout}
	quad_layout := wgpu.DeviceCreatePipelineLayout(
		out.device,
		&{
			label = "quad",
			bindGroupLayoutCount = len(quad_group_layouts),
			bindGroupLayouts = &quad_group_layouts[0],
		},
	)
	defer wgpu.PipelineLayoutRelease(quad_layout)

	quad_attributes := [?]wgpu.VertexAttribute {
		{format = .Float32x4, offset = u64(offset_of(Render_Quad, rect)), shaderLocation = 0},
		{format = .Unorm8x4, offset = u64(offset_of(Render_Quad, colors)) + 0, shaderLocation = 1},
		{format = .Unorm8x4, offset = u64(offset_of(Render_Quad, colors)) + 4, shaderLocation = 2},
		{format = .Unorm8x4, offset = u64(offset_of(Render_Quad, colors)) + 8, shaderLocation = 3},
		{
			format = .Unorm8x4,
			offset = u64(offset_of(Render_Quad, colors)) + 12,
			shaderLocation = 4,
		},
		{format = .Float32x4, offset = u64(offset_of(Render_Quad, clip)), shaderLocation = 5},
		{format = .Float32, offset = u64(offset_of(Render_Quad, radii)), shaderLocation = 6},
		{format = .Float32, offset = u64(offset_of(Render_Quad, thickness)), shaderLocation = 7},
		{format = .Float32, offset = u64(offset_of(Render_Quad, softness)), shaderLocation = 8},
		{format = .Float32x4, offset = u64(offset_of(Render_Quad, source)), shaderLocation = 9},
		{format = .Float32x2, offset = u64(offset_of(Render_Quad, axis)), shaderLocation = 10},
	}

	out.quad_pipeline = wgpu.DeviceCreateRenderPipeline(
		out.device,
		&{
			label = "quad",
			layout = quad_layout,
			vertex = {
				module = quad_module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &wgpu.VertexBufferLayout {
					stepMode = .Instance,
					arrayStride = size_of(Render_Quad),
					attributeCount = len(quad_attributes),
					attributes = &quad_attributes[0],
				},
			},
			primitive = {topology = .TriangleStrip, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &wgpu.FragmentState {
				module = quad_module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = out.format.view,
					blend = &wgpu.BlendState {
						color = {
							operation = .Add,
							srcFactor = .One,
							dstFactor = .OneMinusSrcAlpha,
						},
						alpha = {
							operation = .Add,
							srcFactor = .One,
							dstFactor = .OneMinusSrcAlpha,
						},
					},
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
		},
	)

	out.quad_buffer = wgpu.DeviceCreateBuffer(
		out.device,
		&{
			label = "quads",
			usage = {.Vertex, .CopyDst},
			size = u64(size_of(Render_Quad) * RENDER_QUADS_MAX),
		},
	)


	// View uniform buffers and bind groups
	{
		size: u64 = size_of(View_Uniform)
		for space in Render_Space {
			out.view_buffers[space] = wgpu.DeviceCreateBuffer(
				out.device,
				&{label = "view", usage = {.Uniform, .CopyDst}, size = size},
			)
			out.view_groups[space] = wgpu.DeviceCreateBindGroup(
				out.device,
				&{
					label = "view",
					layout = out.view_layout,
					entryCount = 1,
					entries = &wgpu.BindGroupEntry {
						binding = 0,
						buffer = out.view_buffers[space],
						size = size,
					},
				},
			)
		}
	}

	// Prepare images
	{
		// Create texture, starts zeroed so gaps are transparent
		out.atlas_texture = wgpu.DeviceCreateTexture(
			out.device,
			&{
				label = "atlas",
				usage = {.TextureBinding, .CopyDst},
				dimension = ._2D,
				size = {u32(atlas_size.x), u32(atlas_size.y), 1},
				format = .RGBA8Unorm,
				mipLevelCount = 1,
				sampleCount = 1,
			},
		)

		// Upload each image at its source position
		for extent, i in extents {
			image_pixels := pixels[i]
			pos := [2]int{int(extent.x_min), int(extent.y_min)}
			size := [2]int{int(extent.x_max) - pos.x, int(extent.y_max) - pos.y}
			if size.x <= 0 || size.y <= 0 do continue

			assert(pos.x >= 0 && pos.y >= 0)
			assert(pos.x + size.x <= atlas_size.x && pos.y + size.y <= atlas_size.y)
			assert(len(image_pixels) == size.x * size.y * 4)

			wgpu.QueueWriteTexture(
				out.queue,
				&{
					texture = out.atlas_texture,
					origin = {u32(pos.x), u32(pos.y), 0},
					aspect = .All,
				},
				raw_data(image_pixels),
				uint(len(image_pixels)),
				&{bytesPerRow = u32(size.x * 4), rowsPerImage = u32(size.y)},
				&{u32(size.x), u32(size.y), 1},
			)
		}

		// View, sampler and bind group for the shader
		out.atlas_view = wgpu.TextureCreateView(out.atlas_texture)
		out.sampler = wgpu.DeviceCreateSampler(
			out.device,
			&{
				addressModeU = .ClampToEdge,
				addressModeV = .ClampToEdge,
				addressModeW = .ClampToEdge,
				magFilter = .Linear,
				minFilter = .Linear,
				mipmapFilter = .Nearest,
				lodMaxClamp = 32,
				maxAnisotropy = 1,
			},
		)

		entries := [?]wgpu.BindGroupEntry {
			{binding = 0, textureView = out.atlas_view},
			{binding = 1, sampler = out.sampler},
		}
		out.atlas_group = wgpu.DeviceCreateBindGroup(
			out.device,
			&{
				label = "atlas",
				layout = atlas_layout,
				entryCount = len(entries),
				entries = &entries[0],
			},
		)
	}

	// Ground: grid textures (zero-initialised), uniform buffer, bind group, pipeline
	{
		for format, grid in GROUND_GRID_FORMATS {
			texture := wgpu.DeviceCreateTexture(
				out.device,
				&{
					label = "ground grid",
					usage = {.TextureBinding, .CopyDst},
					dimension = ._2D,
					size = {RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT, 1},
					format = format.format,
					mipLevelCount = 1,
					sampleCount = 1,
				},
			)
			out.ground_grids[grid] = {texture, wgpu.TextureCreateView(texture)}
		}
		{
			texture := wgpu.DeviceCreateTexture(
				out.device,
				&{
					label = "ground category looks",
					usage = {.TextureBinding, .CopyDst},
					dimension = ._2D,
					size = {RENDER_GROUND_CATEGORIES, 2, 1},
					format = .RGBA8Unorm,
					mipLevelCount = 1,
					sampleCount = 1,
				},
			)
			out.ground_category_looks = {texture, wgpu.TextureCreateView(texture)}
		}
		out.ground_uniforms = wgpu.DeviceCreateBuffer(
			out.device,
			&{
				label = "ground uniforms",
				usage = {.Uniform, .CopyDst},
				size = size_of(Ground_Uniform),
			},
		)

		// Group 1. Binding 0: uniforms, 1: sampler, 2 + grid: grid texture, then the category looks,
		// the strokes target and the sprites target.
		// The group is created with the strokes target, on resize
		layout_entries: [GROUND_BINDINGS]wgpu.BindGroupLayoutEntry
		layout_entries[0] = {
			binding = 0,
			visibility = {.Fragment},
			buffer = {type = .Uniform, minBindingSize = size_of(Ground_Uniform)},
		}
		layout_entries[1] = {
			binding = 1,
			visibility = {.Fragment},
			sampler = {type = .Filtering},
		}
		for binding in 2 ..< u32(GROUND_BINDINGS) {
			layout_entries[binding] = {
				binding = binding,
				visibility = {.Fragment},
				texture = {sampleType = .Float, viewDimension = ._2D},
			}
		}
		out.ground_layout = wgpu.DeviceCreateBindGroupLayout(
			out.device,
			&{label = "ground", entryCount = len(layout_entries), entries = &layout_entries[0]},
		)

		module := wgpu.DeviceCreateShaderModule(
			out.device,
			&{
				nextInChain = &wgpu.ShaderSourceWGSL {
					sType = .ShaderSourceWGSL,
					code = GROUND_SHADER,
				},
				label = "ground",
			},
		)
		defer wgpu.ShaderModuleRelease(module)

		group_layouts := [?]wgpu.BindGroupLayout{out.view_layout, out.ground_layout}
		layout := wgpu.DeviceCreatePipelineLayout(
			out.device,
			&{
				label = "ground",
				bindGroupLayoutCount = len(group_layouts),
				bindGroupLayouts = &group_layouts[0],
			},
		)
		defer wgpu.PipelineLayoutRelease(layout)

		out.ground_pipeline = wgpu.DeviceCreateRenderPipeline(
			out.device,
			&{
				label = "ground",
				layout = layout,
				vertex = {module = module, entryPoint = "vs_main"},
				primitive = {topology = .TriangleList},
				multisample = {count = 1, mask = ~u32(0)},
				fragment = &wgpu.FragmentState {
					module = module,
					entryPoint = "fs_main",
					targetCount = 1,
					targets = &wgpu.ColorTargetState {
						format = out.format.view,
						writeMask = wgpu.ColorWriteMaskFlags_All,
					},
				},
			},
		)
	}

	// Strokes: one segment buffer and one pipeline per stroke. Pipelines differ in the channel written
	{
		module := wgpu.DeviceCreateShaderModule(
			out.device,
			&{
				nextInChain = &wgpu.ShaderSourceWGSL {
					sType = .ShaderSourceWGSL,
					code = STROKE_SHADER,
				},
				label = "stroke",
			},
		)
		defer wgpu.ShaderModuleRelease(module)

		layout := wgpu.DeviceCreatePipelineLayout(
			out.device,
			&{label = "stroke", bindGroupLayoutCount = 1, bindGroupLayouts = &out.view_layout},
		)
		defer wgpu.PipelineLayoutRelease(layout)

		attributes := [?]wgpu.VertexAttribute {
			{format = .Float32x2, offset = u64(offset_of(Stroke_Segment, a)), shaderLocation = 0},
			{format = .Float32x2, offset = u64(offset_of(Stroke_Segment, b)), shaderLocation = 1},
		}
		// Keeps the smallest distance written to a pixel
		nearest := wgpu.BlendState {
			color = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
			alpha = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
		}
		for stroke in 0 ..< RENDER_GROUND_STROKES {
			out.stroke_buffers[stroke] = wgpu.DeviceCreateBuffer(
				out.device,
				&{
					label = "stroke segments",
					usage = {.Vertex, .CopyDst},
					size = RENDER_GROUND_STROKE_SEGMENTS_MAX * size_of(Stroke_Segment),
				},
			)
			out.stroke_pipelines[stroke] = wgpu.DeviceCreateRenderPipeline(
				out.device,
				&{
					label = "stroke",
					layout = layout,
					vertex = {
						module = module,
						entryPoint = "vs_main",
						bufferCount = 1,
						buffers = &wgpu.VertexBufferLayout {
							stepMode = .Instance,
							arrayStride = size_of(Stroke_Segment),
							attributeCount = len(attributes),
							attributes = &attributes[0],
						},
					},
					primitive = {topology = .TriangleList},
					multisample = {count = 1, mask = ~u32(0)},
					fragment = &wgpu.FragmentState {
						module = module,
						entryPoint = "fs_main",
						targetCount = 1,
						targets = &wgpu.ColorTargetState {
							format = STROKES_TARGET_FORMAT,
							blend = &nearest,
							// Channel = stroke index
							writeMask = {wgpu.ColorWriteMask(stroke)},
						},
					},
				},
			)
		}
	}

	out.flags += {.Ready}
	return
}

renderer_deinit :: proc(rend: Renderer) {
	for pipeline in rend.stroke_pipelines do if pipeline != nil do wgpu.RenderPipelineRelease(pipeline)
	for buffer in rend.stroke_buffers do if buffer != nil do wgpu.BufferRelease(buffer)
	for target in ([?]Texture{rend.strokes_target, rend.sprites_target}) {
		if target.view != nil do wgpu.TextureViewRelease(target.view)
		if target.texture != nil do wgpu.TextureRelease(target.texture)
	}

	if rend.ground_pipeline != nil do wgpu.RenderPipelineRelease(rend.ground_pipeline)
	if rend.ground_group != nil do wgpu.BindGroupRelease(rend.ground_group)
	if rend.ground_layout != nil do wgpu.BindGroupLayoutRelease(rend.ground_layout)
	if rend.ground_uniforms != nil do wgpu.BufferRelease(rend.ground_uniforms)
	for grid in rend.ground_grids {
		if grid.view != nil do wgpu.TextureViewRelease(grid.view)
		if grid.texture != nil do wgpu.TextureRelease(grid.texture)
	}
	if rend.ground_category_looks.view != nil {
		wgpu.TextureViewRelease(rend.ground_category_looks.view)
	}
	if rend.ground_category_looks.texture != nil {
		wgpu.TextureRelease(rend.ground_category_looks.texture)
	}

	if rend.atlas_group != nil do wgpu.BindGroupRelease(rend.atlas_group)
	if rend.sampler != nil do wgpu.SamplerRelease(rend.sampler)
	if rend.atlas_view != nil do wgpu.TextureViewRelease(rend.atlas_view)
	if rend.atlas_texture != nil do wgpu.TextureRelease(rend.atlas_texture)

	for group in rend.view_groups do if group != nil do wgpu.BindGroupRelease(group)
	for buffer in rend.view_buffers do if buffer != nil do wgpu.BufferRelease(buffer)
	if rend.view_layout != nil do wgpu.BindGroupLayoutRelease(rend.view_layout)

	if rend.quad_pipeline != nil do wgpu.RenderPipelineRelease(rend.quad_pipeline)
	if rend.quad_buffer != nil do wgpu.BufferRelease(rend.quad_buffer)

	if rend.queue != nil do wgpu.QueueRelease(rend.queue)
	if rend.device != nil do wgpu.DeviceRelease(rend.device)
	if rend.adapter != nil do wgpu.AdapterRelease(rend.adapter)
	if rend.surface != nil do wgpu.SurfaceRelease(rend.surface)
	if rend.instance != nil do wgpu.InstanceRelease(rend.instance)
}

renderer_draw :: proc(
	rend: ^Renderer,
	// World-space view for this frame
	view: Render_View,
	quads: []Render_Quad,
	passes: []Render_Pass,
) -> (
	drawn: bool,
) {
	// Abort if not ready
	if !(.Ready in rend.flags) do return

	// Skip if minimised
	if .MINIMIZED in sdl.GetWindowFlags(rend.window) do return

	// Handle window resizing
	{
		size: [2]i32
		if !sdl.GetWindowSizeInPixels(rend.window, &size.x, &size.y) {
			fmt.eprintln("Failed to get window size:", sdl.GetError())
			return
		}

		if size.x == 0 || size.y == 0 do return

		if rend.window_size != size {
			rend.window_size = size

			wgpu.SurfaceConfigure(
				rend.surface,
				&{
					device = rend.device,
					format = rend.format.surface,
					viewFormatCount = 1,
					viewFormats = &rend.format.view,
					usage = {.RenderAttachment},
					width = u32(size.x),
					height = u32(size.y),
					presentMode = .Fifo,
				},
			)

			// Strokes and sprites targets, and the ground group that binds them
			{
				if rend.ground_group != nil do wgpu.BindGroupRelease(rend.ground_group)
				for target in ([?]Texture{rend.strokes_target, rend.sprites_target}) {
					if target.view != nil do wgpu.TextureViewRelease(target.view)
					if target.texture != nil do wgpu.TextureRelease(target.texture)
				}

				// Sprites are drawn by the quad pipeline, so in the surface's view format
				formats := [?]wgpu.TextureFormat{STROKES_TARGET_FORMAT, rend.format.view}
				targets: [2]Texture
				for format, i in formats {
					texture := wgpu.DeviceCreateTexture(
						rend.device,
						&{
							label = "ground target",
							usage = {.RenderAttachment, .TextureBinding},
							dimension = ._2D,
							size = {u32(size.x), u32(size.y), 1},
							format = format,
							mipLevelCount = 1,
							sampleCount = 1,
						},
					)
					targets[i] = {texture, wgpu.TextureCreateView(texture)}
				}
				rend.strokes_target = targets[0]
				rend.sprites_target = targets[1]

				entries: [GROUND_BINDINGS]wgpu.BindGroupEntry
				entries[0] = {
					binding = 0,
					buffer  = rend.ground_uniforms,
					size    = size_of(Ground_Uniform),
				}
				entries[1] = {
					binding = 1,
					sampler = rend.sampler,
				}
				for grid, kind in rend.ground_grids {
					entries[2 + int(kind)] = {
						binding     = 2 + u32(kind),
						textureView = grid.view,
					}
				}
				entries[GROUND_BINDING_CATEGORY_LOOKS] = {
					binding     = GROUND_BINDING_CATEGORY_LOOKS,
					textureView = rend.ground_category_looks.view,
				}
				entries[GROUND_BINDING_STROKES_TARGET] = {
					binding     = GROUND_BINDING_STROKES_TARGET,
					textureView = rend.strokes_target.view,
				}
				entries[GROUND_BINDING_SPRITES_TARGET] = {
					binding     = GROUND_BINDING_SPRITES_TARGET,
					textureView = rend.sprites_target.view,
				}
				rend.ground_group = wgpu.DeviceCreateBindGroup(
					rend.device,
					&{
						label = "ground",
						layout = rend.ground_layout,
						entryCount = len(entries),
						entries = &entries[0],
					},
				)
			}

			fmt.println("Surface:", rend.format, size)
			return
		}
	}

	surface_texture := wgpu.SurfaceGetCurrentTexture(rend.surface)

	// Process texture acquisition with early exits
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		rend.window_size = {}
		return
	case .Occluded:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		return
	case .Error:
		fmt.eprint("wgpu surface texture acquisition failed")
		return
	}

	surface_view := wgpu.TextureCreateView(
		surface_texture.texture,
		&{format = rend.format.view, mipLevelCount = 1, arrayLayerCount = 1},
	)

	// Send data to gpu
	// Views. Screen: 1 unit = 1 physical pixel, origin top-left
	{
		size := [2]f32{f32(rend.window_size.x), f32(rend.window_size.y)}
		// 0 on failure
		density := sdl.GetWindowPixelDensity(rend.window)
		if density <= 0 do density = 1
		views := [Render_Space]View_Uniform {
			.Screen = {size = size, center = size / 2, zoom = 1, pixel_density = density},
			.World = {
				size = size,
				center = view.center,
				zoom = view.zoom,
				pixel_density = density,
			},
		}
		for &uniform, space in views {
			wgpu.QueueWriteBuffer(
				rend.queue,
				rend.view_buffers[space],
				0,
				&uniform,
				size_of(uniform),
			)
		}
	}

	// Quads
	if len(quads) > 0 {
		quad_count := min(RENDER_QUADS_MAX, len(quads))
		wgpu.QueueWriteBuffer(
			rend.queue,
			rend.quad_buffer,
			0,
			raw_data(quads),
			uint(quad_count * size_of(Render_Quad)),
		)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(rend.device)

	// Strokes pass: segment distances into the strokes target, for the ground shader
	{
		pass := wgpu.CommandEncoderBeginRenderPass(
			encoder,
			&{
				colorAttachmentCount = 1,
				colorAttachments = &wgpu.RenderPassColorAttachment {
					view = rend.strokes_target.view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {STROKE_FAR, STROKE_FAR, STROKE_FAR, STROKE_FAR},
				},
			},
		)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[.World])
		for count, stroke in rend.stroke_counts {
			if count == 0 do continue
			wgpu.RenderPassEncoderSetPipeline(pass, rend.stroke_pipelines[stroke])
			wgpu.RenderPassEncoderSetVertexBuffer(
				pass,
				0,
				rend.stroke_buffers[stroke],
				0,
				u64(count) * size_of(Stroke_Segment),
			)
			wgpu.RenderPassEncoderDraw(pass, 6, count, 0, 0)
		}
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	// Sprites pass: quad passes with target = .Ground, for the ground shader
	{
		pass := wgpu.CommandEncoderBeginRenderPass(
			encoder,
			&{
				colorAttachmentCount = 1,
				colorAttachments = &wgpu.RenderPassColorAttachment {
					view = rend.sprites_target.view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {0, 0, 0, 0},
				},
			},
		)
		wgpu.RenderPassEncoderSetPipeline(pass, rend.quad_pipeline)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, rend.quad_buffer, 0, wgpu.WHOLE_SIZE)
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, rend.atlas_group)
		for command in passes {
			c, is_quads := command.(Render_Quad_Pass)
			if !is_quads || c.target != .Ground do continue
			wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[c.space])
			wgpu.RenderPassEncoderDraw(pass, 4, u32(c.len), 0, u32(c.begin))
		}
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	{
		// Clear pass
		pass := wgpu.CommandEncoderBeginRenderPass(
			encoder,
			&{
				colorAttachmentCount = 1,
				colorAttachments = &wgpu.RenderPassColorAttachment {
					view = surface_view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {0.1, 0.2, 0.3, 1},
				},
			},
		)

		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, rend.quad_buffer, 0, wgpu.WHOLE_SIZE)

		for command in passes {
			switch c in command {
			case Render_Quad_Pass:
				// Drawn in the sprites pass
				if c.target == .Ground do continue
				wgpu.RenderPassEncoderSetPipeline(pass, rend.quad_pipeline)
				wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[c.space])
				wgpu.RenderPassEncoderSetBindGroup(pass, 1, rend.atlas_group)
				wgpu.RenderPassEncoderDraw(pass, 4, u32(c.len), 0, u32(c.begin))

			case Render_Ground_Pass:
				// Queue writes are applied at submit, before any draw: only the last ground pass
				// of a frame takes effect
				uniform := Ground_Uniform {
					base_color        = c.ground.base.color,
					stain_amount      = c.ground.base.stain_amount,
					base_stain        = c.ground.base.stain,
					category_jitter   = c.ground.category.jitter,
					category_pattern  = c.ground.category.pattern_color,
					category_strength = c.ground.category.strength,
					divide_shallow    = c.ground.divide.shallow,
					divide_tint       = c.ground.divide.tint,
					divide_deep       = c.ground.divide.deep,
					divide_wobble     = c.ground.divide.wobble,
					divide_line_color = c.ground.divide.line_color,
					divide_line_width = c.ground.divide.line_width,
					value_low         = c.ground.value.low,
					value_strength    = c.ground.value.strength,
					value_high        = c.ground.value.high,
					value_clip        = i32(c.ground.value.clip),
					grid              = {RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT},
					divide_depth_from = c.ground.divide.depth_from,
					divide_depth_full = c.ground.divide.depth_full,
				}
				for stroke, i in c.ground.strokes {
					switch look in stroke {
					case Render_Ground_Stroke_Line:
						uniform.strokes[i] = {
							kind     = .Line,
							color    = look.color,
							width    = look.width,
							fill     = look.wash_color,
							strength = look.wash_strength,
							wander   = look.wander,
							clip     = i32(look.clip),
						}
					case Render_Ground_Stroke_Double:
						uniform.strokes[i] = {
							kind       = .Double,
							color      = look.edge_color,
							width      = look.width,
							fill       = look.fill_color,
							strength   = look.fill_strength,
							edge_width = look.edge_width,
							clip       = i32(look.clip),
						}
					}
				}
				wgpu.QueueWriteBuffer(
					rend.queue,
					rend.ground_uniforms,
					0,
					&uniform,
					size_of(uniform),
				)
				wgpu.RenderPassEncoderSetPipeline(pass, rend.ground_pipeline)
				wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[.World])
				wgpu.RenderPassEncoderSetBindGroup(pass, 1, rend.ground_group)
				wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
			}
		}

		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	commands := wgpu.CommandEncoderFinish(encoder)
	wgpu.QueueSubmit(rend.queue, {commands})
	wgpu.SurfacePresent(rend.surface)

	wgpu.CommandBufferRelease(commands)
	wgpu.CommandEncoderRelease(encoder)
	wgpu.TextureViewRelease(surface_view)
	wgpu.TextureRelease(surface_texture.texture)
	return true
}

// Overwrites the Value grid: input of Render_Ground.value
renderer_ground_value_write :: proc(
	rend: ^Renderer,
	// 1 byte per cell, read as 0..1. Row-major from the top-left
	cells: []u8,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Value, raw_data(cells), len(cells))
}

// Overwrites the Divide grid: input of Render_Ground.divide
renderer_ground_divide_write :: proc(
	rend: ^Renderer,
	// Signed distance per cell, in cells. > 0 land side, < 0 water side. Row-major from the top-left
	distances: []f32,
) {
	if !(.Ready in rend.flags) do return
	// Stored as 16-bit floats
	halves := make([]f16, len(distances), context.temp_allocator)
	for distance, i in distances do halves[i] = f16(distance)
	ground_grid_write(rend, .Divide, raw_data(halves), len(halves))
}

// Overwrites the Category grid: input of Render_Ground.category
renderer_ground_category_write :: proc(
	rend: ^Renderer,
	// Per cell: category, strength (read as 0..1). Row-major from the top-left
	cells: [][2]u8,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Category, raw_data(cells), len(cells))
}

// Overwrites the look of every category: looks[i] for category i, none past len(looks)
renderer_ground_category_looks_write :: proc(rend: ^Renderer, looks: []Render_Ground_Category_Look) {
	if !(.Ready in rend.flags) do return
	assert(len(looks) <= RENDER_GROUND_CATEGORIES)

	// 0..1 to 0..255, rounded
	to_u8 :: proc(value: f32) -> u8 {
		return u8(clamp(value, 0, 1) * 255 + 0.5)
	}
	texels: [2][RENDER_GROUND_CATEGORIES][4]u8
	for look, i in looks {
		texels[0][i] = {to_u8(look.color.r), to_u8(look.color.g), to_u8(look.color.b), to_u8(look.wash)}
		texels[1][i] = {u8(look.pattern), to_u8(look.pattern_ink), 0, 0}
	}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = rend.ground_category_looks.texture, aspect = .All},
		&texels,
		size_of(texels),
		&{bytesPerRow = RENDER_GROUND_CATEGORIES * 4, rowsPerImage = 2},
		&{RENDER_GROUND_CATEGORIES, 2, 1},
	)
}

// Overwrites the Taper grid: thins strokes of kind Render_Ground_Stroke_Line
renderer_ground_taper_write :: proc(
	rend: ^Renderer,
	// 1 byte per cell, read as 0..1. Row-major from the top-left
	cells: []u8,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Taper, raw_data(cells), len(cells))
}

// Overwrites the line geometry of a stroke: input of Render_Ground.strokes[stroke].
// Segments past RENDER_GROUND_STROKE_SEGMENTS_MAX are dropped
renderer_ground_stroke_write :: proc(
	rend: ^Renderer,
	stroke: int,
	// Points in cells
	lines: Polylines,
) {
	if !(.Ready in rend.flags) do return
	assert(stroke >= 0 && stroke < RENDER_GROUND_STROKES)

	segments := make(
		[dynamic]Stroke_Segment,
		0,
		RENDER_GROUND_STROKE_SEGMENTS_MAX,
		context.temp_allocator,
	)
	fill: for run in lines.runs {
		points := lines.points[run.begin:][:run.len]
		count := run.closed ? run.len : run.len - 1
		for i in 0 ..< count {
			if len(segments) == RENDER_GROUND_STROKE_SEGMENTS_MAX do break fill
			append(&segments, Stroke_Segment{points[i], points[(i + 1) % run.len]})
		}
	}

	rend.stroke_counts[stroke] = u32(len(segments))
	if len(segments) == 0 do return
	wgpu.QueueWriteBuffer(
		rend.queue,
		rend.stroke_buffers[stroke],
		0,
		raw_data(segments),
		uint(len(segments) * size_of(Stroke_Segment)),
	)
}

@(private = "file")
ground_grid_write :: proc(rend: ^Renderer, grid: Ground_Grid, texels: rawptr, count: int) {
	assert(count == RENDER_GROUND_WIDTH * RENDER_GROUND_HEIGHT)
	texel_size := GROUND_GRID_FORMATS[grid].texel_size
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = rend.ground_grids[grid].texture, aspect = .All},
		texels,
		uint(count * texel_size),
		&{
			bytesPerRow = u32(RENDER_GROUND_WIDTH * texel_size),
			rowsPerImage = RENDER_GROUND_HEIGHT,
		},
		&{RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT, 1},
	)
}

// Coordinate space of a quad pass
Render_Space :: enum {
	// Physical pixels, origin at the window top-left
	Screen,
	// World units, mapped to the window by the frame's Render_View
	World,
}

// World to window: pixel = (p - center) * zoom + window_size / 2
Render_View :: struct {
	// World position at the window centre
	center: [2]f32,
	// Physical pixels per world unit
	zoom:   f32,
}

// rect, radii, thickness, softness: units of the pass's space
Render_Quad :: struct {
	// Unrotated rectangle
	rect:      Extents,
	// Clip rectangle, screen space. Zero = none
	clip:      Extents,
	// Per corner, 4 colours. TL clockwise winding order
	colors:    [4][4]u8,
	// Source area of texture to process
	source:    Extents,
	// Corner radii (uniform)
	radii:     f32,
	// Border thickness (uniform)
	// thickness = 0 gives fill
	thickness: f32,
	// Border 'softness'
	softness:  f32,
	// Direction of the rect's local x axis, any length. Zero = unrotated. Pivot: rect centre
	axis:      [2]f32,
}

Render_Quad_Pass :: struct {
	space:  Render_Space,
	target: Render_Quad_Target,
	begin:  int,
	len:    int,
}

// Where a quad pass is drawn
Render_Quad_Target :: enum {
	// The window, over the passes before it
	Frame,
	// The ground's sprite layer: composited by the ground pass over the divide's line, under the
	// value layer. Such passes are drawn in order among themselves, whatever their place in the list
	Ground,
}

// Ground pass parameters. The ground shader outputs one colour per window pixel, computed from the
// grids (RENDER_GROUND_WIDTH x RENDER_GROUND_HEIGHT cells) and these layers.
// Layers are composited in field order. Colours: straight RGB, 0..1. A zeroed layer has no effect
Render_Ground :: struct {
	base:     Render_Ground_Base,
	category: Render_Ground_Category,
	divide:   Render_Ground_Divide,
	// Drawn in index order, under the divide's line. Over that line: the quads of passes with
	// target = .Ground
	strokes:  [RENDER_GROUND_STROKES]Render_Ground_Stroke,
	value:    Render_Ground_Value,
}

// Base layer: colour with noise stains. Outside the grid: color * 0.72
Render_Ground_Base :: struct {
	color:        [3]f32,
	// Stain colour. Stain pattern: fbm noise in world space
	stain:        [3]f32,
	// Mix toward stain at full noise, 0..1
	stain_amount: f32,
}

// Category layer. Category grid: (category, strength) per cell. Each category has a look, written
// with renderer_ground_category_looks_write. The looks of the 4 cells around a pixel are blended
Render_Ground_Category :: struct {
	// Colour of the looks' patterns
	pattern_color: [3]f32,
	// Scales washes and patterns, 0..1. 0 = layer off
	strength:      f32,
	// Peak-to-peak noise displacement of the lookup per axis, in cells
	jitter:        f32,
}

// Look of one category
Render_Ground_Category_Look :: struct {
	// Multiplies the colour by mix(1, color, wash * cell strength)
	color:       [3]f32,
	// 0..1
	wash:        f32,
	pattern:     Render_Ground_Pattern,
	// Pattern opacity, 0..1
	pattern_ink: f32,
}

Render_Ground_Pattern :: enum u8 {
	None,
	// Dots about 7 logical pixels apart at any zoom. Share of dots drawn = cell strength
	Stipple,
}

// Divide layer. d = Divide grid (bilinear) + noise: signed distance in cells, > 0 land, < 0 water.
// On the water side it shows the tinted base, covering the category layer.
// Draws a line at d = 0, and defines the sides other layers clip to.
// The line is drawn over the layers between divide and value
Render_Ground_Divide :: struct {
	// Water side: base multiplied by mix(shallow, deep, t), t = 0 at depth_from cells from the line,
	// 1 at depth_full
	shallow:    [3]f32,
	deep:       [3]f32,
	depth_from: f32,
	depth_full: f32,
	// Blend factor of the multiply at the line, 0..1. Falls to 0.65 of it away from the line
	tint:       f32,
	line_color: [3]f32,
	// Logical pixels. Varies along the line by a factor 0.8..1.2
	line_width: f32,
	// Peak-to-peak amplitude of the noise added to d, in cells
	wobble:     f32,
}

// Stroke layer: draws along the lines written with renderer_ground_stroke_write.
// d = distance to the stroke's nearest segment. Widths: logical pixels. nil = off
Render_Ground_Stroke :: union {
	Render_Ground_Stroke_Line,
	Render_Ground_Stroke_Double,
}

// One line, with a wash either side of it
Render_Ground_Stroke_Line :: struct {
	color:         [3]f32,
	// Scaled by 1..0.4 as the Taper grid goes 0.2..0.8. Capped at 1/3 cell
	width:         f32,
	// Multiplies the colour by wash_color, by wash_strength at d = 0 falling to 0 at 1.2 cells
	wash_color:    [3]f32,
	wash_strength: f32,
	// Peak-to-peak noise displacement of the line per axis, in cells
	wander:        f32,
	clip:          Render_Ground_Clip,
}

// Two edge lines with a fill between. Closes to a single line as width goes from 6 to 3
Render_Ground_Stroke_Double :: struct {
	// Outer width, edges included. Capped at 1/2 cell
	width:         f32,
	edge_color:    [3]f32,
	// Varies along the stroke by a factor 0.6..1.4
	edge_width:    f32,
	// Mixed toward fill_color * base colour by fill_strength
	fill_color:    [3]f32,
	fill_strength: f32,
	clip:          Render_Ground_Clip,
}

// Side of the divide a layer is restricted to
Render_Ground_Clip :: enum i32 {
	None,
	Land,
	Water,
}

// Value layer: multiplies the colour by mix(low, high, v). v: Value grid, bilinear
Render_Ground_Value :: struct {
	low:      [3]f32,
	high:     [3]f32,
	// Blend factor of the multiply, 0..1. 0 = layer off
	strength: f32,
	clip:     Render_Ground_Clip,
}

// Full-window draw of the ground, positioned by the frame's Render_View
Render_Ground_Pass :: struct {
	ground: Render_Ground,
}

// Executed in order
Render_Pass :: union {
	Render_Quad_Pass,
	Render_Ground_Pass,
}
