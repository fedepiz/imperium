// Ground shader. Compiled with view.wgsl prepended (View, view_* functions).
// Full-window triangle. fs_main outputs the ground colour of each pixel.
// Positions are in cells, origin at the grid's top-left. Grids: one texel per cell.

// Must match Ground_Uniform in renderer.odin
struct Ground {
    base_color:        vec3f,
    stain_amount:      f32,
    base_stain:        vec3f,
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
}

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

@fragment
fn fs_main(@builtin(position) frag: vec4f) -> @location(0) vec4f {
    let p = view_from_pixel(frag.xy);
    // Physical pixels per cell
    let px = view.zoom;

    // Outside the grid
    if any(p < vec2f(0.0)) || any(p >= ground.grid) {
        return vec4f(ground.base_color * 0.72, 1.0);
    }

    var col = base_at(p, frag.xy);

    // Divide: signed distance d, land mask with a 1 pixel edge
    let d = textureSampleLevel(divide_grid, grid_sampler, p / ground.grid, 0.0).r
          + ground.divide_wobble * (fbm(p * 0.45 + 7.7) - 0.5);
    let land = smoothstep(-0.5 / px, 0.5 / px, d);

    // Divide, water side: tint by depth, strongest at the line
    let depth = clamp(
        (-d - ground.divide_depth_from) / max(ground.divide_depth_full - ground.divide_depth_from, 1e-3),
        0.0, 1.0);
    let water_color = mix(ground.divide_shallow, ground.divide_deep, depth);
    let water = col * mix(vec3f(1.0), water_color, ground.divide_tint * (0.65 + 0.35 * exp(min(d, 0.0) / 5.0)));
    col = mix(water, col, land);

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
