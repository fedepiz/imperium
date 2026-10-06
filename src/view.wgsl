// Prepended to every shader.
// View transform, pass's space to window: pixel = (p - center) * zoom + size / 2

struct View {
    // Window size, physical pixels
    size:   vec2f,
    // Position at the window centre
    center: vec2f,
    // Physical pixels per unit
    zoom:   f32,
}

@group(0) @binding(0) var<uniform> view: View;

// Space position to physical pixels, origin top-left
fn view_to_pixel(p: vec2f) -> vec2f {
    return (p - view.center) * view.zoom + view.size * 0.5;
}

// Physical pixels to space position
fn view_from_pixel(pixel: vec2f) -> vec2f {
    return (pixel - view.size * 0.5) / view.zoom + view.center;
}

// Physical pixels to clip space
fn view_to_clip(pixel: vec2f) -> vec4f {
    return vec4f(pixel / view.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
}

