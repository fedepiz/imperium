package gfx

import "base:runtime"
import "core:fmt"
import "core:math"
import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

import "../util"

// Each list gets its own slice of the instance buffer, since all uploads land before any drawing
RENDER_LISTS_PER_FRAME :: 4

// Blur sigma, in cells
@(private = "file")
HIGHLIGHT_SMOOTHING :: 1.5

// Blur radius, in cells
@(private = "file")
HIGHLIGHT_BLUR_REACH :: 4

// Margin recomputed around an area's cells, in cells
@(private = "file")
HIGHLIGHT_MARGIN :: HIGHLIGHT_BLUR_REACH + 2

// Field clamp, in cells
@(private = "file")
HIGHLIGHT_FIELD_MAX :: 64

// Min field on the area's own cells after blurring, so they stay covered
@(private = "file")
HIGHLIGHT_OWN_MIN :: 0.1

// Line field value far from any line, in cells
@(private = "file")
LINE_FAR :: 1000

// One channel per line kind
@(private = "file")
LINE_FIELD_FORMAT :: wgpu.TextureFormat.RGBA16Float

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

// Must match the shader's Terrain struct
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
	road_stroke, arrow_width:                       f32,
	road_fill, arrow_fill:                          [4]f32,
	head_length, head_width:                        f32,
	overlay_shown:                                  i32,
	border_width:                                   f32,
	border_ink:                                     [4]f32,
	// Per highlight layer
	circle_counts:                                  [4]i32,
}
#assert(size_of(Terrain_Uniforms) == 240)
#assert(len(Render_Highlight_Layer) <= 4, "circle_counts has one slot per highlight layer")

Renderer :: struct {
	window:                              ^sdl.Window,
	// Whether presenting waits for the display's refresh
	vsync:                               bool,
	// Logical pixels, matching SDL mouse coordinates
	view_size:                           [2]f32,
	// Physical pixels per logical pixel; 0 = 1
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
	// Physical pixels; 0 until configured
	surface_size:                        [2]u32,
	max_texture_size:                    int,
	// Current frame target and its single pass
	frame_texture:                       wgpu.Texture,
	frame_view:                          wgpu.TextureView,
	frame_encoder:                       wgpu.CommandEncoder,
	frame_pass:                          wgpu.RenderPassEncoder,
	// Render lists drawn so far this frame
	frame_lists:                         int,
	// Render list pass: view size uniform, instances, one bind group per texture
	list_pipeline:                       wgpu.RenderPipeline,
	list_view_layout, list_image_layout: wgpu.BindGroupLayout,
	list_view_buffer, list_instances:    wgpu.Buffer,
	list_view_group:                     wgpu.BindGroup,
	linear_sampler:                      wgpu.Sampler,
	white:                               Image,
	// Slot 0 is unused; untextured batches bind white
	images:                              [65536]Image,
	// The map pass
	terrain_pipeline:                    wgpu.RenderPipeline,
	terrain_layout:                      wgpu.BindGroupLayout,
	// Recreated with the surface (reads the line field)
	terrain_group:                       wgpu.BindGroup,
	terrain_uniforms:                    wgpu.Buffer,
	terrain_cells, terrain_coast:        Texture,
	cover_cells, cover_palette:          Texture,
	overlay:                             Texture,
	overlay_revision:                    u32,
	overlay_uploaded:                    bool,
	// Uploaded revisions
	terrain_revision, cover_revision:    u32,
	terrain_uploaded, cover_uploaded:    bool,
	// Coast as f16, for upload
	coast_half:                          [RENDER_TERRAIN_CELLS]f16,
	// Arrays with one slice per layer: cells, field, palette. Circles: one row per layer, texel = center, radius, area.
	highlight_layers:                    [Render_Highlight_Layer]Highlight_Layer,
	highlight_cells, highlight_field:    Texture,
	highlight_palette, highlight_circles: Texture,
	// Lines pass: one pipeline per line kind, each writing its own channel of the line field
	line_pipelines:                      [Render_Line_Kind]wgpu.RenderPipeline,
	line_layout:                         wgpu.BindGroupLayout,
	line_group:                          wgpu.BindGroup,
	line_segments:                       [Render_Line_Kind]wgpu.Buffer,
	line_revisions:                      [Render_Line_Kind]u32,
	lines_uploaded:                      [Render_Line_Kind]bool,
	// Per pixel: distance in cells to the nearest line of each kind (one channel each). Recreated with the surface.
	line_field:                          Texture,
	// Marks, premultiplied, composited by the map shader under the highlights. Recreated with the surface.
	marks_layer:                         Texture,
}

// CPU side of a highlight layer: per cell and surface, which area's field the cell holds, and that field
@(private = "file")
Highlight_Layer :: struct {
	// Per area: uploaded revision, and the bounds and surface last uploaded
	revisions:             [RENDER_HIGHLIGHT_AREAS]u32,
	bounds:                [RENDER_HIGHLIGHT_AREAS]util.Cell_Rect,
	surfaces:              [RENDER_HIGHLIGHT_AREAS]Render_Highlight_Surface,
	// CPU copy of the cell textures, uploaded by rectangle
	owners:                [RENDER_TERRAIN_CELLS][Render_Highlight_Surface]u8,
	fields:                [RENDER_TERRAIN_CELLS][Render_Highlight_Surface]f16,
}

// The binding's BlendOperation omits webgpu.h's Undefined, so its values are off by one (.Min is ReverseSubtract).
// This is the native Min.
@(private = "file")
BLEND_MIN :: wgpu.BlendOperation(4)

#assert(len(Render_Line_Kind) <= 4, "the line field has a channel for each kind of line")

// The backend wgpu draws through: Metal on macOS, Vulkan elsewhere.
RENDER_BACKENDS ::
	wgpu.InstanceBackendFlags{.Metal} when ODIN_OS ==
	.Darwin else wgpu.InstanceBackendFlags{.Vulkan}

// macOS: surface from the window's Metal layer. Elsewhere: from the native window handle.
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

	// Adapter and device callbacks run while the instance processes events
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

	// Request the adapter's limits (not portable defaults) so the atlas can be as large as possible
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

	// No sRGB conversion
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
	// Fifo = vsync, supported everywhere
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
	texture_release(renderer.marks_layer)
	texture_release(renderer.cover_cells)
	texture_release(renderer.cover_palette)
	texture_release(renderer.overlay)
	texture_release(renderer.highlight_cells)
	texture_release(renderer.highlight_field)
	texture_release(renderer.highlight_palette)
	texture_release(renderer.highlight_circles)
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

// Acquires the next surface image and begins the cleared pass. False if hidden, zero-sized, or reconfigured.
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

// Clears to clear_color, or loads existing contents
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

// Submits and presents (waits for vsync)
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
	frame_targets_create(renderer, size)
}

// Recreates the surface-sized targets (line field, marks layer) and the map bind group that reads them
@(private = "file")
frame_targets_create :: proc(renderer: ^Renderer, size: [2]u32) {
	if renderer.terrain_group != nil do wgpu.BindGroupRelease(renderer.terrain_group)
	for target in ([2]^Texture{&renderer.line_field, &renderer.marks_layer}) {
		if target.view != nil do wgpu.TextureViewRelease(target.view)
		if target.texture != nil do wgpu.TextureRelease(target.texture)
	}
	target_create :: proc(renderer: ^Renderer, format: wgpu.TextureFormat, size: [2]u32) -> (target: Texture) {
		target.texture = wgpu.DeviceCreateTexture(
			renderer.device,
			&{
				usage = {.RenderAttachment, .TextureBinding},
				dimension = ._2D,
				size = {size.x, size.y, 1},
				format = format,
				mipLevelCount = 1,
				sampleCount = 1,
			},
		)
		target.view = wgpu.TextureCreateView(target.texture, nil)
		return
	}
	renderer.line_field = target_create(renderer, LINE_FIELD_FORMAT, size)
	renderer.marks_layer = target_create(renderer, renderer.surface_format, size)

	group_entries := [13]wgpu.BindGroupEntry {
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
		{binding = 10, textureView = renderer.highlight_circles.view},
		{binding = 11, textureView = renderer.marks_layer.view},
		{binding = 12, textureView = renderer.overlay.view},
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

// Uploads changed data (by revision), draws lines into the line field and marks into the marks layer, each in their
// own pass, then the map, which composites both.
render_terrain :: proc(renderer: ^Renderer, terrain: ^Render_Terrain, marks: ^Render_List) {
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
		palette: [2][RENDER_LAYER_CATEGORIES][4]u8
		for category, i in cover.palette {
			c := category.color
			palette[0][i] = {util.to_u8(c.r), util.to_u8(c.g), util.to_u8(c.b), util.to_u8(category.wash)}
			palette[1][i] = {u8(category.pattern), util.to_u8(category.pattern_ink), 0, 0}
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

	if !renderer.overlay_uploaded || renderer.overlay_revision != terrain.overlay_revision {
		texture_write(renderer, renderer.overlay.texture, raw_data(terrain.overlay[:]), 1)
		renderer.overlay_revision = terrain.overlay_revision
		renderer.overlay_uploaded = true
	}

	circle_counts: [4]i32
	for &highlights, kind in terrain.highlights {
		layer := &renderer.highlight_layers[kind]
		slice := u32(kind)
		// Re-upload changed areas, around old and new positions
		for &area, index in highlights.areas {
			if layer.revisions[index] == area.revision do continue
			rect := highlight_take_up(layer, terrain, &highlights, u8(index))
			texture_write_rect(renderer, renderer.highlight_cells.texture, slice, raw_data(layer.owners[:]), 2, rect)
			texture_write_rect(renderer, renderer.highlight_field.texture, slice, raw_data(layer.fields[:]), 4, rect)
			layer.revisions[index] = area.revision
			layer.bounds[index] = area.bounds
		}
		// Looks, every frame. Row 0: color, border. Row 1: thickness, inside, surface.
		palette: [2][RENDER_HIGHLIGHT_AREAS][4]f32
		for area, i in highlights.areas {
			palette[0][i] = {area.color.r, area.color.g, area.color.b, area.border}
			palette[1][i] = {area.thickness, area.inside, f32(area.surface), 0}
		}
		wgpu.QueueWriteTexture(
			renderer.queue,
			&{texture = renderer.highlight_palette.texture, origin = {0, 0, slice}, aspect = .All},
			&palette,
			size_of(palette),
			&{bytesPerRow = RENDER_HIGHLIGHT_AREAS * size_of([4]f32), rowsPerImage = 2},
			&{RENDER_HIGHLIGHT_AREAS, 2, 1},
		)

		// Circles, every frame
		circle_counts[kind] = i32(len(highlights.circles))
		if len(highlights.circles) == 0 do continue
		circles: [RENDER_HIGHLIGHT_CIRCLES_MAX][4]f32
		for circle, i in highlights.circles {
			circles[i] = {circle.center.x, circle.center.y, circle.radius, f32(circle.area)}
		}
		wgpu.QueueWriteTexture(
			renderer.queue,
			&{texture = renderer.highlight_circles.texture, origin = {0, slice, 0}, aspect = .All},
			&circles,
			uint(len(highlights.circles) * size_of([4]f32)),
			&{bytesPerRow = RENDER_HIGHLIGHT_CIRCLES_MAX * size_of([4]f32), rowsPerImage = 1},
			&{u32(len(highlights.circles)), 1, 1},
		)
	}

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
		road_stroke        = style.road_stroke,
		road_fill          = style.road_fill,
		arrow_width        = style.arrow_width,
		arrow_fill         = style.arrow_fill,
		head_length        = style.head_length,
		head_width         = style.head_width,
		cover_jitter       = cover.jitter,
		paper_stain_amount = style.paper_stain_amount,
		sea_depth_from     = style.sea_depth_from,
		sea_depth_full     = style.sea_depth_full,
		border_width       = style.border_width,
		border_ink         = style.border_ink,
		circle_counts      = circle_counts,
		overlay_shown      = i32(terrain.overlay_shown),
	}
	wgpu.QueueWriteBuffer(
		renderer.queue,
		renderer.terrain_uniforms,
		0,
		&uniforms,
		size_of(uniforms),
	)

	// Interrupt the frame pass for the lines pass, then resume (load, not clear)
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

	// Marks pass
	marks_pass := pass_begin(renderer, renderer.marks_layer.view, .Clear, {0, 0, 0, 0})
	list_draw(renderer, marks_pass, marks)
	wgpu.RenderPassEncoderEnd(marks_pass)
	wgpu.RenderPassEncoderRelease(marks_pass)

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
	list_draw(renderer, renderer.frame_pass, list)
}

@(private = "file")
list_draw :: proc(renderer: ^Renderer, pass: wgpu.RenderPassEncoder, list: ^Render_List) {
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
		// Untextured instances join any batch; the first textured one sets its texture
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

// layers > 0 makes a 2D array texture
@(private = "file")
texture_create :: proc(
	renderer: ^Renderer,
	format: wgpu.TextureFormat,
	size: [2]u32,
	layers: u32 = 0,
) -> (
	texture: Texture,
) {
	texture.texture = wgpu.DeviceCreateTexture(
		renderer.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {size.x, size.y, max(layers, 1)},
			format = format,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	view := wgpu.TextureViewDescriptor {
		format          = format,
		dimension       = layers > 0 ? ._2DArray : ._2D,
		mipLevelCount   = 1,
		arrayLayerCount = max(layers, 1),
		aspect          = .All,
	}
	texture.view = wgpu.TextureCreateView(texture.texture, &view)
	return
}

// texel_size bytes per cell
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

// texel_size bytes per cell. Empty rect = no-op.
@(private = "file")
texture_write_rect :: proc(
	renderer: ^Renderer,
	texture: wgpu.Texture,
	slice: u32,
	data: rawptr,
	texel_size: u32,
	rect: util.Cell_Rect,
) {
	if util.cell_rect_empty(rect) do return
	size := rect.max - rect.min
	wgpu.QueueWriteTexture(
		renderer.queue,
		&{texture = texture, origin = {u32(rect.min.x), u32(rect.min.y), slice}, aspect = .All},
		data,
		uint(RENDER_TERRAIN_CELLS * texel_size),
		&{
			offset = u64(util.grid_index(rect.min, RENDER_TERRAIN_SIZE) * int(texel_size)),
			bytesPerRow = RENDER_TERRAIN_WIDTH * texel_size,
			rowsPerImage = u32(size.y),
		},
		&{u32(size.x), u32(size.y), 1},
	)
}

// Recomputes an area around its old and new cells, for its surface (and the old one if it changed).
// Returns the rect touched.
@(private = "file")
highlight_take_up :: proc(
	layer: ^Highlight_Layer,
	terrain: ^Render_Terrain,
	highlights: ^Render_Highlights,
	area: u8,
) -> util.Cell_Rect {
	look := &highlights.areas[area]
	around := util.cell_rect_union(layer.bounds[area], look.bounds)
	if area == 0 || util.cell_rect_empty(around) do return {}
	around = {around.min - HIGHLIGHT_MARGIN, around.max + HIGHLIGHT_MARGIN}
	if before := layer.surfaces[area]; before != look.surface {
		highlight_take_up_on(layer, terrain, highlights, area, before, around, false)
	}
	highlight_take_up_on(layer, terrain, highlights, area, look.surface, around, true)
	layer.surfaces[area] = look.surface
	return util.cell_rect_clip(around, RENDER_TERRAIN_SIZE)
}

// Computes an area's field over rect for one surface (or removes it if !present).
// Field = signed distance from cell centres minus half a cell, + inside. Cells of the other surface count halfway.
// Blurred to smooth cell steps, and kept >= HIGHLIGHT_OWN_MIN on own cells. Non-area cells keep the field of the
// area they're least outside of. Off-terrain = outside.
@(private = "file")
highlight_take_up_on :: proc(
	layer: ^Highlight_Layer,
	terrain: ^Render_Terrain,
	highlights: ^Render_Highlights,
	area: u8,
	surface: Render_Highlight_Surface,
	around: util.Cell_Rect,
	present: bool,
) {
	clipped := util.cell_rect_clip(around, RENDER_TERRAIN_SIZE)
	if !present || util.cell_rect_empty(highlights.areas[area].bounds) {
		for y in clipped.min.y ..< clipped.max.y do for x in clipped.min.x ..< clipped.max.x {
			index := util.grid_index({x, y}, RENDER_TERRAIN_SIZE)
			if layer.owners[index][surface] == area {
				layer.owners[index][surface] = 0
				layer.fields[index][surface] = 0
			}
		}
		return
	}

	// On terrain and of this surface (land = 0)
	on_surface :: proc(terrain: ^Render_Terrain, surface: Render_Highlight_Surface, cell: [2]int) -> bool {
		if !util.grid_contains(cell, RENDER_TERRAIN_SIZE) do return false
		land := terrain.cells[util.grid_index(cell, RENDER_TERRAIN_SIZE)].r == 0
		return land == (surface == .Land)
	}
	in_area :: proc(
		terrain: ^Render_Terrain,
		highlights: ^Render_Highlights,
		area: u8,
		surface: Render_Highlight_Surface,
		cell: [2]int,
	) -> bool {
		if !on_surface(terrain, surface, cell) do return false
		return highlights.cells[util.grid_index(cell, RENDER_TERRAIN_SIZE)] == area
	}

	// Exact squared distances to nearest outside / inside cell
	origin := around.min
	size := around.max - around.min
	to_out := make([]f64, size.x * size.y, context.temp_allocator)
	to_in := make([]f64, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y do for x in 0 ..< size.x {
		cell := origin + {x, y}
		i := util.grid_index({x, y}, size)
		inside := in_area(terrain, highlights, area, surface, cell)
		out := !inside && (on_surface(terrain, surface, cell) || !util.grid_contains(cell, RENDER_TERRAIN_SIZE))
		to_out[i] = out ? 0 : util.DISTANCE_FAR
		to_in[i] = inside ? 0 : util.DISTANCE_FAR
	}
	util.distance_squared(to_out, size)
	util.distance_squared(to_in, size)
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
		index := util.grid_index({x, y}, RENDER_TERRAIN_SIZE)
		value := field[util.grid_index([2]int{x, y} - origin, size)]
		if in_area(terrain, highlights, area, surface, {x, y}) do value = max(value, HIGHLIGHT_OWN_MIN)
		// Cells of other areas are written by those areas' own updates
		member := highlights.cells[index]
		if member != 0 && member != area && highlights.areas[member].surface == surface {
			if on_surface(terrain, surface, {x, y}) do continue
		}
		owner := &layer.owners[index][surface]
		held := &layer.fields[index][surface]
		if member == area || owner^ == area || owner^ == 0 || value > f32(held^) {
			owner^ = area
			held^ = f16(value)
		}
	}
}

// Separable Gaussian blur (HIGHLIGHT_SMOOTHING), edges extended
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
	// Index of position i along line `line` of axis
	at :: proc(axis, along, across: int, size: [2]int) -> int {
		return util.grid_index(axis == 0 ? [2]int{along, across} : [2]int{across, along}, size)
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

@(private = "file")
shader_create :: proc(renderer: ^Renderer, source: string) -> wgpu.ShaderModule {
	return wgpu.DeviceCreateShaderModule(
		renderer.device,
		&{nextInChain = &wgpu.ShaderSourceWGSL{sType = .ShaderSourceWGSL, code = source}},
	)
}

// Also creates the white texture for untextured batches
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

// Textures sized for the largest terrain, empty
@(private = "file")
terrain_init :: proc(renderer: ^Renderer) -> bool {
	device := renderer.device
	// Coast is linearly filtered (smooth coast); everything else is read per cell and blended in the shader
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
	renderer.overlay = texture_create(renderer, .R8Unorm, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT})
	layers :: u32(len(Render_Highlight_Layer))
	renderer.highlight_cells = texture_create(renderer, .RG8Unorm, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}, layers)
	renderer.highlight_field = texture_create(renderer, .RG16Float, {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}, layers)
	renderer.highlight_palette = texture_create(renderer, .RGBA32Float, {RENDER_HIGHLIGHT_AREAS, 2}, layers)
	renderer.highlight_circles = texture_create(renderer, .RGBA32Float, {RENDER_HIGHLIGHT_CIRCLES_MAX, layers})
	renderer.terrain_uniforms = wgpu.DeviceCreateBuffer(
		device,
		&{usage = {.Uniform, .CopyDst}, size = size_of(Terrain_Uniforms)},
	)

	texture_entry :: proc(
		binding: u32,
		sample: wgpu.TextureSampleType,
		dimension: wgpu.TextureViewDimension = ._2D,
	) -> wgpu.BindGroupLayoutEntry {
		return {
			binding = binding,
			visibility = {.Fragment},
			texture = {sampleType = sample, viewDimension = dimension},
		}
	}
	layout_entries := [13]wgpu.BindGroupLayoutEntry {
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
		texture_entry(7, .Float, ._2DArray),
		texture_entry(8, .Float, ._2DArray),
		texture_entry(9, .UnfilterableFloat, ._2DArray),
		texture_entry(10, .UnfilterableFloat),
		texture_entry(11, .Float),
		texture_entry(12, .Float),
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
	// Opaque, covers everything before it
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

// Storage sized for RENDER_LINE_SEGMENTS_MAX per kind
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

	// Uses the map uniforms (view, head size)
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
	// Min blending: keep the nearest distance
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
    road_stroke: f32,
    arrow_width: f32,
    road_fill: vec4f,
    arrow_fill: vec4f,
    head_length: f32,
    head_width: f32,
    overlay_shown: i32,
    border_width: f32,
    border_ink: vec4f,
    circle_counts: vec4i,
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
// highlight_cells, highlight_field, highlight_palette and highlight_circles are the areas' highlights: see
// highlights_over. region_cells, region_field and region_palette are the regions': see areas_over.
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
// Highlights: one array slice (circles: one row) per Render_Highlight_Layer
@group(0) @binding(7) var highlight_cells: texture_2d_array<f32>;
@group(0) @binding(8) var highlight_field: texture_2d_array<f32>;
@group(0) @binding(9) var highlight_palette: texture_2d_array<f32>;
@group(0) @binding(10) var highlight_circles: texture_2d<f32>;
// Premultiplied
@group(0) @binding(11) var marks: texture_2d<f32>;
// Map mode value per cell, 0..1
@group(0) @binding(12) var overlay: texture_2d<f32>;

// Render_Highlight_Layer
const REGIONS = 0;
const ZONES = 1;
const CONTACTS = 2;
const REACH = 3;

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

// A layer of highlight areas as shown: the color under them, washed over, and how far p is from the nearest edge where
// two areas meet, in cells, far where none do
struct Areas_Shown {
    col: vec3f,
    edge: f32,
}

// The range an edge's steepness is kept within, in the change of the fields' gap per cell: 1 where the fields are true
// distances
const EDGE_STEEPNESS_MIN = 0.25;
const EDGE_STEEPNESS_MAX = 4.0;

// A layer of highlight areas over col at p, d being the signed distance to the coast there, positive on land, and px
// device pixels per cell. highlight_cells holds, per cell and surface (0 land, 1 water), the area of that surface whose
// field the cell holds, 0 for none; highlight_field holds that field: how far the cell's middle is in from the area's edge,
// in cells, negative outside it. A cell is at least as far outside any other area as it is from the edge of the one
// whose field it holds, and it is in no area by as much as it is outside the one whose field it holds.
//
// Each area the four cells around p hold, and no area, has a field there, blended from those cells. An area's depth is
// half how far its field is past the greatest of the others', so where two meet, one's depth is what the other's is
// short of the edge, and where more meet, the greatest is never short of it: no gap opens between them. A land area's
// depth is never past the coast, nor a water area's short of it. Each area is washed over as far as its depth reaches,
// fading in over a device pixel across its edge: the map multiplied toward its color, as strongly as its border at its
// edge, easing to its inside at its thickness in from it. highlight_palette holds each area's color and border in row 0,
// and its thickness, inside and surface in row 1.
fn areas_over(col: vec3f, p: vec2f, d: f32, px: f32, layer: i32) -> Areas_Shown {
    let q = p - 0.5;
    let base = vec2i(floor(q));
    let f = q - floor(q);
    var tint = vec3f(0.0);
    var covered = 0.0;
    var edge = 1e9;
    for (var surface = 0; surface < 2; surface++) {
        let shore = select(-d, d, surface == 0);
        // The four cells around p: the area each holds the field of, that field, and its weight at p, with how the
        // weight changes along x and y, per cell
        var owners: vec4i;
        var values: vec4f;
        var weights: vec4f;
        var weights_dx: vec4f;
        var weights_dy: vec4f;
        for (var j = 0; j < 4; j++) {
            let corner = vec2i(j & 1, j >> 1u);
            let at = clamp(base + corner, vec2i(0), vec2i(u.grid) - 1);
            owners[j] = i32(textureLoad(highlight_cells, at, layer, 0)[surface] * 255.0 + 0.5);
            values[j] = textureLoad(highlight_field, at, layer, 0)[surface];
            let wx = mix(1.0 - f.x, f.x, f32(corner.x));
            let wy = mix(1.0 - f.y, f.y, f32(corner.y));
            weights[j] = wx * wy;
            weights_dx[j] = (f32(corner.x) * 2.0 - 1.0) * wy;
            weights_dy[j] = wx * (f32(corner.y) * 2.0 - 1.0);
        }
        // Each area's field and its slope, in the slot of the first cell holding it, far below any field in the other
        // slots; and no area's
        var fields = vec4f(-1e9);
        var slopes_x = vec4f(0.0);
        var slopes_y = vec4f(0.0);
        let none_at = select(-values, vec4f(0.0), owners == vec4i(0));
        let none = dot(weights, none_at);
        let none_slope = vec2f(dot(weights_dx, none_at), dot(weights_dy, none_at));
        for (var k = 0; k < 4; k++) {
            let area = owners[k];
            var first = area != 0;
            for (var i = 0; i < k; i++) { first = first && owners[i] != area; }
            if (!first) { continue; }
            let at = select(-abs(values), values, owners == vec4i(area));
            fields[k] = dot(weights, at);
            slopes_x[k] = dot(weights_dx, at);
            slopes_y[k] = dot(weights_dy, at);
        }
        // The greatest two fields, whether each is an area's rather than no area's, and their slopes
        var top = none;
        var second = -1e9;
        var top_area = false;
        var second_area = false;
        var top_slope = none_slope;
        var second_slope = vec2f(0.0);
        for (var k = 0; k < 4; k++) {
            let slope = vec2f(slopes_x[k], slopes_y[k]);
            if (fields[k] > top) {
                second = top;
                second_area = top_area;
                second_slope = top_slope;
                top = fields[k];
                top_area = true;
                top_slope = slope;
            } else if (fields[k] > second) {
                second = fields[k];
                second_area = true;
                second_slope = slope;
            }
        }
        // How far p is from where the two meet: how far apart their fields are, over how fast that changes, which is
        // kept within reason so the line keeps near its width
        if (top_area && second_area) {
            let steepness = clamp(length(top_slope - second_slope) * 0.5, EDGE_STEEPNESS_MIN, EDGE_STEEPNESS_MAX);
            edge = min(edge, (top - second) * 0.5 / steepness);
        }
        for (var k = 0; k < 4; k++) {
            if (fields[k] < -1e8) { continue; }
            var rival = none;
            for (var j = 0; j < 4; j++) {
                if (j != k) { rival = max(rival, fields[j]); }
            }
            let depth = min((fields[k] - rival) * 0.5, shore);
            let coverage = smoothstep(-0.5, 0.5, depth * px);
            if (coverage <= 0.0) { continue; }
            let area = owners[k];
            let look = textureLoad(highlight_palette, vec2i(area, 0), layer, 0);
            let fade = textureLoad(highlight_palette, vec2i(area, 1), layer, 0);
            let strength = mix(look.a, fade.y, smoothstep(0.0, max(fade.x, 1e-3), depth));
            tint += coverage * mix(vec3f(1.0), look.rgb, strength);
            covered += coverage;
        }
    }
    // Where areas meet, their fades can add up to more than the whole
    if (covered > 1.0) {
        tint /= covered;
        covered = 1.0;
    }

    return Areas_Shown(col * (tint + (1.0 - covered)), edge);
}

// A highlight layer's areas over col at p, as areas_over has them, and then each area's circles washed over that, as
// one shape: see circles_over. Row layer of highlight_circles holds circle_counts[layer] circles: center, radius, area.
fn highlights_over(col: vec3f, p: vec2f, d: f32, px: f32, layer: i32) -> vec3f {
    // Each area's circles, as one shape, over the areas' cells: its depth is the farthest in of its circles
    var shown = areas_over(col, p, d, px, layer).col;
    let count = u.circle_counts[layer];
    var area = -1;
    var depth = -1e9;
    for (var i = 0; i <= count; i++) {
        var circle = vec4f(0.0, 0.0, 0.0, -1.0);
        if (i < count) { circle = textureLoad(highlight_circles, vec2i(i, layer), 0); }
        let next = i32(round(circle.w));
        if (next != area && area >= 0) {
            shown = circles_over(shown, col, layer, area, depth, d, px);
            depth = -1e9;
        }
        area = next;
        if (area >= 0) { depth = max(depth, circle.z - distance(p, circle.xy)); }
    }
    return shown;
}

// An area's circles over shown, depth being how far in p is from their edge, in cells: washed over col as far as the
// depth reaches, stopping at the coast as the area's cells do, and replacing what is under them.
fn circles_over(shown: vec3f, col: vec3f, layer: i32, area: i32, field: f32, d: f32, px: f32) -> vec3f {
    let look = textureLoad(highlight_palette, vec2i(area, 0), layer, 0);
    let fade = textureLoad(highlight_palette, vec2i(area, 1), layer, 0);
    let depth = min(field, select(-d, d, fade.z < 0.5));
    let coverage = smoothstep(-0.5, 0.5, depth * px);
    let strength = mix(look.a, fade.y, smoothstep(0.0, max(fade.x, 1e-3), depth));
    return mix(shown, col * mix(vec3f(1.0), look.rgb, strength), coverage);
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

        // The regions, washed in their colours from their edges, under the rivers and roads
        let regions = areas_over(col, wander(p, u.wobble * 1.6, 5.7), d, px, REGIONS);
        col = regions.col;

        // Borders: a hairline over the land where two regions meet, on the edge their washes share
        let border = line_aa(regions.edge * px, u.border_width * 0.5 * u.pixel_density);
        col = mix(col, u.border_ink.rgb, border * u.border_ink.a * land);

        // Rivers: a faint wash either side and a line that thins toward the hills, both stopping at the shore. The line
        // never grows past a third of a cell, so rivers fade out as the map zooms away.
        let r = line_distance(wander(p, u.wobble, 3.3), RIVER);
        col = mix(col, col * u.sea_shallow.rgb, u.sea_tint * 0.5 * (1.0 - smoothstep(0.0, 1.2, r)) * land);
        let river_half = min(u.river_width * 0.5 * u.pixel_density * mix(1.0, 0.4, smoothstep(0.2, 0.8, cell.g)), px / 6.0);
        col = mix(col, mix(u.ink.rgb, u.sea_shallow.rgb, 0.3), line_aa(r * px, river_half) * land);

        // Roads: two ink strokes on a faint wash of trodden earth, stopping at the shore, drawn by a hand that trembles
        // a little across them and presses unevenly along them. They keep the course they were traced along, their
        // tremble a pixel or so however far the map zooms. A road keeps its width on screen, never past a quarter of a
        // cell; zoomed out too far for its strokes to part, it closes into a single line of sepia.
        let tremble = (vec2f(value_noise(p * 3.1 + 9.1), value_noise(p * 3.1 + 14.3)) - 0.5) * u.pixel_density / px;
        let road = line_distance(p + tremble, ROAD) * px;
        let road_half = min(u.road_width * 0.5 * u.pixel_density, px / 4.0);
        let parted = smoothstep(1.5, 3.0, road_half / u.pixel_density);
        let sepia = mix(u.ink.rgb, u.road_fill.rgb * paper, 0.35);
        col = mix(col, sepia, line_aa(road, max(road_half, 0.6 * u.pixel_density)) * land * (1.0 - parted));
        col = mix(col, u.road_fill.rgb * paper, u.road_fill.a * line_aa(road, road_half) * land * parted);
        let stroke = u.road_stroke * 0.5 * u.pixel_density * (0.6 + 0.8 * value_noise(p * 1.7 + 2.9));
        col = mix(col, u.ink.rgb, line_aa(abs(road - (road_half - stroke)), stroke) * land * parted);

        let width = u.coast_width * 0.5 * u.pixel_density * (0.8 + 0.4 * value_noise(p * 0.8));
        col = mix(col, u.ink.rgb, line_aa(abs(d) * px, width));

        // Marks (trees, hills...), premultiplied
        let mark = textureLoad(marks, vec2i(frag.xy), 0);
        col = col * (1.0 - mark.a) + mark.rgb;

        // Highlights, their edges wandering as the coast does
        let wandered = wander(p, u.wobble * 1.6, 5.7);
        col = highlights_over(col, wandered, d, px, ZONES);
        col = highlights_over(col, wandered, d, px, CONTACTS);
        col = highlights_over(col, wandered, d, px, REACH);

        // Map mode wash: red where the value is low, green where high
        if (u.overlay_shown != 0) {
            let value = textureSampleLevel(overlay, linear_sampler, p / u.grid, 0.0).r;
            let tint = mix(vec3f(0.85, 0.45, 0.35), vec3f(0.45, 0.75, 0.40), value);
            col = mix(col, col * tint, 0.8 * land);
        }

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

