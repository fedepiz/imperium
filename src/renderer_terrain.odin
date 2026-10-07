#+private
package main

import "core:hash/xxhash"
import "core:math"
import "core:slice"

import "vendor:wgpu"

// Terrain: the map's ground, drawn by the renderer. Paper, sea and coast, land cover, regions,
// rivers, roads, highlights, arrows, a value wash, and marks (mountains, trees, waves).
// renderer_terrain_build: once per map, from a Render_Geography.
// Every frame: a Render_Terrain_Frame, as Render_Data.terrain.
// Everything else the drawing needs is derived here: the coast's distance field, smoothed courses,
// region and highlight fields, mark placement, fades.
// Renderer internals, called by renderer.odin only: terrain_init, terrain_deinit, terrain_resize,
// terrain_frame, terrain_encode, terrain_draw

// Terrain size in cells. 1 world unit = 1 cell
RENDER_TERRAIN_WIDTH :: 1024
RENDER_TERRAIN_HEIGHT :: 1024
RENDER_TERRAIN_CELLS :: RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT
// Regions in a frame, entry 0 included
RENDER_TERRAIN_REGIONS_MAX :: 256
// Highlights in a frame
RENDER_TERRAIN_HIGHLIGHTS_MAX :: 16
// Cells, and circles, of all a frame's highlights together
RENDER_TERRAIN_HIGHLIGHT_CELLS_MAX :: RENDER_TERRAIN_CELLS
RENDER_TERRAIN_HIGHLIGHT_CIRCLES_MAX :: 512
// Points of the arrow
RENDER_TERRAIN_ARROW_POINTS_MAX :: 4096
// Points, and runs, of the courses of one kind
RENDER_TERRAIN_COURSE_POINTS_MAX :: 1 << 16
RENDER_TERRAIN_COURSE_RUNS_MAX :: 256
// Variants of a mark drawing
RENDER_MARK_VARIANTS_MAX :: 4

// What the terrain is drawn from. Read during renderer_terrain_build, not kept.
// Grids: one entry per cell, row-major from the top-left
Render_Geography :: struct {
	// true = lake or sea. Gives the coast: its line, the sea tint, and where land layers stop
	water:     [RENDER_TERRAIN_CELLS]bool,
	// 0..255. Thins rivers toward their source. Places mountains and hills, and picks tree species
	elevation: [RENDER_TERRAIN_CELLS]u8,
	// 0..255. Picks tree species
	moisture:  [RENDER_TERRAIN_CELLS]u8,
	// Gives the cover washes and stipple. Places trees, tufts, marsh and dune marks
	cover:     [RENDER_TERRAIN_CELLS]Render_Cover_Cell,
	// Courses as points in cells, smoothed by the caller. Drawn as segments between the points.
	// Marks keep off them
	rivers:    Render_Courses,
	roads:     Render_Courses,
	// Region per cell, 0 = none. On land only. Gives the region washes and the borders between
	// regions. Their colours: Render_Terrain_Frame.regions
	regions:   [RENDER_TERRAIN_CELLS]u8,
}

Render_Courses :: Polylines(RENDER_TERRAIN_COURSE_POINTS_MAX, RENDER_TERRAIN_COURSE_RUNS_MAX)

// Land cover of one cell
Render_Cover_Cell :: struct {
	kind:     Render_Cover,
	// How strongly the cell is of that kind, 0..255
	strength: u8,
}

Render_Cover :: enum u8 {
	Open,
	Forest,
	Desert,
	Steppe,
	Fertile,
	Marsh,
	Highland,
	Mountains,
	Fields,
}

// The drawings marks are made of
Render_Mark_Drawing :: enum {
	Mountain,
	Hill,
	Conifer,
	Broadleaf,
	Cypress,
	Palm,
	Tuft,
	Marsh,
	Dune,
	Sea,
}

// Atlas rect of each drawing's variants. Empty = missing: the first empty one ends a drawing's variants
Render_Mark_Images :: [Render_Mark_Drawing][RENDER_MARK_VARIANTS_MAX]Extents

// What the terrain shows this frame, besides what it was built from. Read during renderer_draw.
// Fixed capacity
Render_Terrain_Frame :: struct {
	region_display:    Render_Region_Display,
	// Index: region, as in Render_Geography.regions. Entry 0 is unused
	regions:           [RENDER_TERRAIN_REGIONS_MAX]Render_Region,
	// A highlight keeps its slot from frame to frame: when its content changes it fades in again
	highlights:        [RENDER_TERRAIN_HIGHLIGHTS_MAX]Render_Highlight,
	// Of the highlights
	highlight_cells:   [dynamic; RENDER_TERRAIN_HIGHLIGHT_CELLS_MAX]bool,
	highlight_circles: [dynamic; RENDER_TERRAIN_HIGHLIGHT_CIRCLES_MAX]Render_Circle,
	// A path as points in cells, tail to head, drawn with an arrowhead at its end. Empty = none
	arrow:             [dynamic; RENDER_TERRAIN_ARROW_POINTS_MAX][2]f32,
	// A value per cell, 0..255, RENDER_TERRAIN_CELLS long: a wash over the land, from the style's
	// wash_low at 0 to wash_high at 255. Empty = none. For map modes such as supply
	wash:              [dynamic; RENDER_TERRAIN_CELLS]u8,
	// Seconds since the last frame. Drives the fades
	dt:                f32,
}

Render_Region_Display :: enum {
	// No colour
	Hidden,
	// A band of the region's colour along its edge
	Outlined,
	// Outlined when near, filled when far
	Filled_When_Far,
}

Render_Region :: struct {
	color:       [3]f32,
	// Drawn stronger
	highlighted: bool,
}

// A set of cells washed in the colour of its kind
Render_Highlight :: struct {
	kind:          Render_Highlight_Kind,
	// The set is of water cells. Otherwise of land cells
	on_water:      bool,
	// Cell corner + {x, y} is highlight_cells[cells_begin + y * size.x + x]. Zero size = not shown
	corner:        [2]int,
	size:          [2]int,
	cells_begin:   int,
	// Discs added to the shape: highlight_circles[circles_begin:][:circles_len]
	circles_begin: int,
	circles_len:   int,
}

// Highlights of one kind share a look. Kinds on one row tile: where two meet they share an edge.
// Rows are drawn in this order, each over the last: Zone; Contact; Reach, Foreign_Reach
Render_Highlight_Kind :: enum {
	// Where the selected piece can go
	Reach,
	// Reach of a piece the player does not control
	Foreign_Reach,
	// Enemy zone
	Zone,
	// Friendly contact
	Contact,
}

// In cells
Render_Circle :: struct {
	center: [2]f32,
	radius: f32,
}

// Colours: straight RGB, 0..1. Widths: logical pixels
Render_Terrain_Style :: struct {
	paper:                   [3]f32,
	paper_stain:             [3]f32,
	// 0..1
	paper_stain_amount:      f32,
	ink:                     [3]f32,
	// Sea colour: shallow up to sea_depth_from cells from the shore, deep from sea_depth_full
	sea_shallow:             [3]f32,
	sea_deep:                [3]f32,
	sea_depth_from:          f32,
	sea_depth_full:          f32,
	// 0..1
	sea_tint:                f32,
	coast_width:             f32,
	// Hand wobble of the coast and rivers, in cells
	wobble:                  f32,
	// At low elevation. Thins toward the source
	river_width:             f32,
	// Outer width, including two ink lines of road_stroke each
	road_width:              f32,
	road_stroke:             f32,
	road_fill:               [3]f32,
	// 0..1
	road_fill_strength:      f32,
	// Line between regions
	border_width:            f32,
	border_ink:              [3]f32,
	// 0..1
	border_strength:         f32,
	// Region colour bands: near and far (see Render_Region_Display), plain and highlighted
	region_near:             Render_Band,
	region_near_highlighted: Render_Band,
	region_far:              Render_Band,
	region_far_highlighted:  Render_Band,
	highlight_looks:         [Render_Highlight_Kind]Render_Highlight_Look,
	// Outer width, including an ink line either side
	arrow_width:             f32,
	arrow_fill:              [3]f32,
	arrow_head_length:       f32,
	arrow_head_width:        f32,
	// Wash: colour at value 0 and at 255, and its strength, 0..1
	wash_low:                [3]f32,
	wash_high:               [3]f32,
	wash_strength:           f32,
	// Patterns are drawn in ink
	cover_looks:             [Render_Cover]Render_Cover_Look,
	// Wobble of the borders between covers, in cells
	cover_jitter:            f32,
}

// A wash strongest along an area's edge
Render_Band :: struct {
	// Wash strength at the edge, 0..1
	border:    f32,
	// Cells over which it eases inward
	thickness: f32,
	// Wash strength past that, 0..1
	inside:    f32,
}

Render_Highlight_Look :: struct {
	color: [3]f32,
	band:  Render_Band,
	// Cells by which thin parts are thickened, so a thread reads as a band. 0 = as given
	widen: int,
}

// Look of one kind of cover
Render_Cover_Look :: struct {
	// Multiplies the colour by mix(1, color, wash * cell strength)
	color:       [3]f32,
	// 0..1
	wash:        f32,
	pattern:     Render_Pattern,
	// Pattern opacity, 0..1
	pattern_ink: f32,
}

Render_Pattern :: enum u8 {
	None,
	// Dots about 7 logical pixels apart at any zoom. Share of dots drawn = cell strength
	Stipple,
}

@(private = "file")
COVER_SAND :: [3]f32{0.900, 0.800, 0.600}

RENDER_TERRAIN_STYLE_DEFAULT :: Render_Terrain_Style {
	paper = {0.840, 0.772, 0.620},
	paper_stain = {0.720, 0.620, 0.460},
	paper_stain_amount = 0.5,
	ink = {0.150, 0.105, 0.070},
	sea_shallow = {0.560, 0.610, 0.620},
	sea_deep = {0.200, 0.330, 0.480},
	sea_depth_from = 0,
	sea_depth_full = 80,
	sea_tint = 0.55,
	coast_width = 1.6,
	wobble = 0.3,
	river_width = 12,
	road_width = 8,
	road_stroke = 1.1,
	road_fill = {0.950, 0.840, 0.660},
	road_fill_strength = 0.55,
	border_width = 1.5,
	border_ink = {0.400, 0.180, 0.120},
	border_strength = 0.3,
	region_near = {border = 0.25, thickness = 1.5, inside = 0},
	region_near_highlighted = {border = 0.4, thickness = 2.5, inside = 0.02},
	region_far = {border = 0.4, thickness = 3, inside = 0.35},
	region_far_highlighted = {border = 0.5, thickness = 3.5, inside = 0.45},
	highlight_looks = {
		// Mostly outline, so zones show through
		.Reach = {color = {0.300, 0.450, 0.650}, band = {0.7, 1.5, 0.1}, widen = 1},
		.Foreign_Reach = {color = {0.450, 0.420, 0.380}, band = {0.7, 1.5, 0.1}, widen = 1},
		.Zone = {color = {0.700, 0.250, 0.160}, band = {0.6, 2, 0.25}},
		.Contact = {color = {0.850, 0.700, 0.200}, band = {0.6, 2, 0.2}},
	},
	arrow_width = 5,
	arrow_fill = {0.700, 0.250, 0.160},
	arrow_head_length = 7.5,
	arrow_head_width = 6.25,
	wash_low = {0.850, 0.450, 0.350},
	wash_high = {0.450, 0.750, 0.400},
	wash_strength = 0.8,
	cover_looks = {
		.Open = {},
		.Forest = {color = {0.600, 0.640, 0.470}, wash = 0.45},
		.Desert = {color = COVER_SAND, wash = 0.55, pattern = .Stipple, pattern_ink = 0.45},
		.Steppe = {color = COVER_SAND, wash = 0.25},
		.Fertile = {color = {0.720, 0.740, 0.540}, wash = 0.7},
		.Marsh = {color = {0.580, 0.640, 0.640}, wash = 0.5},
		.Highland = {color = {0.740, 0.620, 0.460}, wash = 0.35},
		.Mountains = {color = {0.700, 0.580, 0.420}, wash = 0.45},
		.Fields = {color = {0.790, 0.770, 0.600}, wash = 0.35},
	},
	cover_jitter = 0.8,
}

// Builds the terrain: its coast, regions, courses, cover and marks. Replaces any earlier build.
// marks: the atlas rects of the mark drawings
renderer_terrain_build :: proc(
	rend: ^Renderer,
	geography: ^Render_Geography,
	style: Render_Terrain_Style,
	marks: Render_Mark_Images,
) {
	if !(.Ready in rend.flags) do return
	size :: [2]int{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}

	// Step: State. Nothing of an earlier build's frames is kept
	TERRAIN.style = style
	TERRAIN.region_looks = {}
	TERRAIN.highlights = {}
	TERRAIN.wash_written = 0

	// Step: Coast. First: areas take their sides from it
	coast := make([]f32, RENDER_TERRAIN_CELLS, context.temp_allocator)
	terrain_coast_build(geography.water[:], size, coast)
	ground_divide_write(rend, coast)

	// Step: Regions, and empty highlight layers
	ground_areas_write(rend, LAYER_REGIONS, geography.regions[:], .Land)
	{
		none := make([]u8, RENDER_TERRAIN_CELLS, context.temp_allocator)
		for layer in HIGHLIGHT_AREA_LAYERS do ground_areas_write(rend, layer, none, .Land)
	}

	// Step: Courses, each kind to its stroke
	ground_stroke_write(rend, STROKE_RIVERS, &geography.rivers)
	ground_stroke_write(rend, STROKE_ROADS, &geography.roads)
	// Rivers thin with elevation
	ground_taper_write(rend, geography.elevation[:])

	// Step: Cover
	ground_category_write(rend, geography.cover[:])
	looks := style.cover_looks
	ground_category_looks_write(rend, slice.enumerated_array(&looks))

	// Step: Marks
	images := marks
	terrain_marks_place(
		size,
		geography.elevation[:],
		geography.moisture[:],
		geography.cover[:],
		coast,
		&geography.rivers,
		&geography.roads,
		&images,
		&TERRAIN.marks,
	)
}

// Area layers. Regions: under the courses. Highlights: over the marks, in this order
@(private = "file")
LAYER_REGIONS :: 0
@(private = "file")
LAYER_ZONES :: 1
@(private = "file")
LAYER_CONTACTS :: 2
@(private = "file")
LAYER_REACH :: 3
@(private = "file")
HIGHLIGHT_AREA_LAYERS :: [?]int{LAYER_ZONES, LAYER_CONTACTS, LAYER_REACH}

@(private = "file", rodata)
HIGHLIGHT_LAYERS := [Render_Highlight_Kind]int {
	.Reach         = LAYER_REACH,
	.Foreign_Reach = LAYER_REACH,
	.Zone          = LAYER_ZONES,
	.Contact       = LAYER_CONTACTS,
}

// Strokes
@(private = "file")
STROKE_RIVERS :: 0
@(private = "file")
STROKE_ROADS :: 1
@(private = "file")
STROKE_ARROWS :: 2

// Rate at which region and highlight looks move toward their targets, per second
@(private = "file")
LOOK_EASE :: 10

// Under this zoom, in logical pixels per cell, regions are far
@(private = "file")
REGION_FAR_ZOOM :: 5

// Thickening of highlights: cells of the mask a cell needs within reach to be added.
// A straight 1-cell thread gives 3
@(private = "file")
WIDEN_SUPPORT :: 3

// The noise the shader adds to the coast, the region edges and the highlight edges, per unit of the
// style's wobble
@(private = "file")
EDGE_WOBBLE :: 1.6

#assert(RENDER_TERRAIN_HIGHLIGHTS_MAX < AREAS_PER_LAYER)
#assert(RENDER_TERRAIN_REGIONS_MAX <= AREAS_PER_LAYER)

// Ground sizes, GPU side
@(private = "file")
GROUND_CATEGORIES :: 256
// Area layers, and areas per layer. Area 0 = none
@(private = "file")
AREA_LAYERS :: 4
@(private = "file")
AREAS_PER_LAYER :: 256
// Circles per area layer
@(private = "file")
AREA_CIRCLES_MAX :: 512
@(private = "file")
STROKES :: 3
// Line segments per stroke
@(private = "file")
STROKE_SEGMENTS_MAX :: 1 << 16

// Value of the strokes target where no segment is near, in cells
@(private = "file")
STROKE_FAR :: 1000

// Native Min. The binding's enum lacks webgpu.h's Undefined, so its values are one less than native
@(private = "file")
BLEND_MIN :: wgpu.BlendOperation(4)

@(private = "file")
VIEW_SHADER :: #load("view.wgsl", string)
@(private = "file")
GROUND_SHADER :: VIEW_SHADER + #load("ground.wgsl", string)
@(private = "file")
STROKE_SHADER :: VIEW_SHADER + #load("stroke.wgsl", string)

// The terrain's GPU objects and state between frames. Not in Renderer: too large to pass by value
@(private = "file")
TERRAIN: struct {
	// Ground pass data. ground_group is group 1: uniforms, sampler, grids
	ground_pipeline:       wgpu.RenderPipeline,
	ground_uniforms:       wgpu.Buffer,
	ground_grids:          [Ground_Grid]Texture,
	// GROUND_CATEGORIES x 2 texels. Row 0: wash colour, wash. Row 1: pattern, pattern ink
	ground_category_looks: Texture,
	// Area layers: 2D arrays, one slice per layer. CPU side: GROUND_AREAS.
	// Owners, fields: one texel per cell, a channel per Ground_Side.
	// Looks: AREAS_PER_LAYER x 2 texels. Row 0: colour, border. Row 1: thickness, inside
	ground_area_owners:    Texture,
	ground_area_fields:    Texture,
	ground_area_looks:     Texture,
	// AREA_CIRCLES_MAX x AREA_LAYERS texels, a row per layer:
	// centre, radius, area
	ground_area_circles:   Texture,
	ground_layout:         wgpu.BindGroupLayout,
	// Recreated on resize: it binds strokes_target and marks_target
	ground_group:          wgpu.BindGroup,
	// Strokes. Per stroke: a segment buffer, drawn every frame as distances into one channel of
	// strokes_target
	stroke_pipelines:      [STROKES]wgpu.RenderPipeline,
	stroke_buffers:        [STROKES]wgpu.Buffer,
	stroke_counts:         [STROKES]u32,
	// Window-sized, recreated on resize. Channel i: distance to stroke i's nearest segment, in cells
	strokes_target:        Texture,
	// Window-sized, recreated on resize. The marks, premultiplied
	marks_target:          Texture,
	// Marks in view this frame, as quads of the quad pipeline, drawn into marks_target
	marks_quads:           [dynamic; TERRAIN_MARKS_MAX]Render_Quad,
	marks_buffer:          wgpu.Buffer,
	// From the last build
	style:                 Render_Terrain_Style,
	marks:                 Terrain_Marks,
	// Region looks as drawn, eased toward the frame's. Index: region
	region_looks:          [AREAS_PER_LAYER]Ground_Area_Look,
	// Per highlight slot
	highlights:            [RENDER_TERRAIN_HIGHLIGHTS_MAX]Highlight_Drawn,
	// Hash of the wash last written. 0 = none
	wash_written:          u64,
}

@(private = "file")
Highlight_Drawn :: struct {
	// Hash of the highlight last written. 0 = none
	written: u64,
	// Area layer it was written to
	layer:   int,
	// Look as drawn, eased toward its kind's
	look:    Ground_Area_Look,
}

@(private = "file")
Texture :: struct {
	texture: wgpu.Texture,
	view:    wgpu.TextureView,
}

// Instance of the stroke pipeline, in cells
@(private = "file")
Stroke_Segment :: struct {
	a:    [2]f32,
	b:    [2]f32,
	// Arrowhead at b: length, width, in logical pixels. Zero = none
	head: [2]f32,
}

// Bindings of the ground group: uniforms, sampler, grids, category looks, strokes target,
// marks target
@(private = "file")
GROUND_BINDING_CATEGORY_LOOKS :: 2 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_STROKES_TARGET :: 3 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_MARKS_TARGET :: 4 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_AREA_OWNERS :: 5 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_AREA_FIELDS :: 6 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_AREA_LOOKS :: 7 + len(Ground_Grid)
@(private = "file")
GROUND_BINDING_AREA_CIRCLES :: 8 + len(Ground_Grid)
@(private = "file")
GROUND_BINDINGS :: 9 + len(Ground_Grid)

// Area fields. A field is how far a cell centre is inside its area, in cells, negative outside.
// Blur: sigma and kernel radius, in cells. Smooths the cell steps of the edges
@(private = "file")
AREA_BLUR_SIGMA :: 1.5
@(private = "file")
AREA_BLUR_REACH :: 4
// Cells recomputed around an area's bounds
@(private = "file")
AREA_MARGIN :: AREA_BLUR_REACH + 2
// Fields are clamped to +-this
@(private = "file")
AREA_FIELD_MAX :: 64
// Least field on an area's own cells after the blur, so they stay covered
@(private = "file")
AREA_OWN_MIN :: 0.1

// CPU side of the area layers. Not in Renderer: too large to pass by value
@(private = "file")
GROUND_AREAS: struct {
	// Per cell: on the land side of the divide. From the last Render_Update_Divide
	land:   [RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT]bool,
	layers: [AREA_LAYERS]Area_Layer,
}

@(private = "file")
Area_Layer :: struct {
	// Area per cell, 0 = none
	ids:          [RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT]u8,
	// Per cell and side: the area whose field the cell holds, 0 = none, and that field.
	// A cell outside every area holds the field of the area it is least outside of.
	// Mirrors of ground_area_owners and ground_area_fields
	owners:       [RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT][Ground_Side]u8,
	fields:       [RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT][Ground_Side]f16,
	// Per area: the side it lives on, and the bounds of its cells, [min, max). Empty: max = 0
	sides:        [AREAS_PER_LAYER]Ground_Side,
	bounds:       [AREAS_PER_LAYER]Area_Bounds,
	// Circles last written
	circle_count: i32,
}

@(private = "file")
Area_Bounds :: struct {
	min: [2]int,
	max: [2]int,
}

@(private = "file")
STROKES_TARGET_FORMAT :: wgpu.TextureFormat.RGBA16Float
#assert(STROKES <= 4)

@(private = "file")
Ground_Grid_Format :: struct {
	format:     wgpu.TextureFormat,
	// Bytes per texel
	texel_size: int,
}

@(private = "file", rodata)
GROUND_GRID_FORMATS := [Ground_Grid]Ground_Grid_Format {
	.Value    = {.R8Unorm, 1},
	.Divide   = {.R16Float, 2},
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
	strokes:           [STROKES]Stroke_Uniform,
	areas:             [AREA_LAYERS]Area_Layer_Uniform,
}
#assert(size_of(Ground_Uniform) == 144 + 48 * STROKES + 48 * AREA_LAYERS)

// Must match struct Area_Layer in ground.wgsl
@(private = "file")
Area_Layer_Uniform :: struct {
	border_color:    [3]f32,
	border_strength: f32,
	border_width:    f32,
	border_clip:     i32,
	wander:          f32,
	strength:        f32,
	circle_count:    i32,
	_:               [3]i32,
}

// Must match struct Stroke in ground.wgsl. Field use per kind: see the Ground_Stroke variants
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
	Arrow,
}

// Creates the terrain's GPU objects: grids zero-initialised, pipelines, the marks buffer.
// The window-sized targets and the ground's bind group come with terrain_resize
terrain_init :: proc(rend: ^Renderer) {
	// Ground: grid textures (zero-initialised), uniform buffer, bind group, pipeline
	{
		for format, grid in GROUND_GRID_FORMATS {
			texture := wgpu.DeviceCreateTexture(
				rend.device,
				&{
					label = "ground grid",
					usage = {.TextureBinding, .CopyDst},
					dimension = ._2D,
					size = {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT, 1},
					format = format.format,
					mipLevelCount = 1,
					sampleCount = 1,
				},
			)
			TERRAIN.ground_grids[grid] = {texture, wgpu.TextureCreateView(texture)}
		}
		{
			texture := wgpu.DeviceCreateTexture(
				rend.device,
				&{
					label = "ground category looks",
					usage = {.TextureBinding, .CopyDst},
					dimension = ._2D,
					size = {GROUND_CATEGORIES, 2, 1},
					format = .RGBA8Unorm,
					mipLevelCount = 1,
					sampleCount = 1,
				},
			)
			TERRAIN.ground_category_looks = {texture, wgpu.TextureCreateView(texture)}
		}
		// Area layers
		{
			Area_Texture :: struct {
				texture: ^Texture,
				format:  wgpu.TextureFormat,
				size:    [2]u32,
			}
			area_textures := [?]Area_Texture {
				{
					&TERRAIN.ground_area_owners,
					.RG8Unorm,
					{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
				},
				{
					&TERRAIN.ground_area_fields,
					.RG16Float,
					{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
				},
				{&TERRAIN.ground_area_looks, .RGBA32Float, {AREAS_PER_LAYER, 2}},
			}
			for area_texture in area_textures {
				texture := wgpu.DeviceCreateTexture(
					rend.device,
					&{
						label = "ground areas",
						usage = {.TextureBinding, .CopyDst},
						dimension = ._2D,
						size = {area_texture.size.x, area_texture.size.y, AREA_LAYERS},
						format = area_texture.format,
						mipLevelCount = 1,
						sampleCount = 1,
					},
				)
				// Array view even with one layer
				view := wgpu.TextureCreateView(
					texture,
					&{
						format = area_texture.format,
						dimension = ._2DArray,
						mipLevelCount = 1,
						arrayLayerCount = AREA_LAYERS,
						aspect = .All,
					},
				)
				area_texture.texture^ = {texture, view}
			}
		}
		{
			texture := wgpu.DeviceCreateTexture(
				rend.device,
				&{
					label = "ground area circles",
					usage = {.TextureBinding, .CopyDst},
					dimension = ._2D,
					size = {AREA_CIRCLES_MAX, AREA_LAYERS, 1},
					format = .RGBA32Float,
					mipLevelCount = 1,
					sampleCount = 1,
				},
			)
			TERRAIN.ground_area_circles = {texture, wgpu.TextureCreateView(texture)}
		}
		TERRAIN.ground_uniforms = wgpu.DeviceCreateBuffer(
			rend.device,
			&{
				label = "ground uniforms",
				usage = {.Uniform, .CopyDst},
				size = size_of(Ground_Uniform),
			},
		)

		// Group 1. Binding 0: uniforms, 1: sampler, 2 + grid: grid texture, then the category looks,
		// the strokes target, the marks target and the area layers' owners, fields, looks and circles.
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
		for binding in ([?]u32{GROUND_BINDING_AREA_OWNERS, GROUND_BINDING_AREA_FIELDS}) {
			layout_entries[binding].texture.viewDimension = ._2DArray
		}
		// 32-bit floats cannot be filtered
		layout_entries[GROUND_BINDING_AREA_LOOKS].texture = {
			sampleType    = .UnfilterableFloat,
			viewDimension = ._2DArray,
		}
		layout_entries[GROUND_BINDING_AREA_CIRCLES].texture.sampleType = .UnfilterableFloat
		TERRAIN.ground_layout = wgpu.DeviceCreateBindGroupLayout(
			rend.device,
			&{label = "ground", entryCount = len(layout_entries), entries = &layout_entries[0]},
		)

		module := wgpu.DeviceCreateShaderModule(
			rend.device,
			&{
				nextInChain = &wgpu.ShaderSourceWGSL {
					sType = .ShaderSourceWGSL,
					code = GROUND_SHADER,
				},
				label = "ground",
			},
		)
		defer wgpu.ShaderModuleRelease(module)

		group_layouts := [?]wgpu.BindGroupLayout{rend.view_layout, TERRAIN.ground_layout}
		layout := wgpu.DeviceCreatePipelineLayout(
			rend.device,
			&{
				label = "ground",
				bindGroupLayoutCount = len(group_layouts),
				bindGroupLayouts = &group_layouts[0],
			},
		)
		defer wgpu.PipelineLayoutRelease(layout)

		TERRAIN.ground_pipeline = wgpu.DeviceCreateRenderPipeline(
			rend.device,
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
						format = rend.format.view,
						writeMask = wgpu.ColorWriteMaskFlags_All,
					},
				},
			},
		)
	}

	// Strokes: one segment buffer and one pipeline per stroke. Pipelines differ in the channel written
	{
		module := wgpu.DeviceCreateShaderModule(
			rend.device,
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
			rend.device,
			&{label = "stroke", bindGroupLayoutCount = 1, bindGroupLayouts = &rend.view_layout},
		)
		defer wgpu.PipelineLayoutRelease(layout)

		attributes := [?]wgpu.VertexAttribute {
			{format = .Float32x2, offset = u64(offset_of(Stroke_Segment, a)), shaderLocation = 0},
			{format = .Float32x2, offset = u64(offset_of(Stroke_Segment, b)), shaderLocation = 1},
			{
				format = .Float32x2,
				offset = u64(offset_of(Stroke_Segment, head)),
				shaderLocation = 2,
			},
		}
		// Keeps the smallest distance written to a pixel
		nearest := wgpu.BlendState {
			color = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
			alpha = {operation = BLEND_MIN, srcFactor = .One, dstFactor = .One},
		}
		for stroke in 0 ..< STROKES {
			TERRAIN.stroke_buffers[stroke] = wgpu.DeviceCreateBuffer(
				rend.device,
				&{
					label = "stroke segments",
					usage = {.Vertex, .CopyDst},
					size = STROKE_SEGMENTS_MAX * size_of(Stroke_Segment),
				},
			)
			TERRAIN.stroke_pipelines[stroke] = wgpu.DeviceCreateRenderPipeline(
				rend.device,
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
						module      = module,
						entryPoint  = "fs_main",
						targetCount = 1,
						targets     = &wgpu.ColorTargetState {
							format    = STROKES_TARGET_FORMAT,
							blend     = &nearest,
							// Channel = stroke index
							writeMask = {wgpu.ColorWriteMask(stroke)},
						},
					},
				},
			)
		}
	}

	TERRAIN.marks_buffer = wgpu.DeviceCreateBuffer(
		rend.device,
		&{
			label = "terrain marks",
			usage = {.Vertex, .CopyDst},
			size = u64(size_of(Render_Quad) * TERRAIN_MARKS_MAX),
		},
	)
}

terrain_deinit :: proc() {
	if TERRAIN.marks_buffer != nil do wgpu.BufferRelease(TERRAIN.marks_buffer)
	for pipeline in TERRAIN.stroke_pipelines do if pipeline != nil do wgpu.RenderPipelineRelease(pipeline)
	for buffer in TERRAIN.stroke_buffers do if buffer != nil do wgpu.BufferRelease(buffer)
	for target in ([?]Texture{TERRAIN.strokes_target, TERRAIN.marks_target}) {
		if target.view != nil do wgpu.TextureViewRelease(target.view)
		if target.texture != nil do wgpu.TextureRelease(target.texture)
	}

	if TERRAIN.ground_pipeline != nil do wgpu.RenderPipelineRelease(TERRAIN.ground_pipeline)
	if TERRAIN.ground_group != nil do wgpu.BindGroupRelease(TERRAIN.ground_group)
	if TERRAIN.ground_layout != nil do wgpu.BindGroupLayoutRelease(TERRAIN.ground_layout)
	if TERRAIN.ground_uniforms != nil do wgpu.BufferRelease(TERRAIN.ground_uniforms)
	for grid in TERRAIN.ground_grids {
		if grid.view != nil do wgpu.TextureViewRelease(grid.view)
		if grid.texture != nil do wgpu.TextureRelease(grid.texture)
	}
	for texture in ([?]Texture {
			TERRAIN.ground_area_owners,
			TERRAIN.ground_area_fields,
			TERRAIN.ground_area_looks,
			TERRAIN.ground_area_circles,
		}) {
		if texture.view != nil do wgpu.TextureViewRelease(texture.view)
		if texture.texture != nil do wgpu.TextureRelease(texture.texture)
	}
	if TERRAIN.ground_category_looks.view != nil {
		wgpu.TextureViewRelease(TERRAIN.ground_category_looks.view)
	}
	if TERRAIN.ground_category_looks.texture != nil {
		wgpu.TextureRelease(TERRAIN.ground_category_looks.texture)
	}
}

// Recreates the window-sized targets, and the ground's bind group that binds them.
// size: physical pixels
terrain_resize :: proc(rend: ^Renderer, size: [2]i32) {
	// Strokes and marks targets, and the ground group that binds them
	{
		if TERRAIN.ground_group != nil do wgpu.BindGroupRelease(TERRAIN.ground_group)
		for target in ([?]Texture{TERRAIN.strokes_target, TERRAIN.marks_target}) {
			if target.view != nil do wgpu.TextureViewRelease(target.view)
			if target.texture != nil do wgpu.TextureRelease(target.texture)
		}

		// Marks are drawn by the quad pipeline, so in the surface's view format
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
		TERRAIN.strokes_target = targets[0]
		TERRAIN.marks_target = targets[1]

		entries: [GROUND_BINDINGS]wgpu.BindGroupEntry
		entries[0] = {
			binding = 0,
			buffer  = TERRAIN.ground_uniforms,
			size    = size_of(Ground_Uniform),
		}
		entries[1] = {
			binding = 1,
			sampler = rend.sampler,
		}
		for grid, kind in TERRAIN.ground_grids {
			entries[2 + int(kind)] = {
				binding     = 2 + u32(kind),
				textureView = grid.view,
			}
		}
		entries[GROUND_BINDING_CATEGORY_LOOKS] = {
			binding     = GROUND_BINDING_CATEGORY_LOOKS,
			textureView = TERRAIN.ground_category_looks.view,
		}
		entries[GROUND_BINDING_STROKES_TARGET] = {
			binding     = GROUND_BINDING_STROKES_TARGET,
			textureView = TERRAIN.strokes_target.view,
		}
		entries[GROUND_BINDING_AREA_OWNERS] = {
			binding     = GROUND_BINDING_AREA_OWNERS,
			textureView = TERRAIN.ground_area_owners.view,
		}
		entries[GROUND_BINDING_AREA_FIELDS] = {
			binding     = GROUND_BINDING_AREA_FIELDS,
			textureView = TERRAIN.ground_area_fields.view,
		}
		entries[GROUND_BINDING_AREA_LOOKS] = {
			binding     = GROUND_BINDING_AREA_LOOKS,
			textureView = TERRAIN.ground_area_looks.view,
		}
		entries[GROUND_BINDING_AREA_CIRCLES] = {
			binding     = GROUND_BINDING_AREA_CIRCLES,
			textureView = TERRAIN.ground_area_circles.view,
		}
		entries[GROUND_BINDING_MARKS_TARGET] = {
			binding     = GROUND_BINDING_MARKS_TARGET,
			textureView = TERRAIN.marks_target.view,
		}
		TERRAIN.ground_group = wgpu.DeviceCreateBindGroup(
			rend.device,
			&{
				label = "ground",
				layout = TERRAIN.ground_layout,
				entryCount = len(entries),
				entries = &entries[0],
			},
		)
	}
}

// A frame's terrain: eases the looks, writes the highlights that changed, the arrow, the wash if
// it changed, the ground's uniforms, and the marks in view.
// window: size of the window in logical pixels
terrain_frame :: proc(
	rend: ^Renderer,
	frame: ^Render_Terrain_Frame,
	view: Render_View,
	window: [2]f32,
) {
	// A highlight's cells, in frame.highlight_cells
	cells_of :: proc(frame: ^Render_Terrain_Frame, highlight: Render_Highlight) -> []bool {
		count := highlight.size.x * highlight.size.y
		return frame.highlight_cells[highlight.cells_begin:][:count]
	}

	style := &TERRAIN.style

	// Step: Visible. The part of the world in the window, in cells
	visible: Extents
	{
		half := window / 2 / view.zoom
		visible = {
			x_min = view.center.x - half.x,
			y_min = view.center.y - half.y,
			x_max = view.center.x + half.x,
			y_max = view.center.y + half.y,
		}
	}
	// Share of the way to its target a look moves this frame
	ease := 1 - math.exp(-LOOK_EASE * frame.dt)

	// Step: Regions. Band by display, zoom and highlight
	{
		far := view.zoom < REGION_FAR_ZOOM
		for region, id in frame.regions {
			if id == 0 do continue
			band: Render_Band
			switch frame.region_display {
			case .Hidden:
			case .Outlined:
				band = region.highlighted ? style.region_near_highlighted : style.region_near
			case .Filled_When_Far:
				if far {
					band = region.highlighted ? style.region_far_highlighted : style.region_far
				} else {
					band = region.highlighted ? style.region_near_highlighted : style.region_near
				}
			}
			drawn := &TERRAIN.region_looks[id]
			drawn.color += (region.color - drawn.color) * ease
			drawn.border += (band.border - drawn.border) * ease
			drawn.thickness += (band.thickness - drawn.thickness) * ease
			drawn.inside += (band.inside - drawn.inside) * ease
		}
		ground_area_looks_write(rend, LAYER_REGIONS, TERRAIN.region_looks[:])
	}

	// Step: Highlights. Slot i is area i + 1 of its kind's layer. Cells are written when they change
	{
		looks: [AREA_LAYERS][RENDER_TERRAIN_HIGHLIGHTS_MAX + 1]Ground_Area_Look
		circles: [AREA_LAYERS][dynamic; AREA_CIRCLES_MAX]Ground_Area_Circle
		for &drawn, slot in TERRAIN.highlights {
			area := u8(slot + 1)
			highlight := frame.highlights[slot]
			cells := cells_of(frame, highlight)
			shown := len(cells) > 0
			layer := HIGHLIGHT_LAYERS[highlight.kind]
			look := style.highlight_looks[highlight.kind]

			// 0 is kept for "none"
			content: u64
			if shown {
				header := [6]int {
					int(highlight.kind),
					int(highlight.on_water),
					highlight.corner.x,
					highlight.corner.y,
					highlight.size.x,
					highlight.size.y,
				}
				content = u64(xxhash.XXH3_64_default(slice.to_bytes(header[:])))
				content = u64(xxhash.XXH3_64_with_seed(slice.to_bytes(cells), content))
				content = max(content, 1)
			}

			if content != drawn.written {
				// Gone, or moved to another layer
				if drawn.written != 0 && (!shown || drawn.layer != layer) {
					ground_area_write(rend, drawn.layer, area, .Land, {}, {}, nil)
				}
				if shown {
					if look.widen > 0 {
						thick := make([]bool, len(cells), context.temp_allocator)
						mask_thicken(cells, highlight.size, look.widen, WIDEN_SUPPORT, thick)
						// Cells added by thickening are not taken from the layer's other highlights
						for &inside, i in thick {
							if !inside || cells[i] do continue
							cell := highlight.corner + {i % highlight.size.x, i / highlight.size.x}
							for other, other_slot in frame.highlights {
								if other_slot == slot || HIGHLIGHT_LAYERS[other.kind] != layer do continue
								at := cell - other.corner
								if at.x < 0 || at.y < 0 || at.x >= other.size.x || at.y >= other.size.y do continue
								if cells_of(frame, other)[at.y * other.size.x + at.x] {
									inside = false
									break
								}
							}
						}
						cells = thick
					}
					ground_area_write(
						rend,
						layer,
						area,
						highlight.on_water ? .Water : .Land,
						highlight.corner,
						highlight.size,
						cells,
					)
					// Fades in
					drawn.look.border = 0
					drawn.look.inside = 0
				}
				drawn.written = content
				drawn.layer = layer
			}
			if !shown do continue

			drawn.look.color += (look.color - drawn.look.color) * ease
			drawn.look.border += (look.band.border - drawn.look.border) * ease
			drawn.look.thickness += (look.band.thickness - drawn.look.thickness) * ease
			drawn.look.inside += (look.band.inside - drawn.look.inside) * ease
			looks[layer][area] = drawn.look
			for circle in frame.highlight_circles[highlight.circles_begin:][:highlight.circles_len] {
				if len(circles[layer]) == AREA_CIRCLES_MAX do break
				append(&circles[layer], Ground_Area_Circle{circle.center, circle.radius, area})
			}
		}
		for layer in HIGHLIGHT_AREA_LAYERS {
			ground_area_looks_write(rend, layer, looks[layer][:])
			ground_area_circles_write(rend, layer, circles[layer][:])
		}
	}

	// Step: Arrow
	{
		arrow := new(Polylines(RENDER_TERRAIN_ARROW_POINTS_MAX, 1), context.temp_allocator)
		copy(polylines_reserve(len(frame.arrow), false, arrow), frame.arrow[:])
		ground_stroke_write(
			rend,
			STROKE_ARROWS,
			arrow,
			{style.arrow_head_length, style.arrow_head_width},
		)
	}

	// Step: Wash. Its values are written when they change
	ground := ground_from_style(style^)
	if len(frame.wash) > 0 {
		assert(len(frame.wash) == RENDER_TERRAIN_CELLS)
		content := max(u64(xxhash.XXH3_64_default(frame.wash[:])), 1)
		if content != TERRAIN.wash_written {
			ground_value_write(rend, frame.wash[:])
			TERRAIN.wash_written = content
		}
		ground.value = {
			low      = style.wash_low,
			high     = style.wash_high,
			strength = style.wash_strength,
			clip     = .Land,
		}
	}

	// Step: Uniforms
	uniform := Ground_Uniform {
		base_color        = ground.base.color,
		stain_amount      = ground.base.stain_amount,
		base_stain        = ground.base.stain,
		category_jitter   = ground.category.jitter,
		category_pattern  = ground.category.pattern_color,
		category_strength = ground.category.strength,
		divide_shallow    = ground.divide.shallow,
		divide_tint       = ground.divide.tint,
		divide_deep       = ground.divide.deep,
		divide_wobble     = ground.divide.wobble,
		divide_line_color = ground.divide.line_color,
		divide_line_width = ground.divide.line_width,
		value_low         = ground.value.low,
		value_strength    = ground.value.strength,
		value_high        = ground.value.high,
		value_clip        = i32(ground.value.clip),
		grid              = {RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT},
		divide_depth_from = ground.divide.depth_from,
		divide_depth_full = ground.divide.depth_full,
	}
	for layer, i in ground.areas {
		uniform.areas[i] = {
			border_color    = layer.border_color,
			border_strength = layer.border_strength,
			border_width    = layer.border_width,
			border_clip     = i32(layer.border_clip),
			wander          = layer.wander,
			strength        = layer.strength,
			circle_count    = GROUND_AREAS.layers[i].circle_count,
		}
	}
	for stroke, i in ground.strokes {
		switch look in stroke {
		case Ground_Stroke_Line:
			uniform.strokes[i] = {
				kind     = .Line,
				color    = look.color,
				width    = look.width,
				fill     = look.wash_color,
				strength = look.wash_strength,
				wander   = look.wander,
				clip     = i32(look.clip),
			}
		case Ground_Stroke_Double:
			uniform.strokes[i] = {
				kind       = .Double,
				color      = look.edge_color,
				width      = look.width,
				fill       = look.fill_color,
				strength   = look.fill_strength,
				edge_width = look.edge_width,
				clip       = i32(look.clip),
			}
		case Ground_Stroke_Arrow:
			uniform.strokes[i] = {
				kind       = .Arrow,
				color      = look.edge_color,
				width      = look.width,
				fill       = look.fill_color,
				edge_width = look.edge_width,
			}
		}
	}
	wgpu.QueueWriteBuffer(rend.queue, TERRAIN.ground_uniforms, 0, &uniform, size_of(uniform))

	// Step: Marks in view
	{
		clear(&TERRAIN.marks_quads)
		terrain_marks_quads(&TERRAIN.marks, visible, &TERRAIN.marks_quads)
		if len(TERRAIN.marks_quads) > 0 {
			wgpu.QueueWriteBuffer(
				rend.queue,
				TERRAIN.marks_buffer,
				0,
				raw_data(TERRAIN.marks_quads[:]),
				uint(len(TERRAIN.marks_quads) * size_of(Render_Quad)),
			)
		}
	}
}

// The terrain's offscreen passes: distances to the strokes, and the marks in view. The ground
// shader reads both
terrain_encode :: proc(rend: ^Renderer, encoder: wgpu.CommandEncoder) {
	// Strokes pass: segment distances into the strokes target, for the ground shader
	{
		pass := wgpu.CommandEncoderBeginRenderPass(
			encoder,
			&{
				colorAttachmentCount = 1,
				colorAttachments = &wgpu.RenderPassColorAttachment {
					view = TERRAIN.strokes_target.view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {STROKE_FAR, STROKE_FAR, STROKE_FAR, STROKE_FAR},
				},
			},
		)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[.World])
		for count, stroke in TERRAIN.stroke_counts {
			if count == 0 do continue
			wgpu.RenderPassEncoderSetPipeline(pass, TERRAIN.stroke_pipelines[stroke])
			wgpu.RenderPassEncoderSetVertexBuffer(
				pass,
				0,
				TERRAIN.stroke_buffers[stroke],
				0,
				u64(count) * size_of(Stroke_Segment),
			)
			wgpu.RenderPassEncoderDraw(pass, 6, count, 0, 0)
		}
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}

	// Marks pass: the marks in view into the marks target
	{
		pass := wgpu.CommandEncoderBeginRenderPass(
			encoder,
			&{
				colorAttachmentCount = 1,
				colorAttachments = &wgpu.RenderPassColorAttachment {
					view = TERRAIN.marks_target.view,
					depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
					loadOp = .Clear,
					storeOp = .Store,
					clearValue = {0, 0, 0, 0},
				},
			},
		)
		quads_draw(rend, pass, TERRAIN.marks_buffer, .World, 0, len(TERRAIN.marks_quads))
		wgpu.RenderPassEncoderEnd(pass)
		wgpu.RenderPassEncoderRelease(pass)
	}
}

// The ground: one triangle over the window
terrain_draw :: proc(rend: ^Renderer, pass: wgpu.RenderPassEncoder) {
	wgpu.RenderPassEncoderSetPipeline(pass, TERRAIN.ground_pipeline)
	wgpu.RenderPassEncoderSetBindGroup(pass, 0, rend.view_groups[.World])
	wgpu.RenderPassEncoderSetBindGroup(pass, 1, TERRAIN.ground_group)
	wgpu.RenderPassEncoderDraw(pass, 3, 1, 0, 0)
}

// The ground's layers for a style. Value layer: off, see the wash in terrain_frame
@(private = "file")
ground_from_style :: proc(style: Render_Terrain_Style) -> (ground: Ground) {
	ground.base = {
		color        = style.paper,
		stain        = style.paper_stain,
		stain_amount = style.paper_stain_amount,
	}
	ground.category = {
		pattern_color = style.ink,
		strength      = 1,
		jitter        = style.cover_jitter,
	}
	ground.divide = {
		shallow    = style.sea_shallow,
		deep       = style.sea_deep,
		depth_from = style.sea_depth_from,
		depth_full = style.sea_depth_full,
		tint       = style.sea_tint,
		line_color = style.ink,
		line_width = style.coast_width,
		wobble     = style.wobble * EDGE_WOBBLE,
	}
	ground.areas[LAYER_REGIONS] = {
		border_color    = style.border_ink,
		border_strength = style.border_strength,
		border_width    = style.border_width,
		border_clip     = .Land,
		wander          = style.wobble * EDGE_WOBBLE,
		strength        = 1,
	}
	for layer in HIGHLIGHT_AREA_LAYERS {
		ground.areas[layer] = {
			wander   = style.wobble * EDGE_WOBBLE,
			strength = 1,
		}
	}
	ground.strokes[STROKE_ARROWS] = Ground_Stroke_Arrow {
		width      = style.arrow_width,
		fill_color = style.arrow_fill,
		edge_color = style.ink,
		edge_width = 1,
	}
	ground.strokes[STROKE_RIVERS] = Ground_Stroke_Line {
		color         = style.ink + (style.sea_shallow - style.ink) * 0.3,
		width         = style.river_width,
		wash_color    = style.sea_shallow,
		wash_strength = style.sea_tint * 0.5,
		wander        = style.wobble,
		clip          = .Land,
	}
	ground.strokes[STROKE_ROADS] = Ground_Stroke_Double {
		width         = style.road_width,
		edge_color    = style.ink,
		edge_width    = style.road_stroke,
		fill_color    = style.road_fill,
		fill_strength = style.road_fill_strength,
		clip          = .Land,
	}
	return
}

// Overwrites the Value grid: input of Ground.value
@(private = "file")
ground_value_write :: proc(
	rend: ^Renderer,
	// 1 byte per cell, read as 0..1. Row-major from the top-left
	cells: []u8,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Value, raw_data(cells), len(cells))
}

// Overwrites the Divide grid: input of Ground.divide
@(private = "file")
ground_divide_write :: proc(
	rend: ^Renderer,
	// Signed distance per cell, in cells. > 0 land side, < 0 water side. Row-major from the top-left
	distances: []f32,
) {
	if !(.Ready in rend.flags) do return
	// Stored as 16-bit floats
	halves := make([]f16, len(distances), context.temp_allocator)
	for distance, i in distances do halves[i] = f16(distance)
	ground_grid_write(rend, .Divide, raw_data(halves), len(halves))

	// The area layers' fields depend on each cell's side
	for distance, i in distances do GROUND_AREAS.land[i] = distance > 0
}

// Replaces every area of a layer. Each area's edges are smoothed, and neighbours share theirs.
// Cells are taken on the given side of the divide only: write the Divide grid first
@(private = "file")
ground_areas_write :: proc(
	rend: ^Renderer,
	layer: int,
	// Area per cell, 0 = none. Row-major from the top-left
	ids: []u8,
	side: Ground_Side,
) {
	if !(.Ready in rend.flags) do return
	assert(layer >= 0 && layer < AREA_LAYERS)
	assert(len(ids) == RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT)
	areas := &GROUND_AREAS.layers[layer]

	// Step: Cells. Ids on the side, and the bounds of each area
	areas.bounds = {}
	bounds := &areas.bounds
	for id, i in ids {
		areas.owners[i] = {}
		areas.fields[i] = {}
		areas.ids[i] = 0
		if id == 0 || GROUND_AREAS.land[i] != (side == .Land) do continue
		areas.ids[i] = id
		cell := [2]int{i % RENDER_TERRAIN_WIDTH, i / RENDER_TERRAIN_WIDTH}
		if bounds[id].max == {} {
			bounds[id] = {cell, cell + 1}
		} else {
			bounds[id].min = {min(bounds[id].min.x, cell.x), min(bounds[id].min.y, cell.y)}
			bounds[id].max = {max(bounds[id].max.x, cell.x + 1), max(bounds[id].max.y, cell.y + 1)}
		}
	}

	// Step: Fields
	for area in 1 ..< AREAS_PER_LAYER {
		if bounds[area].max == {} do continue
		areas.sides[area] = side
		area_field_build(
			areas,
			u8(area),
			bounds[area].min - AREA_MARGIN,
			bounds[area].max + AREA_MARGIN,
		)
	}

	// Step: Upload the layer
	extent := wgpu.Extent3D{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT, 1}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{
			texture = TERRAIN.ground_area_owners.texture,
			origin = {0, 0, u32(layer)},
			aspect = .All,
		},
		&areas.owners,
		size_of(areas.owners),
		&{bytesPerRow = RENDER_TERRAIN_WIDTH * 2, rowsPerImage = RENDER_TERRAIN_HEIGHT},
		&extent,
	)
	wgpu.QueueWriteTexture(
		rend.queue,
		&{
			texture = TERRAIN.ground_area_fields.texture,
			origin = {0, 0, u32(layer)},
			aspect = .All,
		},
		&areas.fields,
		size_of(areas.fields),
		&{bytesPerRow = RENDER_TERRAIN_WIDTH * 4, rowsPerImage = RENDER_TERRAIN_HEIGHT},
		&extent,
	)
}

// Replaces the cells of one area of a layer: mask[y * size.x + x] for cell corner + {x, y}.
// An empty mask removes the area. Cells are taken on the given side of the divide only, and are
// taken from the layer's other areas
@(private = "file")
ground_area_write :: proc(
	rend: ^Renderer,
	layer: int,
	area: u8,
	side: Ground_Side,
	corner: [2]int,
	size: [2]int,
	mask: []bool,
) {
	if !(.Ready in rend.flags) do return
	assert(layer >= 0 && layer < AREA_LAYERS)
	assert(area != 0)
	assert(len(mask) == size.x * size.y)
	GRID :: [2]int{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}
	areas := &GROUND_AREAS.layers[layer]

	// Step: Cells. Drop the old ones, take the new ones. Areas losing cells are rebuilt too
	before := areas.bounds[area]
	before_side := areas.sides[area]
	for y in before.min.y ..< before.max.y {
		for x in before.min.x ..< before.max.x {
			if areas.ids[y * GRID.x + x] == area do areas.ids[y * GRID.x + x] = 0
		}
	}
	after: Area_Bounds
	robbed: [AREAS_PER_LAYER]bool
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			if !mask[y * size.x + x] do continue
			cell := corner + {x, y}
			if cell.x < 0 || cell.y < 0 || cell.x >= GRID.x || cell.y >= GRID.y do continue
			index := cell.y * GRID.x + cell.x
			if GROUND_AREAS.land[index] != (side == .Land) do continue
			if was := areas.ids[index]; was != 0 do robbed[was] = true
			areas.ids[index] = area
			if after.max == {} {
				after = {cell, cell + 1}
			} else {
				after.min = {min(after.min.x, cell.x), min(after.min.y, cell.y)}
				after.max = {max(after.max.x, cell.x + 1), max(after.max.y, cell.y + 1)}
			}
		}
	}
	areas.bounds[area] = after
	areas.sides[area] = side
	if before.max == {} && after.max == {} do return

	// Step: Fields. Over the old and new bounds: fields held for the area there are dropped,
	// then rebuilt from the new cells
	around := after.max == {} ? before : after
	if before.max != {} && after.max != {} {
		around.min = {min(before.min.x, after.min.x), min(before.min.y, after.min.y)}
		around.max = {max(before.max.x, after.max.x), max(before.max.y, after.max.y)}
	}
	around = {around.min - AREA_MARGIN, around.max + AREA_MARGIN}
	for y in max(around.min.y, 0) ..< min(around.max.y, GRID.y) {
		for x in max(around.min.x, 0) ..< min(around.max.x, GRID.x) {
			index := y * GRID.x + x
			for held_side in Ground_Side {
				if areas.owners[index][held_side] != area do continue
				areas.owners[index][held_side] = 0
				areas.fields[index][held_side] = 0
			}
		}
	}
	if after.max != {} do area_field_build(areas, area, around.min, around.max)
	for was_robbed, other in robbed {
		if !was_robbed || u8(other) == area do continue
		lo := areas.bounds[other].min - AREA_MARGIN
		hi := areas.bounds[other].max + AREA_MARGIN
		area_field_build(areas, u8(other), lo, hi)
		around.min = {min(around.min.x, lo.x), min(around.min.y, lo.y)}
		around.max = {max(around.max.x, hi.x), max(around.max.y, hi.y)}
	}

	// Step: Upload the cells touched
	lo := [2]int{max(around.min.x, 0), max(around.min.y, 0)}
	hi := [2]int{min(around.max.x, GRID.x), min(around.max.y, GRID.y)}
	if hi.x <= lo.x || hi.y <= lo.y do return
	first := lo.y * GRID.x + lo.x
	extent := wgpu.Extent3D{u32(hi.x - lo.x), u32(hi.y - lo.y), 1}
	origin := wgpu.Origin3D{u32(lo.x), u32(lo.y), u32(layer)}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = TERRAIN.ground_area_owners.texture, origin = origin, aspect = .All},
		&areas.owners,
		size_of(areas.owners),
		&{
			offset = u64(first * 2),
			bytesPerRow = RENDER_TERRAIN_WIDTH * 2,
			rowsPerImage = extent.height,
		},
		&extent,
	)
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = TERRAIN.ground_area_fields.texture, origin = origin, aspect = .All},
		&areas.fields,
		size_of(areas.fields),
		&{
			offset = u64(first * 4),
			bytesPerRow = RENDER_TERRAIN_WIDTH * 4,
			rowsPerImage = extent.height,
		},
		&extent,
	)
}

// Overwrites the circles of a layer. A circle adds a disc to its area's shape, cut at the divide like
// the area. Circles of one area must be consecutive. Circles past the budget are dropped
@(private = "file")
ground_area_circles_write :: proc(rend: ^Renderer, layer: int, circles: []Ground_Area_Circle) {
	if !(.Ready in rend.flags) do return
	assert(layer >= 0 && layer < AREA_LAYERS)

	count := min(len(circles), AREA_CIRCLES_MAX)
	GROUND_AREAS.layers[layer].circle_count = i32(count)
	if count == 0 do return
	texels: [AREA_CIRCLES_MAX][4]f32
	for circle, i in circles[:count] {
		texels[i] = {circle.center.x, circle.center.y, circle.radius, f32(circle.area)}
	}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{
			texture = TERRAIN.ground_area_circles.texture,
			origin = {0, u32(layer), 0},
			aspect = .All,
		},
		&texels,
		uint(count * size_of([4]f32)),
		&{bytesPerRow = AREA_CIRCLES_MAX * size_of([4]f32), rowsPerImage = 1},
		&{u32(count), 1, 1},
	)
}

// Overwrites the look of every area of a layer: looks[i] for area i, none past len(looks)
@(private = "file")
ground_area_looks_write :: proc(rend: ^Renderer, layer: int, looks: []Ground_Area_Look) {
	if !(.Ready in rend.flags) do return
	assert(layer >= 0 && layer < AREA_LAYERS)
	assert(len(looks) <= AREAS_PER_LAYER)

	// Row 1 also carries the area's side, for its circles
	texels: [2][AREAS_PER_LAYER][4]f32
	for look, i in looks {
		texels[0][i] = {look.color.r, look.color.g, look.color.b, look.border}
		texels[1][i] = {look.thickness, look.inside, f32(GROUND_AREAS.layers[layer].sides[i]), 0}
	}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = TERRAIN.ground_area_looks.texture, origin = {0, 0, u32(layer)}, aspect = .All},
		&texels,
		size_of(texels),
		&{bytesPerRow = AREAS_PER_LAYER * size_of([4]f32), rowsPerImage = 2},
		&{AREAS_PER_LAYER, 2, 1},
	)
}

// In/out: areas.
// Recomputes the field of one area over the cells of [lo, hi), and writes it to the cells that hold it:
// the area's own, and those outside every area that are nearer to it than to the area they hold.
// Field: signed distance from the cell centre to the area's edge, less half a cell, blurred.
// Cells of the other side of the divide are neither inside nor outside: the field passes over them
@(private = "file")
area_field_build :: proc(areas: ^Area_Layer, area: u8, lo: [2]int, hi: [2]int) {
	GRID :: [2]int{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}
	side := areas.sides[area]

	in_grid :: proc(cell: [2]int) -> bool {
		return cell.x >= 0 && cell.y >= 0 && cell.x < GRID.x && cell.y < GRID.y
	}
	on_side :: proc(side: Ground_Side, cell: [2]int) -> bool {
		if !in_grid(cell) do return false
		return GROUND_AREAS.land[cell.y * GRID.x + cell.x] == (side == .Land)
	}

	// Step: Distances to the nearest cell outside the area, and inside it
	size := hi - lo
	inside := make([]bool, size.x * size.y, context.temp_allocator)
	outside := make([]bool, size.x * size.y, context.temp_allocator)
	for y in 0 ..< size.y {
		for x in 0 ..< size.x {
			cell := lo + {x, y}
			i := y * size.x + x
			inside[i] = on_side(side, cell) && areas.ids[cell.y * GRID.x + cell.x] == area
			// Off the grid counts as outside
			outside[i] = !inside[i] && (on_side(side, cell) || !in_grid(cell))
		}
	}
	out_by := make([]f32, size.x * size.y, context.temp_allocator)
	in_by := make([]f32, size.x * size.y, context.temp_allocator)
	distance_transform(outside, size, out_by)
	distance_transform(inside, size, in_by)

	// Step: Field
	field := make([]f32, size.x * size.y, context.temp_allocator)
	for &value, i in field {
		switch {
		case in_by[i] == 0:
			value = out_by[i] - 0.5
		case out_by[i] == 0:
			value = 0.5 - in_by[i]
		case:
			value = (out_by[i] - in_by[i]) / 2
		}
		value = clamp(value, -AREA_FIELD_MAX, AREA_FIELD_MAX)
	}
	grid_blur(field, size, AREA_BLUR_SIGMA, AREA_BLUR_REACH)

	// Step: Write
	for y in max(lo.y, 0) ..< min(hi.y, GRID.y) {
		for x in max(lo.x, 0) ..< min(hi.x, GRID.x) {
			index := y * GRID.x + x
			value := field[(y - lo.y) * size.x + (x - lo.x)]
			member := areas.ids[index]
			if member == area && on_side(side, {x, y}) do value = max(value, AREA_OWN_MIN)
			// Cells of other areas are written by those areas
			if member != 0 && member != area && areas.sides[member] == side {
				if on_side(side, {x, y}) do continue
			}
			owner := &areas.owners[index][side]
			held := &areas.fields[index][side]
			if member == area || owner^ == area || owner^ == 0 || value > f32(held^) {
				owner^ = area
				held^ = f16(value)
			}
		}
	}
}

// Overwrites the Category grid: input of Ground.category
@(private = "file")
ground_category_write :: proc(
	rend: ^Renderer,
	// Row-major from the top-left
	cells: []Render_Cover_Cell,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Category, raw_data(cells), len(cells))
}

// Overwrites the look of every category: looks[i] for category i, none past len(looks)
@(private = "file")
ground_category_looks_write :: proc(rend: ^Renderer, looks: []Render_Cover_Look) {
	if !(.Ready in rend.flags) do return
	assert(len(looks) <= GROUND_CATEGORIES)

	// 0..1 to 0..255, rounded
	to_u8 :: proc(value: f32) -> u8 {
		return u8(clamp(value, 0, 1) * 255 + 0.5)
	}
	texels: [2][GROUND_CATEGORIES][4]u8
	for look, i in looks {
		texels[0][i] = {
			to_u8(look.color.r),
			to_u8(look.color.g),
			to_u8(look.color.b),
			to_u8(look.wash),
		}
		texels[1][i] = {u8(look.pattern), to_u8(look.pattern_ink), 0, 0}
	}
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = TERRAIN.ground_category_looks.texture, aspect = .All},
		&texels,
		size_of(texels),
		&{bytesPerRow = GROUND_CATEGORIES * 4, rowsPerImage = 2},
		&{GROUND_CATEGORIES, 2, 1},
	)
}

// Overwrites the Taper grid: thins strokes of kind Ground_Stroke_Line
@(private = "file")
ground_taper_write :: proc(
	rend: ^Renderer,
	// 1 byte per cell, read as 0..1. Row-major from the top-left
	cells: []u8,
) {
	if !(.Ready in rend.flags) do return
	ground_grid_write(rend, .Taper, raw_data(cells), len(cells))
}

// Overwrites the line geometry of a stroke: input of Ground.strokes[stroke].
// Segments past STROKE_SEGMENTS_MAX are dropped
@(private = "file")
ground_stroke_write :: proc(
	rend: ^Renderer,
	stroke: int,
	// Points in cells
	lines: ^Polylines($P, $R),
	// Arrowhead at the end of each open run: length, width, in logical pixels. Zero = none
	head: [2]f32 = {},
) {
	if !(.Ready in rend.flags) do return
	assert(stroke >= 0 && stroke < STROKES)

	total := 0
	for run in lines.runs do total += run.closed ? run.len : max(run.len - 1, 0)
	total = min(total, STROKE_SEGMENTS_MAX)
	TERRAIN.stroke_counts[stroke] = u32(total)
	if total == 0 do return

	segments := make([dynamic]Stroke_Segment, 0, total, context.temp_allocator)
	fill: for run in lines.runs {
		points := lines.points[run.begin:][:run.len]
		count := run.closed ? run.len : run.len - 1
		for i in 0 ..< count {
			if len(segments) == total do break fill
			segment := Stroke_Segment {
				a = points[i],
				b = points[(i + 1) % run.len],
			}
			if !run.closed && i == count - 1 do segment.head = head
			append(&segments, segment)
		}
	}
	wgpu.QueueWriteBuffer(
		rend.queue,
		TERRAIN.stroke_buffers[stroke],
		0,
		raw_data(segments),
		uint(len(segments) * size_of(Stroke_Segment)),
	)
}

@(private = "file")
ground_grid_write :: proc(rend: ^Renderer, grid: Ground_Grid, texels: rawptr, count: int) {
	assert(count == RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT)
	texel_size := GROUND_GRID_FORMATS[grid].texel_size
	wgpu.QueueWriteTexture(
		rend.queue,
		&{texture = TERRAIN.ground_grids[grid].texture, aspect = .All},
		texels,
		uint(count * texel_size),
		&{
			bytesPerRow = u32(RENDER_TERRAIN_WIDTH * texel_size),
			rowsPerImage = RENDER_TERRAIN_HEIGHT,
		},
		&{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT, 1},
	)
}

// Ground pass parameters. The ground shader outputs one colour per window pixel, computed from the
// grids (RENDER_TERRAIN_WIDTH x RENDER_TERRAIN_HEIGHT cells) and these layers.
// Layers are composited in field order. Colours: straight RGB, 0..1. A zeroed layer has no effect
@(private = "file")
Ground :: struct {
	base:     Ground_Base,
	category: Ground_Category,
	divide:   Ground_Divide,
	// Layer 0: here, under the strokes. Layers 1 and up: in order, over the marks, under the value
	// layer
	areas:    [AREA_LAYERS]Ground_Area_Layer,
	// Drawn in index order. Line and Double: under the divide's line. Arrow: over every layer.
	// Over the divide's line: the marks
	strokes:  [STROKES]Ground_Stroke,
	value:    Ground_Value,
}

// Base layer: colour with noise stains. Outside the grid: color * 0.72
@(private = "file")
Ground_Base :: struct {
	color:        [3]f32,
	// Stain colour. Stain pattern: fbm noise in world space
	stain:        [3]f32,
	// Mix toward stain at full noise, 0..1
	stain_amount: f32,
}

// Category layer. Category grid: (category, strength) per cell. Each category has a look, written
// with Render_Update_Category_Looks. The looks of the 4 cells around a pixel are blended
@(private = "file")
Ground_Category :: struct {
	// Colour of the looks' patterns
	pattern_color: [3]f32,
	// Scales washes and patterns, 0..1. 0 = layer off
	strength:      f32,
	// Peak-to-peak noise displacement of the lookup per axis, in cells
	jitter:        f32,
}

// Divide layer. d = Divide grid (bilinear) + noise: signed distance in cells, > 0 land, < 0 water.
// On the water side it shows the tinted base, covering the category layer.
// Draws a line at d = 0, and defines the sides other layers clip to.
// The line is drawn over the layers between divide and value
@(private = "file")
Ground_Divide :: struct {
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

// Stroke layer: draws along the lines written with Render_Update_Stroke.
// d = distance to the stroke's nearest segment. Widths: logical pixels. nil = off
@(private = "file")
Ground_Stroke :: union {
	Ground_Stroke_Line,
	Ground_Stroke_Double,
	Ground_Stroke_Arrow,
}

// A filled line with an edge line either side, the same width on screen at any zoom.
// Heads: see Render_Update_Stroke
@(private = "file")
Ground_Stroke_Arrow :: struct {
	// Outer width, edges included
	width:      f32,
	fill_color: [3]f32,
	edge_color: [3]f32,
	edge_width: f32,
}

// One line, with a wash either side of it
@(private = "file")
Ground_Stroke_Line :: struct {
	color:         [3]f32,
	// Scaled by 1..0.4 as the Taper grid goes 0.2..0.8. Capped at 1/3 cell
	width:         f32,
	// Multiplies the colour by wash_color, by wash_strength at d = 0 falling to 0 at 1.2 cells
	wash_color:    [3]f32,
	wash_strength: f32,
	// Peak-to-peak noise displacement of the line per axis, in cells
	wander:        f32,
	clip:          Ground_Clip,
}

// Two edge lines with a fill between. Closes to a single line as width goes from 6 to 3
@(private = "file")
Ground_Stroke_Double :: struct {
	// Outer width, edges included. Capped at 1/2 cell
	width:         f32,
	edge_color:    [3]f32,
	// Varies along the stroke by a factor 0.6..1.4
	edge_width:    f32,
	// Mixed toward fill_color * base colour by fill_strength
	fill_color:    [3]f32,
	fill_strength: f32,
	clip:          Ground_Clip,
}

// Area layer: a wash per area, and a line where two areas meet.
// Areas: Render_Update_Areas or Render_Update_Area. Their looks: Render_Update_Area_Looks
@(private = "file")
Ground_Area_Layer :: struct {
	// Line where two areas meet
	border_color:    [3]f32,
	// 0..1
	border_strength: f32,
	// Logical pixels
	border_width:    f32,
	border_clip:     Ground_Clip,
	// Peak-to-peak noise displacement of the edges per axis, in cells
	wander:          f32,
	// Scales the washes, 0..1. 0 = no washes
	strength:        f32,
}

// Look of one area. The colour under it is multiplied toward color:
// by border at the area's edge, easing to inside over thickness cells inward
@(private = "file")
Ground_Area_Look :: struct {
	color:     [3]f32,
	// 0..1
	border:    f32,
	// Cells
	thickness: f32,
	// 0..1
	inside:    f32,
}

// A disc added to an area's shape
@(private = "file")
Ground_Area_Circle :: struct {
	// Cells
	center: [2]f32,
	radius: f32,
	area:   u8,
}

// Side of the divide an area lives on
@(private = "file")
Ground_Side :: enum u8 {
	Land,
	Water,
}

// Side of the divide a layer is restricted to
@(private = "file")
Ground_Clip :: enum i32 {
	None,
	Land,
	Water,
}

// Value layer: multiplies the colour by mix(low, high, v). v: Value grid, bilinear
@(private = "file")
Ground_Value :: struct {
	low:      [3]f32,
	high:     [3]f32,
	// Blend factor of the multiply, 0..1. 0 = layer off
	strength: f32,
	clip:     Ground_Clip,
}

