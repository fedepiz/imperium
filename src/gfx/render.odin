package gfx

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
	// The cover layer's categories, cell by cell
	Cover,
}

// How the map is drawn. Colors use straight RGBA; only RGB is used.
Render_Terrain_Style :: struct {
	paper:              [4]f32,
	paper_stain:        [4]f32,
	// How strongly the stains show: 0 for none, 1 for full
	paper_stain_amount: f32,
	ink:                [4]f32,
	// The water's color near the shore and out in the deep. It is shallow up to sea_depth_from cells from the shore,
	// deep from sea_depth_full cells, and blends evenly in between.
	sea_shallow:        [4]f32,
	sea_deep:           [4]f32,
	sea_depth_from:     f32,
	sea_depth_full:     f32,
	sea_tint:           f32,
	// Coast line width in logical pixels, and how far the coast wanders from the cells, in cells
	coast_width:        f32,
	wobble:             f32,
	// River line width in logical pixels, where a river reaches the lowlands; it thins toward its sources.
	river_width:        f32,
	// Road width in logical pixels, edges included, and the band of bare paper either side of it. Roads are ochre
	// between two ink edges; zoomed out too far for the edges to read, they narrow to a single line.
	road_width:         f32,
	road_halo:          f32,
	road_fill:          [4]f32,
	// Arrow width in logical pixels, edges included: a band of arrow_fill between two ink edges, the same width however
	// far the map zooms
	arrow_width:        f32,
	arrow_fill:         [4]f32,
	// The triangle a line's head is drawn from, in logical pixels: how long it is from its back to its tip, and how wide
	// at its back. Its kind's width is drawn around it, as around the rest of the line.
	head_length:        f32,
	head_width:         f32,
}

// How many categories a layer can have, category 0 included
RENDER_LAYER_CATEGORIES :: 256

// Ink patterns a category can draw over its wash
Render_Pattern :: enum u8 {
	None,
	// Fine dots, always about the same distance apart on screen
	Stipple,
}

// How one category of a layer is drawn: the paper is multiplied toward color by wash, and the pattern is drawn in ink
// as dark as pattern_ink, both scaled by each cell's strength. Only the color's RGB is used.
Render_Layer_Palette :: struct {
	color:       [4]f32,
	wash:        f32,
	pattern:     Render_Pattern,
	pattern_ink: f32,
}

// A map layer: one category per cell, with how strongly the cell is of it, and a palette saying how each category is
// drawn. Drawing blends the categories of neighbouring cells, along borders that wander up to jitter cells from the
// grid, so the map shows no cell edges. What the categories mean is the owner's business: the renderer only draws them.
// Cells are indexed y * RENDER_TERRAIN_WIDTH + x.
Render_Layer :: struct {
	// Bumped whenever cells or palette change; the renderer uploads them again only then.
	revision: u32,
	// Category, then strength from 0 to 255
	cells:    [RENDER_TERRAIN_CELLS][2]u8,
	palette:  [RENDER_LAYER_CATEGORIES]Render_Layer_Palette,
	jitter:   f32,
}

// The kinds of line the map draws, each in its own look, each over the ones before it
Render_Line_Kind :: enum u8 {
	River,
	Road,
	Arrow,
}

// A straight piece of a line, its ends in cells
Render_Segment :: struct {
	start: [2]f32,
	end:   [2]f32,
	// A head ends the line here: a triangle with its tip at end, pointing on from start. See Render_Terrain_Style.
	head:  b32,
}

// The most segments a kind of line can have
RENDER_LINE_SEGMENTS_MAX :: 1 << 19

// The lines of one kind, as the segments they are drawn from
Render_Lines :: struct {
	// Bumped whenever the segments change; the renderer uploads them again only then.
	revision: u32,
	segments: [dynamic; RENDER_LINE_SEGMENTS_MAX]Render_Segment,
}

// How many areas the highlights can have, area 0, which is none, included
RENDER_HIGHLIGHT_AREAS :: 256

// A rectangle of cells, from min up to but not including max; empty when max is not past min on both axes
Render_Cell_Rect :: struct {
	min, max: [2]i32,
}

// What a highlight area lies on: its edge along the coast is the coast, and its cells of the other surface are not drawn
Render_Highlight_Surface :: enum u8 {
	Land,
	Water,
}

// How an area is highlighted: the map is multiplied toward color, as strongly as border at the area's edge, easing to
// inside at thickness cells in from it and beyond. Only the color's RGB is used.
Render_Highlight_Area :: struct {
	// Bumped whenever which cells are in the area, or its surface, changes; the renderer takes them up again only then.
	revision:  u32,
	// Every cell in the area is within these
	bounds:    Render_Cell_Rect,
	surface:   Render_Highlight_Surface,
	color:     [4]f32,
	border:    f32,
	thickness: f32,
	inside:    f32,
}

// Areas of cells highlighted over the map, each in its own look. A cell is in at most one area. Each area is drawn with
// a smooth edge that follows its cells, and is the coast along the coast; where two areas meet they share one edge, and
// neither draws past it. Cells are indexed y * RENDER_TERRAIN_WIDTH + x.
Render_Highlights :: struct {
	// Which area each cell is in, 0 for none
	cells: [RENDER_TERRAIN_CELLS]u8,
	areas: [RENDER_HIGHLIGHT_AREAS]Render_Highlight_Area,
}

// Takes every cell out of a highlight area
render_highlight_clear :: proc(highlights: ^Render_Highlights, area: u8) {
	bounds := &highlights.areas[area].bounds
	for y in bounds.min.y ..< bounds.max.y do for x in bounds.min.x ..< bounds.max.x {
		cell := &highlights.cells[int(y) * RENDER_TERRAIN_WIDTH + int(x)]
		if cell^ == area do cell^ = 0
	}
	bounds^ = {}
	highlights.areas[area].revision += 1
}

// Puts a cell in a highlight area, taking it out of any other it was in
render_highlight_add :: proc(highlights: ^Render_Highlights, area: u8, cell: [2]int) {
	assert(area != 0, "Highlight area 0 is none")
	index := cell.y * RENDER_TERRAIN_WIDTH + cell.x
	if was := highlights.cells[index]; was != area {
		if was != 0 do highlights.areas[was].revision += 1
		highlights.cells[index] = area
	}
	at := [2]i32{i32(cell.x), i32(cell.y)}
	bounds := &highlights.areas[area].bounds
	bounds^ = cell_rect_union(bounds^, {at, at + 1})
	highlights.areas[area].revision += 1
}

@(private)
cell_rect_empty :: proc(rect: Render_Cell_Rect) -> bool {
	return rect.max.x <= rect.min.x || rect.max.y <= rect.min.y
}

// The smallest rectangle holding both
@(private)
cell_rect_union :: proc(a, b: Render_Cell_Rect) -> Render_Cell_Rect {
	if cell_rect_empty(a) do return b
	if cell_rect_empty(b) do return a
	return {{min(a.min.x, b.min.x), min(a.min.y, b.min.y)}, {max(a.max.x, b.max.x), max(a.max.y, b.max.y)}}
}

// The part of a rectangle on the terrain
@(private)
cell_rect_clip :: proc(rect: Render_Cell_Rect) -> Render_Cell_Rect {
	grid := [2]i32{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}
	return {
		{clamp(rect.min.x, 0, grid.x), clamp(rect.min.y, 0, grid.y)},
		{clamp(rect.max.x, 0, grid.x), clamp(rect.max.y, 0, grid.y)},
	}
}

// Everything the map pass draws from. Cells are indexed y * RENDER_TERRAIN_WIDTH + x, with cell (0, 0) at the top left.
Render_Terrain :: struct {
	// Bumped whenever cells or coast change; the renderer uploads them again only then.
	revision:   u32,
	// The terrain as the rules see it, one texel per cell: surface (land, lake, sea as 0, 127, 254), elevation, trees,
	// moisture.
	cells:      [RENDER_TERRAIN_CELLS][4]u8,
	// Derived from the cells: signed distance to the coast, in cells, positive on land.
	coast:      [RENDER_TERRAIN_CELLS]f32,
	// The lines drawn over the map, of each kind
	lines:      [Render_Line_Kind]Render_Lines,
	// What covers the land, drawn onto it: forest, desert and so on. Water is drawn over it.
	cover:      Render_Layer,
	// Areas drawn over the map, under the arrows
	highlights: Render_Highlights,
	// The cell at the middle of the view, and logical pixels per cell
	center:     [2]f32,
	zoom:       f32,
	debug_mode: Render_Terrain_Debug,
	style:      Render_Terrain_Style,
}

