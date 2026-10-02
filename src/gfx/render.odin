package gfx

import "../util"

RENDER_MAX_INSTANCES :: 8192 * 2

// Max terrain size, in cells
RENDER_TERRAIN_WIDTH :: 1024
RENDER_TERRAIN_HEIGHT :: 1024
RENDER_TERRAIN_CELLS :: RENDER_TERRAIN_WIDTH * RENDER_TERRAIN_HEIGHT
RENDER_TERRAIN_SIZE :: [2]int{RENDER_TERRAIN_WIDTH, RENDER_TERRAIN_HEIGHT}
RENDER_LAYER_CATEGORIES :: 256

// Per line kind
RENDER_LINE_SEGMENTS_MAX :: 1 << 19

// Including area 0 (none)
RENDER_HIGHLIGHT_AREAS :: 256
RENDER_HIGHLIGHT_CIRCLES_MAX :: 512

Texture_Id :: distinct u16

// Tightly packed, top-to-bottom RGBA8 pixels. Storage is owned by the caller.
Bitmap :: struct {
	pixels: [][4]u8,
	width:  int,
	height: int,
}

// Consecutive instances with equal keys are drawn in one call
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
	clip:      [4]f32,
	color:     [Corner][4]f32,
	radii:     [Corner]f32,
	softness:  f32,
	// 0 = filled; > 0 = inward border width
	thickness: f32,
}

Render_List :: struct {
	keys:      [RENDER_MAX_INSTANCES]Render_Key,
	instances: [RENDER_MAX_INSTANCES]Render_Instance,
}

// Values must match the map shader's debug_mode
Render_Terrain_Debug :: enum i32 {
	Map,
	Surface,
	Elevation,
	Trees,
	Moisture,
	Cover,
}

// Colours are straight RGBA; only RGB is used unless stated. Widths in logical pixels.
Render_Terrain_Style :: struct {
	paper:              [4]f32,
	paper_stain:        [4]f32,
	// 0..1
	paper_stain_amount: f32,
	ink:                [4]f32,
	// Shallow until sea_depth_from cells from shore, deep from sea_depth_full, linear in between
	sea_shallow:        [4]f32,
	sea_deep:           [4]f32,
	sea_depth_from:     f32,
	sea_depth_full:     f32,
	sea_tint:           f32,
	// wobble: max coast displacement, in cells
	coast_width:        f32,
	wobble:             f32,
	// At the lowlands; thins toward the source
	river_width:        f32,
	// Total width, including two ink strokes of road_stroke each; road_fill (alpha = strength) in between
	road_width:         f32,
	road_stroke:        f32,
	road_fill:          [4]f32,
	// Total width including ink edges, constant on screen
	arrow_width:        f32,
	arrow_fill:         [4]f32,
	// Arrowhead triangle; the line width is drawn around it
	head_length:        f32,
	head_width:         f32,
	// Region border; alpha = strength
	border_width:       f32,
	border_ink:         [4]f32,
}

Render_Pattern :: enum u8 {
	None,
	// Dots, constant spacing on screen
	Stipple,
}

// Paper is multiplied toward color by wash, pattern drawn at pattern_ink; both scaled by cell strength
Render_Layer_Palette :: struct {
	color:       [4]f32,
	wash:        f32,
	pattern:     Render_Pattern,
	pattern_ink: f32,
}

// One category + strength per cell. Category borders are jittered (up to jitter cells) to hide the grid.
Render_Layer :: struct {
	// Bump on change to re-upload
	revision: u32,
	// Category, strength 0..255
	cells:    [RENDER_TERRAIN_CELLS][2]u8,
	palette:  [RENDER_LAYER_CATEGORIES]Render_Layer_Palette,
	jitter:   f32,
}

// Drawn in order
Render_Line_Kind :: enum u8 {
	River,
	Road,
	Arrow,
}

// In cells
Render_Segment :: struct {
	start: [2]f32,
	end:   [2]f32,
	// Arrowhead at end
	head:  b32,
}

Render_Lines :: struct {
	// Bump on change to re-upload
	revision: u32,
	segments: [dynamic; RENDER_LINE_SEGMENTS_MAX]Render_Segment,
}

// Areas are clipped at the coast to their surface
Render_Highlight_Surface :: enum u8 {
	Land,
	Water,
}

Render_Highlight_Area :: struct {
	// Bump when cells or surface change
	revision:  u32,
	bounds:    util.Cell_Rect,
	surface:   Render_Highlight_Surface,
	// Map is multiplied toward color: border strength at the edge, easing to inside over thickness cells
	color:     [4]f32,
	border:    f32,
	thickness: f32,
	inside:    f32,
}

// Drawn separately, so they can overlap
Render_Highlight_Layer :: enum u8 {
	// Over cover, under rivers and roads
	Regions,
	// The rest: over the coast and marks, under arrows, in this order
	Zones,
	Contacts,
	Reach,
}

// Cells get smooth edges; neighbouring areas share one edge. Circles are exact, drawn over all cells, clipped at
// the coast.
Render_Highlights :: struct {
	// Area per cell, 0 = none
	cells:   [RENDER_TERRAIN_CELLS]u8,
	areas:   [RENDER_HIGHLIGHT_AREAS]Render_Highlight_Area,
	// Refilled every frame; grouped by area
	circles: [dynamic; RENDER_HIGHLIGHT_CIRCLES_MAX]Render_Highlight_Circle,
}

// In cells
Render_Highlight_Circle :: struct {
	center: [2]f32,
	radius: f32,
	area:   u8,
}

render_highlight_clear :: proc(highlights: ^Render_Highlights, area: u8) {
	bounds := &highlights.areas[area].bounds
	for y in bounds.min.y ..< bounds.max.y do for x in bounds.min.x ..< bounds.max.x {
		cell := &highlights.cells[util.grid_index({x, y}, RENDER_TERRAIN_SIZE)]
		if cell^ == area do cell^ = 0
	}
	bounds^ = {}
	highlights.areas[area].revision += 1
}

// Removes the cell from its previous area
render_highlight_add :: proc(highlights: ^Render_Highlights, area: u8, cell: [2]int) {
	assert(area != 0, "Highlight area 0 is none")
	index := util.grid_index(cell, RENDER_TERRAIN_SIZE)
	if was := highlights.cells[index]; was != area {
		if was != 0 do highlights.areas[was].revision += 1
		highlights.cells[index] = area
	}
	bounds := &highlights.areas[area].bounds
	bounds^ = util.cell_rect_union(bounds^, {cell, cell + 1})
	highlights.areas[area].revision += 1
}

// Cell index = y * RENDER_TERRAIN_WIDTH + x, (0, 0) top left
Render_Terrain :: struct {
	// Bump when cells or coast change
	revision:   u32,
	// surface (land 0, lake 127, sea 254), elevation, trees, moisture
	cells:      [RENDER_TERRAIN_CELLS][4]u8,
	// Signed distance to coast, in cells, + on land
	coast:      [RENDER_TERRAIN_CELLS]f32,
	lines:      [Render_Line_Kind]Render_Lines,
	// Land cover (forest, desert...); water draws over it
	cover:      Render_Layer,
	highlights: [Render_Highlight_Layer]Render_Highlights,
	// center: in cells. zoom: logical pixels per cell.
	center:     [2]f32,
	zoom:       f32,
	debug_mode: Render_Terrain_Debug,
	style:      Render_Terrain_Style,
}

