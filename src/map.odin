#+private
package main

import "core:hash/xxhash"
import "core:math"
import "core:slice"

// Map graphics: turns a map's geography and style into what the renderer draws.
// map_build: once per map, from a Map_Geography. Places the marks.
// map_frame: every frame, from a Map_Scene.
// Neither touches the renderer: they append the updates, quads and passes it is to be given.
// Updates hold slices of their inputs and of temporary memory: give them to renderer_update before
// either goes away

// Map size in cells: the renderer's ground
MAP_WIDTH :: RENDER_GROUND_WIDTH
MAP_HEIGHT :: RENDER_GROUND_HEIGHT
MAP_CELLS :: MAP_WIDTH * MAP_HEIGHT

// Smoothed points and ways, per kind (rivers, roads). Roman scenario: 18,368 river points in 104 ways
MAP_WAY_POINTS_MAX :: 1 << 16
MAP_WAYS_MAX :: 1 << 10

// Highlights in a scene
MAP_HIGHLIGHTS_MAX :: 16
#assert(MAP_HIGHLIGHTS_MAX < RENDER_GROUND_AREAS)

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

// Map graphics state kept between frames
Map :: struct {
	marks:        Map_Marks,
	pawns:        Map_Pawns,
	// Region looks as drawn, eased toward the scene's. Index: region
	region_looks: [RENDER_GROUND_AREAS]Render_Ground_Area_Look,
	// Per scene highlight slot
	highlights:   [MAP_HIGHLIGHTS_MAX]Map_Highlight_Drawn,
	// Hash of the scene wash last written to the renderer. 0 = none
	wash_written: u64,
}

Map_Highlight_Drawn :: struct {
	// Hash of the highlight last written to the renderer. 0 = none
	written: u64,
	// Area layer it was written to
	layer:   int,
	// Look as drawn, eased toward its kind's
	look:    Render_Ground_Area_Look,
}

// What the game wants shown this frame. Transient: read during the call, not kept
Map_Scene :: struct {
	// Camera. The view the caller gives renderer_draw
	view:           Render_View,
	// Size of the window, in logical pixels
	window:         [2]f32,
	region_display: Map_Region_Display,
	// Index: region, as in Map_Geography.regions. Entry 0 is unused
	regions:        []Map_Region,
	// Up to MAP_HIGHLIGHTS_MAX. A highlight keeps its slot from frame to frame: when its content
	// changes it fades in again
	highlights:     []Map_Highlight,
	// Paths as points in cells, tail to head. Each run is drawn with an arrowhead at its end
	arrows:         Polylines,
	// Pieces, drawn in order, each over the last. Labels are drawn over all pawns
	pawns:          []Map_Pawn,
	// A value per cell, 0..255, MAP_CELLS long: shown as a wash over the land, from
	// Map_Style.wash_low at 0 to wash_high at 255. Empty = none. For map modes such as supply
	wash:           []u8,
}

Map_Region_Display :: enum {
	// No colour
	Hidden,
	// A band of the region's colour along its edge
	Outlined,
	// Outlined when near, filled when far
	Filled_When_Far,
}

Map_Region :: struct {
	color:       [3]f32,
	// Drawn stronger
	highlighted: bool,
}

// A set of cells shown washed in the colour of its kind
Map_Highlight :: struct {
	kind:     Map_Highlight_Kind,
	// The set is of water cells. Otherwise of land cells
	on_water: bool,
	// cells[y * size.x + x] is cell corner + {x, y}. No cells = not shown
	corner:   [2]int,
	size:     [2]int,
	cells:    []bool,
	// Discs added to the shape
	circles:  []Map_Circle,
}

// Highlights of one kind share a look. Kinds on one row tile: where two meet they share an edge.
// Rows are drawn in this order, each over the last: Zone; Contact; Reach, Foreign_Reach
Map_Highlight_Kind :: enum {
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
Map_Circle :: struct {
	center: [2]f32,
	radius: f32,
}

// What map_build draws the map from. Transient: read during the call, not kept.
// Grids: one entry per cell, row-major from the top-left, MAP_CELLS long
Map_Geography :: struct {
	// true = lake or sea. Gives the coast: its line, the sea tint, and where land layers stop
	water:     []bool,
	// 0..255. Thins rivers toward their source. Places mountains and hills, and picks tree species
	elevation: []u8,
	// 0..255. Picks tree species
	moisture:  []u8,
	// Gives the cover washes and stipple. Places trees, tufts, marsh and dune marks
	cover:     []Map_Cover_Cell,
	// Courses as points in cells, unsmoothed. Drawn as lines. Marks keep off them
	rivers:    Polylines,
	roads:     Polylines,
	// Region per cell, 0 = none. On land only. Gives the shapes of the region washes and the
	// borders between regions. Their colours: Map_Scene.regions
	regions:   []u8,
}

// Ground area layers the map uses. Regions: under the lines. The rest: over the marks, in this order
MAP_AREAS_REGIONS :: 0
MAP_AREAS_ZONES :: 1
MAP_AREAS_CONTACTS :: 2
MAP_AREAS_REACH :: 3
#assert(RENDER_GROUND_AREA_LAYERS >= 4)

@(private = "file", rodata)
HIGHLIGHT_LAYERS := [Map_Highlight_Kind]int {
	.Reach         = MAP_AREAS_REACH,
	.Foreign_Reach = MAP_AREAS_REACH,
	.Zone          = MAP_AREAS_ZONES,
	.Contact       = MAP_AREAS_CONTACTS,
}

// Ground strokes the map uses
MAP_STROKE_RIVERS :: 0
MAP_STROKE_ROADS :: 1
MAP_STROKE_ARROWS :: 2
#assert(RENDER_GROUND_STROKES >= 3)

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

// Land cover of one cell
Map_Cover_Cell :: struct {
	kind:     Map_Cover,
	// How strongly the cell is of that kind, 0..255
	strength: u8,
}
// Passed to the ground's category layer as is
#assert(size_of(Map_Cover_Cell) == size_of(Render_Ground_Category_Cell))

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
	// Line between regions
	border_width:       f32,
	border_ink:         [3]f32,
	// 0..1
	border_strength:    f32,
	// Region colour bands: near and far (see Map_Region_Display), plain and highlighted
	region_near:             Map_Band,
	region_near_highlighted: Map_Band,
	region_far:              Map_Band,
	region_far_highlighted:  Map_Band,
	highlight_looks:         [Map_Highlight_Kind]Map_Highlight_Look,
	// Outer width, including an ink line either side
	arrow_width:        f32,
	arrow_fill:         [3]f32,
	arrow_head_length:  f32,
	arrow_head_width:   f32,
	// Scene wash: colour at value 0 and at 255, and its strength, 0..1
	wash_low:           [3]f32,
	wash_high:          [3]f32,
	wash_strength:      f32,
	// Tints of pawns: when highlighted, and at the peak of a pulse. Labels are in ink with a paper halo
	pawn_highlight:     [3]f32,
	pawn_pulse:         [3]f32,
	// Patterns are drawn in ink
	cover_looks:        [Map_Cover]Render_Ground_Category_Look,
	// Wobble of the borders between covers, in cells
	cover_jitter:       f32,
}

// A wash strongest along an area's edge
Map_Band :: struct {
	// Wash strength at the edge, 0..1
	border:    f32,
	// Cells over which it eases inward
	thickness: f32,
	// Wash strength past that, 0..1
	inside:    f32,
}

Map_Highlight_Look :: struct {
	color: [3]f32,
	band:  Map_Band,
	// Cells by which thin parts are thickened, so a thread reads as a band. 0 = as given
	widen: int,
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
	border_width       = 1.5,
	border_ink         = {0.400, 0.180, 0.120},
	border_strength    = 0.3,
	region_near             = {border = 0.25, thickness = 1.5, inside = 0},
	region_near_highlighted = {border = 0.4, thickness = 2.5, inside = 0.02},
	region_far              = {border = 0.4, thickness = 3, inside = 0.35},
	region_far_highlighted  = {border = 0.5, thickness = 3.5, inside = 0.45},
	highlight_looks         = {
		// Mostly outline, so zones show through
		.Reach = {color = {0.300, 0.450, 0.650}, band = {0.7, 1.5, 0.1}, widen = 1},
		.Foreign_Reach = {color = {0.450, 0.420, 0.380}, band = {0.7, 1.5, 0.1}, widen = 1},
		.Zone = {color = {0.700, 0.250, 0.160}, band = {0.6, 2, 0.25}},
		.Contact = {color = {0.850, 0.700, 0.200}, band = {0.6, 2, 0.2}},
	},
	arrow_width        = 5,
	arrow_fill         = {0.700, 0.250, 0.160},
	arrow_head_length  = 7.5,
	arrow_head_width   = 6.25,
	wash_low           = {0.850, 0.450, 0.350},
	wash_high          = {0.450, 0.750, 0.400},
	wash_strength      = 0.8,
	pawn_highlight     = {0.900, 0.350, 0.300},
	pawn_pulse         = {1.000, 0.700, 0.350},
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

// Out: m, and updates, appended to.
// Builds a map: the ground's grids, strokes and category looks as updates, and the marks in m.
// Finds the pawn images and the label font in assets
map_build :: proc(
	m: ^Map,
	assets: ^Assets,
	geography: Map_Geography,
	style: Map_Style,
	updates: ^[dynamic; RENDER_UPDATES_MAX]Render_Update,
) {
	assert(len(geography.water) == MAP_CELLS)
	assert(len(geography.elevation) == MAP_CELLS && len(geography.moisture) == MAP_CELLS)
	assert(len(geography.cover) == MAP_CELLS)
	assert(len(geography.regions) == MAP_CELLS)
	size :: [2]int{MAP_WIDTH, MAP_HEIGHT}

	// Step: Coast
	coast := make([]f32, MAP_CELLS, context.temp_allocator)
	map_coast_build(geography.water, size, coast)
	append(updates, Render_Update_Divide{distances = coast})

	// Step: Regions. After the coast: areas are cut at it
	append(updates, Render_Update_Areas{layer = MAP_AREAS_REGIONS, ids = geography.regions, side = .Land})

	// Step: Ways. Smoothed, each kind to its stroke
	Way_Kind :: struct {
		raw:       Polylines,
		smoothing: Polyline_Smoothing,
		stroke:    int,
	}
	way_kinds := [?]Way_Kind {
		{geography.rivers, MAP_RIVER_SMOOTHING, MAP_STROKE_RIVERS},
		{geography.roads, MAP_ROAD_SMOOTHING, MAP_STROKE_ROADS},
	}
	ways: [RENDER_GROUND_STROKES]Polylines
	for kind in way_kinds {
		ways[kind.stroke] = polylines_over(
			make([][2]f32, MAP_WAY_POINTS_MAX, context.temp_allocator),
			make([]Polyline_Run, MAP_WAYS_MAX, context.temp_allocator),
		)
		polylines_smooth(kind.raw, kind.smoothing, &ways[kind.stroke])
		append(updates, Render_Update_Stroke{stroke = kind.stroke, lines = ways[kind.stroke]})
	}
	// Rivers thin with elevation
	append(updates, Render_Update_Taper{cells = geography.elevation})

	// Step: Cover
	append(
		updates,
		Render_Update_Category{cells = slice.reinterpret([]Render_Ground_Category_Cell, geography.cover)},
	)
	looks := make([]Render_Ground_Category_Look, len(Map_Cover), context.temp_allocator)
	for look, kind in style.cover_looks do looks[kind] = look
	append(updates, Render_Update_Category_Looks{looks = looks})

	// Step: Pawn images and label font
	map_pawns_build(&m.pawns, assets)

	// Step: Marks
	map_marks_place(
		size,
		geography.elevation,
		geography.moisture,
		geography.cover,
		coast,
		ways[MAP_STROKE_RIVERS],
		ways[MAP_STROKE_ROADS],
		assets,
		&m.marks,
	)
}

// Out: updates, quads, passes, appended to. In/out: m.
// A frame of the map. Updates: the area looks, the highlights that changed, the arrows, the wash if it
// changed. Passes: the ground, the marks in view, the pawns, their labels
map_frame :: proc(
	m: ^Map,
	assets: ^Assets,
	scene: Map_Scene,
	style: Map_Style,
	// Seconds since the last frame
	dt: f32,
	updates: ^[dynamic; RENDER_UPDATES_MAX]Render_Update,
	quads: ^[dynamic; RENDER_QUADS_MAX]Render_Quad,
	passes: ^[dynamic; RENDER_PASS_MAX]Render_Pass,
) {
	assert(len(scene.highlights) <= MAP_HIGHLIGHTS_MAX)
	assert(scene.view.zoom > 0)

	// Step: Visible. The part of the world in the window, in cells
	visible: Extents
	{
		half := scene.window / 2 / scene.view.zoom
		visible = {
			x_min = scene.view.center.x - half.x,
			y_min = scene.view.center.y - half.y,
			x_max = scene.view.center.x + half.x,
			y_max = scene.view.center.y + half.y,
		}
	}
	// Share of the way to its target a look moves this frame
	ease := 1 - math.exp(-LOOK_EASE * dt)

	// Step: Regions. Band by display, zoom and highlight
	{
		far := scene.view.zoom < REGION_FAR_ZOOM
		for region, id in scene.regions {
			if id == 0 || id >= RENDER_GROUND_AREAS do continue
			band: Map_Band
			switch scene.region_display {
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
			drawn := &m.region_looks[id]
			drawn.color += (region.color - drawn.color) * ease
			drawn.border += (band.border - drawn.border) * ease
			drawn.thickness += (band.thickness - drawn.thickness) * ease
			drawn.inside += (band.inside - drawn.inside) * ease
		}
		append(updates, Render_Update_Area_Looks{layer = MAP_AREAS_REGIONS, looks = m.region_looks[:]})
	}

	// Step: Highlights. Slot i is area i + 1 of its kind's layer. Cells are written when they change
	{
		// Per layer, in temporary memory: the updates keep slices of them
		HIGHLIGHT_AREA_LAYERS :: [?]int{MAP_AREAS_ZONES, MAP_AREAS_CONTACTS, MAP_AREAS_REACH}
		looks: [RENDER_GROUND_AREA_LAYERS][]Render_Ground_Area_Look
		circles: [RENDER_GROUND_AREA_LAYERS][dynamic]Render_Ground_Area_Circle
		for layer in HIGHLIGHT_AREA_LAYERS {
			looks[layer] = make([]Render_Ground_Area_Look, MAP_HIGHLIGHTS_MAX + 1, context.temp_allocator)
			circles[layer] = make(
				[dynamic]Render_Ground_Area_Circle,
				0,
				RENDER_GROUND_AREA_CIRCLES_MAX,
				context.temp_allocator,
			)
		}
		for &drawn, slot in m.highlights {
			area := u8(slot + 1)
			highlight: Map_Highlight
			if slot < len(scene.highlights) do highlight = scene.highlights[slot]
			shown := len(highlight.cells) > 0
			layer := HIGHLIGHT_LAYERS[highlight.kind]
			look := style.highlight_looks[highlight.kind]

			// 0 is kept for "none"
			content: u64
			if shown {
				assert(len(highlight.cells) == highlight.size.x * highlight.size.y)
				header := [6]int {
					int(highlight.kind),
					int(highlight.on_water),
					highlight.corner.x,
					highlight.corner.y,
					highlight.size.x,
					highlight.size.y,
				}
				content = u64(xxhash.XXH3_64_default(slice.to_bytes(header[:])))
				content = u64(xxhash.XXH3_64_with_seed(slice.to_bytes(highlight.cells), content))
				content = max(content, 1)
			}

			if content != drawn.written {
				// Gone, or moved to another layer
				if drawn.written != 0 && (!shown || drawn.layer != layer) {
					append(updates, Render_Update_Area{layer = drawn.layer, area = area})
				}
				if shown {
					cells := highlight.cells
					if look.widen > 0 {
						thick := make([]bool, len(cells), context.temp_allocator)
						mask_thicken(cells, highlight.size, look.widen, WIDEN_SUPPORT, thick)
						// Cells added by thickening are not taken from the layer's other highlights
						for &inside, i in thick {
							if !inside || cells[i] do continue
							cell := highlight.corner + {i % highlight.size.x, i / highlight.size.x}
							for other, other_slot in scene.highlights {
								if other_slot == slot || HIGHLIGHT_LAYERS[other.kind] != layer do continue
								at := cell - other.corner
								if at.x < 0 || at.y < 0 || at.x >= other.size.x || at.y >= other.size.y do continue
								if len(other.cells) > 0 && other.cells[at.y * other.size.x + at.x] {
									inside = false
									break
								}
							}
						}
						cells = thick
					}
					append(
						updates,
						Render_Update_Area {
							layer = layer,
							area = area,
							side = highlight.on_water ? .Water : .Land,
							corner = highlight.corner,
							size = highlight.size,
							mask = cells,
						},
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
			for circle in highlight.circles {
				if len(circles[layer]) == RENDER_GROUND_AREA_CIRCLES_MAX do break
				append(&circles[layer], Render_Ground_Area_Circle{circle.center, circle.radius, area})
			}
		}
		for layer in HIGHLIGHT_AREA_LAYERS {
			append(updates, Render_Update_Area_Looks{layer = layer, looks = looks[layer]})
			append(updates, Render_Update_Area_Circles{layer = layer, circles = circles[layer][:]})
		}
	}

	// Step: Arrows
	append(
		updates,
		Render_Update_Stroke {
			stroke = MAP_STROKE_ARROWS,
			lines = scene.arrows,
			head = {style.arrow_head_length, style.arrow_head_width},
		},
	)

	// Step: Wash. Its values are written when they change
	ground := map_ground(style)
	if len(scene.wash) > 0 {
		assert(len(scene.wash) == MAP_CELLS)
		content := max(u64(xxhash.XXH3_64_default(scene.wash)), 1)
		if content != m.wash_written {
			append(updates, Render_Update_Value{cells = scene.wash})
			m.wash_written = content
		}
		ground.value = {
			low      = style.wash_low,
			high     = style.wash_high,
			strength = style.wash_strength,
			clip     = .Land,
		}
	}

	// Step: Ground pass, and the marks in view drawn into it
	append(passes, Render_Ground_Pass{ground = ground})
	begin := len(quads)
	map_marks_quads(&m.marks, visible, quads)
	append(
		passes,
		Render_Quad_Pass {
			space = .World,
			target = .Ground,
			begin = begin,
			len = len(quads) - begin,
		},
	)

	// Step: Pawns and labels, over the ground
	map_pawns_frame(&m.pawns, assets, scene.pawns, scene.view, visible, style, dt, quads, passes)
}

// Ground layers for a style. Value layer: off, see the wash in map_frame
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
	ground.areas[MAP_AREAS_REGIONS] = {
		border_color    = style.border_ink,
		border_strength = style.border_strength,
		border_width    = style.border_width,
		border_clip     = .Land,
		wander          = style.wobble * 1.6,
		strength        = 1,
	}
	for layer in ([?]int{MAP_AREAS_ZONES, MAP_AREAS_CONTACTS, MAP_AREAS_REACH}) {
		ground.areas[layer] = {
			wander   = style.wobble * 1.6,
			strength = 1,
		}
	}
	ground.strokes[MAP_STROKE_ARROWS] = Render_Ground_Stroke_Arrow {
		width      = style.arrow_width,
		fill_color = style.arrow_fill,
		edge_color = style.ink,
		edge_width = 1,
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
