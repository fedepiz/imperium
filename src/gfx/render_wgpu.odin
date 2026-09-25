package gfx

import "base:runtime"
import "core:fmt"
import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

// How many render lists can be drawn in one frame: each gets its own part of the instance buffer, as every upload
// lands before any of the frame's drawing runs.
RENDER_LISTS_PER_FRAME :: 4

// A texture the render list can draw from, bound with its sampler
@(private = "file")
Render_Image :: struct {
	texture:    wgpu.Texture,
	view:       wgpu.TextureView,
	bind_group: wgpu.BindGroup,
}

// A texture with the one view the shaders read it through
@(private = "file")
Render_Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

// The map shader's uniforms, laid out as the shader's Terrain struct
@(private = "file")
Render_Terrain_Uniforms :: struct {
	grid, center, view_size:                        [2]f32,
	zoom, pixel_density:                            f32,
	paper, paper_stain, ink, sea_shallow, sea_deep: [4]f32,
	debug_mode:                                     i32,
	sea_tint, coast_width, wobble:                  f32,
	river_width, cover_jitter:                      f32,
	paper_stain_amount, sea_depth_from:             f32,
	sea_depth_full:                                 f32,
	_:                                              [3]f32,
}
#assert(size_of(Render_Terrain_Uniforms) == 160)

Renderer :: struct {
	window:                                    ^sdl.Window,
	// Whether presenting waits for the display's refresh
	vsync:                                     bool,
	// Logical window dimensions, matching SDL mouse coordinates.
	view_size:                                 [2]f32,
	// Physical pixels per logical pixel; zero is taken as one.
	pixel_density:                             f32,
	instance:                                  wgpu.Instance,
	surface:                                   wgpu.Surface,
	adapter:                                   wgpu.Adapter,
	device:                                    wgpu.Device,
	queue:                                     wgpu.Queue,
	// Set by the device's error callback: anything the device reported since
	failed:                                    bool,
	surface_format:                            wgpu.TextureFormat,
	surface_alpha:                             wgpu.CompositeAlphaMode,
	// The size the surface is configured at, in physical pixels; zero until it is
	surface_size:                              [2]u32,
	max_texture_size:                          int,
	// The frame being drawn: its target, and one pass recording everything
	frame_texture:                             wgpu.Texture,
	frame_view:                                wgpu.TextureView,
	frame_encoder:                             wgpu.CommandEncoder,
	frame_pass:                                wgpu.RenderPassEncoder,
	// Render lists drawn so far this frame
	frame_lists:                               int,
	// The render list pass: view size uniform, instances, and a bind group per texture
	list_pipeline:                             wgpu.RenderPipeline,
	list_view_layout, list_image_layout:       wgpu.BindGroupLayout,
	list_view_buffer, list_instances:          wgpu.Buffer,
	list_view_group:                           wgpu.BindGroup,
	linear_sampler:                            wgpu.Sampler,
	white:                                     Render_Image,
	// Slot zero is never registered; untextured batches use white.
	images:                                    [65536]Render_Image,
	// The map pass
	terrain_pipeline:                          wgpu.RenderPipeline,
	terrain_layout:                            wgpu.BindGroupLayout,
	terrain_group:                             wgpu.BindGroup,
	terrain_uniforms:                          wgpu.Buffer,
	terrain_cells, terrain_coast:              Render_Texture,
	terrain_river:                             Render_Texture,
	cover_cells, cover_palette:                Render_Texture,
	// The revisions the textures hold, once anything has been uploaded
	terrain_revision, cover_revision:          u32,
	terrain_uploaded, cover_uploaded:          bool,
	// Coast and rivers converted to half floats for upload, as the textures hold them
	coast_half:                                [RENDER_TERRAIN_CELLS]f16,
	river_half:                                [RENDER_TERRAIN_CELLS][2]f16,
}

// The backend wgpu draws through: Metal on macOS, Vulkan elsewhere.
RENDER_BACKENDS :: wgpu.InstanceBackendFlags{.Metal} when ODIN_OS == .Darwin else wgpu.InstanceBackendFlags{.Vulkan}

// On macOS the window draws through a Metal layer, which the surface is made from; elsewhere the surface is made
// from the native window handle.
render_window_flags :: proc() -> (sdl.WindowFlags, bool) {
	when ODIN_OS == .Darwin {
		return {.METAL}, true
	} else {
		return {}, true
	}
}

render_init :: proc(renderer: ^Renderer, window: ^sdl.Window) -> bool {
	renderer.window = window
	instance_extras := wgpu.InstanceExtras {
		sType    = .InstanceExtras,
		backends = RENDER_BACKENDS,
	}
	renderer.instance = wgpu.CreateInstance(&{nextInChain = &instance_extras})
	if renderer.instance == nil {
		fmt.eprintln("wgpu instance creation failed")
		return false
	}
	renderer.surface = sdl3glue.GetSurface(renderer.instance, window)
	if renderer.surface == nil {
		fmt.eprintln("wgpu surface creation failed")
		return false
	}

	// Adapter and device arrive through callbacks, which run while the instance processes its events.
	on_adapter :: proc "c" (
		status: wgpu.RequestAdapterStatus,
		adapter: wgpu.Adapter,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		renderer := (^Renderer)(userdata1)
		(^bool)(userdata2)^ = true
		if status != .Success {
			fmt.eprintf("wgpu adapter request failed: %s\n", message)
			return
		}
		renderer.adapter = adapter
	}
	adapter_done: bool
	wgpu.InstanceRequestAdapter(
		renderer.instance,
		&{featureLevel = .Core, powerPreference = .HighPerformance, compatibleSurface = renderer.surface},
		{mode = .AllowProcessEvents, callback = on_adapter, userdata1 = renderer, userdata2 = &adapter_done},
	)
	for !adapter_done do wgpu.InstanceProcessEvents(renderer.instance)
	if renderer.adapter == nil do return false

	// Ask for what the adapter can do rather than the portable defaults, so the atlas can be as large as the GPU allows.
	limits, limits_status := wgpu.AdapterGetLimits(renderer.adapter)
	if limits_status != .Success {
		fmt.eprintln("wgpu adapter limits query failed")
		return false
	}
	on_device :: proc "c" (
		status: wgpu.RequestDeviceStatus,
		device: wgpu.Device,
		message: string,
		userdata1, userdata2: rawptr,
	) {
		context = runtime.default_context()
		renderer := (^Renderer)(userdata1)
		(^bool)(userdata2)^ = true
		if status != .Success {
			fmt.eprintf("wgpu device request failed: %s\n", message)
			return
		}
		renderer.device = device
	}
	on_error :: proc "c" (device: ^wgpu.Device, type: wgpu.ErrorType, message: string, userdata1, userdata2: rawptr) {
		context = runtime.default_context()
		fmt.eprintf("wgpu error (%v): %s\n", type, message)
		(^Renderer)(userdata1).failed = true
	}
	device_done: bool
	wgpu.AdapterRequestDevice(
		renderer.adapter,
		&{
			requiredLimits = &limits,
			uncapturedErrorCallbackInfo = {callback = on_error, userdata1 = renderer},
		},
		{mode = .AllowProcessEvents, callback = on_device, userdata1 = renderer, userdata2 = &device_done},
	)
	for !device_done do wgpu.InstanceProcessEvents(renderer.instance)
	if renderer.device == nil do return false
	renderer.queue = wgpu.DeviceGetQueue(renderer.device)
	renderer.max_texture_size = int(limits.maxTextureDimension2D)

	// Colors are written as they are, with no conversion to sRGB, so a plain format.
	capabilities, capabilities_status := wgpu.SurfaceGetCapabilities(renderer.surface, renderer.adapter)
	if capabilities_status != .Success || capabilities.formatCount == 0 {
		fmt.eprintln("wgpu surface capabilities query failed")
		return false
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)
	renderer.surface_format = capabilities.formats[0]
	for format in capabilities.formats[:capabilities.formatCount] {
		if format == .BGRA8Unorm || format == .RGBA8Unorm {
			renderer.surface_format = format
			break
		}
	}
	renderer.surface_alpha = capabilities.alphaModes[0]
	for mode in capabilities.alphaModes[:capabilities.alphaModeCount] {
		if mode == .Opaque do renderer.surface_alpha = mode
	}
	// Fifo waits for the display's refresh, and every surface supports it.
	renderer.vsync = true

	renderer.linear_sampler = wgpu.DeviceCreateSampler(
		renderer.device,
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
	if !render_list_init(renderer) || !render_terrain_init(renderer) {
		return false
	}
	return !renderer.failed
}

render_destroy :: proc(renderer: ^Renderer) {
	image_release :: proc(image: Render_Image) {
		if image.bind_group != nil do wgpu.BindGroupRelease(image.bind_group)
		if image.view != nil do wgpu.TextureViewRelease(image.view)
		if image.texture != nil do wgpu.TextureRelease(image.texture)
	}
	texture_release :: proc(texture: Render_Texture) {
		if texture.view != nil do wgpu.TextureViewRelease(texture.view)
		if texture.texture != nil do wgpu.TextureRelease(texture.texture)
	}
	for image in renderer.images do image_release(image)
	image_release(renderer.white)
	texture_release(renderer.terrain_cells)
	texture_release(renderer.terrain_coast)
	texture_release(renderer.terrain_river)
	texture_release(renderer.cover_cells)
	texture_release(renderer.cover_palette)
	if renderer.terrain_group != nil do wgpu.BindGroupRelease(renderer.terrain_group)
	if renderer.terrain_layout != nil do wgpu.BindGroupLayoutRelease(renderer.terrain_layout)
	if renderer.terrain_uniforms != nil do wgpu.BufferRelease(renderer.terrain_uniforms)
	if renderer.terrain_pipeline != nil do wgpu.RenderPipelineRelease(renderer.terrain_pipeline)
	if renderer.list_view_group != nil do wgpu.BindGroupRelease(renderer.list_view_group)
	if renderer.list_view_layout != nil do wgpu.BindGroupLayoutRelease(renderer.list_view_layout)
	if renderer.list_image_layout != nil do wgpu.BindGroupLayoutRelease(renderer.list_image_layout)
	if renderer.list_view_buffer != nil do wgpu.BufferRelease(renderer.list_view_buffer)
	if renderer.list_instances != nil do wgpu.BufferRelease(renderer.list_instances)
	if renderer.list_pipeline != nil do wgpu.RenderPipelineRelease(renderer.list_pipeline)
	if renderer.linear_sampler != nil do wgpu.SamplerRelease(renderer.linear_sampler)
	if renderer.queue != nil do wgpu.QueueRelease(renderer.queue)
	if renderer.device != nil do wgpu.DeviceRelease(renderer.device)
	if renderer.adapter != nil do wgpu.AdapterRelease(renderer.adapter)
	if renderer.surface != nil do wgpu.SurfaceRelease(renderer.surface)
	if renderer.instance != nil do wgpu.InstanceRelease(renderer.instance)
}

render_max_texture_size :: proc(renderer: ^Renderer) -> int {
	return renderer.max_texture_size
}

// Takes the next image of the window and starts the frame's pass, cleared. False when there is nothing to draw to: the
// window is hidden or empty, or the surface had to be configured again.
render_frame_begin :: proc(renderer: ^Renderer, clear_color: [4]f32) -> bool {
	size, ok := render_window_pixels(renderer.window)
	if !ok {
		fmt.eprintf("Getting the window pixel size failed: %s\n", sdl.GetError())
		return false
	}
	if size.x == 0 || size.y == 0 {
		return false
	}
	if size != renderer.surface_size {
		render_surface_configure(renderer, size)
	}

	surface_texture := wgpu.SurfaceGetCurrentTexture(renderer.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		render_surface_configure(renderer, size)
		return false
	case .Occluded:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		return false
	case .Error:
		fmt.eprintln("wgpu surface texture acquisition failed")
		return false
	}

	renderer.frame_texture = surface_texture.texture
	renderer.frame_view = wgpu.TextureCreateView(renderer.frame_texture, nil)
	renderer.frame_encoder = wgpu.DeviceCreateCommandEncoder(renderer.device, nil)
	color := [4]f64{f64(clear_color.r), f64(clear_color.g), f64(clear_color.b), f64(clear_color.a)}
	renderer.frame_pass = wgpu.CommandEncoderBeginRenderPass(
		renderer.frame_encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = renderer.frame_view,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = color,
			},
		},
	)
	renderer.frame_lists = 0
	return true
}

// Submits the frame and presents it; presenting waits for the display's refresh.
render_frame_end :: proc(renderer: ^Renderer) {
	wgpu.RenderPassEncoderEnd(renderer.frame_pass)
	wgpu.RenderPassEncoderRelease(renderer.frame_pass)
	commands := wgpu.CommandEncoderFinish(renderer.frame_encoder, nil)
	wgpu.QueueSubmit(renderer.queue, {commands})
	wgpu.SurfacePresent(renderer.surface)
	wgpu.CommandBufferRelease(commands)
	wgpu.CommandEncoderRelease(renderer.frame_encoder)
	wgpu.TextureViewRelease(renderer.frame_view)
	wgpu.TextureRelease(renderer.frame_texture)
	renderer.frame_pass, renderer.frame_encoder, renderer.frame_view, renderer.frame_texture = nil, nil, nil, nil
}

@(private = "file")
render_surface_configure :: proc(renderer: ^Renderer, size: [2]u32) {
	wgpu.SurfaceConfigure(
		renderer.surface,
		&{
			device = renderer.device,
			format = renderer.surface_format,
			usage = {.RenderAttachment},
			width = size.x,
			height = size.y,
			alphaMode = renderer.surface_alpha,
			presentMode = .Fifo,
		},
	)
	renderer.surface_size = size
}

// Draws the map over the whole view. Cells, coast and rivers are uploaded again only when the revision has changed.
render_terrain :: proc(renderer: ^Renderer, terrain: ^Render_Terrain) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 || terrain.zoom <= 0 {
		return
	}

	if !renderer.terrain_uploaded || renderer.terrain_revision != terrain.revision {
		for coast, i in terrain.coast {
			renderer.coast_half[i] = f16(coast)
		}
		for river, i in terrain.river {
			renderer.river_half[i] = {f16(river.x), f16(river.y)}
		}
		render_texture_write(renderer, renderer.terrain_cells.texture, raw_data(terrain.cells[:]), 4)
		render_texture_write(renderer, renderer.terrain_coast.texture, raw_data(renderer.coast_half[:]), 2)
		render_texture_write(renderer, renderer.terrain_river.texture, raw_data(renderer.river_half[:]), 4)
		renderer.terrain_revision = terrain.revision
		renderer.terrain_uploaded = true
	}

	cover := &terrain.cover
	if !renderer.cover_uploaded || renderer.cover_revision != cover.revision {
		byte :: proc(v: f32) -> u8 {return u8(clamp(v, 0, 1) * 255 + 0.5)}
		palette: [2][RENDER_LAYER_CATEGORIES][4]u8
		for category, i in cover.palette {
			c := category.color
			palette[0][i] = {byte(c.r), byte(c.g), byte(c.b), byte(category.wash)}
			palette[1][i] = {u8(category.pattern), byte(category.pattern_ink), 0, 0}
		}
		render_texture_write(renderer, renderer.cover_cells.texture, raw_data(cover.cells[:]), 2)
		wgpu.QueueWriteTexture(
			renderer.queue,
			&{texture = renderer.cover_palette.texture, aspect = .All},
			&palette,
			size_of(palette),
			&{bytesPerRow = RENDER_LAYER_CATEGORIES * 4, rowsPerImage = 2},
			&{RENDER_LAYER_CATEGORIES, 2, 1},
		)
		renderer.cover_revision = cover.revision
		renderer.cover_uploaded = true
	}

	style := &terrain.style
	uniforms := Render_Terrain_Uniforms {
		grid               = {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
		center             = terrain.center,
		view_size          = renderer.view_size,
		zoom               = terrain.zoom,
		pixel_density      = renderer.pixel_density if renderer.pixel_density > 0 else 1,
		paper              = style.paper,
		paper_stain        = style.paper_stain,
		ink                = style.ink,
		sea_shallow        = style.sea_shallow,
		sea_deep           = style.sea_deep,
		debug_mode         = i32(terrain.debug_mode),
		sea_tint           = style.sea_tint,
		coast_width        = style.coast_width,
		wobble             = style.wobble,
		river_width        = style.river_width,
		cover_jitter       = cover.jitter,
		paper_stain_amount = style.paper_stain_amount,
		sea_depth_from     = style.sea_depth_from,
		sea_depth_full     = style.sea_depth_full,
	}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.terrain_uniforms, 0, &uniforms, size_of(uniforms))

	pass := renderer.frame_pass
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.terrain_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.terrain_group)
	wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
}

// src, dst and clip are [x, y, width, height], with a top-left origin.
// src uses texture pixels; dst, clip, radii and softness use logical pixels.
// Textures should have their top row at v=0. Colors use straight alpha.
// Instances draw in the order they sit in the list.
render_list :: proc(renderer: ^Renderer, list: ^Render_List) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 {
		return
	}
	assert(renderer.frame_lists < RENDER_LISTS_PER_FRAME, "More render lists in one frame than RENDER_LISTS_PER_FRAME")
	offset := u64(renderer.frame_lists * size_of(list.instances))
	renderer.frame_lists += 1
	wgpu.QueueWriteBuffer(renderer.queue, renderer.list_instances, offset, raw_data(list.instances[:]), size_of(list.instances))
	view := [4]f32{renderer.view_size.x, renderer.view_size.y, 0, 0}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.list_view_buffer, 0, &view, size_of(view))

	pass := renderer.frame_pass
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.list_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.list_view_group)
	wgpu.RenderPassEncoderSetVertexBuffer(pass, 0, renderer.list_instances, offset, size_of(list.instances))

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
		group := renderer.images[batch_texture].bind_group
		assert(batch_texture == 0 || group != nil, "Texture ID has no registered wgpu texture")
		if batch_texture == 0 do group = renderer.white.bind_group
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, group)
		wgpu.RenderPassEncoderDraw(pass, 6, u32(end - first), 0, u32(first))
		first = end
	}
}

render_create_atlas_texture :: proc(renderer: ^Renderer, id: Texture_Id, bitmap: Bitmap) {
	assert(id != 0)
	assert(bitmap.width > 0 && bitmap.height > 0)
	assert(len(bitmap.pixels) == bitmap.width * bitmap.height)
	assert(renderer.images[id].texture == nil, "Texture ID is already registered")
	renderer.images[id] = render_image_create(renderer, bitmap)
}

@(private = "file")
render_image_create :: proc(renderer: ^Renderer, bitmap: Bitmap) -> (image: Render_Image) {
	size := [2]u32{u32(bitmap.width), u32(bitmap.height)}
	texture := render_texture_create(renderer, .RGBA8Unorm, size)
	image.texture, image.view = texture.texture, texture.view
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = image.texture, aspect = .All},
		raw_data(bitmap.pixels),
		uint(len(bitmap.pixels) * 4),
		&{bytesPerRow = size.x * 4, rowsPerImage = size.y},
		&{size.x, size.y, 1},
	)
	entries := [2]wgpu.BindGroupEntry {
		{binding = 0, textureView = image.view},
		{binding = 1, sampler = renderer.linear_sampler},
	}
	image.bind_group = wgpu.DeviceCreateBindGroup(
		renderer.device,
		&{layout = renderer.list_image_layout, entryCount = len(entries), entries = &entries[0]},
	)
	return
}

@(private = "file")
render_texture_create :: proc(
	renderer: ^Renderer,
	format: wgpu.TextureFormat,
	size: [2]u32,
) -> (
	texture: Render_Texture,
) {
	texture.texture = wgpu.DeviceCreateTexture(
		renderer.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {size.x, size.y, 1},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	texture.view = wgpu.TextureCreateView(texture.texture, nil)
	return
}

// Uploads a whole terrain-sized texture, texel_size bytes per cell.
@(private = "file")
render_texture_write :: proc(renderer: ^Renderer, texture: wgpu.Texture, data: rawptr, texel_size: u32) {
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = texture, aspect = .All},
		data,
		uint(RENDER_TERRAIN_CELLS * texel_size),
		&{bytesPerRow = RENDER_TERRAIN_WIDTH * texel_size, rowsPerImage = RENDER_TERRAIN_HEIGHT},
		&{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT, 1},
	)
}

@(private = "file")
render_shader_create :: proc(renderer: ^Renderer, source: string) -> wgpu.ShaderModule {
	return wgpu.DeviceCreateShaderModule(
		renderer.device,
		&{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = source}},
	)
}

// Makes the render list pipeline, its buffers, and the white texture untextured batches bind.
@(private = "file")
render_list_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	view_entry := wgpu.BindGroupLayoutEntry {
		binding = 0,
		visibility = {.Vertex},
		buffer = {type = .Uniform, minBindingSize = 16},
	}
	renderer.list_view_layout = wgpu.DeviceCreateBindGroupLayout(device, &{entryCount = 1, entries = &view_entry})
	image_entries := [2]wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	renderer.list_image_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = len(image_entries), entries = &image_entries[0]},
	)

	renderer.list_view_buffer = wgpu.DeviceCreateBuffer(device, &{usage = {.Uniform, .CopyDst}, size = 16})
	renderer.list_instances = wgpu.DeviceCreateBuffer(
		device,
		&{usage = {.Vertex, .CopyDst}, size = RENDER_LISTS_PER_FRAME * size_of(Render_List{}.instances)},
	)
	view_group_entry := wgpu.BindGroupEntry {
		binding = 0,
		buffer  = renderer.list_view_buffer,
		size    = 16,
	}
	renderer.list_view_group = wgpu.DeviceCreateBindGroup(
		device,
		&{layout = renderer.list_view_layout, entryCount = 1, entries = &view_group_entry},
	)
	white := [1][4]u8{{255, 255, 255, 255}}
	renderer.white = render_image_create(renderer, {pixels = white[:], width = 1, height = 1})

	module := render_shader_create(renderer, RENDER_LIST_SOURCE)
	defer wgpu.ShaderModuleRelease(module)
	layouts := [2]wgpu.BindGroupLayout{renderer.list_view_layout, renderer.list_image_layout}
	pipeline_layout := wgpu.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = len(layouts), bindGroupLayouts = &layouts[0]},
	)
	defer wgpu.PipelineLayoutRelease(pipeline_layout)

	attributes := [10]wgpu.VertexAttribute {
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, src)), shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, dst)), shaderLocation = 1},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, clip)), shaderLocation = 2},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, color)), shaderLocation = 3},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, color)) + 16, shaderLocation = 4},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, color)) + 32, shaderLocation = 5},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, color)) + 48, shaderLocation = 6},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, radii)), shaderLocation = 7},
		{format = .Float32, offset = u64(offset_of(Render_Instance, softness)), shaderLocation = 8},
		{format = .Float32, offset = u64(offset_of(Render_Instance, thickness)), shaderLocation = 9},
	}
	buffer := wgpu.VertexBufferLayout {
		stepMode       = .Instance,
		arrayStride    = size_of(Render_Instance),
		attributeCount = len(attributes),
		attributes     = &attributes[0],
	}
	blend := wgpu.BlendState {
		color = {operation = .Add, srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha},
		alpha = {operation = .Add, srcFactor = .One, dstFactor = .OneMinusSrcAlpha},
	}
	target := wgpu.ColorTargetState {
		format    = renderer.surface_format,
		blend     = &blend,
		writeMask = wgpu.ColorWriteMaskFlags_All,
	}
	renderer.list_pipeline = wgpu.DeviceCreateRenderPipeline(
		device,
		&{
			layout = pipeline_layout,
			vertex = {module = module, entryPoint = "vs_main", bufferCount = 1, buffers = &buffer},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = max(u32)},
			fragment = &{module = module, entryPoint = "fs_main", targetCount = 1, targets = &target},
		},
	)
	return renderer.list_pipeline != nil && !renderer.failed
}

// Makes the map pipeline and its textures, with storage for the largest terrain and nothing in them yet.
@(private = "file")
render_terrain_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	// Cells and coast are filtered between cells: that makes the coast smooth and the washes soft. Everything else is
	// read cell by cell and blended in the shader.
	renderer.terrain_cells = render_texture_create(renderer, .RGBA8Unorm, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT})
	renderer.terrain_coast = render_texture_create(renderer, .R16Float, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT})
	renderer.terrain_river = render_texture_create(renderer, .RG16Float, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT})
	renderer.cover_cells = render_texture_create(renderer, .RG8Unorm, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT})
	renderer.cover_palette = render_texture_create(renderer, .RGBA8Unorm, {RENDER_LAYER_CATEGORIES, 2})
	renderer.terrain_uniforms = wgpu.DeviceCreateBuffer(
		device,
		&{usage = {.Uniform, .CopyDst}, size = size_of(Render_Terrain_Uniforms)},
	)

	texture_entry :: proc(binding: u32, sample: wgpu.TextureSampleType) -> wgpu.BindGroupLayoutEntry {
		return {binding = binding, visibility = {.Fragment}, texture = {sampleType = sample, viewDimension = ._2D}}
	}
	layout_entries := [7]wgpu.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			buffer = {type = .Uniform, minBindingSize = size_of(Render_Terrain_Uniforms)},
		},
		texture_entry(1, .Float),
		texture_entry(2, .Float),
		texture_entry(3, .Float),
		texture_entry(4, .Float),
		texture_entry(5, .Float),
		{binding = 6, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	renderer.terrain_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = len(layout_entries), entries = &layout_entries[0]},
	)
	group_entries := [7]wgpu.BindGroupEntry {
		{binding = 0, buffer = renderer.terrain_uniforms, size = size_of(Render_Terrain_Uniforms)},
		{binding = 1, textureView = renderer.terrain_cells.view},
		{binding = 2, textureView = renderer.terrain_coast.view},
		{binding = 3, textureView = renderer.terrain_river.view},
		{binding = 4, textureView = renderer.cover_cells.view},
		{binding = 5, textureView = renderer.cover_palette.view},
		{binding = 6, sampler = renderer.linear_sampler},
	}
	renderer.terrain_group = wgpu.DeviceCreateBindGroup(
		device,
		&{layout = renderer.terrain_layout, entryCount = len(group_entries), entries = &group_entries[0]},
	)

	module := render_shader_create(renderer, RENDER_MAP_SOURCE)
	defer wgpu.ShaderModuleRelease(module)
	pipeline_layout := wgpu.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &renderer.terrain_layout},
	)
	defer wgpu.PipelineLayoutRelease(pipeline_layout)
	// The map is opaque and covers everything drawn before it.
	target := wgpu.ColorTargetState {
		format    = renderer.surface_format,
		writeMask = wgpu.ColorWriteMaskFlags_All,
	}
	renderer.terrain_pipeline = wgpu.DeviceCreateRenderPipeline(
		device,
		&{
			layout = pipeline_layout,
			vertex = {module = module, entryPoint = "vs_main"},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = max(u32)},
			fragment = &{module = module, entryPoint = "fs_main", targetCount = 1, targets = &target},
		},
	)
	return renderer.terrain_pipeline != nil && !renderer.failed
}

// The render list shader
@(private = "file")
RENDER_LIST_SOURCE :: `
struct View { size: vec2f, _pad: vec2f }
@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var image: texture_2d<f32>;
@group(1) @binding(1) var image_sampler: sampler;

struct Instance {
    @location(0) src: vec4f,
    @location(1) dst: vec4f,
    @location(2) clip: vec4f,
    @location(3) color_tl: vec4f,
    @location(4) color_tr: vec4f,
    @location(5) color_br: vec4f,
    @location(6) color_bl: vec4f,
    @location(7) radii: vec4f,
    @location(8) softness: f32,
    @location(9) thickness: f32,
}

struct Varyings {
    @builtin(position) position: vec4f,
    @location(0) local_position: vec2f,
    @location(1) @interpolate(flat) rect_src: vec4f,
    @location(2) @interpolate(flat) rect_size: vec2f,
    @location(3) @interpolate(flat) color_tl: vec4f,
    @location(4) @interpolate(flat) color_tr: vec4f,
    @location(5) @interpolate(flat) color_br: vec4f,
    @location(6) @interpolate(flat) color_bl: vec4f,
    @location(7) @interpolate(flat) corner_radii: vec4f,
    // Edge softness and border thickness
    @location(8) @interpolate(flat) edge: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32, inst: Instance) -> Varyings {
    var corners = array<vec2f, 6>(
        vec2f(0.0, 0.0), vec2f(1.0, 0.0), vec2f(1.0, 1.0),
        vec2f(0.0, 0.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));
    var out: Varyings;
    // The quad shrinks to its part inside the clip; nothing inside moves, as local_position stays relative to dst.
    let lo = max(inst.dst.xy, inst.clip.xy);
    let hi = max(min(inst.dst.xy + inst.dst.zw, inst.clip.xy + inst.clip.zw), lo);
    let position = mix(lo, hi, corners[vertex]);
    out.local_position = position - inst.dst.xy;
    out.position = vec4f(position / view.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    out.rect_src = inst.src;
    out.rect_size = inst.dst.zw;
    out.color_tl = inst.color_tl;
    out.color_tr = inst.color_tr;
    out.color_br = inst.color_br;
    out.color_bl = inst.color_bl;
    out.corner_radii = inst.radii;
    out.edge = vec2f(inst.softness, inst.thickness);
    return out;
}

fn rect_sdf(p: vec2f, half_size: vec2f, radius: f32) -> f32 {
    return length(max(abs(p) - half_size + radius, vec2f(0.0))) - radius;
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4f {
    let t = in.local_position / in.rect_size;
    var color = mix(mix(in.color_tl, in.color_tr, t.x), mix(in.color_bl, in.color_br, t.x), t.y);
    // Only instances with a source rect sample; the rest ignore whatever texture their batch binds.
    if (in.rect_src.z > 0.0) {
        let uv = (in.rect_src.xy + t * in.rect_src.zw) / vec2f(textureDimensions(image, 0));
        color *= textureSampleLevel(image, image_sampler, uv, 0.0);
    }
    let half_size = in.rect_size * 0.5;
    let p = in.local_position - half_size;
    let radii = in.corner_radii;
    var r = select(select(radii.z, radii.w, p.x < 0.0), select(radii.y, radii.x, p.x < 0.0), p.y < 0.0);
    r = clamp(r, 0.0, min(half_size.x, half_size.y));
    // Inset the shape to fit a 2*softness fade inside the supplied quad.
    let softness = max(in.edge.x, 0.0);
    let thickness = in.edge.y;
    let feather = max(2.0 * softness, 0.0001);
    let shape_half_size = half_size - vec2f(2.0 * softness);
    var border = 1.0;
    if (thickness > 0.0) {
        let inner = rect_sdf(p, shape_half_size - vec2f(thickness), max(r - thickness, 0.0));
        border = smoothstep(0.0, feather, inner);
    }
    // Plain image/text quads use texture coverage without an additional edge fade.
    var corner = 1.0;
    if (r > 0.0 || softness > 0.75) {
        let outer = rect_sdf(p, shape_half_size, r);
        corner = 1.0 - smoothstep(0.0, feather, outer);
    }
    return vec4f(color.rgb, color.a * corner * border);
}
`

// The map pass: one triangle covering the view, drawn before the render lists.
// Positions are in cells: the world is grid cells wide and tall, with cell (0, 0) at the top left.
// cells holds the terrain as the rules see it, one texel per cell: surface, elevation, trees, moisture. textureLoad reads
// a cell exactly; sampling blends neighbouring cells.
// coast holds the signed distance to the coast in cells, positive on land, blended between cells.
// river holds, per cell, the offset from its middle to the nearest point of a river line.
// cover_cells and cover_palette are the cover layer: see layer_at.
@(private = "file")
RENDER_MAP_SOURCE :: `
struct Terrain {
    grid: vec2f,
    center: vec2f,
    view_size: vec2f,
    zoom: f32,
    pixel_density: f32,
    paper: vec4f,
    paper_stain: vec4f,
    ink: vec4f,
    sea_shallow: vec4f,
    sea_deep: vec4f,
    debug_mode: i32,
    sea_tint: f32,
    coast_width: f32,
    wobble: f32,
    river_width: f32,
    cover_jitter: f32,
    paper_stain_amount: f32,
    sea_depth_from: f32,
    sea_depth_full: f32,
}
@group(0) @binding(0) var<uniform> u: Terrain;
@group(0) @binding(1) var cells: texture_2d<f32>;
@group(0) @binding(2) var coast: texture_2d<f32>;
@group(0) @binding(3) var river: texture_2d<f32>;
@group(0) @binding(4) var cover_cells: texture_2d<f32>;
@group(0) @binding(5) var cover_palette: texture_2d<f32>;
@group(0) @binding(6) var linear_sampler: sampler;

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((vertex << 1u) & 2u), f32(vertex & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

fn hash(p_in: vec2f) -> f32 {
    var p = fract(p_in * vec2f(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}
// Hash of a lattice point, in 0..1
fn lattice_hash(i: vec2f) -> f32 {
    let h = bitcast<vec2u>(vec2i(i)) * vec2u(1597334677u, 3812015801u);
    return f32(((h.x ^ h.y) * 1597334677u) >> 8u) / 16777216.0;
}
fn value_noise(p: vec2f) -> f32 {
    let i = floor(p);
    var f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    let a = lattice_hash(i);
    let b = lattice_hash(i + vec2f(1.0, 0.0));
    let c = lattice_hash(i + vec2f(0.0, 1.0));
    let d = lattice_hash(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
// Four octaves of value noise, in 0..1
fn fbm(p_in: vec2f) -> f32 {
    var p = p_in;
    var sum = 0.0;
    var weight = 0.5;
    for (var i = 0; i < 4; i++) { sum += weight * value_noise(p); p *= 2.03; weight *= 0.5; }
    return sum / 0.9375;
}
// Coverage of a line of half width half_w at distance dist, both in device pixels; thinner lines fade instead of vanishing.
fn line_aa(dist: f32, half_w: f32) -> f32 {
    let hw = max(half_w, 0.5);
    return (1.0 - smoothstep(hw - 0.6, hw + 0.6, dist)) * min(1.0, half_w / 0.5);
}

// Vellum: large stains fixed to the world, and a fine grain fixed to the screen.
fn paper_at(p: vec2f, frag: vec2f) -> vec3f {
    let stain = smoothstep(0.35, 0.85, fbm(p * 0.02 + 3.1)) * 0.85 + (fbm(p * 0.09 + 11.3) - 0.5) * 0.2;
    let c = mix(u.paper.rgb, u.paper_stain.rgb, clamp(stain * u.paper_stain_amount, 0.0, 1.0));
    return c * (1.0 - (hash(floor(frag)) - 0.5) * 0.035);
}

// Distance from p to the nearest river line, in cells. Each of the four cells around p knows its nearest river point;
// blending them is exact along a straight river. Where they see different rivers, blending would draw a false river
// between the two, so the nearest of their points is taken instead.
fn river_distance(p: vec2f) -> f32 {
    let q = p - 0.5;
    let base = floor(q);
    let f = q - base;
    var n: array<vec2f, 4>;
    for (var k = 0; k < 4; k++) {
        let c = base + vec2f(f32(k & 1), f32(k >> 1u));
        n[k] = c + 0.5 + textureLoad(river, clamp(vec2i(c), vec2i(0), vec2i(u.grid) - 1), 0).rg;
    }
    let spread = max(max(distance(n[0], n[1]), distance(n[2], n[3])), max(distance(n[0], n[2]), distance(n[1], n[3])));
    if (spread < 2.0) { return distance(p, mix(mix(n[0], n[1], f.x), mix(n[2], n[3], f.x), f.y)); }
    return min(min(distance(p, n[0]), distance(p, n[1])), min(distance(p, n[2]), distance(p, n[3])));
}

// Ink dots on a grid fixed to the world, spacing cells apart: each grid square keeps its dot with the chance density,
// somewhere near its middle. radius is in device pixels.
fn stipple_grid(p: vec2f, spacing: f32, px: f32, density: f32, radius: f32) -> f32 {
    let g = p / spacing;
    let id = floor(g);
    if (hash(id + 3.7) >= density) { return 0.0; }
    let dot_at = id + 0.25 + 0.5 * vec2f(hash(id), hash(id + 17.3));
    return 1.0 - smoothstep(radius - 0.6, radius + 0.6, length(g - dot_at) * spacing * px);
}

// Desert stippling, the dots always about seven device pixels apart: the grid halves or doubles as the map zooms, and
// the two nearest grids fade into each other.
fn stipple_at(p: vec2f, px: f32, density: f32) -> f32 {
    let level = log2(7.0 * u.pixel_density / px);
    let l0 = floor(level);
    let f = level - l0;
    let radius = 0.75 * u.pixel_density;
    return mix(stipple_grid(p, exp2(l0), px, density, radius), stipple_grid(p, exp2(l0 + 1.0), px, density, radius), f);
}

// A layer as drawn at p: what its wash multiplies the paper by, and for each ink pattern (x: stipple) how dense it is
// and how dark its ink.
struct Layer_Look {
    tint: vec3f,
    density: vec4f,
    ink: vec4f,
}

// Reads a layer at p. cells holds a category and a strength per cell; palette holds, for each category, its color and
// wash in row 0 and its pattern and ink in row 1. Categories cannot be blended as numbers, so the four cells around p
// are read exactly and their looks blended instead. p first wanders up to jitter cells, so borders do not follow the
// grid.
fn layer_at(layer_cells: texture_2d<f32>, palette: texture_2d<f32>, p: vec2f, jitter: f32) -> Layer_Look {
    let q = p - 0.5 + jitter * (vec2f(fbm(p * 0.3 + 1.3), fbm(p * 0.3 + 9.1)) - 0.5);
    let base = floor(q);
    let f = q - base;
    var look = Layer_Look(vec3f(0.0), vec4f(0.0), vec4f(0.0));
    for (var k = 0; k < 4; k++) {
        let corner = vec2i(k & 1, k >> 1u);
        let cell = textureLoad(layer_cells, clamp(vec2i(base) + corner, vec2i(0), vec2i(u.grid) - 1), 0).rg;
        let category = i32(cell.r * 255.0 + 0.5);
        let wash = textureLoad(palette, vec2i(category, 0), 0);
        let pattern = textureLoad(palette, vec2i(category, 1), 0);
        let weight = mix(1.0 - f.x, f.x, f32(corner.x)) * mix(1.0 - f.y, f.y, f32(corner.y));
        look.tint += weight * mix(vec3f(1.0), wash.rgb, wash.a * cell.g);
        let kind = i32(pattern.r * 255.0 + 0.5);
        if (kind > 0) {
            look.density[kind - 1] += weight * cell.g;
            look.ink[kind - 1] += weight * pattern.g;
        }
    }
    return look;
}

fn debug_color(cell: vec4f, p: vec2f) -> vec3f {
    // Land, river, lake, sea
    let surface = i32(cell.r * 3.0 + 0.5);
    let water = surface >= 2;
    if (u.debug_mode == 1) {
        if (surface == 0) { return vec3f(0.85, 0.8, 0.65); }
        if (surface == 1) { return vec3f(0.2, 0.6, 0.55); }
        if (surface == 2) { return vec3f(0.35, 0.6, 0.85); }
        return vec3f(0.25, 0.45, 0.7);
    }
    if (water) { return vec3f(0.12, 0.2, 0.3); }
    if (u.debug_mode == 2) { return vec3f(cell.g); }
    if (u.debug_mode == 3) { return mix(vec3f(0.85, 0.8, 0.65), vec3f(0.15, 0.4, 0.15), cell.b); }
    if (u.debug_mode == 5) {
        // Each category's color, deepened, and fainter where the cell is weakly of it
        let c = textureLoad(cover_cells, vec2i(floor(p)), 0).rg;
        let category = i32(c.r * 255.0 + 0.5);
        if (category == 0) { return vec3f(0.85, 0.8, 0.65); }
        let color = textureLoad(cover_palette, vec2i(category, 0), 0).rgb;
        return mix(vec3f(0.85, 0.8, 0.65), color * color, 0.35 + 0.65 * c.g);
    }
    return mix(vec3f(0.8, 0.65, 0.4), vec3f(0.3, 0.5, 0.75), cell.a);
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    // Screen position in logical pixels, from the top left like the rest of the renderer
    let screen = frag.xy / u.pixel_density;
    let p = u.center + (screen - u.view_size * 0.5) / u.zoom;
    // Device pixels per cell: line widths and anti-aliasing are measured in these.
    let px = u.zoom * u.pixel_density;

    if (any(p < vec2f(0.0)) || any(p >= u.grid)) {
        return vec4f(u.paper.rgb * 0.72, 1.0);
    }

    var col: vec3f;
    if (u.debug_mode > 0) {
        col = debug_color(textureLoad(cells, vec2i(floor(p)), 0), p);
        // Cell edges, once cells are big enough to tell apart
        let g = fract(p);
        let edge = min(min(g.x, 1.0 - g.x), min(g.y, 1.0 - g.y)) * px;
        col = mix(col, vec3f(0.0), (1.0 - smoothstep(0.0, 1.0, edge)) * 0.3 * smoothstep(4.0, 8.0, px));
    } else {
        let cell = textureSampleLevel(cells, linear_sampler, p / u.grid, 0.0);
        // The coast wanders a little from the cells, as if drawn by hand.
        let d = textureSampleLevel(coast, linear_sampler, p / u.grid, 0.0).r + u.wobble * (fbm(p * 0.45 + 7.7) - 0.5) * 1.6;
        let land = smoothstep(-0.5 / px, 0.5 / px, d);
        col = paper_at(p, frag.xy);
        // Water deepens in color away from its shore, and its wash is strongest along the coast.
        let deep = clamp((-d - u.sea_depth_from) / max(u.sea_depth_full - u.sea_depth_from, 1e-3), 0.0, 1.0);
        let sea_color = mix(u.sea_shallow.rgb, u.sea_deep.rgb, deep);
        let sea = col * mix(vec3f(1.0), sea_color, u.sea_tint * (0.65 + 0.35 * exp(min(d, 0.0) / 5.0)));
        // What covers the land: each category's wash and ink pattern
        let cover = layer_at(cover_cells, cover_palette, p, u.cover_jitter);
        var ground = col * cover.tint;
        ground = mix(ground, u.ink.rgb, stipple_at(p, px, cover.density.x) * cover.ink.x);
        col = mix(sea, ground, land);

        // Rivers: a faint wash either side and a line that thins toward the hills, both stopping at the shore. The line
        // never grows past a third of a cell, so rivers fade out as the map zooms away.
        let r = river_distance(p) + u.wobble * (fbm(p * 0.6 + 3.3) - 0.5) * 0.5;
        col = mix(col, col * u.sea_shallow.rgb, u.sea_tint * 0.5 * (1.0 - smoothstep(0.0, 1.2, r)) * land);
        let river_half = min(u.river_width * 0.5 * u.pixel_density * mix(1.0, 0.4, smoothstep(0.2, 0.8, cell.g)), px / 6.0);
        col = mix(col, mix(u.ink.rgb, u.sea_shallow.rgb, 0.3), line_aa(r * px, river_half) * land);

        let width = u.coast_width * 0.5 * u.pixel_density * (0.8 + 0.4 * value_noise(p * 0.8));
        col = mix(col, u.ink.rgb, line_aa(abs(d) * px, width));
    }

    // The sheet darkens toward its edges.
    let m = min(p, u.grid - p);
    col *= mix(0.84, 1.0, smoothstep(0.0, 12.0, min(m.x, m.y)));
    return vec4f(col, 1.0);
}
`

// The window's size in physical pixels, or false when SDL cannot tell.
@(private = "file")
render_window_pixels :: proc(window: ^sdl.Window) -> (size: [2]u32, ok: bool) {
	width, height: i32
	if !sdl.GetWindowSizeInPixels(window, &width, &height) {
		return {}, false
	}
	return {u32(max(width, 0)), u32(max(height, 0))}, true
}
