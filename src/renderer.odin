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

// Budgets
RENDER_IMAGES_MAX :: 4000
// Largest texture every WebGPU device supports
RENDER_ATLAS_SIZE_MAX :: 8192
// Mip levels of the atlas: level n is the images at 1 / 2^n size. Quads drawn smaller than their
// source read the level that matches
RENDER_ATLAS_MIPS :: 5
// Atlas images must sit on multiples of this, and at least this far apart: a texel of the
// smallest level then never covers two images
RENDER_ATLAS_SPACING :: 1 << (RENDER_ATLAS_MIPS - 1)

// Per space
RENDER_QUADS_MAX :: 1 << 16

Renderer_Flag :: enum {
	Ready,
}

Renderer :: struct {
	flags:         bit_set[Renderer_Flag],
	window:        ^sdl.Window,
	instance:      wgpu.Instance,
	adapter:       wgpu.Adapter,
	surface:       wgpu.Surface,
	device:        wgpu.Device,
	queue:         wgpu.Queue,
	format:        Surface_Format,
	// Cached window size
	window_size:   [2]i32,
	// Quads. The buffer has RENDER_QUADS_MAX slots per space, in Render_Space order
	quad_pipeline: wgpu.RenderPipeline,
	quad_buffer:   wgpu.Buffer,
	// View uniforms per space. Group 0 of every pipeline
	view_layout:   wgpu.BindGroupLayout,
	view_buffers:  [Render_Space]wgpu.Buffer,
	view_groups:   [Render_Space]wgpu.BindGroup,
	// Linear filter, also between mip levels, clamp to edge. Used by the atlas and the terrain's grids
	sampler:       wgpu.Sampler,
	// Images
	atlas_texture: wgpu.Texture,
	atlas_view:    wgpu.TextureView,
	atlas_group:   wgpu.BindGroup,
}

@(private = "file")
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

// Must match struct View in view.wgsl
@(private = "file")
View_Uniform :: struct {
	size:          [2]f32,
	center:        [2]f32,
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
			size = u64(size_of(Render_Quad) * RENDER_QUADS_MAX * len(Render_Space)),
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
				mipLevelCount = RENDER_ATLAS_MIPS,
				sampleCount = 1,
			},
		)

		// Upload each image at its source position, then its halvings to the smaller levels
		for extent, i in extents {
			image_pixels := pixels[i]
			pos := [2]int{int(extent.x_min), int(extent.y_min)}
			size := [2]int{int(extent.x_max) - pos.x, int(extent.y_max) - pos.y}
			if size.x <= 0 || size.y <= 0 do continue

			assert(pos.x >= 0 && pos.y >= 0)
			assert(pos.x + size.x <= atlas_size.x && pos.y + size.y <= atlas_size.y)
			assert(len(image_pixels) == size.x * size.y * 4)
			assert(pos.x % RENDER_ATLAS_SPACING == 0 && pos.y % RENDER_ATLAS_SPACING == 0)

			for level in 0 ..< RENDER_ATLAS_MIPS {
				if level > 0 {
					halved := make(
						[]u8,
						((size.x + 1) / 2) * ((size.y + 1) / 2) * 4,
						context.temp_allocator,
					)
					image_halve(image_pixels, size, halved)
					image_pixels = halved
					size = (size + 1) / 2
				}
				wgpu.QueueWriteTexture(
					out.queue,
					&{
						texture = out.atlas_texture,
						mipLevel = u32(level),
						origin = {u32(pos.x >> uint(level)), u32(pos.y >> uint(level)), 0},
						aspect = .All,
					},
					raw_data(image_pixels),
					uint(len(image_pixels)),
					&{bytesPerRow = u32(size.x * 4), rowsPerImage = u32(size.y)},
					&{u32(size.x), u32(size.y), 1},
				)
			}
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
				mipmapFilter = .Linear,
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

	terrain_init(&out)

	out.flags += {.Ready}
	return
}

renderer_deinit :: proc(rend: Renderer) {
	terrain_deinit()

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
	// What this frame draws
	data: ^Render_Data,
) -> (
	drawn: bool,
) {
	// Abort if not ready
	if !(.Ready in rend.flags) do return

	// Not drawing: still submit, so queued buffer and texture writes do not pile up
	defer if !drawn do wgpu.QueueSubmit(rend.queue, {})

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

			terrain_resize(rend, size)

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
	// Views. Callers work in logical pixels: the uniforms are in physical ones.
	// Screen: 1 unit = 1 logical pixel, origin top-left
	{
		size := [2]f32{f32(rend.window_size.x), f32(rend.window_size.y)}
		density := pixel_density(rend)
		views := [Render_Space]View_Uniform {
			.Screen = {
				size = size,
				center = size / density / 2,
				zoom = density,
				pixel_density = density,
			},
			.World = {
				size = size,
				center = data.view.center,
				zoom = data.view.zoom * density,
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

	// Quads, each space at its slots
	for &quads, space in data.quads {
		if len(quads) == 0 do continue
		wgpu.QueueWriteBuffer(
			rend.queue,
			rend.quad_buffer,
			u64(int(space) * RENDER_QUADS_MAX * size_of(Render_Quad)),
			raw_data(quads[:]),
			uint(len(quads) * size_of(Render_Quad)),
		)
	}

	// Terrain: this frame's looks, highlights, arrows, wash and marks in view
	{
		window := [2]f32{f32(rend.window_size.x), f32(rend.window_size.y)} / pixel_density(rend)
		terrain_frame(rend, data.terrain, data.view, window)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(rend.device)

	// Terrain: its offscreen passes, read by its draw below
	terrain_encode(rend, encoder)

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

		terrain_draw(rend, pass)

		// Quads over it, space by space
		for &quads, space in data.quads {
			quads_draw(
				rend,
				pass,
				rend.quad_buffer,
				space,
				int(space) * RENDER_QUADS_MAX,
				len(quads),
			)
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

// count quads of buffer from first, in space
quads_draw :: proc(
	rend: ^Renderer,
	pass: wgpu.RenderPassEncoder,
	buffer: wgpu.Buffer,
	space: Render_Space,
	first, count: int,
) {
	if count == 0 do return
	wgpu.RenderPassEncoderSetPipeline(pass, rend.quad_pipeline)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, buffer, 0, wgpu.WHOLE_SIZE)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[space])
	wgpu.RenderPassEncoderSetBindGroup(pass, 1, rend.atlas_group)
	wgpu.RenderPassEncoderDraw(pass, 4, u32(count), 0, u32(first))
}

// Physical pixels per logical pixel of the window. The renderer's interface is in logical pixels
// throughout: this stays inside it
@(private = "file")
pixel_density :: proc(rend: ^Renderer) -> f32 {
	density := sdl.GetWindowPixelDensity(rend.window)
	return density > 0 ? density : 1
}

// Coordinate space of quads. Drawn over the terrain in this order
Render_Space :: enum {
	// World units, mapped to the window by the frame's Render_View
	World,
	// Logical pixels, origin at the window top-left
	Screen,
}

// World to window, in logical pixels: pixel = (p - center) * zoom + window_size / 2
Render_View :: struct {
	// World position at the window centre
	center: [2]f32,
	// Logical pixels per world unit
	zoom:   f32,
}

// rect, radii, thickness, softness: units of the quad's space
Render_Quad :: struct {
	// Unrotated rectangle
	rect:      Extents,
	// Clip rectangle, in screen space (logical pixels) whatever the quad's space. Zero = none
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

// What a frame gives renderer_draw. Quads past a space's capacity are dropped
Render_Data :: struct {
	view:    Render_View,
	terrain: Render_Terrain_Frame,
	quads:   [Render_Space][dynamic; RENDER_QUADS_MAX]Render_Quad,
}

// Keeps the view
render_data_clear :: proc(data: ^Render_Data) {
	data.terrain = {}
	for space in Render_Space do clear(&data.quads[space])
}

