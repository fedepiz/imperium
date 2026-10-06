// Stroke distance shader. Compiled with view.wgsl prepended (View, view_* functions).
// One instanced quad per segment, in world space. Output: distance from the pixel to the segment, in cells.
// Min-blended into one channel of the strokes target, which the ground shader reads.

struct Varyings {
    @builtin(position)              position: vec4f,
    // Cells
    @location(0)                    p: vec2f,
    @location(1) @interpolate(flat) a: vec2f,
    @location(2) @interpolate(flat) b: vec2f,
}

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32, @location(0) a: vec2f, @location(1) b: vec2f) -> Varyings {
    // x: along the segment, 0 at a, 1 at b. y: across it, -1..1
    var corners = array<vec2f, 6>(
        vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
        vec2f(0.0, -1.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));
    let corner = corners[vertex];

    let length = distance(a, b);
    let along  = select(vec2f(1.0, 0.0), (b - a) / length, length > 1e-6);
    let across = vec2f(-along.y, along.x);

    // Distance the quad extends past the segment, in cells: the farthest the ground shader reads.
    // 2 cells (wash, wander) + 24 logical pixels (widest stroke)
    let reach = 2.0 + 24.0 * view.pixel_density / view.zoom;
    let p = mix(a - along * reach, b + along * reach, corner.x) + across * reach * corner.y;

    var out: Varyings;
    out.position = view_to_clip(view_to_pixel(p));
    out.p = p;
    out.a = a;
    out.b = b;
    return out;
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4f {
    let ab = in.b - in.a;
    let t  = clamp(dot(in.p - in.a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    let d  = distance(in.p, in.a + ab * t);
    return vec4f(d);
}
