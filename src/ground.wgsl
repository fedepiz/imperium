// Ground shader. Compiled with view.wgsl prepended (View, view_* functions).
// Full-window triangle. fs_main outputs the ground colour of each pixel.
// Positions are in cells, origin at the grid's top-left. Grids: one texel per cell.

// Must match Ground_Uniform in renderer.odin
struct Ground {
    base_color:        vec3f,
    stain_amount:      f32,
    base_stain:        vec3f,
    category_jitter:   f32,
    divide_shallow:    vec3f,
    divide_tint:       f32,
    divide_deep:       vec3f,
    divide_wobble:     f32,
    divide_line_color: vec3f,
    divide_line_width: f32,
    value_low:         vec3f,
    value_strength:    f32,
    value_high:        vec3f,
    // Render_Ground_Clip
    value_clip:        i32,
    // Grid size in cells
    grid:              vec2f,
    divide_depth_from: f32,
    divide_depth_full: f32,
    category_pattern:  vec3f,
    category_strength: f32,
    strokes:           array<Stroke, STROKE_COUNT>,
}

// RENDER_GROUND_STROKES
const STROKE_COUNT = 2;

// Must match Stroke_Uniform in renderer.odin
struct Stroke {
    color:      vec3f,
    width:      f32,
    fill:       vec3f,
    strength:   f32,
    // Stroke_Kind
    kind:       i32,
    // Render_Ground_Clip
    clip:       i32,
    edge_width: f32,
    wander:     f32,
}

// Stroke_Kind
const STROKE_NONE   = 0;
const STROKE_LINE   = 1;
const STROKE_DOUBLE = 2;

// Render_Ground_Clip
const CLIP_NONE  = 0;
const CLIP_LAND  = 1;
const CLIP_WATER = 2;

@group(1) @binding(0) var<uniform> ground: Ground;
// Linear filter, clamp to edge
@group(1) @binding(1) var grid_sampler: sampler;
// Grids. Binding = 2 + Ground_Grid
@group(1) @binding(2) var value_grid:  texture_2d<f32>;
@group(1) @binding(3) var divide_grid: texture_2d<f32>;
@group(1) @binding(4) var taper_grid:  texture_2d<f32>;
// rg: category / 255, strength
@group(1) @binding(5) var category_grid: texture_2d<f32>;
// x: category. Row 0: wash colour rgb, wash. Row 1: Render_Ground_Pattern / 255, pattern ink
@group(1) @binding(6) var category_looks: texture_2d<f32>;
// Window-sized. Channel i: distance to stroke i's nearest segment, in cells
@group(1) @binding(7) var strokes_target: texture_2d<f32>;

// Render_Ground_Pattern
const PATTERN_STIPPLE = 1;

// Full-window triangle
@vertex
fn vs_main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
    let p = vec2f(f32((index << 1u) & 2u), f32(index & 2u));
    return vec4f(p * 2.0 - 1.0, 0.0, 1.0);
}

fn hash(p_in: vec2f) -> f32 {
    var p = fract(p_in * vec2f(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Integer lattice hash, 0..1
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

// 4-octave value noise, 0..1
fn fbm(p_in: vec2f) -> f32 {
    var p = p_in;
    var sum = 0.0;
    var weight = 0.5;
    for (var i = 0; i < 4; i++) { sum += weight * value_noise(p); p *= 2.03; weight *= 0.5; }
    return sum / 0.9375;
}

// Base layer: colour, stains (world-space fbm), grain (per-pixel hash)
fn base_at(p: vec2f, pixel: vec2f) -> vec3f {
    let stain = smoothstep(0.35, 0.85, fbm(p * 0.02 + 3.1)) * 0.85 + (fbm(p * 0.09 + 11.3) - 0.5) * 0.2;
    let c = mix(ground.base_color, ground.base_stain, clamp(stain * ground.stain_amount, 0.0, 1.0));
    return c * (1.0 - (hash(floor(pixel)) - 0.5) * 0.035);
}

// Coverage of a line of half width half_w at distance dist, both in physical pixels.
// Lines thinner than a pixel fade instead of vanishing
fn line_aa(dist: f32, half_w: f32) -> f32 {
    let hw = max(half_w, 0.5);
    return (1.0 - smoothstep(hw - 0.6, hw + 0.6, dist)) * min(1.0, half_w / 0.5);
}

// Factor of a layer clipped to a side of the divide. land: 0 water side, 1 land side
fn clip_factor(clip: i32, land: f32) -> f32 {
    if clip == CLIP_LAND { return land; }
    if clip == CLIP_WATER { return 1.0 - land; }
    return 1.0;
}

// Dots on a world-fixed grid of the given spacing, in cells. Each grid square has a dot with
// probability density, near its middle. radius in physical pixels
fn stipple_grid(p: vec2f, spacing: f32, px: f32, density: f32, radius: f32) -> f32 {
    let g  = p / spacing;
    let id = floor(g);
    if hash(id + 3.7) >= density { return 0.0; }
    let dot_at = id + 0.25 + 0.5 * vec2f(hash(id), hash(id + 17.3));
    return 1.0 - smoothstep(radius - 0.6, radius + 0.6, length(g - dot_at) * spacing * px);
}

// Stipple with dots about 7 logical pixels apart at any zoom: grid spacing is a power of two cells,
// and the two nearest spacings cross-fade
fn stipple_at(p: vec2f, px: f32, density: f32) -> f32 {
    let level  = log2(7.0 * view.pixel_density / px);
    let l0     = floor(level);
    let radius = 0.75 * view.pixel_density;
    return mix(
        stipple_grid(p, exp2(l0), px, density, radius),
        stipple_grid(p, exp2(l0 + 1.0), px, density, radius),
        level - l0);
}

// Category layer at p
struct Category_Shown {
    // Factor on the colour under the layer
    tint:            vec3f,
    stipple_density: f32,
    stipple_ink:     f32,
}

// Categories are not interpolable, so the 4 cells around p are read exactly and their looks blended.
// The lookup position is displaced by noise, so category borders do not follow the grid
fn category_at(p: vec2f) -> Category_Shown {
    let q = p - 0.5 + ground.category_jitter * (vec2f(fbm(p * 0.3 + 1.3), fbm(p * 0.3 + 9.1)) - 0.5);
    let origin = floor(q);
    let f = q - origin;
    var shown = Category_Shown(vec3f(0.0), 0.0, 0.0);
    for (var k = 0; k < 4; k++) {
        let corner   = vec2i(k & 1, k >> 1u);
        let cell     = textureLoad(category_grid, clamp(vec2i(origin) + corner, vec2i(0), vec2i(ground.grid) - 1), 0).rg;
        let category = i32(cell.r * 255.0 + 0.5);
        let wash     = textureLoad(category_looks, vec2i(category, 0), 0);
        let pattern  = textureLoad(category_looks, vec2i(category, 1), 0);
        let weight   = mix(1.0 - f.x, f.x, f32(corner.x)) * mix(1.0 - f.y, f.y, f32(corner.y));
        shown.tint += weight * mix(vec3f(1.0), wash.rgb, wash.a * cell.g);
        if i32(pattern.r * 255.0 + 0.5) == PATTERN_STIPPLE {
            shown.stipple_density += weight * cell.g;
            shown.stipple_ink     += weight * pattern.g;
        }
    }
    return shown;
}

// p displaced by noise, peak-to-peak amount per axis, in cells
fn wander(p: vec2f, amount: f32, seed: f32) -> vec2f {
    return p + amount * (vec2f(fbm(p * 0.6 + seed), fbm(p * 0.6 + seed + 5.2)) - 0.5);
}

// Distance from p to the nearest segment of a stroke, in cells. Strokes target, bilinear
fn stroke_distance(p: vec2f, stroke: i32) -> f32 {
    let uv = view_to_pixel(p) / vec2f(textureDimensions(strokes_target));
    return textureSampleLevel(strokes_target, grid_sampler, uv, 0.0)[stroke];
}

// Stroke layer over col. base: base layer colour at p. land: 0 water side, 1 land side. px: pixels per cell
fn stroke_over(col_in: vec3f, p: vec2f, index: i32, base: vec3f, land: f32, px: f32) -> vec3f {
    let stroke  = ground.strokes[index];
    let shown   = clip_factor(stroke.clip, land);
    let density = view.pixel_density;
    var col = col_in;

    if stroke.kind == STROKE_LINE {
        let d = stroke_distance(wander(p, stroke.wander, 3.3), index);
        // Wash, to 1.2 cells either side
        col = mix(col, col * stroke.fill, stroke.strength * (1.0 - smoothstep(0.0, 1.2, d)) * shown);
        // Line. Half width: thinned by the taper grid, capped at 1/6 cell
        let taper = textureSampleLevel(taper_grid, grid_sampler, p / ground.grid, 0.0).r;
        let half  = min(stroke.width * 0.5 * density * mix(1.0, 0.4, smoothstep(0.2, 0.8, taper)), px / 6.0);
        col = mix(col, stroke.color, line_aa(d * px, half) * shown);
    } else if stroke.kind == STROKE_DOUBLE {
        // Lookup trembles by about a pixel
        let tremble = (vec2f(value_noise(p * 3.1 + 9.1), value_noise(p * 3.1 + 14.3)) - 0.5) * density / px;
        let d    = stroke_distance(p + tremble, index) * px;
        // Half width, capped at 1/4 cell
        let half = min(stroke.width * 0.5 * density, px / 4.0);
        // 0: too narrow for two edges, drawn as one line. 1: edges and fill
        let parted = smoothstep(1.5, 3.0, half / density);
        let fill   = stroke.fill * base;
        col = mix(col, mix(stroke.color, fill, 0.35), line_aa(d, max(half, 0.6 * density)) * shown * (1.0 - parted));
        col = mix(col, fill, stroke.strength * line_aa(d, half) * shown * parted);
        // Edge lines, half width varying along the stroke
        let edge = stroke.edge_width * 0.5 * density * (0.6 + 0.8 * value_noise(p * 1.7 + 2.9));
        col = mix(col, stroke.color, line_aa(abs(d - (half - edge)), edge) * shown * parted);
    }
    return col;
}

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let p = view_from_pixel(frag.xy);
    // Physical pixels per cell
    let px = view.zoom;

    // Outside the grid
    if any(p < vec2f(0.0)) || any(p >= ground.grid) {
        return vec4f(ground.base_color * 0.72, 1.0);
    }

    let base = base_at(p, frag.xy);

    // Category layer: washes, then patterns
    let category = category_at(p);
    var col = base * mix(vec3f(1.0), category.tint, ground.category_strength);
    col = mix(col, ground.category_pattern,
              stipple_at(p, px, category.stipple_density) * category.stipple_ink * ground.category_strength);

    // Divide: signed distance d, land mask with a 1 pixel edge
    let d = textureSampleLevel(divide_grid, grid_sampler, p / ground.grid, 0.0).r
          + ground.divide_wobble * (fbm(p * 0.45 + 7.7) - 0.5);
    let land = smoothstep(-0.5 / px, 0.5 / px, d);

    // Divide, water side: tint by depth, strongest at the line
    let depth = clamp(
        (-d - ground.divide_depth_from) / max(ground.divide_depth_full - ground.divide_depth_from, 1e-3),
        0.0, 1.0);
    let water_color = mix(ground.divide_shallow, ground.divide_deep, depth);
    let water = base * mix(vec3f(1.0), water_color, ground.divide_tint * (0.65 + 0.35 * exp(min(d, 0.0) / 5.0)));
    col = mix(water, col, land);

    // Strokes
    for (var i = 0; i < STROKE_COUNT; i++) {
        col = stroke_over(col, p, i, base, land, px);
    }

    // Divide, line at d = 0
    let line_half = ground.divide_line_width * 0.5 * view.pixel_density * (0.8 + 0.4 * value_noise(p * 0.8));
    col = mix(col, ground.divide_line_color, line_aa(abs(d) * px, line_half));

    // Value layer: multiply by mix(low, high, value)
    let value = textureSampleLevel(value_grid, grid_sampler, p / ground.grid, 0.0).r;
    let tint  = mix(ground.value_low, ground.value_high, value);
    col = mix(col, col * tint, ground.value_strength * clip_factor(ground.value_clip, land));

    // Edge darkening: 0.84 at the grid border, 1 from 12 cells in
    let m = min(p, ground.grid - p);
    col *= mix(0.84, 1.0, smoothstep(0.0, 12.0, min(m.x, m.y)));
    return vec4f(col, 1.0);
}
