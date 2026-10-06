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


// Budgets
RENDER_IMAGES_MAX :: 4000
// Largest texture every WebGPU device supports
RENDER_ATLAS_SIZE_MAX :: 8192

RENDER_QUADS_MAX :: 32000
RENDER_PASS_MAX :: 256

// Ground size in cells. 1 world unit = 1 cell
RENDER_GROUND_WIDTH :: 1024
RENDER_GROUND_HEIGHT :: 1024


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
	ground_grids:    [Render_Ground_Grid]Texture,
	ground_group:    wgpu.BindGroup,
}

@(private = "file")
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

@(private = "file")
Ground_Grid_Format :: struct {
	format:     wgpu.TextureFormat,
	// Bytes per texel
	texel_size: int,
}

@(private = "file", rodata)
GROUND_GRID_FORMATS := [Render_Ground_Grid]Ground_Grid_Format {
	.Value = {.R8Unorm, 1},
}

// Must match struct Ground in ground.wgsl.
// WGSL vec3f: align 16, size 12. Each [3]f32 is followed by one f32 (scalar or padding)
@(private = "file")
Ground_Uniform :: struct {
	base_color:     [3]f32,
	stain_amount:   f32,
	base_stain:     [3]f32,
	value_strength: f32,
	value_low:      [3]f32,
	_:              f32,
	value_high:     [3]f32,
	_:              f32,
	// Grid size in cells
	grid:           [2]f32,
	_:              [2]f32,
}

// Must match struct View in view.wgsl
@(private = "file")
View_Uniform :: struct {
	size:   [2]f32,
	center: [2]f32,
	zoom:   f32,
	_:      f32,
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
		out.ground_uniforms = wgpu.DeviceCreateBuffer(
			out.device,
			&{
				label = "ground uniforms",
				usage = {.Uniform, .CopyDst},
				size = size_of(Ground_Uniform),
			},
		)

		// Group 1. Binding 0: uniforms, 1: sampler, 2 + grid: grid texture
		layout_entries: [2 + len(Render_Ground_Grid)]wgpu.BindGroupLayoutEntry
		group_entries: [2 + len(Render_Ground_Grid)]wgpu.BindGroupEntry
		layout_entries[0] = {
			binding = 0,
			visibility = {.Fragment},
			buffer = {type = .Uniform, minBindingSize = size_of(Ground_Uniform)},
		}
		group_entries[0] = {
			binding = 0,
			buffer  = out.ground_uniforms,
			size    = size_of(Ground_Uniform),
		}
		layout_entries[1] = {
			binding = 1,
			visibility = {.Fragment},
			sampler = {type = .Filtering},
		}
		group_entries[1] = {
			binding = 1,
			sampler = out.sampler,
		}
		for texture, grid in out.ground_grids {
			binding := 2 + u32(grid)
			layout_entries[binding] = {
				binding = binding,
				visibility = {.Fragment},
				texture = {sampleType = .Float, viewDimension = ._2D},
			}
			group_entries[binding] = {
				binding     = binding,
				textureView = texture.view,
			}
		}
		group_layout := wgpu.DeviceCreateBindGroupLayout(
			out.device,
			&{label = "ground", entryCount = len(layout_entries), entries = &layout_entries[0]},
		)
		defer wgpu.BindGroupLayoutRelease(group_layout)
		out.ground_group = wgpu.DeviceCreateBindGroup(
			out.device,
			&{
				label = "ground",
				layout = group_layout,
				entryCount = len(group_entries),
				entries = &group_entries[0],
			},
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

		group_layouts := [?]wgpu.BindGroupLayout{out.view_layout, group_layout}
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

	out.flags += {.Ready}
	return
}

renderer_deinit :: proc(rend: Renderer) {
	if rend.ground_pipeline != nil do wgpu.RenderPipelineRelease(rend.ground_pipeline)
	if rend.ground_group != nil do wgpu.BindGroupRelease(rend.ground_group)
	if rend.ground_uniforms != nil do wgpu.BufferRelease(rend.ground_uniforms)
	for grid in rend.ground_grids {
		if grid.view != nil do wgpu.TextureViewRelease(grid.view)
		if grid.texture != nil do wgpu.TextureRelease(grid.texture)
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
		views := [Render_Space]View_Uniform {
			.Screen = {size = size, center = size / 2, zoom = 1},
			.World = {size = size, center = view.center, zoom = view.zoom},
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
				wgpu.RenderPassEncoderSetPipeline(pass, rend.quad_pipeline)
				wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[c.space])
				wgpu.RenderPassEncoderSetBindGroup(pass, 1, rend.atlas_group)
				wgpu.RenderPassEncoderDraw(pass, 4, u32(c.len), 0, u32(c.begin))

			case Render_Ground_Pass:
				// Queue writes are applied at submit, before any draw: only the last ground pass
				// of a frame takes effect
				uniform := Ground_Uniform {
					base_color     = c.ground.base.color,
					stain_amount   = c.ground.base.stain_amount,
					base_stain     = c.ground.base.stain,
					value_strength = c.ground.value.strength,
					value_low      = c.ground.value.low,
					value_high     = c.ground.value.high,
					grid           = {RENDER_GROUND_WIDTH, RENDER_GROUND_HEIGHT},
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

// Overwrites all cells of a grid
renderer_ground_write :: proc(
	rend: ^Renderer,
	grid: Render_Ground_Grid,
	// Row-major from the top-left, no row padding. Texel format: see Render_Ground_Grid
	cells: []byte,
) {
	if !(.Ready in rend.flags) do return
	texel_size := GROUND_GRID_FORMATS[grid].texel_size
	assert(len(cells) == RENDER_GROUND_WIDTH * RENDER_GROUND_HEIGHT * texel_size)

	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = rend.ground_grids[grid].texture, aspect = .All},
		raw_data(cells),
		uint(len(cells)),
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
	space: Render_Space,
	begin: int,
	len:   int,
}

// Ground pass parameters. The ground shader outputs one colour per window pixel, computed from the
// grids (RENDER_GROUND_WIDTH x RENDER_GROUND_HEIGHT cells) and these layers.
// Layers are composited in field order. Colours: straight RGB, 0..1
Render_Ground :: struct {
	base:  Render_Ground_Base,
	value: Render_Ground_Value,
}

// Base layer: colour with noise stains. Outside the grid: color * 0.72
Render_Ground_Base :: struct {
	color:        [3]f32,
	// Stain colour. Stain pattern: fbm noise in world space
	stain:        [3]f32,
	// Mix toward stain at full noise, 0..1
	stain_amount: f32,
}

// Value layer: multiplies the colour by mix(low, high, v). v: Value grid, bilinear
Render_Ground_Value :: struct {
	low:      [3]f32,
	high:     [3]f32,
	// Blend factor of the multiply, 0..1. 0 = layer off
	strength: f32,
}

// Per-cell textures read by the ground shader. Written with renderer_ground_write
Render_Ground_Grid :: enum {
	// 1 byte per cell, read as 0..1. Input of Render_Ground.value
	Value,
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
