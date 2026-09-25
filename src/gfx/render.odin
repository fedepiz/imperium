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
	paper:       [4]f32,
	paper_stain: [4]f32,
	ink:         [4]f32,
	sea_color:   [4]f32,
	sea_tint:    f32,
	// Coast line width in logical pixels, and how far the coast wanders from the cells, in cells
	coast_width: f32,
	wobble:      f32,
	// River line width in logical pixels, where a river reaches the lowlands; it thins toward its sources.
	river_width: f32,
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

// How far around a river its offsets reach, in cells. Cells farther away hold RENDER_RIVER_FAR.
RENDER_RIVER_REACH :: 4
RENDER_RIVER_FAR :: [2]f32{RENDER_RIVER_REACH, RENDER_RIVER_REACH}

// Everything the map pass draws from. Cells are indexed y * RENDER_TERRAIN_WIDTH + x, with cell (0, 0) at the top left.
Render_Terrain :: struct {
	// Bumped whenever cells or coast change; the renderer uploads them again only then.
	revision:   u32,
	// The terrain as the rules see it, one texel per cell: surface (land, river, lake, sea as 0, 85, 170, 255),
	// elevation, trees, moisture.
	cells:      [RENDER_TERRAIN_CELLS][4]u8,
	// Derived from the cells: signed distance to the coast, in cells, positive on land.
	coast:      [RENDER_TERRAIN_CELLS]f32,
	// Derived from the cells: from the middle of each cell to the nearest point of a river line, in cells.
	river:      [RENDER_TERRAIN_CELLS][2]f32,
	// What covers the land, drawn onto it: forest, desert and so on. Water is drawn over it.
	cover:      Render_Layer,
	// The cell at the middle of the view, and logical pixels per cell
	center:     [2]f32,
	zoom:       f32,
	debug_mode: Render_Terrain_Debug,
	style:      Render_Terrain_Style,
}
