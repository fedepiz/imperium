# Map renderer: minimum primitives

## The minimum

Two primitives. Everything else is either a CPU computation that produces their inputs, or a variant of how one of them is bound (target, blend, shader).

### 1. Quad (have) — the *instance* primitive

A discrete thing placed at a position, with its own shape and look. What the current one lacks for the map:

| Addition | Why |
|---|---|
| **Transform select** (screen or world→screen via the view uniform) | Map quads live in cells. Converting thousands on the CPU each frame while panning is wasted work; one uniform does it. |
| **Rotation** (a direction vector per instance) | A rounded box with `radius = half_height`, rotated, *is* a capsule. So every line segment is a rotated pill quad. Rotation also gives you oriented arrowheads, curved labels (per-glyph rotation), and facing pawns. Without it you'd need a separate segment primitive for the same SDF. |
| **Per-pass target and blend** | The same instances need to be drawn into different places: colour over the frame (premultiplied over), **minimum-distance into an offscreen float texture** (`Min` blend), multiply tint. This is what lets quads build the inputs of primitive 2. |
| **Distance-output shader variant** | Same instance data, fragment writes `d` instead of colour. Pills write analytic distance; textured quads write the sampled texel as distance (an **SDF sprite**: an arrowhead or any authored shape). This is a second pipeline over the same buffer, not a new primitive. |

### 2. Field pass — the *continuous* primitive

A full-screen triangle; the fragment turns its pixel into a world position `p` and `px`, samples textures, outputs a colour. Needed because the ground is a function defined everywhere, on a grid finer than any quad decomposition: paper noise, sea depth gradient, cover washes blended between cells, zoom-adaptive stipple. One quad per cell would be a million instances and still couldn't blend palette lookups across cell edges.

Its inputs are all textures, of three kinds:

| Kind | Space | Examples | Produced by |
|---|---|---|---|
| **Grids** | world, 1024² | surface, elevation, moisture, trees, cover id, map-mode value | decoded at load / written on state change |
| **Stamped fields** | world, 1024² (or 2×) | coast distance; region `(id_left, id_right, signed d)`; highlight fields per layer | CPU stamping of polylines, discs, cell sets |
| **Line distance** | screen | distance to nearest river / road / arrow, one channel each | quad distance variant, `Min` blend, every frame |
| **Palettes** | 256×n | region id → colour/border/inside; cover id → tint/pattern | rewritten on state change / hover |

The field pass runs more than once per frame with different shaders and blends (ground: opaque; highlights/map-mode: multiply over marks). That's the same primitive bound differently.

### Why not a third

- **Polygon mesh** for region fills: not needed. Stamping the wobbled contour gives each texel the two region ids on either side and a signed distance; the pixel picks a side by the interpolated sign. Fill, inward fade and border all come from one field, and they're consistent with each other by construction because they come from the same polyline. A mesh would be a third pipeline with no gain.
- **Segment/ribbon primitive**: not needed. The union-before-styling problem (joins, translucent washes, pen pressure, two-stroke roads) is solved by the min-distance texture; the pill quads just write `d`, the field pass styles once per pixel. Along-path `s` isn't required by any element below.
- **Stencil**: not needed because nothing translucent is drawn as a capsule union; all line *styling* happens in the field pass.

### CPU computations (not primitives, but required producers)

Contour extraction (marching squares on label grids); polyline smoothing + wobble (one function, used by coast, borders, rivers, roads, arrow paths); polyline cut at coast; **stamping** (segment, disc, cell set → distance field texel writes); mark placement with footprint claims; atlas packing (have); text layout (have); view/camera.

## Every element, mapped

In draw order. **Q** = quad, **Qd** = quad distance variant into a line texture, **F** = field pass.

| # | Element | Primitive | Inputs / notes |
|---|---|---|---|
| 1 | River distance | Qd (pills, world) | static segment range, `Min` blend → channel R |
| 2 | Road distance | Qd (pills, world) | static range → channel G |
| 3 | Arrow distance | Qd (pills + SDF-sprite heads, world) | dynamic range → channel B |
| 4 | Outside-world backdrop | F ground | `p` outside grid → dark paper |
| 5 | Paper (stains world-fixed, grain screen-fixed) | F ground | `fbm(p)`, `hash(frag)` |
| 6 | Sea tint, depth gradient, shallow band | F ground | coast field (sign + magnitude) |
| 7 | Land/sea mask | F ground | coast field, `coverage(d, px)` — shared by 6, 8, 9, 11–14, 20, 21 |
| 8 | Cover washes (forest, fertile, marsh…) | F ground | cover id grid + cover palette, 4-cell blend |
| 9 | Desert stipple | F ground | cover palette pattern, `px`-adaptive grid |
| 10 | Region fill, inward fade, near/far look, highlighted/hover | F ground | region field + region palette (palette row rewritten on owner/hover change) |
| 11 | Region border hairline | F ground | region field: `|d|` small, `coverage` |
| 12 | Coast ink line, width varying | F ground | coast field, `noise(p)` |
| 13 | River wash + line, thinning with elevation, capped at `px/6` | F ground | line tex R, elevation grid, land mask |
| 14 | Road fill + two strokes + tremble, collapsing when zoomed out | F ground | line tex G, `noise(p)`, `px`, land mask |
| 15 | Sheet-edge vignette | F ground | `min(p, grid − p)` |
| 16 | Marks: mountains, hills, trees ×4 species, tufts, marsh, dunes, sea marks | Q (world, atlas) | placed at load with footprint claims; static range |
| 17 | Towns / settlement icons | Q (world, atlas) | from scenario |
| 18 | Pawns + medallions | Q (world, atlas) | dynamic range |
| 19 | Labels (region, town names; straight or curved) | Q (world, glyph atlas, rotation) | text layout on CPU |
| 20 | Highlight areas: zones, contacts, reach — edge, thickness, inside, clipped to land or water | F overlay (multiply) | highlight fields (one per layer, stamped from cell sets at state change) + highlight palette, coast field for surface clip |
| 21 | Highlight circles | F overlay | discs stamped into the same highlight field on CPU |
| 22 | Map-mode / supply overlay | F overlay | value grid, land mask |
| 23 | Arrows: fill between ink edges, constant screen width, head | F overlay | line tex B; or opaque pills+head in two layers (ink, fill) as Q — both work since the fill is opaque; the F route keeps all line styling in one place |
| 24 | Selection / hover outline on a region | F ground | palette row change only — no geometry |
| 25 | Debug views: raw channels, cell grid lines, line hit test | F ground (mode switch) | grids, line tex |
| 26 | UI: panels, tooltips, text, portraits | Q (screen) | have |

Picking (region under cursor, arrow under cursor, pawn under cursor) is CPU-side against the id grid, polylines and quad rects; it uses no primitive.

Frame sequence: **1–3** (distance textures) → **4–15** (one ground field pass) → **16–19** (world quads) → **20–23** (overlay field pass, multiply) → **26** (screen quads).
