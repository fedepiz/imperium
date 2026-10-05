# Map renderer: implementation plan

Companion to `map_primitives.md` (the primitive analysis). This file is the detailed brief for implementing the map
renderer on the `rewrite` branch. It is written to be handed to a fresh session with no memory of the discussion that
produced it, together with a desktop where Odin, SDL3 and wgpu run and the result can be looked at.

Reference implementation: commit `10b8261` (last commit before the rewrite), files `src/gfx/render_wgpu.odin`
(shaders and GPU), `src/gfx/render.odin` (types), `src/game/map_draw.odin` (map build, marks, highlights),
`src/game/polyline.odin`, `src/game/ways.odin`, `src/game/pawns.odin`, `src/util/util.odin` (smoothing, distance
transform, random). Read them with `git show 10b8261:<path>`. Where this plan says "as `main`", it means that code.

## 1. Goal and non-goals

**Goal.** A renderer and a map-graphics layer whose output is identical, or indistinguishable at normal zooms, to
what `main` draws: the vellum paper, wobbling coast, washed regions with hairline borders, rivers, two-stroke roads,
scattered marks, highlight areas and circles, map-mode wash, arrows, pawns with medallions and labels. The look of
`main` is the specification; its shader is the reference for every formula.

**Non-goals for this phase.** No game logic. Nothing in these two layers knows what a forest, a region owner, an army
or an order is. Terrain classification, region colouring, arrow generation and pawn state are *inputs*, supplied by
a test harness now and by the game later. Simplifications to the old mechanisms (baked wobble, stamped region fields)
are deferred to a later phase and only accepted after a side-by-side comparison; see §9.

**Fidelity first, then simplify.** Port the old formulas and mechanisms into the new structure. Do not improve the
look while porting; every visible difference must be deliberate.

## 2. Separation

Three layers, two seams. The seams are plain data. Each layer may be compiled and exercised without the one above.

```
game / test harness    classification, ownership, orders, pawn state
        │  Seam B: grids, polylines, palettes, placement rules, sprites, text, camera
        ▼
map graphics           contour tracing, smoothing, distance fields, mark placement, line building,
                       map shaders, pawn/label layout — graphical logic only
        │  Seam A: quads, passes, textures, uniforms
        ▼
renderer               wgpu only — pipelines, buffers, textures, blend states, surface
```

Rules:

- **Renderer** knows no map. It has no notion of cells, coast, region or mark. It knows: a view (for the world→screen
  transform, as numbers), quad instances, passes, textures by id, uniform blobs. Its only shaders are the quad shader,
  its distance variant, and field shaders handed to it as WGSL source by the layer above (or compiled in by name — see
  §3.5). It is tested by firing hand-written quads at it, as `main.odin` does today.
- **Map graphics** knows no game. Its vocabulary: *label grid* (u8/u16 per cell, 0 = none), *value grid* (u8 or f32
  per cell), *polyline* (points in cells, open or closed), *palette entry* (colour, wash, border, thickness, inside,
  pattern), *placement rule* (images, grid spacing, score ranges over named value grids), *sprite* (image, world rect,
  tint), *text* (string, font, world or screen anchor), *camera*. It never sees `Terrain_Type`, `Region`, `Pawn` or
  `Scene`. The word "region" appears only as the generic "area" in highlight layers. It is tested by loading the
  scenario PNGs and text files directly and inventing palettes.
- **Game** (later) does: elevation/moisture/trees → cover label + strength (`terrain_type_of` in
  `10b8261:src/sim/world.odin:430`); region id → colour per colouring mode; piece → sprite + label; order → arrow
  polyline; reach/zone → highlight cell set. All of this is already game code in `main` and is not touched here.

Enforcement: put the renderer and map graphics in **separate packages** (`src/gpu`, `src/mapgfx`) so the compiler
forbids upward references, with `src/main.odin` as the harness. If the single-package style of the rewrite is
preferred, keep the same file split (`renderer.odin`, `map_*.odin`) and the rule that no `map_*` file names a type
defined outside `map_*`/`renderer`/`math`; review for it at each commit. Packages are recommended.

Where state lives: the rewrite keeps big fixed arrays in a global struct (`GLOBAL`) and uses the panic allocator for
`context.allocator`, with the temp allocator for load-time scratch. Keep that: each layer owns one fixed-size state
struct; scratch (contour tracing buffers, distance transforms) goes in `context.temp_allocator` and is freed per frame.

## 3. Seam A: the renderer API

Extends `src/renderer.odin` as it stands (quad pipeline, atlas, viewport uniform). Everything below is additive.

### 3.1 View uniform

Replaces the `[4]f32` viewport buffer. Bound at group 0 of every pipeline.

```odin
Render_View :: struct {
	// Window size in physical pixels
	size:          [2]f32,
	// World→screen: screen = (p - center) * zoom + size / 2. zoom in physical pixels per cell.
	center:        [2]f32,
	zoom:          f32,
	// Physical pixels per logical pixel; style widths are given in logical pixels
	pixel_density: f32,
	// World size in cells (1024, 1024)
	grid:          [2]f32,
}
```

WGSL helpers in a shared prelude (string-concatenated into every shader): `world_to_screen(p)`, `screen_to_world(s)`,
`to_clip(screen)`. `px = view.zoom` is physical pixels per cell; in `main` it was `zoom * pixel_density` because
`zoom` there was logical. **Decide once:** camera zoom is in *logical* pixels per cell at Seam B (so game tuning
constants keep their meaning, `CAMERA_ZOOM_MIN/MAX` 2..24), and map graphics writes `view.zoom = camera.zoom *
pixel_density`.

### 3.2 Quad instance

```odin
Render_Quad :: struct {
	rect:      Extents,     // in the quad's space (see pass.space)
	clip:      Extents,     // screen pixels; zero = none
	colors:    [4][4]u8,    // TL, TR, BR, BL, straight alpha
	source:    Extents,     // atlas pixels; x_max <= x_min = untextured
	radii:     f32,
	thickness: f32,
	softness:  f32,
	// New: unit direction of the rect's local x axis. {1, 0} = unrotated. Rotation is about the rect centre.
	axis:      [2]f32,
}
```

Rotation is the one shape addition. The fragment transforms the pixel into the rect's local frame before
`rounded_box`; the vertex shader rotates the four corners about the centre; `grow` is unchanged. A capsule from `a` to
`b` with half width `w` is: centre `(a+b)/2`, rect of size `(|b-a| + 2w, 2w)`, `radii = w`, `axis = (b-a)/|b-a|`.

### 3.3 Passes

```odin
Render_Space  :: enum { Screen, World }
Render_Target :: enum { Frame, Marks, Lines }         // offscreen targets are screen-sized, recreated on resize
Render_Blend  :: enum { Over, Min }                    // Over: premultiplied src-over. Min: keep the smaller value.

Render_Quad_Pass :: struct {
	space:   Render_Space,
	target:  Render_Target,
	blend:   Render_Blend,
	// Which channel(s) a Min pass writes (line kind → channel)
	mask:    bit_set[0..<4],
	// Colour variant draws the quad shader; Distance variant writes distance to the quad's edge in cells
	variant: enum { Color, Distance },
	begin, len: int,
}

Render_Field_Pass :: struct {
	shader:  Render_Field_Shader,                        // enum of compiled-in field shaders, see 3.5
	target:  Render_Target,
	load:    enum { Clear, Keep },
}

Render_Pass :: union { Render_Quad_Pass, Render_Field_Pass }
```

A frame is `renderer_draw(view, quads, passes, uniforms)`. The renderer walks the pass list in order, opening a wgpu
render pass whenever target or load changes, and binding pipelines per `(variant, target, blend, mask)`. The pipeline
set is fixed and small: Color/Frame/Over, Color/Marks/Over, Distance/Lines/Min × 4 masks, plus one pipeline per field
shader. Create them all at init.

**Distance variant.** Same vertex shader; fragment outputs `rounded_box(...)` in *cells* (divide by `view.zoom`) to
all channels, with the pipeline's write mask selecting one. For textured quads it outputs the sampled red channel
scaled by `source` size — an SDF sprite — but nothing in this phase needs it (arrowheads use the analytic triangle
below). Note `main` drew the head as a triangle SDF in the segment's fragment (`head_distance`,
`10b8261:src/gfx/render_wgpu.odin:1524`). Port that as a flag on the distance variant: `thickness < 0` means "this
pill's end carries a head of width `softness`, length `radii`" — or, cleaner, add a `Render_Shape :: enum { Box,
Capsule_Head }` byte to the instance. Pick the enum; it costs nothing.

The Lines target is `RGBA16Float`, cleared to `LINE_FAR = 1000` each frame; channel R = rivers, G = roads, B = arrows.
The Marks target is the surface format, cleared to transparent, blended Over. Both are sampled by field shaders.

### 3.4 Textures

```odin
Texture_Id :: distinct u8
Render_Texture_Desc :: struct {
	size:   [2]int,
	layers: int,                                                 // 1 for 2D, >1 for 2D array
	format: enum { R8, RG8, RGBA8, R16F, RG16F, RGBA16F, RGBA32F },
}
renderer_texture_create :: proc(^Renderer, Texture_Id, Render_Texture_Desc)
renderer_texture_write  :: proc(^Renderer, Texture_Id, layer: int, rect: [4]int, pixels: rawptr, bytes_per_pixel: int)
```

Textures are referenced by id from field shaders' bind groups (fixed binding tables per shader, see 3.5). The atlas
stays as it is. Samplers: one `linear` (clamp), one `nearest`.

### 3.5 Field shaders

A field pass draws one full-screen triangle (`vs` as `10b8261:...:1585`). Field shaders are WGSL files `#load`ed by
the renderer, each with a fixed bind-group layout the renderer knows by name. The renderer does not know what they
draw. Two shaders in this phase:

- `map_ground.wgsl` — the port of `MAP_SOURCE` (`10b8261:src/gfx/render_wgpu.odin:1557-1986`) minus nothing: it
  draws everything from paper to arrows, sampling the Lines and Marks targets as `main` did. Keeping it whole is the
  fidelity path; splitting it into ground/overlay passes (as `map_primitives.md` sketches) is a §9 item.
- `map_debug` is a mode inside the same shader (`debug_mode` uniform), as in `main`.

Its bind group (group 1), ported one-to-one from `main`'s group 0 (`:1561-1576`), with the uniform struct
`Terrain_Uniforms` (`:1435-1470`) renamed `Map_Uniforms` and the view fields removed (they come from group 0):

| binding | name | format | contents |
|---|---|---|---|
| 0 | uniforms | — | style + debug mode + circle counts + overlay_shown |
| 1 | cells | RGBA8, 1024² | surface (0 land, 127 lake, 254 sea), elevation, trees, moisture |
| 2 | coast | R16F, 1024² | signed distance to coast in cells, + on land |
| 3 | lines | RGBA16F, screen | Lines target |
| 4 | cover_cells | RG8, 1024² | category, strength |
| 5 | cover_palette | RGBA8, 256×2 | row 0: colour rgb + wash; row 1: pattern kind, pattern ink |
| 6 | linear sampler | | |
| 7 | highlight_cells | RG8 array[4], 1024² | per surface (land, water): area owning the cell's field |
| 8 | highlight_field | RG16F array[4], 1024² | per surface: that area's field |
| 9 | highlight_palette | RGBA32F array[4], 256×2 | row 0: colour rgb + border; row 1: thickness, inside, surface |
| 10 | highlight_circles | RGBA32F, 512×4 | centre xy, radius, area; row per layer |
| 11 | marks | surface fmt, screen | Marks target |
| 12 | overlay | R8, 1024² | map-mode value |

Layers of the highlight arrays: 0 Regions, 1 Zones, 2 Contacts, 3 Reach.

### 3.6 Budgets

`RENDER_QUADS_MAX` 32000 is too small once marks are quads: `main` allowed `MARKS_MAX = 1<<17` marks and
`RENDER_LINE_SEGMENTS_MAX = 1<<19` segments per kind. Raise `RENDER_QUADS_MAX` to 1<<19 (each quad 80 bytes → 40 MB
buffer; fine) or give static ranges their own buffer that is uploaded once. Recommended: **two quad buffers**,
`static` (marks, river and road pills; written at load) and `frame` (everything else; written each frame), with the
pass naming which. Culling: marks and pills outside the view are skipped by map graphics before submission (as
`marks_draw` did), so per-frame instance counts stay small; the static buffer is only for not re-uploading.

## 4. Seam B: the map graphics API

One state struct, `Map_Gfx`, holding the textures' CPU mirrors and the derived data. Inputs are plain slices/arrays;
nothing is retained by pointer past the call.

### 4.1 Static build (load, or whenever the ground changes)

```odin
Map_Ground :: struct {
	size:      [2]int,                 // 1024, 1024
	surface:   []u8,                   // label grid: 0 land, 1 lake, 2 sea
	elevation: []u8,
	trees:     []u8,
	moisture:  []u8,
	// Cover: label grid + strength 0..255, categories indexed into cover_palette. 0 = plain.
	cover:     []u8,
	cover_strength: []u8,
	// Area ids for the Regions highlight layer, 0 = none, water cells ignored
	regions:   []u16,
}

Map_Polylines :: struct {
	// Already smoothed by the caller? No: raw cell-centre points; map graphics smooths with the kind's Smoothing.
	rivers, roads: []Polyline,
}

map_gfx_build :: proc(mg: ^Map_Gfx, rend: ^Renderer, ground: Map_Ground, lines: Map_Polylines,
                      cover_palette: [256]Map_Palette_Entry, placement: []Map_Placement_Rule)
```

`map_gfx_build` does everything in `map_derive` + `marks_place` (`10b8261:src/game/map_draw.odin:380-470,
870-1070`), described in §5, and uploads the static textures and the static quad buffer.

### 4.2 Per-frame

```odin
Map_Camera :: struct { center: [2]f32, zoom: f32 }   // zoom in logical pixels per cell

Map_Highlight_Area :: struct {
	layer:     enum { Regions, Zones, Contacts, Reach },
	surface:   enum { Land, Water },
	revision:  u64,                                      // caller bumps when cells change
	color:     [4]f32, border, thickness, inside: f32,
	// Cells, either as a region id already in ground.regions (Regions layer) or an explicit set:
	corner:    [2]int, cells: []bool,                    // AREA_SIZE² row-major, as sim.Area
	widen:     int,                                      // see area_widen
	circles:   [][3]f32,                                 // centre, radius
}

Map_Sprite :: struct { image: Image_Id, rect: Extents /* cells */, tint: [4]f32 }
Map_Text   :: struct { text: string, font: Font_Id, at: [2]f32 /* cells, centre-top */, color: [4]f32, halo: [4]f32 }

map_gfx_frame :: proc(mg: ^Map_Gfx, rend: ^Renderer, out: ^Render_Data,
                      camera: Map_Camera, style: Map_Style, debug: Map_Debug_Mode,
                      arrows: []Polyline,                 // raw paths; map graphics smooths and adds heads
                      areas: []Map_Highlight_Area,        // ≤ 255 per layer, slot i → area id i+1
                      overlay: []u8, overlay_shown: bool, overlay_revision: u32,
                      sprites: []Map_Sprite, texts: []Map_Text, dt: f32)
```

`map_gfx_frame` writes the view uniform, re-uploads changed highlight areas and the overlay, writes palettes and
circles, builds this frame's quads (pills for arrows; culled marks; sprites; glyphs) and appends passes to `out` in
the order of §6. The highlight *easing* (`highlight_ease`, rate 10/s) belongs to the caller in `main`; keep it there
(it is game feel), so `Map_Highlight_Area` carries the already-eased look.

Pawns are not a map-graphics concept: the caller turns each pawn into one or two `Map_Sprite`s (fill silhouette in
paper colour, then drawing) and a `Map_Text`, using the sizes in §8.6. The medallion cross-fade and focus pulse stay
with the caller. Map graphics only guarantees sprites draw after marks and before texts, and texts last.

Picking is CPU-side in the caller against the grids and its own sprite rects; map graphics exposes
`map_gfx_coast_at(p) -> f32` and nothing else.

## 5. Graphical algorithms (what map graphics computes)

All of these exist in `main`; port them, don't redesign. Parameters in §8.

### 5.1 Polylines and smoothing

`Polyline :: struct { points: [][2]f32, closed: bool }`, points in cells. One fixed-capacity builder as
`10b8261:src/game/polyline.odin` (`POLYLINE_POINTS_MAX 1<<16`, runs `1<<13`, corner-cut iterations ≤ 3, runs ≤ 8
points aren't softened). `smooth_polyline` as `10b8261:src/util/util.odin:265`: soften iterations (pull toward
neighbour average by `softness`), then corner-cut iterations (each doubles the points, cut at `cut_ratio` capped by
`cut_max`). Smoothing per kind: rivers `{cut_iter 3, cut_ratio .25}`, roads `{cut_iter 2, cut_ratio .25, cut_max
1.5}`, coast `{softness .3, soften_iter 2, cut_iter 2, cut_ratio .2}`, arrows: none in `main` (raw path points, cell
centres). Way points from the files are cell coordinates `+ 0.5`.

### 5.2 Contour tracing

`trace_boundaries` (`10b8261:src/game/map_draw.odin:633-740`): on a u16 label grid, every edge between two different
non-zero labels becomes a directed cell-corner edge with the larger label on the left; corners record outgoing edges
and how many edges meet. Walk open runs first (from corners where ≠ 2 edges meet), then closed loops; each run is
smoothed and stored. Used for the coast with labels sea=1, land=2 (so land is on the left). Also reusable for region
borders later (§9), not needed for fidelity: `main` draws borders from the region field.

### 5.3 Coast distance field

As `map_derive` (`:409-440`): stamp every coast polyline into `to_coast` (offset from cell centre to nearest point,
reach 3 cells) with `coast_side` (±1 by segment side, `polyline_stamp`); compute exact Euclidean distance transforms
`to_water` and `to_land` (`util.distance_from`, squared-distance EDT); per cell `far = water ? -(to_land-0.5) :
to_water-0.5`, `near = |to_coast|`, side falls back to the cell's own surface when `near > 1`; `coast = lerp(side*near,
far, smoothstep(2, 3, near))`. Upload as R16F.

### 5.4 Lines

Rivers and roads: each polyline's segments become pill quads in the static buffer, world space, distance variant,
target Lines, Min blend, channel by kind. The old vertex shader grew each segment's quad by `2 + 24/zoom` cells (plus
head room) so the distance is valid as far as the shader reads it (river wash 1.2 cells, wander up to `wobble*1.6`,
road halo): set the pill's `softness`/grow to the same reach. Arrows: dynamic range, channel B, last segment flagged
with a head (`head_length 7.5`, `head_width 6.25` logical px, triangle SDF `head_distance`). The old pipeline wrote
with `writeMask = kind's channel` — that is `Render_Quad_Pass.mask`.

### 5.5 Cover layer

`cover_cells = {category, strength}` straight from the input grids; palette rows as §3.5. Jitter 0.8 cells
(`cover_jitter`, used by `layer_at` which wanders the lookup and blends the four surrounding cells' looks).

### 5.6 Highlight areas (regions, zones, contacts, reach)

Port `highlight_take_up` / `highlight_take_up_on` / `blur` (`10b8261:src/gfx/render_wgpu.odin:882-1021`) verbatim
into map graphics (it was in gfx in `main`; it is graphical logic and belongs here now). Per area and surface: exact
EDT to nearest inside / outside cell over the area's bounds + margin 6, `field = (out_by - in_by)/2` with the 0.5
adjustments, clamp ±64, Gaussian blur σ 1.5 radius 4, own cells ≥ 0.1, written where the area owns or is nearer.
`render_highlight_add/clear` bookkeeping (`10b8261:src/gfx/render.odin:191-214`). Regions layer: every land cell with
`regions[i] != 0` is added to area `regions[i]` at build. `area_widen` (`:596-630`) for the Reach look (widen 1).
The shader side is `areas_over`/`highlights_over`/`circles_over`, ported unchanged.

### 5.7 Marks

Port `marks_place` (`:870-1070`) and its tables (§8.4, §8.5) whole. Inputs: the grids (elevation, moisture, cover +
strength), the coast field, and a `claimed` footprint grid at 4 squares per cell seeded by `ways_claim_ground`
(rivers band 1.0, roads band 1.2, from `to_way` offsets with reach 4) and `preclaim_coast_water` (band 3 cells of
water). The *temperature* input (`1 - north - 0.47*elevation + 0.5*(0.6 - moisture)`) is a graphical heuristic and
stays here. Output: marks sorted by foot y, each a world-space textured quad with alpha from the fade ramp.
`random_xy(x, y, stream)` hash (`util.odin:340`) must be ported exactly or the forest will differ from `main`.

Marks are drawn each frame into the Marks target (culled to the view, with `main`'s behaviour of one draw per frame);
the ground shader composites `marks` premultiplied after the coast line and before highlights.

### 5.8 Text

Per-glyph quads from the existing font atlas, as `main.odin` does now; `Map_Text` draws the halo (8 offsets at 1.5
logical px in paper colour) then the text, centred at `at` in cells → screen, at constant screen size. Fonts:
`forgotten_uncial` 22 (Text) and 36 (Title). Note the rewrite's `assets.odin` rasterises at 18 px with `aniron`; add
the font sizes/faces the pawns need.

## 6. Frame

```
map_gfx_frame:
  view uniform ← camera, window size, pixel density
  uploads: changed highlight areas (rect writes), palettes, circles, overlay if revision changed, map uniforms
  quads: arrows → pills (dynamic range); marks in view → textured quads; sprites; glyphs
  passes:
    Quad  Distance  Lines  Min   static rivers    mask R
    Quad  Distance  Lines  Min   static roads     mask G
    Quad  Distance  Lines  Min   dynamic arrows   mask B
    Quad  Color     Marks  Over  marks in view
    Field map_ground Frame Clear
    Quad  Color     Frame  Over  sprites (world)
    Quad  Color     Frame  Over  texts (screen-sized glyphs at world anchors)
harness:
    Quad  Color     Frame  Over  UI (screen)
```

The field pass clears the frame (the backdrop colour outside the world comes from the shader), so the renderer's own
clear is no longer needed when a field pass is first.

## 7. Test harness (`src/main.odin`)

Exercises Seam B with authentic data and zero game logic:

1. Load `assets/scenarios/roman/{surface,elevation,moisture,trees}.png` (1024² grey) and `regions.png` (RGB → id via
   `regions.txt` colours). Surface PNG values → labels: check the encoding against `10b8261:src/game/scenario.odin`
   (`git show`), which reads the same files.
2. Parse `rivers.txt` / `roads.txt` (`way = { id = N  points = [[x, y], ...] }`) — port `ways_read` minus the tabula
   dependency or port tabula; `10b8261:src/tabula/tabula.odin`.
3. Cover grid: a *harness-local* stand-in for `terrain_type_of`: e.g. elevation ≥ 0.75 → Mountains(7); trees ≥ 0.5 →
   Forest(1); moisture < 0.4 → Desert(2); moisture > 0.85 and elevation < 0.2 → Marsh(5); else Open(0), strength 255.
   This is explicitly throwaway; it must not migrate into map graphics.
4. Cover palette and style from §8.1–8.3 verbatim; region palette: hash of id → colour.
5. Camera: wheel zoom about the cursor (step 1.15, 2..24 logical px/cell, not below world-fills-view), drag pan,
   WASD pan 900 px/s eased 6/s, clamp centre to world (`10b8261:src/game/camera.odin`). Key to cycle debug views.
6. Fake dynamics: one arrow along a hand-written path with a head; one Zone area as a 32-cell disc of cells on land
   with a circle; four pawns (sprite pairs + labels) at fixed cells; map-mode overlay = moisture; toggle keys.
7. Compare against `main` running side by side at the same camera. Screenshots at zoom 2, 5, 10, 24 over the same
   centre are the acceptance test for every step below.

## 8. Constants from `main` (copy exactly)

### 8.1 Style (`map_draw_init`, logical pixels, straight RGBA)

```
paper {0.840,0.772,0.620}  paper_stain {0.720,0.620,0.460}  paper_stain_amount 0.50  ink {0.150,0.105,0.070}
sea_shallow {0.560,0.610,0.620}  sea_deep {0.200,0.330,0.480}  sea_depth_from 0  sea_depth_full 80  sea_tint 0.55
coast_width 1.6  wobble 0.3  river_width 12  road_width 8  road_stroke 1.1  road_fill {0.950,0.840,0.660, a 0.55}
arrow_width 5  arrow_fill {0.700,0.250,0.160}  head_length 7.5  head_width 6.25
border_width 1.5  border_ink {0.400,0.180,0.120, a 0.3}  cover_jitter 0.8
```

### 8.2 Cover palette (`COVER_LOOKS`; sand = {0.900,0.800,0.600})

```
Open {}            Forest {0.600,0.640,0.470} wash .45        Desert sand wash .55 Stipple ink .45
Steppe sand wash .25   Fertile {0.720,0.740,0.540} wash .7    Marsh {0.580,0.640,0.640} wash .5
Highland {0.740,0.620,0.460} wash .35   Mountains {0.700,0.580,0.420} wash .45   Fields {0.790,0.770,0.600} wash .35
```

### 8.3 Looks

Region looks `REGION_LOOKS[mode][near|far]{plain, highlighted}` (`:46-80`), `REGION_FAR_ZOOM 5`; area looks
`AREA_LOOKS` (`:21-30`): Reach {0.300,0.450,0.650} border .7 thickness 1.5 inside .1 widen 1; Zones
{0.700,0.250,0.160} .6 2 .25; foreign reach {0.450,0.420,0.380} .7 1.5 .1 widen 1; Contacts {0.850,0.700,0.200} .6
2 .2. Ease rate 10/s. These belong to the caller (game), listed here for the harness.

### 8.4 Mark layers (`LAYERS`, `:198-240`)

| layer | spacing | row_squash | jitter | width | vary | footprint w/below | claims_own |
|---|---|---|---|---|---|---|---|
| Mountain | 8.04 | 0.8 | .6,.15 | 4.7 | .2 | .5/.45 | yes |
| Molehill | 3.84 | 0.8 | .7,.6 | 3.29 | .2 | .525/.5 | yes |
| Tree | 2.1 | 0.8 | .7,.6 | 1.6 | .3 | .7/0 | |
| Tuft | 3.8 | 0.8 | .7,.6 | 1.3 | .2 | — | |
| Marsh | 3.2 | 0.8 | .7,.6 | 2.3 | .15 | — | |
| Dune | 5.5 | 0.8 | .7,.6 | 3.4 | .2 | — | |
| Sea | 12 | 0.8 | .7,.6 | 3 | 0 | — | |

### 8.5 Markings (`MARKINGS`, `:242-330`; images under `assets/gfx/terrain/`, which exist on this branch)

mountain_0..3 Mountain, on land, elevation [.7,1.1), cover Mountains 1, grow .55 · hill_0..3 Molehill, land,
elevation [.6,.85) · conifer Tree, land, temperature [-.08,.02), cover Forest 1 / Fertile .45 · broadleaf same with
temperature [.02,.34) · cypress [.34,.5) · palm [.5,10), cover Fertile .45 · tuft Tuft, land, cover Steppe 1 ·
marsh Marsh, land, cover Marsh 1 · dune Dune, land, cover Desert 1 · sea_0..1 Sea, coast [-1000,-5), fade {-19,-5}.
"On land" = coast [1,1000). `BLUR {1, .1, .1}` random offsets on coast/elevation/temperature. `FOOTPRINT_RES 4`,
`MARK_DRAWN_WIDTH .7`, `WIDEN_SUPPORT 3`, `WAY_REACH 4`, `COAST_REACH 3`, `COAST_WATER_BAND 3`.

### 8.6 Pawns (`pawns.odin`)

`PAWN_CELLS_PER_PIXEL` Picture 5/400, Medallion 5/150; `PAWN_SIZES` Village 1.65 Town 1.95 City 2.1 Large_City 2.55
Army 1.1 Fleet 1.0; medallions below zoom 10, fade .25 s; focus tint {1,.7,.35} pulse 1.2 s; engaged tint
{.9,.35,.3}; label halo 1.5 px, font Text 22 px, centred below the sprite. Images `assets/gfx/{pawns,medallions}/
<culture>_<tag>[ _fill].png`.

### 8.7 Shader constants

`LINE_FAR 1000`; `EDGE_STEEPNESS_MIN .25 / MAX 4`; `HIGHLIGHT_SMOOTHING 1.5`, `BLUR_REACH 4`, `MARGIN 6`,
`FIELD_MAX 64`, `OWN_MIN .1`; noise seeds and scales exactly as in `MAP_SOURCE` (paper `0.02+3.1`, `0.09+11.3`; coast
wobble `0.45+7.7` ×1.6; region wander `wobble*1.6, 5.7`; river wander `wobble, 3.3`; road tremble `value_noise(p*3.1
+9.1/14.3)`, stroke pressure `value_noise(p*1.7+2.9)`; coast width `value_noise(p*0.8)`; stipple 7 device px).

## 9. Deferred simplifications (only after parity, each with a before/after comparison)

1. Bake the wobble into the coast contour before stamping, and drop `wander`/`fbm` from the coast lookup. Needs the
   region lookup to agree (see `map_primitives.md`, §"Why not a third"): either keep the shader wander for regions or
   move region fills to contour-stamped fields too.
2. Replace per-area EDT+blur highlight fields with contour-stamped fields; retire `areas_over`'s 4-cell exact-read
   logic for a plain sampled field + id.
3. Split `map_ground.wgsl` into ground (opaque) and overlay (multiply) passes with marks drawn straight to the frame,
   removing the Marks target.
4. Draw region borders from traced contours as pills instead of from the field's edge estimate.

None of these change Seam A or Seam B.

## 10. Implementation order

Each step compiles, runs and shows something; commit each.

1. **Renderer: view uniform, `axis`, `space`.** Harness draws rotated pills in world space and pans/zooms them.
   Accept: a pill stays a pill at any rotation and zoom; screen-space UI quads unaffected.
2. **Renderer: targets, blends, distance variant, textures API, field pass plumbing** with a trivial field shader
   that shows a bound R8 texture as grey. Harness binds `elevation.png`. Accept: elevation visible, correct
   orientation, outside-world colour, resize works.
3. **Map graphics: grids + cells texture + the ground shader in debug modes 1–5** (surface, elevation, trees,
   moisture, cover). Accept: matches `main`'s debug views.
4. **Coast:** tracing, smoothing, stamping, EDT, coast texture; shader paper/sea/land/coast line. Accept: coast
   identical to `main` at the four zooms (same wobble, same width noise).
5. **Lines:** static pills, Lines target, Min blend; river and road styling in the shader. Accept: identical.
6. **Cover + stipple.** Accept: identical with the harness cover grid fed to both (`main` would need the same grid —
   compare at the level of "same palette, same look per category" instead).
7. **Regions:** highlight bookkeeping, field build, palettes, `areas_over`, borders. Accept: identical with a fixed
   palette.
8. **Marks:** placement, claims, Marks target, composite. Accept: same forest, same mountains (hash parity).
9. **Highlights + circles + overlay.** Accept: identical with the harness's fake zone.
10. **Arrows.** Accept: identical head and body.
11. **Sprites + texts** (pawns, labels, halo). Accept: identical sizes and medallion switch.
12. Budgets, culling, static buffer; profile at zoom 2 full-screen 4K.

## 11. Open decisions (make before step 1)

- Packages vs single package (§2). Recommended: packages.
- Zoom unit at Seam B: logical px/cell (recommended) or physical.
- `Render_Shape` enum on the instance vs flag encoding for arrowheads (recommended: enum byte).
- One quad buffer with a large budget vs static + frame buffers (recommended: two).
