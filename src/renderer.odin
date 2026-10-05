#+private
package main

import "base:runtime"

import "core:fmt"

import sdl "vendor:sdl3"

import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

@(private = "file")
QUAD_SHADER :: #load("quad.wgsl", string)

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
	// Viewport data
	viewport_buffer: wgpu.Buffer,
	viewport_group:  wgpu.BindGroup,
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

renderer_init :: proc(window: ^sdl.Window) -> (out: Renderer) {
	assert(window != nil)
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

	device_done: bool
	wgpu.AdapterRequestDevice(
		out.adapter,
		nil,
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
	}

	out.quad_pipeline = wgpu.DeviceCreateRenderPipeline(
		out.device,
		&{
			label = "quad",
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


	{
		size: u64 = size_of([4]f32)
		out.viewport_buffer = wgpu.DeviceCreateBuffer(
			out.device,
			&{label = "viewport", usage = {.Uniform, .CopyDst}, size = size},
		)
		layout := wgpu.RenderPipelineGetBindGroupLayout(out.quad_pipeline, 0)
		out.viewport_group = wgpu.DeviceCreateBindGroup(
			out.device,
			&{
				label = "viewport",
				layout = layout,
				entryCount = 1,
				entries = &wgpu.BindGroupEntry {
					binding = 0,
					buffer = out.viewport_buffer,
					size = size,
				},
			},
		)

	}

	out.flags += {.Ready}
	return
}

renderer_deinit :: proc(rend: Renderer) {
	if rend.viewport_group != nil do wgpu.BindGroupRelease(rend.viewport_group)
	if rend.viewport_buffer != nil do wgpu.BufferRelease(rend.viewport_buffer)

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

			viewport := [4]f32{f32(size.x), f32(size.y), 0, 0}
			wgpu.QueueWriteBuffer(
				rend.queue,
				rend.viewport_buffer,
				0,
				&viewport,
				size_of(viewport),
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

	view := wgpu.TextureCreateView(
		surface_texture.texture,
		&{format = rend.format.view, mipLevelCount = 1, arrayLayerCount = 1},
	)

	// Send data to gpu
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
					view = view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {0.1, 0.2, 0.3, 1},
				},
			},
		)

		wgpu.RenderPassEncoderSetPipeline(pass, rend.quad_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.viewport_group)
		wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, rend.quad_buffer, 0, wgpu.WHOLE_SIZE)

		for command in passes {
			switch c in command {
			case Render_Quad_Pass:
				wgpu.RenderPassEncoderDraw(pass, 4, u32(c.len), 0, u32(c.begin))
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
	wgpu.TextureViewRelease(view)
	wgpu.TextureRelease(surface_texture.texture)
	return true
}

Texture_Id :: u32

Render_Quad :: struct {
	// Rectangle in xy (pixel) space
	rect:      Extents,
	// Clipping rectangle in xy space
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
}

RENDER_QUADS_MAX :: 32000
RENDER_PASS_MAX :: 256

Render_Quad_Pass :: struct {
	texture: Texture_Id,
	begin:   int,
	len:     int,
}

Render_Pass :: union {
	Render_Quad_Pass,
}
