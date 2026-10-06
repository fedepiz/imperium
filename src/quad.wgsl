// Maps the pass's space to the window: pixel = (p - center) * zoom + size / 2
struct View {
    // Window size in physical pixels
    size:   vec2f,
    // Position shown at the window centre
    center: vec2f,
    // Physical pixels per unit
    zoom:   f32,
}

@group(0) @binding(0) var<uniform> view: View;

@group(1) @binding(0) var atlas:         texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

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

// Lengths are in physical pixels from here on
struct Vertex_Out {
    @builtin(position)              position:  vec4f,
    @location(0)                    color:     vec4f,
    // From the rect centre, in the rect's own (rotated) frame
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

    // Space to pixels
    let centre    = ((quad.rect.xy + quad.rect.zw) * 0.5 - view.center) * view.zoom + view.size * 0.5;
    let half_size = (quad.rect.zw - quad.rect.xy) * 0.5 * view.zoom;
    let shape     = vec3f(quad.radius, quad.thickness, quad.softness) * view.zoom;

    // Local x axis, zero = unrotated. The y axis is a quarter turn on, towards screen down
    let axis_length = length(quad.axis);
    let axis_x      = select(vec2f(1.0, 0.0), quad.axis / axis_length, axis_length > 0.0);
    let axis_y      = vec2f(-axis_x.y, axis_x.x);

    // Room for the soft edge and anti-aliasing
    let grow  = shape.z + 1.0;
    let local = (corner * 2.0 - 1.0) * (half_size + grow);
    let pixel = centre + local.x * axis_x + local.y * axis_y;

    // Pixels to clip space
    let clip = pixel / view.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);

    // Quad colours
    var colors = array(quad.color_tl, quad.color_tr, quad.color_bl, quad.color_br);

    var out: Vertex_Out;
    out.position  = vec4f(clip, 0.0, 1.0);
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
    let texel = textureSampleLevel(atlas, atlas_sampler, uv, 0.0);
    let tex   = select(vec4f(1.0), texel, in.source.z > in.source.x);

    // Premultiply alpha
    let alpha = in.color.a * coverage;
    return vec4f(in.color.rgb * alpha, alpha) * tex;
}
