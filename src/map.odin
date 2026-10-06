#+private
package main

// Map graphics: turns map inputs (style, ways) into the layers of the renderer's ground

// Ground strokes the map uses
MAP_STROKE_RIVERS :: 0
MAP_STROKE_ROADS :: 1
#assert(RENDER_GROUND_STROKES >= 2)

// Rivers: wide curves
MAP_RIVER_SMOOTHING :: Polyline_Smoothing {
	cut_iter  = 3,
	cut_ratio = 0.25,
}

// Roads: straight, tight bends
MAP_ROAD_SMOOTHING :: Polyline_Smoothing {
	cut_iter  = 2,
	cut_ratio = 0.25,
	cut_max   = 1.5,
}

// Land cover. Value = category in the ground's category layer
Map_Cover :: enum u8 {
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

// Colours: straight RGB, 0..1. Widths: logical pixels
Map_Style :: struct {
	paper:              [3]f32,
	paper_stain:        [3]f32,
	// 0..1
	paper_stain_amount: f32,
	ink:                [3]f32,
	// Sea colour: shallow up to sea_depth_from cells from the shore, deep from sea_depth_full
	sea_shallow:        [3]f32,
	sea_deep:           [3]f32,
	sea_depth_from:     f32,
	sea_depth_full:     f32,
	// 0..1
	sea_tint:           f32,
	coast_width:        f32,
	// Hand wobble of the coast and rivers, in cells
	wobble:             f32,
	// At low elevation. Thins toward the source
	river_width:        f32,
	// Outer width, including two ink lines of road_stroke each
	road_width:         f32,
	road_stroke:        f32,
	road_fill:          [3]f32,
	// 0..1
	road_fill_strength: f32,
	// Patterns are drawn in ink
	cover_looks:        [Map_Cover]Render_Ground_Category_Look,
	// Wobble of the borders between covers, in cells
	cover_jitter:       f32,
}

@(private = "file")
COVER_SAND :: [3]f32{0.900, 0.800, 0.600}

MAP_STYLE :: Map_Style {
	paper              = {0.840, 0.772, 0.620},
	paper_stain        = {0.720, 0.620, 0.460},
	paper_stain_amount = 0.5,
	ink                = {0.150, 0.105, 0.070},
	sea_shallow        = {0.560, 0.610, 0.620},
	sea_deep           = {0.200, 0.330, 0.480},
	sea_depth_from     = 0,
	sea_depth_full     = 80,
	sea_tint           = 0.55,
	coast_width        = 1.6,
	wobble             = 0.3,
	river_width        = 12,
	road_width         = 8,
	road_stroke        = 1.1,
	road_fill          = {0.950, 0.840, 0.660},
	road_fill_strength = 0.55,
	cover_looks        = {
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
	cover_jitter       = 0.8,
}

// Ground layers for a style. Value layer: off.
// The cover looks are not part of it: write style.cover_looks with renderer_ground_category_looks_write
map_ground :: proc(style: Map_Style) -> (ground: Render_Ground) {
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
		wobble     = style.wobble * 1.6,
	}
	ground.strokes[MAP_STROKE_RIVERS] = Render_Ground_Stroke_Line {
		color         = style.ink + (style.sea_shallow - style.ink) * 0.3,
		width         = style.river_width,
		wash_color    = style.sea_shallow,
		wash_strength = style.sea_tint * 0.5,
		wander        = style.wobble,
		clip          = .Land,
	}
	ground.strokes[MAP_STROKE_ROADS] = Render_Ground_Stroke_Double {
		width         = style.road_width,
		edge_color    = style.ink,
		edge_width    = style.road_stroke,
		fill_color    = style.road_fill,
		fill_strength = style.road_fill_strength,
		clip          = .Land,
	}
	return
}
