struct Viewport {
    size: vec2f
}

@group(0) @binding(0) var<uniform> viewport: Viewport;

@group(1) @binding(0) var atlas:         texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

struct Quad_In {
    @location(0) rect:      vec4f,
    @location(1) color_tl:  vec4f,
    @location(2) color_tr:  vec4f,
    @location(3) color_br:  vec4f,
    @location(4) color_bl:  vec4f,
    @location(5) clip:      vec4f,
    @location(6) radius:    f32,
    @location(7) thickness: f32,
    @location(8) softness:  f32,
    @location(9) source:    vec4f,
}

struct Vertex_Out {
    @builtin(position)              position: vec4f,
    @location(0)                    color:    vec4f,
    @location(1) @interpolate(flat) rect:     vec4f,
    @location(2) @interpolate(flat) clip:     vec4f,
    @location(3) @interpolate(flat) shape:    vec3f,
    @location(4) @interpolate(flat) source:   vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) index:u32, quad: Quad_In) -> Vertex_Out {
    // Strip corners
    let corner = vec2f(f32(index & 1u), f32(index >> 1u));

    let grow  = quad.softness + 1;
    let pixel = mix(quad.rect.xy - grow, quad.rect.zw + grow, corner);

    // Pixels to clip space
    let clip = pixel / viewport.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);

    // Quad colours
    var colors = array(quad.color_tl, quad.color_tr, quad.color_bl, quad.color_br);

    var out: Vertex_Out;
    out.position = vec4f(clip, 0.0, 1.0);
    out.color    = colors[index];
    out.rect     = quad.rect;
    out.clip     = quad.clip;
    out.shape    = vec3f(quad.radius, quad.thickness, quad.softness);
    out.source   = quad.source;
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
    let half_size   = (in.rect.zw - in.rect.xy) * 0.5;
    let centre      = (in.rect.xy + in.rect.zw) * 0.5;
    let half_radius = min(radius, min(half_size.x, half_size.y));
    let dist        = rounded_box(pixel - centre, half_size, half_radius);

    // Coverage, one pixel anti-aliasing plus softness
    let edge     = 0.5 + softness;
    var coverage = 1.0 - smoothstep(-edge, edge, dist);

    // Border, cut out the inside
    if thickness > 0.0 {
        coverage *= smoothstep(-edge, edge, dist + thickness);
    }

    let t     = clamp((pixel - in.rect.xy) / (in.rect.zw - in.rect.xy), vec2f(0.0), vec2f(1.0));
    let uv    = mix(in.source.xy, in.source.zw, t) / vec2f(textureDimensions(atlas));
    let texel = textureSampleLevel(atlas, atlas_sampler, uv, 0.0);
    let tex   = select(vec4f(1.0), texel, in.source.z > in.source.x);

    // Premultiply alpha
    let alpha = in.color.a * coverage;
    return vec4f(in.color.rgb * alpha, alpha) * tex;
}
