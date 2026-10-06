// Stroke distance shader. Compiled with view.wgsl prepended (View, view_* functions).
// One instanced quad per segment, in world space. Output: distance from the pixel to the segment, in cells.
// A segment with a head also outputs the signed distance to the head's triangle, negative inside.
// Min-blended into one channel of the strokes target, which the ground shader reads.

struct Varyings {
    @builtin(position)              position: vec4f,
    // Cells
    @location(0)                    p: vec2f,
    @location(1) @interpolate(flat) a: vec2f,
    @location(2) @interpolate(flat) b: vec2f,
    // Arrowhead at b: length, width, in cells. Zero = none
    @location(3) @interpolate(flat) head: vec2f,
}

// Unit vector from a to b. +x where they coincide
fn direction(a: vec2f, b: vec2f) -> vec2f {
    let length = distance(a, b);
    return select(vec2f(1.0, 0.0), (b - a) / length, length > 1e-6);
}

@vertex
fn vs_main(
    @builtin(vertex_index) vertex: u32,
    @location(0) a: vec2f,
    @location(1) b: vec2f,
    // Logical pixels
    @location(2) head_pixels: vec2f,
) -> Varyings {
    // x: along the segment, 0 at a, 1 at b. y: across it, -1..1
    var corners = array<vec2f, 6>(
        vec2f(0.0, -1.0), vec2f(1.0, -1.0), vec2f(1.0, 1.0),
        vec2f(0.0, -1.0), vec2f(1.0, 1.0), vec2f(0.0, 1.0));
    let corner = corners[vertex];

    let along  = direction(a, b);
    let across = vec2f(-along.y, along.x);
    let head   = head_pixels * view.pixel_density / view.zoom;

    // Distance the quad extends past the segment, in cells: the farthest the ground shader reads.
    // 2 cells (wash, wander) + 24 logical pixels (widest stroke) + the head
    let reach = 2.0 + 24.0 * view.pixel_density / view.zoom + head.x + head.y * 0.5;
    let p = mix(a - along * reach, b + along * reach, corner.x) + across * reach * corner.y;

    var out: Varyings;
    out.position = view_to_clip(view_to_pixel(p));
    out.p = p;
    out.a = a;
    out.b = b;
    out.head = head;
    return out;
}

// Signed distance from p to the triangle with its tip at tip, pointing away from tail. Negative inside.
// head: length, width
fn head_distance(p: vec2f, tail: vec2f, tip: vec2f, head: vec2f) -> f32 {
    let along = direction(tail, tip);
    // p with the tip at the origin: x across the head, folded to one side; y back along it
    let q    = vec2f(abs(dot(p - tip, vec2f(-along.y, along.x))), dot(tip - p, along));
    let size = vec2f(head.y * 0.5, head.x);
    // Nearest points on the slanted side and on the back, and which side of each q is on
    let side = q - size * clamp(dot(q, size) / dot(size, size), 0.0, 1.0);
    let back = q - size * vec2f(clamp(q.x / size.x, 0.0, 1.0), 1.0);
    let d    = min(vec2f(dot(side, side), q.y * size.x - q.x * size.y), vec2f(dot(back, back), size.y - q.y));
    return -sqrt(d.x) * sign(d.y);
}

@fragment
fn fs_main(in: Varyings) -> @location(0) vec4f {
    let ab = in.b - in.a;
    let t  = clamp(dot(in.p - in.a, ab) / max(dot(ab, ab), 1e-12), 0.0, 1.0);
    var d  = distance(in.p, in.a + ab * t);
    if in.head.x > 0.0 {
        d = min(d, head_distance(in.p, in.a, in.b, in.head));
    }
    return vec4f(d);
}
