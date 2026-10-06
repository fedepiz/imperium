// Quad shader. Compiled with view.wgsl prepended (View, view_* functions)

@group(1) @binding(0) var atlas:         texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

// Added to the mip level. Negative: sharper, and less steady when shrunk
const LEVEL_BIAS = 0.0;

struct Quad_In {
    @location(0)  rect:      vec4f,
    @location(1)  color_tl:  vec4f,
    @location(2)  color_tr:  vec4f,
    @location(3)  color_br:  vec4f,
    @location(4)  color_bl:  vec4f,
    @location(5)  clip:      vec4f,
    @location(6)  radius:    f32,
    @location(7)  thickness: f32,
    @location(8)  softness:  f32,
    @location(9)  source:    vec4f,
    @location(10) axis:      vec2f,
}

// All lengths in physical pixels
struct Vertex_Out {
    @builtin(position)              position:  vec4f,
    @location(0)                    color:     vec4f,
    // Offset from the rect centre, in the rect's rotated frame
    @location(1)                    local:     vec2f,
    @location(2) @interpolate(flat) half_size: vec2f,
    @location(3) @interpolate(flat) clip:      vec4f,
    @location(4) @interpolate(flat) shape:     vec3f,
    @location(5) @interpolate(flat) source:    vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) index:u32, quad: Quad_In) -> Vertex_Out {
    // Strip corners
    let corner = vec2f(f32(index & 1u), f32(index >> 1u));

    // Pass's space to pixels
    let centre    = view_to_pixel((quad.rect.xy + quad.rect.zw) * 0.5);
    let half_size = (quad.rect.zw - quad.rect.xy) * 0.5 * view.zoom;
    let shape     = vec3f(quad.radius, quad.thickness, quad.softness) * view.zoom;

    // Local axes. Zero axis = unrotated. axis_y = axis_x rotated by 90 degrees
    let axis_length = length(quad.axis);
    let axis_x      = select(vec2f(1.0, 0.0), quad.axis / axis_length, axis_length > 0.0);
    let axis_y      = vec2f(-axis_x.y, axis_x.x);

    // Expand by softness + 1 pixel for anti-aliasing
    let grow  = shape.z + 1.0;
    let local = (corner * 2.0 - 1.0) * (half_size + grow);
    let pixel = centre + local.x * axis_x + local.y * axis_y;

    // Quad colours
    var colors = array(quad.color_tl, quad.color_tr, quad.color_bl, quad.color_br);

    var out: Vertex_Out;
    out.position  = view_to_clip(pixel);
    out.color     = colors[index];
    out.local     = local;
    out.half_size = half_size;
    out.clip      = quad.clip;
    out.shape     = shape;
    out.source    = quad.source;
    return out;
}

// Signed distance to a rounded box centered on the origin: negative inside
fn rounded_box(p: vec2f, half_size: vec2f, radius: f32) -> f32 {
    let q = abs(p) - half_size + radius;
    return length(max(q, vec2f(0.0,0.0))) + min(max(q.x,q.y), 0.0) - radius;
}

@fragment
fn fs_main(in: Vertex_Out) -> @location(0) vec4f {
    let pixel     = in.position.xy;
    let radius    = in.shape.x;
    let thickness = in.shape.y;
    let softness  = in.shape.z;

    // Clip
    if in.clip.z > in.clip.x {
        if any(pixel < in.clip.xy) || any(pixel >= in.clip.zw) {
            discard;
        }
    }

    // Distance to the shape edge
    let half_radius = min(radius, min(in.half_size.x, in.half_size.y));
    let dist        = rounded_box(in.local, in.half_size, half_radius);

    // Coverage, one pixel anti-aliasing plus softness
    let edge     = 0.5 + softness;
    var coverage = 1.0 - smoothstep(-edge, edge, dist);

    // Border, cut out the inside
    if thickness > 0.0 {
        coverage *= smoothstep(-edge, edge, dist + thickness);
    }

    let t     = clamp(in.local / (in.half_size * 2.0) + 0.5, vec2f(0.0), vec2f(1.0));
    let uv    = mix(in.source.xy, in.source.zw, t) / vec2f(textureDimensions(atlas));
    // Mip level: source texels per pixel of the quad, as a power of two
    let texels = (in.source.zw - in.source.xy) / (in.half_size * 2.0);
    let level  = log2(max(max(texels.x, texels.y), 1.0)) + LEVEL_BIAS;
    let texel  = textureSampleLevel(atlas, atlas_sampler, uv, max(level, 0.0));
    let tex   = select(vec4f(1.0), texel, in.source.z > in.source.x);

    // Premultiply alpha
    let alpha = in.color.a * coverage;
    return vec4f(in.color.rgb * alpha, alpha) * tex;
}
