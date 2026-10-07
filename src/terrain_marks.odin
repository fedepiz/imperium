#+private
package main

import "core:math"
import "core:math/linalg"
import "core:slice"

// Terrain marks: small drawings scattered over the map (mountains, trees, waves). Placed once, drawn as quads.
// Each layer is a jittered grid of candidate points. At a point every marking of the layer gets a score from
// coast distance, elevation, temperature and cover. A mark is kept with probability sum(scores), its marking
// picked by score. Marks then claim ground, in layer order, so they do not cover ways or each other

// Roman scenario: 42,887 candidates, 38,675 placed
TERRAIN_MARKS_MAX :: 1 << 16

Terrain_Marks :: struct {
	// Sorted by foot (bottom edge), top to bottom: nearer marks draw over farther ones
	marks: [dynamic; TERRAIN_MARKS_MAX]Terrain_Mark,
}

Terrain_Mark :: struct {
	// Centre, in cells
	pos:    [2]f32,
	// In cells
	size:   [2]f32,
	// Atlas rect
	source: Extents,
	// Opacity, 0..255
	alpha:  u8,
}

// Claim grid: squares per cell side
@(private = "file")
FOOTPRINT_RES :: 4

// Claim grid values. 0 = free, PRECLAIMED = ways and near-shore water: no mark may cover it,
// 2 + layer = claimed by a mark of that layer
@(private = "file")
PRECLAIMED :: 1

// Fraction of a mark's width checked against preclaimed ground
@(private = "file")
MARK_DRAWN_WIDTH :: 0.7

// Ground kept free of marks: half-width of the band along rivers and roads, and width of the band
// of water along the coast, in cells
@(private = "file")
RIVER_BAND :: f32(1.0)
@(private = "file")
ROAD_BAND :: f32(1.2)
@(private = "file")
COAST_WATER_BAND :: f32(3)

// Reach of the offset-to-way field, in cells. Above the bands
@(private = "file")
WAY_REACH :: f32(4)

// Random offset on coast, elevation, temperature, so neighbouring ranges blend instead of meeting at a line
@(private = "file")
BLUR :: [3]f32{1, 0.1, 0.1}

// [lo, hi). lo == hi: any value
@(private = "file")
Range :: struct {
	lo: f32,
	hi: f32,
}

// Coast distance ranges
@(private = "file")
ON_LAND :: Range{1, 1000}
@(private = "file")
OFFSHORE :: Range{-1000, -5}

// In placement order: earlier layers claim ground from later ones
@(private = "file")
Layer :: enum {
	Mountain,
	Molehill,
	Tree,
	Tuft,
	Marsh,
	Dune,
	Sea,
}

@(private = "file")
Layer_Def :: struct {
	// Grid step in cells. Rows are spacing * row_squash apart, odd rows offset half a step
	spacing:         f32,
	row_squash:      f32,
	// Fraction of a step
	jitter:          [2]f32,
	// In cells, +-vary as a fraction
	width:           f32,
	vary:            f32,
	// Ground claimed by each mark, as fractions of its size: its width, and below its foot.
	// Both zero = claims nothing
	footprint_width: f32,
	footprint_below: f32,
	// Also blocks later marks of the same layer
	claims_own:      bool,
}

@(private = "file", rodata)
LAYERS := [Layer]Layer_Def {
	// Low vertical jitter so back peaks stay visible over front ones
	.Mountain = {
		spacing = 8.04,
		row_squash = 0.8,
		jitter = {0.6, 0.15},
		width = 4.7,
		vary = 0.2,
		footprint_width = 0.5,
		footprint_below = 0.45,
		claims_own = true,
	},
	.Molehill = {
		spacing = 3.84,
		row_squash = 0.8,
		jitter = {0.7, 0.6},
		width = 3.29,
		vary = 0.2,
		footprint_width = 0.525,
		footprint_below = 0.5,
		claims_own = true,
	},
	.Tree = {
		spacing = 2.1,
		row_squash = 0.8,
		jitter = {0.7, 0.6},
		width = 1.6,
		vary = 0.3,
		footprint_width = 0.7,
	},
	.Tuft = {spacing = 3.8, row_squash = 0.8, jitter = {0.7, 0.6}, width = 1.3, vary = 0.2},
	.Marsh = {spacing = 3.2, row_squash = 0.8, jitter = {0.7, 0.6}, width = 2.3, vary = 0.15},
	.Dune = {spacing = 5.5, row_squash = 0.8, jitter = {0.7, 0.6}, width = 3.4, vary = 0.2},
	.Sea = {spacing = 12, row_squash = 0.8, jitter = {0.7, 0.6}, width = 3},
}

@(private = "file")
Marking :: struct {
	drawing:     Render_Mark_Drawing,
	layer:       Layer,
	// Where it grows
	coast:       Range,
	elevation:   Range,
	temperature: Range,
	// Density per cover kind, times the cell's cover strength. All zero = density 1 everywhere
	cover:       [Render_Cover]f32,
	// Width multiplier at the top of the elevation range
	grow:        f32,
	// Opacity over coast distance: 0 at fade_from, 1 at fade_full. Equal = opaque
	fade_from:   f32,
	fade_full:   f32,
}

@(private = "file")
TREE_COVER :: #partial [Render_Cover]f32 {
	.Forest  = 1,
	.Fertile = 0.45,
}

@(private = "file", rodata)
MARKINGS := [?]Marking {
	{
		drawing = .Mountain,
		layer = .Mountain,
		coast = ON_LAND,
		elevation = {0.7, 1.1},
		cover = #partial{.Mountains = 1},
		grow = 0.55,
	},
	{
		drawing = .Hill,
		layer = .Molehill,
		coast = ON_LAND,
		elevation = {0.6, 0.85},
	},
	{
		drawing = .Conifer,
		layer = .Tree,
		coast = ON_LAND,
		temperature = {-0.08, 0.02},
		cover = TREE_COVER,
	},
	{
		drawing = .Broadleaf,
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.02, 0.34},
		cover = TREE_COVER,
	},
	{
		drawing = .Cypress,
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.34, 0.5},
		cover = TREE_COVER,
	},
	{
		drawing = .Palm,
		layer = .Tree,
		coast = ON_LAND,
		temperature = {0.5, 10},
		cover = #partial{.Fertile = 0.45},
	},
	{
		drawing = .Tuft,
		layer = .Tuft,
		coast = ON_LAND,
		cover = #partial{.Steppe = 1},
	},
	{
		drawing = .Marsh,
		layer = .Marsh,
		coast = ON_LAND,
		cover = #partial{.Marsh = 1},
	},
	{
		drawing = .Dune,
		layer = .Dune,
		coast = ON_LAND,
		cover = #partial{.Desert = 1},
	},
	{
		drawing = .Sea,
		layer = .Sea,
		coast = OFFSHORE,
		fade_from = -19,
		fade_full = -5,
	},
}

// Out: out.
// Places the marks of a map, replacing out.marks. Grids are row-major, size.x * size.y cells
terrain_marks_place :: proc(
	size: [2]int,
	// 0..255 per cell
	elevation: []u8,
	moisture: []u8,
	cover: []Render_Cover_Cell,
	// Signed distance to the coast per cell, in cells. > 0 on land
	coast: []f32,
	// Smoothed, in cells. The ground along them stays free of marks
	rivers: Polylines,
	roads: Polylines,
	// Atlas rects of the drawings
	images: ^Render_Mark_Images,
	out: ^Terrain_Marks,
) {
	cells := size.x * size.y
	assert(len(elevation) == cells && len(moisture) == cells)
	assert(len(cover) == cells && len(coast) == cells)

	// Random streams per layer
	stream :: proc(layer: Layer, use: u32) -> u32 {return u32(layer) * 16 + use}
	footprint_square :: proc(p: [2]f32) -> [2]int {
		return {int(p.x * FOOTPRINT_RES), int(p.y * FOOTPRINT_RES)}
	}

	// Step: Images. Atlas rect per marking and variant; variants end at the first empty rect
	sources: [len(MARKINGS)][RENDER_MARK_VARIANTS_MAX]Extents
	variants: [len(MARKINGS)]int
	for marking, m in MARKINGS {
		for rect in images[marking.drawing] {
			if rect.x_max <= rect.x_min do break
			sources[m][variants[m]] = rect
			variants[m] += 1
		}
	}

	// Step: Preclaim. Ground along ways, and water near the coast
	footprint := size * FOOTPRINT_RES
	claimed := make([]u8, footprint.x * footprint.y, context.temp_allocator)
	{
		Way_Band :: struct {
			lines: Polylines,
			band:  f32,
		}
		to_way := make([][2]f32, cells, context.temp_allocator)
		for way in ([?]Way_Band{{rivers, RIVER_BAND}, {roads, ROAD_BAND}}) {
			for &offset in to_way do offset = WAY_REACH
			polylines_stamp(way.lines, WAY_REACH, size, to_way, nil)
			for offset, i in to_way {
				if linalg.length(offset) > way.band + 1 do continue
				cell := [2]int{i % size.x, i / size.x}
				nearest := [2]f32{f32(cell.x), f32(cell.y)} + 0.5 + offset
				for y in 0 ..< FOOTPRINT_RES {
					for x in 0 ..< FOOTPRINT_RES {
						square := cell * FOOTPRINT_RES + {x, y}
						middle := ([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES
						if linalg.length(middle - nearest) >= way.band do continue
						claimed[square.y * footprint.x + square.x] = PRECLAIMED
					}
				}
			}
		}
		for distance, i in coast {
			// Cells too far from the band to have squares in it
			if distance >= 1 || distance <= -COAST_WATER_BAND - 1 do continue
			cell := [2]int{i % size.x, i / size.x}
			for y in 0 ..< FOOTPRINT_RES {
				for x in 0 ..< FOOTPRINT_RES {
					square := cell * FOOTPRINT_RES + {x, y}
					middle := ([2]f32{f32(square.x), f32(square.y)} + 0.5) / FOOTPRINT_RES
					at := grid_bilinear(coast, size, middle)
					if at < 0 && at > -COAST_WATER_BAND {
						claimed[square.y * footprint.x + square.x] = PRECLAIMED
					}
				}
			}
		}
	}

	// Step: Candidates. Per layer, per grid point: score the layer's markings, roll for a mark.
	// Capped at TERRAIN_MARKS_MAX like the marks
	Candidate :: struct {
		mark:  Terrain_Mark,
		layer: Layer,
	}
	candidates := make([dynamic]Candidate, 0, TERRAIN_MARKS_MAX, context.temp_allocator)
	fill: for def, layer in LAYERS {
		step := [2]f32{def.spacing, def.spacing * def.row_squash}
		cols := int(f32(size.x) / step.x)
		rows := int(f32(size.y) / step.y)
		for row in 0 ..< rows {
			for col in 0 ..< cols {
				// Grid point, jittered
				wander := [2]f32 {
					random_xy(col, row, stream(layer, 0)),
					random_xy(col, row, stream(layer, 1)),
				}
				wander -= 0.5
				shift := [2]f32{f32(row % 2) * 0.5, 0}
				pos := ([2]f32{f32(col), f32(row)} + shift + 0.5 + wander * def.jitter) * step
				at := [2]int{int(math.floor(pos.x)), int(math.floor(pos.y))}
				if at.x < 0 || at.y < 0 || at.x >= size.x || at.y >= size.y do continue
				cell := at.y * size.x + at.x

				// What grows here
				height := f32(elevation[cell]) / 255
				wet := f32(moisture[cell]) / 255
				north := 1 - (f32(at.y) + 0.5) / f32(size.y)
				temperature := 1 - north - 0.47 * height + 0.5 * (0.6 - wet)
				values := [3]f32{coast[cell], height, temperature}
				values += (random_xy(col, row, stream(layer, 2)) - 0.5) * 2 * BLUR

				scores: [len(MARKINGS)]f32
				total: f32
				scoring: for marking, m in MARKINGS {
					if marking.layer != layer do continue
					ranges := [3]Range{marking.coast, marking.elevation, marking.temperature}
					for range, r in ranges {
						if range.lo != range.hi &&
						   (values[r] < range.lo || values[r] >= range.hi) {
							continue scoring
						}
					}
					scores[m] = 1
					if marking.cover != {} {
						scores[m] =
							marking.cover[cover[cell].kind] * f32(cover[cell].strength) / 255
					}
					total += scores[m]
				}
				if random_xy(col, row, stream(layer, 3)) >= total do continue
				m, _ := pick_weighted(scores[:], random_xy(col, row, stream(layer, 4)))
				marking := MARKINGS[m]

				// Size and look
				width :=
					def.width *
					math.lerp(1 - def.vary, 1 + def.vary, random_xy(col, row, stream(layer, 5)))
				if marking.grow != 0 {
					up :=
						(height - marking.elevation.lo) /
						(marking.elevation.hi - marking.elevation.lo)
					width *= 1 + marking.grow * clamp(up, 0, 1)
				}
				variant := int(random_xy(col, row, stream(layer, 6)) * f32(variants[m]))
				source := sources[m][variant]
				// Missing image
				if source.x_max <= source.x_min do continue
				aspect := (source.y_max - source.y_min) / (source.x_max - source.x_min)
				alpha := u8(255)
				if marking.fade_from != marking.fade_full {
					alpha = u8(
						smoothstep(marking.fade_from, marking.fade_full, coast[cell]) * 255 + 0.5,
					)
				}

				if len(candidates) == TERRAIN_MARKS_MAX do break fill
				append(
					&candidates,
					Candidate {
						mark = {
							pos = pos,
							size = {width, width * aspect},
							source = source,
							alpha = alpha,
						},
						layer = layer,
					},
				)
			}
		}
	}

	// Step: Claims. Keep the candidates whose ground is free, in order, each claiming its footprint
	clear(&out.marks)
	placing: for candidate in candidates {
		mark := candidate.mark
		def := LAYERS[candidate.layer]
		foot_y := mark.pos.y + mark.size.y / 2

		// Foot on ground claimed by an earlier layer, or by its own if the layer claims its own
		foot := footprint_square({mark.pos.x, foot_y})
		if foot.y < footprint.y {
			by := int(claimed[foot.y * footprint.x + foot.x])
			if by != 0 && (by - 2 < int(candidate.layer) || def.claims_own) do continue
		}
		// Drawn over preclaimed ground
		{
			half := mark.size.x * MARK_DRAWN_WIDTH / 2
			first := linalg.clamp(
				footprint_square({mark.pos.x - half, foot_y - mark.size.y}),
				0,
				footprint,
			)
			last := linalg.clamp(footprint_square({mark.pos.x + half, foot_y}) + 1, 0, footprint)
			for y in first.y ..< last.y {
				for x in first.x ..< last.x {
					if claimed[y * footprint.x + x] == PRECLAIMED do continue placing
				}
			}
		}
		append(&out.marks, mark)

		if def.footprint_width == 0 && def.footprint_below == 0 do continue
		half := mark.size.x * def.footprint_width / 2
		first := linalg.clamp(
			footprint_square({mark.pos.x - half, foot_y - mark.size.y}),
			0,
			footprint,
		)
		last := linalg.clamp(
			footprint_square({mark.pos.x + half, foot_y + def.footprint_below * mark.size.y}) + 1,
			0,
			footprint,
		)
		for y in first.y ..< last.y {
			for x in first.x ..< last.x {
				square := &claimed[y * footprint.x + x]
				if square^ == 0 do square^ = u8(candidate.layer) + 2
			}
		}
	}

	// Step: Sort by foot
	slice.sort_by(out.marks[:], proc(a, b: Terrain_Mark) -> bool {
		return a.pos.y + a.size.y / 2 < b.pos.y + b.size.y / 2
	})
}

// Out: out.
// A world-space quad per mark overlapping visible (in cells), in draw order. Returns how many were
// written. Quads past len(out) are dropped
terrain_marks_quads :: proc(marks: ^Terrain_Marks, visible: Extents, out: []Render_Quad) -> (count: int) {
	for mark in marks.marks {
		if count == len(out) do break
		lo := mark.pos - mark.size / 2
		hi := mark.pos + mark.size / 2
		if hi.x < visible.x_min || lo.x > visible.x_max do continue
		if hi.y < visible.y_min || lo.y > visible.y_max do continue
		color := [4]u8{255, 255, 255, mark.alpha}
		out[count] = {
			rect   = {lo.x, lo.y, hi.x, hi.y},
			source = mark.source,
			colors = {color, color, color, color},
		}
		count += 1
	}
	return
}
