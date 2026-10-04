#+private file
package main

import "base:runtime"

import "core:fmt"

import sdl "vendor:sdl3"

import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

Renderer_Flag :: enum {
	Ready,
}

Renderer :: struct {
	flags:       bit_set[Renderer_Flag],
	window:      ^sdl.Window,
	instance:    wgpu.Instance,
	adapter:     wgpu.Adapter,
	surface:     wgpu.Surface,
	device:      wgpu.Device,
	queue:       wgpu.Queue,
	format:      Surface_Format,
	// Cached window size
	window_size: [2]i32,
}

Surface_Format :: struct {
	surface: wgpu.TextureFormat,
	view:    wgpu.TextureFormat,
}

// In order of preference
SURFACE_FORMATS :: [?]Surface_Format {
	{.BGRA8Unorm, .BGRA8Unorm},
	{.RGBA8Unorm, .RGBA8Unorm},
	{.BGRA8UnormSrgb, .BGRA8Unorm},
	{.RGBA8UnormSrgb, .RGBA8Unorm},
}


@(private = "package")
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

	// Crate device & queue
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

	out.flags += {.Ready}
	return
}

@(private = "package")
renderer_deinit :: proc(renderer: Renderer) {
	if renderer.instance != nil do wgpu.InstanceRelease(renderer.instance)
	if renderer.surface != nil do wgpu.SurfaceRelease(renderer.surface)
	if renderer.adapter != nil do wgpu.AdapterRelease(renderer.adapter)
	if renderer.device != nil do wgpu.DeviceRelease(renderer.device)
	if renderer.queue != nil do wgpu.QueueRelease(renderer.queue)
}

@(private = "package")
renderer_draw :: proc(rend: ^Renderer) -> (drawn: bool) {
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

	// Process texture aquisition with early exists
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

