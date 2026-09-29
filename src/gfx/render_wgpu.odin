package gfx

import "base:runtime"
import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

// How many render lists can be drawn in one frame: each gets its own part of the instance buffer, as every upload
// lands before any of the frame's drawing runs.
RENDER_LISTS_PER_FRAME :: 4

// A texture the render list can draw from, bound with its sampler
@(private = "file")
Image :: struct {
	texture:    wgpu.Texture,
	view:       wgpu.TextureView,
	bind_group: wgpu.BindGroup,
}

// A texture with the one view the shaders read it through
@(private = "file")
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

// The map shader's uniforms, laid out as the shader's Terrain struct
@(private = "file")
Terrain_Uniforms :: struct {
	grid, center, view_size:                        [2]f32,
	zoom, pixel_density:                            f32,
	paper, paper_stain, ink, sea_shallow, sea_deep: [4]f32,
	debug_mode:                                     i32,
	sea_tint, coast_width, wobble:                  f32,
	river_width, cover_jitter:                      f32,
	paper_stain_amount, sea_depth_from:             f32,
	sea_depth_full, road_width:                     f32,
	road_halo, arrow_width:                         f32,
	road_fill, arrow_fill:                          [4]f32,
	head_length, head_width:                        f32,
	_:                                              [2]f32,
}
#assert(size_of(Terrain_Uniforms) == 208)

Renderer :: struct {
	window:                              ^sdl.Window,
	// Whether presenting waits for the display's refresh
	vsync:                               bool,
	// Logical window dimensions, matching SDL mouse coordinates.
	view_size:                           [2]f32,
	// Physical pixels per logical pixel; zero is taken as one.
	pixel_density:                       f32,
	instance:                            wgpu.Instance,
	surface:                             wgpu.Surface,
	adapter:                             wgpu.Adapter,
	device:                              wgpu.Device,
	queue:                               wgpu.Queue,
	// Set by the device's error callback: anything the device reported since
	failed:                              bool,
	surface_format:                      wgpu.TextureFormat,
	surface_alpha:                       wgpu.CompositeAlphaMode,
	// The size the surface is configured at, in physical pixels; zero until it is
	surface_size:                        [2]u32,
	max_texture_size:                    int,
	// The frame being drawn: its target, and one pass recording everything
	frame_texture:                       wgpu.Texture,
	frame_view:                          wgpu.TextureView,
	frame_encoder:                       wgpu.CommandEncoder,
	frame_pass:                          wgpu.RenderPassEncoder,
	// Render lists drawn so far this frame
	frame_lists:                         int,
	// The render list pass: view size uniform, instances, and a bind group per texture
	list_pipeline:                       wgpu.RenderPipeline,
	list_view_layout, list_image_layout: wgpu.BindGroupLayout,
	list_view_buffer, list_instances:    wgpu.Buffer,
	list_view_group:                     wgpu.BindGroup,
	linear_sampler:                      wgpu.Sampler,
	white:                               Image,
	// Slot zero is never registered; untextured batches use white.
	images:                              [65536]Image,
	// The map pass
	terrain_pipeline:                    wgpu.RenderPipeline,
	terrain_layout:                      wgpu.BindGroupLayout,
	// Made again with the surface, as it reads the line field
	terrain_group:                       wgpu.BindGroup,
	terrain_uniforms:                    wgpu.Buffer,
	terrain_cells, terrain_coast:        Texture,
	cover_cells, cover_palette:          Texture,
	// The revisions the textures hold, once anything has been uploaded
	terrain_revision, cover_revision:    u32,
	terrain_uploaded, cover_uploaded:    bool,
	// The coast converted to half floats for upload, as its texture holds it
	coast_half:                          [RENDER_TERRAIN_CELLS]f16,
	// The highlights: per cell and surface, the area of that surface whose field the cell holds, and that field; and each
	// area's look
	highlight_cells:                     Texture,
	highlight_field:                     Texture,
	highlight_palette:                   Texture,
	// Per area, the revision the textures hold, and the bounds and surface its cells were taken up with
	highlight_revisions:                 [RENDER_HIGHLIGHT_AREAS]u32,
	highlight_bounds:                    [RENDER_HIGHLIGHT_AREAS]Render_Cell_Rect,
	highlight_surfaces:                  [RENDER_HIGHLIGHT_AREAS]Render_Highlight_Surface,
	// What the highlight textures hold, kept here to be uploaded a rectangle at a time
	highlight_owners:                    [RENDER_TERRAIN_CELLS][Render_Highlight_Surface]u8,
	highlight_fields:                    [RENDER_TERRAIN_CELLS][Render_Highlight_Surface]f16,
	// The lines pass: a pipeline for each kind of line, drawing into its own channel of the field, and each kind's
	// segments, with the revisions they hold once anything has been uploaded
	line_pipelines:                      [Render_Line_Kind]wgpu.RenderPipeline,
	line_layout:                         wgpu.BindGroupLayout,
	line_group:                          wgpu.BindGroup,
	line_segments:                       [Render_Line_Kind]wgpu.Buffer,
	line_revisions:                      [Render_Line_Kind]u32,
	lines_uploaded:                      [Render_Line_Kind]bool,
	// For each pixel of the frame, the distance to the nearest line of each kind, in cells, in a channel for each kind.
	// Made again with the surface, at its size.
	line_field:                          Texture,
}

// The binding's BlendOperation leaves out webgpu.h's Undefined, so each of its values is one below the native one, and
// .Min is taken for ReverseSubtract. This is the native Min.
@(private = "file")
BLEND_MIN :: wgpu.BlendOperation(4)

// The line field's distance where no line is near, in cells
@(private = "file")
LINE_FAR :: 1000

// The line field's format: a channel for each kind of line
@(private = "file")
LINE_FIELD_FORMAT :: wgpu.TextureFormat.RGBA16Float

#assert(len(Render_Line_Kind) <= 4, "the line field has a channel for each kind of line")

// The backend wgpu draws through: Metal on macOS, Vulkan elsewhere.
RENDER_BACKENDS ::
	wgpu.InstanceBackendFlags{.Metal} when ODIN_OS ==
	.Darwin else wgpu.InstanceBackendFlags{.Vulkan}

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
		&{
			featureLevel = .Core,
			powerPreference = .HighPerformance,
			compatibleSurface = renderer.surface,
		},
		{
			mode = .AllowProcessEvents,
			callback = on_adapter,
			userdata1 = renderer,
			userdata2 = &adapter_done,
		},
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
	on_error :: proc "c" (
		device: ^wgpu.Device,
		type: wgpu.ErrorType,
		message: string,
		userdata1, userdata2: rawptr,
	) {
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
		{
			mode = .AllowProcessEvents,
			callback = on_device,
			userdata1 = renderer,
			userdata2 = &device_done,
		},
	)
	for !device_done do wgpu.InstanceProcessEvents(renderer.instance)
	if renderer.device == nil do return false
	renderer.queue = wgpu.DeviceGetQueue(renderer.device)
	renderer.max_texture_size = int(limits.maxTextureDimension2D)

	// Colors are written as they are, with no conversion to sRGB, so a plain format.
	capabilities, capabilities_status := wgpu.SurfaceGetCapabilities(
		renderer.surface,
		renderer.adapter,
	)
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
	if !list_init(renderer) || !terrain_init(renderer) {
		return false
	}
	return !renderer.failed
}

render_destroy :: proc(renderer: ^Renderer) {
	image_release :: proc(image: Image) {
		if image.bind_group != nil do wgpu.BindGroupRelease(image.bind_group)
		if image.view != nil do wgpu.TextureViewRelease(image.view)
		if image.texture != nil do wgpu.TextureRelease(image.texture)
	}
	texture_release :: proc(texture: Texture) {
		if texture.view != nil do wgpu.TextureViewRelease(texture.view)
		if texture.texture != nil do wgpu.TextureRelease(texture.texture)
	}
	for image in renderer.images do image_release(image)
	image_release(renderer.white)
	texture_release(renderer.terrain_cells)
	texture_release(renderer.terrain_coast)
	texture_release(renderer.line_field)
	texture_release(renderer.cover_cells)
	texture_release(renderer.cover_palette)
	texture_release(renderer.highlight_cells)
	texture_release(renderer.highlight_field)
	texture_release(renderer.highlight_palette)
	if renderer.terrain_group != nil do wgpu.BindGroupRelease(renderer.terrain_group)
	if renderer.terrain_layout != nil do wgpu.BindGroupLayoutRelease(renderer.terrain_layout)
	if renderer.terrain_uniforms != nil do wgpu.BufferRelease(renderer.terrain_uniforms)
	if renderer.terrain_pipeline != nil do wgpu.RenderPipelineRelease(renderer.terrain_pipeline)
	for pipeline in renderer.line_pipelines do if pipeline != nil do wgpu.RenderPipelineRelease(pipeline)
	if renderer.line_group != nil do wgpu.BindGroupRelease(renderer.line_group)
	if renderer.line_layout != nil do wgpu.BindGroupLayoutRelease(renderer.line_layout)
	for buffer in renderer.line_segments do if buffer != nil do wgpu.BufferRelease(buffer)
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
	size, ok := window_pixels(renderer.window)
	if !ok {
		fmt.eprintf("Getting the window pixel size failed: %s\n", sdl.GetError())
		return false
	}
	if size.x == 0 || size.y == 0 {
		return false
	}
	if size != renderer.surface_size {
		surface_configure(renderer, size)
	}

	surface_texture := wgpu.SurfaceGetCurrentTexture(renderer.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	case .Timeout, .Outdated, .Lost:
		if surface_texture.texture != nil do wgpu.TextureRelease(surface_texture.texture)
		surface_configure(renderer, size)
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
	renderer.frame_pass = pass_begin(renderer, renderer.frame_view, .Clear, clear_color)
	renderer.frame_lists = 0
	return true
}

// Begins a pass of the frame's commands drawing into view: cleared to clear_color, or keeping what it holds.
@(private = "file")
pass_begin :: proc(
	renderer: ^Renderer,
	view: wgpu.TextureView,
	load: wgpu.LoadOp,
	clear_color: [4]f32 = {},
) -> wgpu.RenderPassEncoder {
	return wgpu.CommandEncoderBeginRenderPass(
		renderer.frame_encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = view,
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
				loadOp = load,
				storeOp = .Store,
				clearValue = {
					f64(clear_color.r),
					f64(clear_color.g),
					f64(clear_color.b),
					f64(clear_color.a),
				},
			},
		},
	)
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
	renderer.frame_pass, renderer.frame_encoder, renderer.frame_view, renderer.frame_texture =
		nil, nil, nil, nil
}

@(private = "file")
surface_configure :: proc(renderer: ^Renderer, size: [2]u32) {
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
	line_field_create(renderer, size)
}

// Makes the line field at size, and the map pass's bind group, which reads it.
@(private = "file")
line_field_create :: proc(renderer: ^Renderer, size: [2]u32) {
	if renderer.terrain_group != nil do wgpu.BindGroupRelease(renderer.terrain_group)
	if renderer.line_field.view != nil do wgpu.TextureViewRelease(renderer.line_field.view)
	if renderer.line_field.texture != nil do wgpu.TextureRelease(renderer.line_field.texture)
	renderer.line_field.texture = wgpu.DeviceCreateTexture(
		renderer.device,
		&{
			usage = {.RenderAttachment, .TextureBinding},
			dimension = ._2D,
			size = {size.x, size.y, 1},
			format = LINE_FIELD_FORMAT,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	renderer.line_field.view = wgpu.TextureCreateView(renderer.line_field.texture, nil)

	group_entries := [10]wgpu.BindGroupEntry {
		{binding = 0, buffer = renderer.terrain_uniforms, size = size_of(Terrain_Uniforms)},
		{binding = 1, textureView = renderer.terrain_cells.view},
		{binding = 2, textureView = renderer.terrain_coast.view},
		{binding = 3, textureView = renderer.line_field.view},
		{binding = 4, textureView = renderer.cover_cells.view},
		{binding = 5, textureView = renderer.cover_palette.view},
		{binding = 6, sampler = renderer.linear_sampler},
		{binding = 7, textureView = renderer.highlight_cells.view},
		{binding = 8, textureView = renderer.highlight_field.view},
		{binding = 9, textureView = renderer.highlight_palette.view},
	}
	renderer.terrain_group = wgpu.DeviceCreateBindGroup(
		renderer.device,
		&{
			layout = renderer.terrain_layout,
			entryCount = len(group_entries),
			entries = &group_entries[0],
		},
	)
}

// Draws the map over the whole view. Cells, coast, cover and each kind of line are uploaded again only when their
// revision has changed. The lines are drawn first, in a pass of their own, into the line field the map reads.
render_terrain :: proc(renderer: ^Renderer, terrain: ^Render_Terrain) {
	if renderer.view_size.x <= 0 || renderer.view_size.y <= 0 || terrain.zoom <= 0 {
		return
	}

	if !renderer.terrain_uploaded || renderer.terrain_revision != terrain.revision {
		for coast, i in terrain.coast {
			renderer.coast_half[i] = f16(coast)
		}
		texture_write(renderer, renderer.terrain_cells.texture, raw_data(terrain.cells[:]), 4)
		texture_write(
			renderer,
			renderer.terrain_coast.texture,
			raw_data(renderer.coast_half[:]),
			2,
		)
		renderer.terrain_revision = terrain.revision
		renderer.terrain_uploaded = true
	}

	for &lines, kind in terrain.lines {
		if renderer.lines_uploaded[kind] && renderer.line_revisions[kind] == lines.revision do continue
		if len(lines.segments) > 0 {
			wgpu.QueueWriteBuffer(
				renderer.queue,
				renderer.line_segments[kind],
				0,
				raw_data(lines.segments[:]),
				uint(len(lines.segments) * size_of(Render_Segment)),
			)
		}
		renderer.line_revisions[kind] = lines.revision
		renderer.lines_uploaded[kind] = true
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
		texture_write(renderer, renderer.cover_cells.texture, raw_data(cover.cells[:]), 2)
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

	// Each highlight area whose cells changed, taken up again around where it was and is
	highlights := &terrain.highlights
	for &area, index in highlights.areas {
		if renderer.highlight_revisions[index] == area.revision do continue
		rect := highlight_take_up(renderer, terrain, u8(index))
		texture_write_rect(renderer, renderer.highlight_cells.texture, raw_data(renderer.highlight_owners[:]), 2, rect)
		texture_write_rect(renderer, renderer.highlight_field.texture, raw_data(renderer.highlight_fields[:]), 4, rect)
		renderer.highlight_revisions[index] = area.revision
		renderer.highlight_bounds[index] = area.bounds
	}
	// The looks, every frame, as they are small: color and border in row 0, thickness and inside in row 1
	highlight_palette: [2][RENDER_HIGHLIGHT_AREAS][4]f32
	for area, i in highlights.areas {
		highlight_palette[0][i] = {area.color.r, area.color.g, area.color.b, area.border}
		highlight_palette[1][i] = {area.thickness, area.inside, 0, 0}
	}
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = renderer.highlight_palette.texture, aspect = .All},
		&highlight_palette,
		size_of(highlight_palette),
		&{bytesPerRow = RENDER_HIGHLIGHT_AREAS * size_of([4]f32), rowsPerImage = 2},
		&{RENDER_HIGHLIGHT_AREAS, 2, 1},
	)

	style := &terrain.style
	uniforms := Terrain_Uniforms {
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
		road_width         = style.road_width,
		road_halo          = style.road_halo,
		road_fill          = style.road_fill,
		arrow_width        = style.arrow_width,
		arrow_fill         = style.arrow_fill,
		head_length        = style.head_length,
		head_width         = style.head_width,
		cover_jitter       = cover.jitter,
		paper_stain_amount = style.paper_stain_amount,
		sea_depth_from     = style.sea_depth_from,
		sea_depth_full     = style.sea_depth_full,
	}
	wgpu.QueueWriteBuffer(
		renderer.queue,
		renderer.terrain_uniforms,
		0,
		&uniforms,
		size_of(uniforms),
	)

	// The frame's pass ends for the lines' own, and begins again keeping what it holds.
	wgpu.RenderPassEncoderEnd(renderer.frame_pass)
	wgpu.RenderPassEncoderRelease(renderer.frame_pass)
	lines_pass := pass_begin(
		renderer,
		renderer.line_field.view,
		.Clear,
		{LINE_FAR, LINE_FAR, LINE_FAR, LINE_FAR},
	)
	for &lines, kind in terrain.lines {
		if len(lines.segments) == 0 do continue
		wgpu.RenderPassEncoderSetPipeline(lines_pass, renderer.line_pipelines[kind])
		wgpu.RenderPassEncoderSetBindGroup(lines_pass, 0, renderer.line_group)
		wgpu.RenderPassEncoderSetVertexBuffer(
			lines_pass,
			0,
			renderer.line_segments[kind],
			0,
			u64(len(lines.segments) * size_of(Render_Segment)),
		)
		wgpu.RenderPassEncoderDraw(lines_pass, 6, u32(len(lines.segments)), 0, 0)
	}
	wgpu.RenderPassEncoderEnd(lines_pass)
	wgpu.RenderPassEncoderRelease(lines_pass)
	renderer.frame_pass = pass_begin(renderer, renderer.frame_view, .Load)

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
	assert(
		renderer.frame_lists < RENDER_LISTS_PER_FRAME,
		"More render lists in one frame than RENDER_LISTS_PER_FRAME",
	)
	offset := u64(renderer.frame_lists * size_of(list.instances))
	renderer.frame_lists += 1
	wgpu.QueueWriteBuffer(
		renderer.queue,
		renderer.list_instances,
		offset,
		raw_data(list.instances[:]),
		size_of(list.instances),
	)
	view := [4]f32{renderer.view_size.x, renderer.view_size.y, 0, 0}
	wgpu.QueueWriteBuffer(renderer.queue, renderer.list_view_buffer, 0, &view, size_of(view))

	pass := renderer.frame_pass
	wgpu.RenderPassEncoderSetPipeline(pass, renderer.list_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, renderer.list_view_group)
	wgpu.RenderPassEncoderSetVertexBuffer(
		pass,
		0,
		renderer.list_instances,
		offset,
		size_of(list.instances),
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
	renderer.images[id] = image_create(renderer, bitmap)
}

@(private = "file")
image_create :: proc(renderer: ^Renderer, bitmap: Bitmap) -> (image: Image) {
	size := [2]u32{u32(bitmap.width), u32(bitmap.height)}
	texture := texture_create(renderer, .RGBA8Unorm, size)
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
texture_create :: proc(
	renderer: ^Renderer,
	format: wgpu.TextureFormat,
	size: [2]u32,
) -> (
	texture: Texture,
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
texture_write :: proc(renderer: ^Renderer, texture: wgpu.Texture, data: rawptr, texel_size: u32) {
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = texture, aspect = .All},
		data,
		uint(RENDER_TERRAIN_CELLS * texel_size),
		&{bytesPerRow = RENDER_TERRAIN_WIDTH * texel_size, rowsPerImage = RENDER_TERRAIN_HEIGHT},
		&{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT, 1},
	)
}

// Uploads a rectangle of a terrain-sized texture from terrain-sized data, texel_size bytes per cell. An empty rectangle
// uploads nothing.
@(private = "file")
texture_write_rect :: proc(
	renderer: ^Renderer,
	texture: wgpu.Texture,
	data: rawptr,
	texel_size: u32,
	rect: Render_Cell_Rect,
) {
	if cell_rect_empty(rect) do return
	size := rect.max - rect.min
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = texture, origin = {u32(rect.min.x), u32(rect.min.y), 0}, aspect = .All},
		data,
		uint(RENDER_TERRAIN_CELLS * texel_size),
		&{
			offset = u64((int(rect.min.y) * RENDER_TERRAIN_WIDTH + int(rect.min.x)) * int(texel_size)),
			bytesPerRow = RENDER_TERRAIN_WIDTH * texel_size,
			rowsPerImage = u32(size.y),
		},
		&{u32(size.x), u32(size.y), 1},
	)
}

// How far, in cells, an area's field is smoothed over, as the standard deviation of the blur
@(private = "file")
HIGHLIGHT_SMOOTHING :: 1.5
// The blur's reach either side, in cells
@(private = "file")
HIGHLIGHT_BLUR_REACH :: 4
// How far around an area's cells its field is taken up, in cells: past the blur's reach, and the cell beyond
@(private = "file")
HIGHLIGHT_MARGIN :: HIGHLIGHT_BLUR_REACH + 2
// The farthest in or out an area's field goes, in cells
@(private = "file")
HIGHLIGHT_FIELD_MAX :: 64

// Takes up a highlight area's cells, around where they were and where they are, for its surface, and for the surface it
// was taken up for before if that was the other. Returns the rectangle of the terrain gone over.
@(private = "file")
highlight_take_up :: proc(renderer: ^Renderer, terrain: ^Render_Terrain, area: u8) -> Render_Cell_Rect {
	look := &terrain.highlights.areas[area]
	around := cell_rect_union(renderer.highlight_bounds[area], look.bounds)
	if area == 0 || cell_rect_empty(around) do return {}
	around = {around.min - HIGHLIGHT_MARGIN, around.max + HIGHLIGHT_MARGIN}
	if before := renderer.highlight_surfaces[area]; before != look.surface {
		highlight_take_up_on(renderer, terrain, area, before, around, false)
	}
	highlight_take_up_on(renderer, terrain, area, look.surface, around, true)
	renderer.highlight_surfaces[area] = look.surface
	return cell_rect_clip(around)
}

// Takes up a highlight area over a rectangle for the areas of a surface, or takes it away from them unless present. The
// area's field is its signed distance, in cells, from the middles of its cells, less half a cell, positive inside; cells
// of the other surface are neither in it nor out of it, and are as far in as they are nearer its cells than the cells
// out of it, halved. The field is then blurred, so its edge runs smooth across the steps of the cells. Each cell of the
// area holds the area's field; each other cell holds the field of whichever area of the surface it is least outside,
// unless it is in another area of the surface. Cells off the terrain count as out.
@(private = "file")
highlight_take_up_on :: proc(
	renderer: ^Renderer,
	terrain: ^Render_Terrain,
	area: u8,
	surface: Render_Highlight_Surface,
	around: Render_Cell_Rect,
	present: bool,
) {
	highlights := &terrain.highlights
	clipped := cell_rect_clip(around)
	if !present || cell_rect_empty(highlights.areas[area].bounds) {
		for y in clipped.min.y ..< clipped.max.y do for x in clipped.min.x ..< clipped.max.x {
			index := int(y) * RENDER_TERRAIN_WIDTH + int(x)
			if renderer.highlight_owners[index][surface] == area {
				renderer.highlight_owners[index][surface] = 0
				renderer.highlight_fields[index][surface] = 0
			}
		}
		return
	}

	// The cell is on the terrain and of the surface; land is surface 0 in the terrain's cells
	on_surface :: proc(terrain: ^Render_Terrain, surface: Render_Highlight_Surface, cell: [2]i32) -> bool {
		if cell.x < 0 || cell.y < 0 || cell.x >= RENDER_TERRAIN_WIDTH || cell.y >= RENDER_TERRAIN_HEIGHT do return false
		land := terrain.cells[int(cell.y) * RENDER_TERRAIN_WIDTH + int(cell.x)].r == 0
		return land == (surface == .Land)
	}
	on_terrain :: proc(cell: [2]i32) -> bool {
		return cell.x >= 0 && cell.y >= 0 && cell.x < RENDER_TERRAIN_WIDTH && cell.y < RENDER_TERRAIN_HEIGHT
	}
	in_area :: proc(terrain: ^Render_Terrain, area: u8, surface: Render_Highlight_Surface, cell: [2]i32) -> bool {
		if !on_surface(terrain, surface, cell) do return false
		return terrain.highlights.cells[int(cell.y) * RENDER_TERRAIN_WIDTH + int(cell.x)] == area
	}

	// Squared distances from each cell to the nearest out of the area, and to the nearest in it, exactly
	FAR :: 1e12
	origin := around.min
	size := [2]int{int(around.max.x - around.min.x), int(around.max.y - around.min.y)}
	to_out := make([]f64, size.x * size.y, context.temp_allocator)
	to_in := make([]f64, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y do for x in 0 ..< size.x {
		cell := origin + {i32(x), i32(y)}
		inside := in_area(terrain, area, surface, cell)
		out := !inside && (on_surface(terrain, surface, cell) || !on_terrain(cell))
		to_out[y * size.x + x] = out ? 0 : FAR
		to_in[y * size.x + x] = inside ? 0 : FAR
	}
	distance_transform_2d(to_out, size)
	distance_transform_2d(to_in, size)
	field := make([]f32, size.x * size.y, context.temp_allocator)
	for &value, i in field {
		out_by, in_by := f32(math.sqrt(to_out[i])), f32(math.sqrt(to_in[i]))
		switch {
		case in_by == 0:
			value = out_by - 0.5
		case out_by == 0:
			value = 0.5 - in_by
		case:
			value = (out_by - in_by) / 2
		}
		value = clamp(value, -HIGHLIGHT_FIELD_MAX, HIGHLIGHT_FIELD_MAX)
	}
	blur(field, size)

	for y in clipped.min.y ..< clipped.max.y do for x in clipped.min.x ..< clipped.max.x {
		index := int(y) * RENDER_TERRAIN_WIDTH + int(x)
		value := field[int(y - origin.y) * size.x + int(x - origin.x)]
		// Another area's cell holds that area's field, which its own take up writes
		member := highlights.cells[index]
		if member != 0 && member != area && highlights.areas[member].surface == surface {
			if on_surface(terrain, surface, {x, y}) do continue
		}
		owner := &renderer.highlight_owners[index][surface]
		held := &renderer.highlight_fields[index][surface]
		if member == area || owner^ == area || owner^ == 0 || value > f32(held^) {
			owner^ = area
			held^ = f16(value)
		}
	}
}

// Replaces squared distances over a grid of a size, 0 at the cells measured to, with the squared distance from each
// cell to the nearest of those, a line at a time along each axis
@(private = "file")
distance_transform_2d :: proc(squared: []f64, size: [2]int) {
	longest := max(size.x, size.y)
	line := make([]f64, longest, context.temp_allocator)
	parabolas := make([]int, longest, context.temp_allocator)
	bounds := make([]f64, longest + 1, context.temp_allocator)
	for x in 0 ..< size.x {
		for y in 0 ..< size.y do line[y] = squared[y * size.x + x]
		distance_transform(line[:size.y], parabolas, bounds)
		for y in 0 ..< size.y do squared[y * size.x + x] = line[y]
	}
	for y in 0 ..< size.y {
		distance_transform(squared[y * size.x:][:size.x], parabolas, bounds)
	}
}

// Blurs values over a grid of a size, by HIGHLIGHT_SMOOTHING, a line at a time along each axis. Past the grid's edges
// the edge values go on.
@(private = "file")
blur :: proc(values: []f32, size: [2]int) {
	weights: [2 * HIGHLIGHT_BLUR_REACH + 1]f32
	total: f32
	for &weight, i in weights {
		offset := f32(i - HIGHLIGHT_BLUR_REACH)
		weight = math.exp(-offset * offset / (2 * HIGHLIGHT_SMOOTHING * HIGHLIGHT_SMOOTHING))
		total += weight
	}
	for &weight in weights do weight /= total
	// Where in values the value at a place along a line of an axis is, the line being across others of it
	at :: proc(axis, along, across: int, size: [2]int) -> int {
		return axis == 0 ? across * size.x + along : along * size.x + across
	}
	line := make([]f32, max(size.x, size.y), context.temp_allocator)
	for axis in 0 ..< 2 {
		length, lines := size[axis], size[1 - axis]
		for across in 0 ..< lines {
			for along in 0 ..< length do line[along] = values[at(axis, along, across, size)]
			for along in 0 ..< length {
				sum: f32
				for weight, i in weights {
					sum += weight * line[clamp(along + i - HIGHLIGHT_BLUR_REACH, 0, length - 1)]
				}
				values[at(axis, along, across, size)] = sum
			}
		}
	}
}

// Replaces each squared distance f[q] along a line with the least of f[p] + (q - p)^2 over the line: the squared
// distance to the nearest point, with f the squared distance already along the other axis. The lower envelope of
// parabolas, as Felzenszwalb and Huttenlocher give it; parabolas and bounds are scratch, the length of f and one more.
@(private = "file")
distance_transform :: proc(f: []f64, parabolas: []int, bounds: []f64) {
	n := len(f)
	if n == 0 do return
	result := make([]f64, n, context.temp_allocator)
	k := 0
	parabolas[0] = 0
	bounds[0], bounds[1] = math.inf_f64(-1), math.inf_f64(1)
	// Where the parabola from q overtakes the one from p
	crossing :: proc(f: []f64, q, p: int) -> f64 {
		return ((f[q] + f64(q * q)) - (f[p] + f64(p * p))) / f64(2 * q - 2 * p)
	}
	for q in 1 ..< n {
		s := crossing(f, q, parabolas[k])
		// bounds[0] is -infinity, so this stops at the first parabola at the latest
		for s <= bounds[k] {
			k -= 1
			s = crossing(f, q, parabolas[k])
		}
		k += 1
		parabolas[k] = q
		bounds[k], bounds[k + 1] = s, math.inf_f64(1)
	}
	k = 0
	for q in 0 ..< n {
		for bounds[k + 1] < f64(q) do k += 1
		p := parabolas[k]
		result[q] = f64((q - p) * (q - p)) + f[p]
	}
	copy(f, result)
}

@(private = "file")
shader_create :: proc(renderer: ^Renderer, source: string) -> wgpu.ShaderModule {
	return wgpu.DeviceCreateShaderModule(
		renderer.device,
		&{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = source}},
	)
}

// Makes the render list pipeline, its buffers, and the white texture untextured batches bind.
@(private = "file")
list_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	view_entry := wgpu.BindGroupLayoutEntry {
		binding = 0,
		visibility = {.Vertex},
		buffer = {type = .Uniform, minBindingSize = 16},
	}
	renderer.list_view_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = 1, entries = &view_entry},
	)
	image_entries := [2]wgpu.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	renderer.list_image_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = len(image_entries), entries = &image_entries[0]},
	)

	renderer.list_view_buffer = wgpu.DeviceCreateBuffer(
		device,
		&{usage = {.Uniform, .CopyDst}, size = 16},
	)
	renderer.list_instances = wgpu.DeviceCreateBuffer(
		device,
		&{
			usage = {.Vertex, .CopyDst},
			size = RENDER_LISTS_PER_FRAME * size_of(Render_List{}.instances),
		},
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
	renderer.white = image_create(renderer, {pixels = white[:], width = 1, height = 1})

	module := shader_create(renderer, LIST_SOURCE)
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
		{
			format = .Float32x4,
			offset = u64(offset_of(Render_Instance, color)) + 16,
			shaderLocation = 4,
		},
		{
			format = .Float32x4,
			offset = u64(offset_of(Render_Instance, color)) + 32,
			shaderLocation = 5,
		},
		{
			format = .Float32x4,
			offset = u64(offset_of(Render_Instance, color)) + 48,
			shaderLocation = 6,
		},
		{format = .Float32x4, offset = u64(offset_of(Render_Instance, radii)), shaderLocation = 7},
		{
			format = .Float32,
			offset = u64(offset_of(Render_Instance, softness)),
			shaderLocation = 8,
		},
		{
			format = .Float32,
			offset = u64(offset_of(Render_Instance, thickness)),
			shaderLocation = 9,
		},
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
			fragment = &{
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	return renderer.list_pipeline != nil && !renderer.failed
}

// Makes the map pipeline and its textures, with storage for the largest terrain and nothing in them yet.
@(private = "file")
terrain_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	// Cells and coast are filtered between cells: that makes the coast smooth and the washes soft. Everything else is
	// read cell by cell and blended in the shader.
	renderer.terrain_cells = texture_create(
		renderer,
		.RGBA8Unorm,
		{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
	)
	renderer.terrain_coast = texture_create(
		renderer,
		.R16Float,
		{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
	)
	renderer.cover_cells = texture_create(
		renderer,
		.RG8Unorm,
		{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
	)
	renderer.cover_palette = texture_create(renderer, .RGBA8Unorm, {RENDER_LAYER_CATEGORIES, 2})
	renderer.highlight_cells = texture_create(
		renderer,
		.RG8Unorm,
		{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
	)
	renderer.highlight_field = texture_create(
		renderer,
		.RG16Float,
		{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
	)
	renderer.highlight_palette = texture_create(
		renderer,
		.RGBA32Float,
		{RENDER_HIGHLIGHT_AREAS, 2},
	)
	renderer.terrain_uniforms = wgpu.DeviceCreateBuffer(
		device,
		&{usage = {.Uniform, .CopyDst}, size = size_of(Terrain_Uniforms)},
	)

	texture_entry :: proc(
		binding: u32,
		sample: wgpu.TextureSampleType,
	) -> wgpu.BindGroupLayoutEntry {
		return {
			binding = binding,
			visibility = {.Fragment},
			texture = {sampleType = sample, viewDimension = ._2D},
		}
	}
	layout_entries := [10]wgpu.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			buffer = {type = .Uniform, minBindingSize = size_of(Terrain_Uniforms)},
		},
		texture_entry(1, .Float),
		texture_entry(2, .Float),
		texture_entry(3, .Float),
		texture_entry(4, .Float),
		texture_entry(5, .Float),
		{binding = 6, visibility = {.Fragment}, sampler = {type = .Filtering}},
		texture_entry(7, .Float),
		texture_entry(8, .Float),
		texture_entry(9, .UnfilterableFloat),
	}
	renderer.terrain_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = len(layout_entries), entries = &layout_entries[0]},
	)
	module := shader_create(renderer, MAP_SOURCE)
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
			fragment = &{
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	return lines_init(renderer) && renderer.terrain_pipeline != nil && !renderer.failed
}

// Makes the lines pass: its pipelines, and storage for the most segments of each kind of line.
@(private = "file")
lines_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	for &buffer in renderer.line_segments {
		buffer = wgpu.DeviceCreateBuffer(
			device,
			&{
				usage = {.Vertex, .CopyDst},
				size = RENDER_LINE_SEGMENTS_MAX * size_of(Render_Segment),
			},
		)
	}

	// The lines read the map's uniforms, for the view and the size of heads.
	entry := wgpu.BindGroupLayoutEntry {
		binding = 0,
		visibility = {.Vertex, .Fragment},
		buffer = {type = .Uniform, minBindingSize = size_of(Terrain_Uniforms)},
	}
	renderer.line_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = 1, entries = &entry},
	)
	group_entry := wgpu.BindGroupEntry {
		binding = 0,
		buffer  = renderer.terrain_uniforms,
		size    = size_of(Terrain_Uniforms),
	}
	renderer.line_group = wgpu.DeviceCreateBindGroup(
		device,
		&{layout = renderer.line_layout, entryCount = 1, entries = &group_entry},
	)

	module := shader_create(renderer, LINES_SOURCE)
	defer wgpu.ShaderModuleRelease(module)
	pipeline_layout := wgpu.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &renderer.line_layout},
	)
	defer wgpu.PipelineLayoutRelease(pipeline_layout)
	attributes := [3]wgpu.VertexAttribute {
		{format = .Float32x2, offset = u64(offset_of(Render_Segment, start)), shaderLocation = 0},
		{format = .Float32x2, offset = u64(offset_of(Render_Segment, end)), shaderLocation = 1},
		{format = .Uint32, offset = u64(offset_of(Render_Segment, head)), shaderLocation = 2},
	}
	buffer := wgpu.VertexBufferLayout {
		stepMode       = .Instance,
		arrayStride    = size_of(Render_Segment),
		attributeCount = len(attributes),
		attributes     = &attributes[0],
	}
	// Where quads overlap, the field keeps the nearest distance.
	nearest := wgpu.BlendState {
		color = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
		alpha = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
	}
	for &pipeline, kind in renderer.line_pipelines {
		target := wgpu.ColorTargetState {
			format    = LINE_FIELD_FORMAT,
			blend     = &nearest,
			writeMask = {wgpu.ColorWriteMask(kind)},
		}
		pipeline = wgpu.DeviceCreateRenderPipeline(
			device,
			&{
				layout = pipeline_layout,
				vertex = {
					module = module,
					entryPoint = "vs_main",
					bufferCount = 1,
					buffers = &buffer,
				},
				primitive = {topology = .TriangleList},
				multisample = {count = 1, mask = max(u32)},
				fragment = &{
					module = module,
					entryPoint = "fs_main",
					targetCount = 1,
					targets = &target,
				},
			},
		)
		if pipeline == nil do return false
	}
	return true
}

// The render list shader
@(private = "file")
LIST_SOURCE :: `
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

// The map shaders' uniforms, laid out as Terrain_Uniforms
@(private = "file")
TERRAIN_UNIFORMS_SOURCE :: `
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
    road_width: f32,
    road_halo: f32,
    arrow_width: f32,
    road_fill: vec4f,
    arrow_fill: vec4f,
    head_length: f32,
    head_width: f32,
}
`

// The lines pass: each segment of a kind of line drawn as a quad around it, reaching as far as the map draws anything
// from a line, writing its distance, in cells, into that kind's channel of the line field. A segment that ends in a head
// also writes the signed distance to the head's triangle, negative inside, and reaches far enough to take it in.
@(private = "file")
LINES_SOURCE ::
	TERRAIN_UNIFORMS_SOURCE +
	`
@group(0) @binding(0) var<uniform> u: Terrain;

struct Varyings {
    @builtin(position) position: vec4f,
    // In cells
    @location(0) p: vec2f,
    @location(1) @interpolate(flat) start: vec2f,
    @location(2) @interpolate(flat) end: vec2f,
    @location(3) @interpolate(flat) head: u32,
}

// The direction from start to end, or across the map when they meet
fn direction(start: vec2f, end: vec2f) -> vec2f {
    let length = distance(start, end);
    return select(vec2f(1.0, 0.0), (end - start) / length, length > 1e-6);
}

@vertex
fn vs_main(
    @builtin(vertex_index) vertex: u32,
    @location(0) start: vec2f,
    @location(1) end: vec2f,
    @location(2) head: u32,
) -> Varyings {
    // Along the segment from 0 at the start to 1 at the end, and across it from -1 to 1
    var corners = array<vec2f, 6>(
        vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
        vec2f(0.0, -1.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));
    let corner = corners[vertex];
    let along = direction(start, end);
    let across = vec2f(-along.y, along.x);
    // Two cells, for the rivers' wash and the wander, and room for the widest road and its halo, and for a head
    var reach = 2.0 + 24.0 / u.zoom;
    if (head != 0u) { reach += (u.head_length + u.head_width * 0.5) / u.zoom; }
    let p = mix(start - along * reach, end + along * reach, corner.x) + across * reach * corner.y;
    let screen = (p - u.center) * u.zoom + u.view_size * 0.5;
    var out: Varyings;
    out.position = vec4f(screen / u.view_size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    out.p = p;
    out.start = start;
    out.end = end;
    out.head = head;
    return out;
}

// Signed distance from p to the triangle of a head, in cells, negative inside: its tip at tip, pointing on from start.
fn head_distance(p: vec2f, start: vec2f, tip: vec2f) -> f32 {
    let along = direction(start, tip);
    // p with the tip at the origin, back along the head in y and across it in x, folded onto one side; size is half
    // the head's width and its length
    let q = vec2f(abs(dot(p - tip, vec2f(-along.y, along.x))), dot(tip - p, along));
    let size = vec2f(u.head_width * 0.5, u.head_length) / u.zoom;
    // The nearest points on the slanted side and on the back, and on which side of each q lies
    let side = q - size * clamp(dot(q, size) / dot(size, size), 0.0, 1.0);
    let back = q - size * vec2f(clamp(q.x / size.x, 0.0, 1.0), 1.0);
    let d = min(vec2f(dot(side, side), q.y * size.x - q.x * size.y), vec2f(dot(back, back), size.y - q.y));
    return -sqrt(d.x) * sign(d.y);
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4f {
    let ab = in.end - in.start;
    let t = clamp(dot(in.p - in.start, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    var d = distance(in.p, in.start + ab * t);
    if (in.head != 0u) { d = min(d, head_distance(in.p, in.start, in.end)); }
    return vec4f(d, d, d, d);
}
`

// The map pass: one triangle covering the view, drawn before the render lists.
// Positions are in cells: the world is grid cells wide and tall, with cell (0, 0) at the top left.
// cells holds the terrain as the rules see it, one texel per cell: surface, elevation, trees, moisture. textureLoad reads
// a cell exactly; sampling blends neighbouring cells.
// coast holds the signed distance to the coast in cells, positive on land, blended between cells.
// lines is the line field: for each pixel of the view, the distance to the nearest line of each kind, in cells, in a
// channel for each kind.
// cover_cells and cover_palette are the cover layer: see layer_at.
// highlight_cells, highlight_field and highlight_palette are the highlights: see highlights_over.
@(private = "file")
MAP_SOURCE ::
	TERRAIN_UNIFORMS_SOURCE +
	`
@group(0) @binding(0) var<uniform> u: Terrain;
@group(0) @binding(1) var cells: texture_2d<f32>;
@group(0) @binding(2) var coast: texture_2d<f32>;
@group(0) @binding(3) var lines: texture_2d<f32>;
@group(0) @binding(4) var cover_cells: texture_2d<f32>;
@group(0) @binding(5) var cover_palette: texture_2d<f32>;
@group(0) @binding(6) var linear_sampler: sampler;
@group(0) @binding(7) var highlight_cells: texture_2d<f32>;
@group(0) @binding(8) var highlight_field: texture_2d<f32>;
@group(0) @binding(9) var highlight_palette: texture_2d<f32>;

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
// p moved by up to amount cells either way along each axis, in a direction that wanders smoothly over the map: a line
// looked up there wanders as if drawn by hand, keeping its width.
fn wander(p: vec2f, amount: f32, seed: f32) -> vec2f {
    return p + amount * (vec2f(fbm(p * 0.6 + seed), fbm(p * 0.6 + seed + 5.2)) - 0.5);
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

// The kinds of line, as Render_Line_Kind numbers them
const RIVER = 0;
const ROAD = 1;
const ARROW = 2;

// Distance from p to the nearest line of a kind, in cells, negative inside a head. It is read from the line field where
// p shows in the view, blended between pixels.
fn line_distance(p: vec2f, kind: i32) -> f32 {
    let pixel = ((p - u.center) * u.zoom + u.view_size * 0.5) * u.pixel_density;
    return textureSampleLevel(lines, linear_sampler, pixel / vec2f(textureDimensions(lines)), 0.0)[kind];
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

// How far a cell's middle is in from the edge of a highlight area of a surface (0 land, 1 water), in cells, negative
// outside it. highlight_cells holds, per cell and surface, the area of that surface whose field the cell holds, 0 for
// none; highlight_field holds that field. A cell is at least as far outside any other area as it is from the edge of
// the one whose field it holds.
fn highlight_field_at(cell: vec2i, area: i32, surface: i32) -> f32 {
    let at = clamp(cell, vec2i(0), vec2i(u.grid) - 1);
    let owner = i32(textureLoad(highlight_cells, at, 0)[surface] * 255.0 + 0.5);
    let value = textureLoad(highlight_field, at, 0)[surface];
    if (owner == area) { return value; }
    return -abs(value);
}

// The highlights over col at p, d being the signed distance to the coast there, positive on land, and px device pixels
// per cell. Each area's depth is its field, from the fields of the areas the four cells around p hold, blended; a land
// area's is never past the coast, nor a water area's short of it. Each area is washed over as far as its depth reaches,
// fading in over a device pixel across its edge: the map multiplied toward its color, as strongly as its border at its
// edge, easing to its inside at its thickness in from it. Of any two areas, one's depth is never more than the other's
// is short of the edge, so where they meet one fades in as the other fades out, and they never overlap.
// highlight_palette holds each area's color and border in row 0, and its thickness and inside in row 1.
fn highlights_over(col: vec3f, p: vec2f, d: f32, px: f32) -> vec3f {
    let q = p - 0.5;
    let base = vec2i(floor(q));
    let f = q - floor(q);
    var tint = vec3f(0.0);
    var covered = 0.0;
    for (var surface = 0; surface < 2; surface++) {
        let shore = select(-d, d, surface == 0);
        var seen = vec4i(0);
        for (var k = 0; k < 4; k++) {
            let at = clamp(base + vec2i(k & 1, k >> 1u), vec2i(0), vec2i(u.grid) - 1);
            let area = i32(textureLoad(highlight_cells, at, 0)[surface] * 255.0 + 0.5);
            if (area == 0 || any(seen == vec4i(area))) { continue; }
            seen[k] = area;
            var field = 0.0;
            for (var j = 0; j < 4; j++) {
                let corner = vec2i(j & 1, j >> 1u);
                let weight = mix(1.0 - f.x, f.x, f32(corner.x)) * mix(1.0 - f.y, f.y, f32(corner.y));
                field += weight * highlight_field_at(base + corner, area, surface);
            }
            let depth = min(field, shore);
            let coverage = smoothstep(-0.5, 0.5, depth * px);
            if (coverage <= 0.0) { continue; }
            let look = textureLoad(highlight_palette, vec2i(area, 0), 0);
            let fade = textureLoad(highlight_palette, vec2i(area, 1), 0);
            let strength = mix(look.a, fade.y, smoothstep(0.0, max(fade.x, 1e-3), depth));
            tint += coverage * mix(vec3f(1.0), look.rgb, strength);
            covered += coverage;
        }
    }
    // Where three areas meet, their fades can add up to more than the whole
    if (covered > 1.0) {
        tint /= covered;
        covered = 1.0;
    }
    return col * (tint + (1.0 - covered));
}

fn debug_color(cell: vec4f, p: vec2f) -> vec3f {
    // Land, lake, sea
    let surface = i32(cell.r * 2.0 + 0.5);
    let water = surface >= 1;
    if (u.debug_mode == 1) {
        if (surface == 1) { return vec3f(0.35, 0.6, 0.85); }
        if (surface == 2) { return vec3f(0.25, 0.45, 0.7); }
        // Lines over the land: rivers, then roads over them
        if (line_distance(p, ROAD) < 0.5) { return vec3f(0.6, 0.3, 0.15); }
        if (line_distance(p, RIVER) < 0.5) { return vec3f(0.2, 0.6, 0.55); }
        return vec3f(0.85, 0.8, 0.65);
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
        let paper = paper_at(p, frag.xy);
        col = paper;
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
        let r = line_distance(wander(p, u.wobble, 3.3), RIVER);
        col = mix(col, col * u.sea_shallow.rgb, u.sea_tint * 0.5 * (1.0 - smoothstep(0.0, 1.2, r)) * land);
        let river_half = min(u.river_width * 0.5 * u.pixel_density * mix(1.0, 0.4, smoothstep(0.2, 0.8, cell.g)), px / 6.0);
        col = mix(col, mix(u.ink.rgb, u.sea_shallow.rgb, 0.3), line_aa(r * px, river_half) * land);

        // Roads: ochre between two ink edges, on a band of bare paper that hides what is drawn under it, stopping at the
        // shore. A road never grows past a fifth of a cell; zoomed out too far for its edges to read, it narrows to a
        // single darker line that stays in view.
        let road = line_distance(wander(p, u.wobble * 0.6, 9.1), ROAD) * px;
        let road_half = min(u.road_width * 0.5 * u.pixel_density, px / 5.0);
        let cased = smoothstep(2.0, 4.0, road_half / u.pixel_density);
        let road_edge = 0.5 * u.pixel_density;
        col = mix(col, paper, line_aa(road, road_half + u.road_halo * u.pixel_density) * land * cased);
        let road_color = mix(mix(u.road_fill.rgb, u.ink.rgb, 0.4), u.road_fill.rgb, cased);
        col = mix(col, road_color, line_aa(road, max(road_half, 0.75 * u.pixel_density)) * land);
        col = mix(col, u.ink.rgb, line_aa(abs(road - (road_half - road_edge)), road_edge) * land * cased);

        let width = u.coast_width * 0.5 * u.pixel_density * (0.8 + 0.4 * value_noise(p * 0.8));
        col = mix(col, u.ink.rgb, line_aa(abs(d) * px, width));

        // Highlights, their edges wandering as the coast does
        col = highlights_over(col, wander(p, u.wobble * 1.6, 5.7), d, px);

        // Arrows, over everything else on land and sea: their fill between two ink edges, the same width however far
        // the map zooms, and their heads as wide again as the triangles they are drawn from
        let arrow = line_distance(p, ARROW) * px;
        let arrow_half = u.arrow_width * 0.5 * u.pixel_density;
        let arrow_edge = 0.5 * u.pixel_density;
        col = mix(col, u.arrow_fill.rgb, line_aa(arrow, arrow_half));
        col = mix(col, u.ink.rgb, line_aa(abs(arrow - (arrow_half - arrow_edge)), arrow_edge));
    }

    // The sheet darkens toward its edges.
    let m = min(p, u.grid - p);
    col *= mix(0.84, 1.0, smoothstep(0.0, 12.0, min(m.x, m.y)));
    return vec4f(col, 1.0);
}
`

// The window's size in physical pixels, or false when SDL cannot tell.
@(private = "file")
window_pixels :: proc(window: ^sdl.Window) -> (size: [2]u32, ok: bool) {
	width, height: i32
	if !sdl.GetWindowSizeInPixels(window, &width, &height) {
		return {}, false
	}
	return {u32(max(width, 0)), u32(max(height, 0))}, true
}

