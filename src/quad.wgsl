struct Viewport {
    size: vec2f
}

@group(0) @binding(0) var<uniform> viewport: Viewport;

struct Quad_In {
    @location(0) rect:     vec4f,
    @location(1) color_tl: vec4f,
    @location(2) color_tr: vec4f,
    @location(3) color_br: vec4f,
    @location(4) color_bl: vec4f,
}

struct Vertex_Out {
    @builtin(position) position: vec4f,
    @location(0)       color   : vec4f,
}

@vertex
fn vs_main(@builtin(vertex_index) index:u32, quad: Quad_In) -> Vertex_Out {
    // Strip corners
    let corner = vec2f(f32(index & 1u), f32(index >> 1u));
    let pixel = mix(quad.rect.xy, quad.rect.zw, corner);

    // Pixels to clip space
    let clip = pixel / viewport.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0);

    // Quad colours
    var colors = array(quad.color_tl, quad.color_tr, quad.color_bl, quad.color_br);

    var out: Vertex_Out;
    out.position = vec4f(clip, 0.0, 1.0);
    out.color = colors[index];
    return out;
}

@fragment
fn fs_main(in: Vertex_Out) -> @location(0) vec4f {
    // Premultiply alpha
    return vec4f(in.color.rgb * in.color.a, in.color.a);
}
