mod entities;
mod game;

use std::collections::HashMap;

use arena::{AVec, Arena};
use macroquad::prelude as mq;
use ui::{ir, layout, run};

fn main() {
    macroquad::Window::new("Imperium", amain());
}

/// How the renderer fills an element's bounds with a texture. A property of
/// the registered image, opaque to the layout engine.
#[derive(Clone, Copy, Default)]
enum ImageMode {
    #[default]
    Stretch,
    Tile,
}

struct ImageEntry {
    texture: mq::Texture2D,
    mode: ImageMode,
}

#[derive(Default)]
struct ImageMap {
    last: u64,
    inner: HashMap<layout::ImageId, ImageEntry>,
}

#[derive(Clone, Copy, Default)]
struct Image {
    id: layout::ImageId,
    width: f32,
    height: f32,
}

impl ImageMap {
    pub fn insert(&mut self, texture: mq::Texture2D) -> Image {
        self.insert_with(texture, ImageMode::Stretch)
    }

    pub fn insert_with(&mut self, texture: mq::Texture2D, mode: ImageMode) -> Image {
        // Pre-increment, so 0 is dummy
        self.last = self.last.saturating_add(1);
        let id = layout::ImageId(self.last);
        let image = Image {
            id,
            width: texture.width(),
            height: texture.height(),
        };
        self.inner.insert(image.id, ImageEntry { texture, mode });
        image
    }

    pub fn get(&self, id: layout::ImageId) -> Option<&ImageEntry> {
        self.inner.get(&id)
    }
}

async fn amain() {
    let mut layout = layout::Engine::default();

    let mut font = mq::load_ttf_font("assets/fonts/default.ttf").await.unwrap();
    font.set_filter(mq::FilterMode::Linear);

    let mut images = ImageMap::default();
    let test_image = {
        let image = mq::load_texture("assets/images/pawns/soldier.png")
            .await
            .unwrap();
        images.insert(image)
    };
    let background = {
        let image = mq::load_texture("assets/widget.png").await.unwrap();
        images.insert_with(image, ImageMode::Tile)
    };

    let mut frame_arena = Arena::new();

    // The whole script-UI module is one unit: reload = drop its arena and
    // compile again.
    'reload: loop {
        let module_arena = Arena::new();
        let source = std::fs::read_to_string("ui_example.txt").unwrap_or_default();
        let module = ir::compile(&module_arena, &source);
        for error in module.errors {
            eprintln!("ui_example.txt: {error}");
        }
        for warning in module.warnings {
            eprintln!("ui_example.txt: {warning}");
        }

        loop {
            mq::clear_background(mq::BLACK);
            frame_arena.reset();
            let data = demo_ui_data(&frame_arena, test_image, background);

            let (output, events) = build_ui(&mut layout, &font, &module, data, &frame_arena);
            if !output.duplicate_ids().is_empty() {
                eprintln!("duplicate element ids: {:?}", output.duplicate_ids());
            }
            render_ui_commands(output.commands(), &font, &images);

            for action in events {
                println!("ui action: {action}");
            }

            if mq::is_key_pressed(mq::KeyCode::Escape) {
                return;
            }
            if mq::is_key_pressed(mq::KeyCode::R) {
                mq::next_frame().await;
                continue 'reload;
            }

            if mq::is_mouse_button_pressed(mq::MouseButton::Left) && !output.is_pointer_over_ui() {
                println!("Clicked")
            }

            mq::next_frame().await;
        }
    }
}

/// Demo rows and image bindings for the script UI, built fresh into the
/// frame arena. Stands in for whatever the game will fetch for real.
fn demo_ui_data<'a>(arena: &'a Arena, soldier: Image, widget: Image) -> ir::UiData<'a> {
    const ROWS: usize = 12;
    let mut rows = AVec::with_capacity_in(ROWS, arena);
    for index in 0..ROWS {
        let bindings = arena.alloc_slice_copy(&[ir::Binding {
            key: "LABEL",
            value: arena.alloc_str(&format!("Row {index:02}")),
        }]);
        rows.push(ir::Row { bindings });
    }
    let image = |key, image: Image| ir::ImageData {
        key,
        image: image.id,
        width: image.width,
        height: image.height,
    };
    ir::UiData {
        lists: arena.alloc_slice_copy(&[ir::ListData {
            id: "demo_rows",
            rows: rows.into_slice(),
        }]),
        images: arena.alloc_slice_copy(&[image("soldier", soldier), image("widget", widget)]),
    }
}

fn build_ui<'a, 'f>(
    engine: &'a mut layout::Engine,
    font: &mq::Font,
    module: &ir::UiModule<'_>,
    data: ir::UiData<'f>,
    frame: &'f Arena,
) -> (layout::Output<'a>, &'f [&'f str]) {
    let (mouse_x, mouse_y) = mq::mouse_position();
    let (wheel_x, wheel_y) = mq::mouse_wheel();

    let input = layout::Input {
        bounds: layout::Rectangle {
            x: 0.0,
            y: 0.0,
            w: mq::screen_width(),
            h: mq::screen_height(),
        },
        mouse_pos: layout::V2 {
            x: mouse_x,
            y: mouse_y,
        },
        mouse_pressed: mq::is_mouse_button_pressed(mq::MouseButton::Left),
        mouse_down: mq::is_mouse_button_down(mq::MouseButton::Left),
        mouse_released: mq::is_mouse_button_released(mq::MouseButton::Left),
        wheel: layout::V2 {
            x: wheel_x,
            y: wheel_y,
        },
    };
    let measure_text = |text: &str, _font: layout::FontId, size| {
        let measured = mq::measure_text(text, Some(font), size, 1.0);
        layout::TextMetrics {
            size: layout::V2 {
                x: measured.width,
                y: measured.height,
            },
            baseline: measured.offset_y,
        }
    };

    let mut events: &'f [&'f str] = &[];
    let output = engine.layout(input, measure_text, |ui| {
        events = run::run(module, data, frame, ui);
    });
    (output, events)
}

fn render_ui_commands(commands: &[layout::DrawCommand], font: &mq::Font, images: &ImageMap) {
    let mut clip_stack: Vec<layout::Rectangle> = Vec::new();
    for command in commands {
        let color = mq::Color::new(
            command.color.r,
            command.color.g,
            command.color.b,
            command.color.a,
        );
        match command.kind {
            layout::DrawKind::Rectangle => {
                if command.corner_radius > 0.0 {
                    draw_rounded_rectangle(command.bounds, command.corner_radius, color);
                } else {
                    mq::draw_rectangle(
                        command.bounds.x,
                        command.bounds.y,
                        command.bounds.w,
                        command.bounds.h,
                        color,
                    );
                }
            }
            layout::DrawKind::Text => {
                mq::draw_text_ex(
                    command.text.text,
                    command.bounds.x,
                    command.bounds.y + command.text_baseline,
                    mq::TextParams {
                        font: Some(font),
                        font_size: command.text.size,
                        color,
                        ..Default::default()
                    },
                );
            }
            layout::DrawKind::Border => {
                if command.corner_radius > 0.0 {
                    draw_rounded_rectangle_lines(
                        command.bounds,
                        command.corner_radius,
                        command.border_width,
                        color,
                    );
                } else {
                    mq::draw_rectangle_lines(
                        command.bounds.x,
                        command.bounds.y,
                        command.bounds.w,
                        command.bounds.h,
                        command.border_width,
                        color,
                    );
                }
            }
            layout::DrawKind::Image => {
                if let Some(entry) = images.get(command.image) {
                    match entry.mode {
                        ImageMode::Stretch => {
                            mq::draw_texture_ex(
                                &entry.texture,
                                command.bounds.x,
                                command.bounds.y,
                                color,
                                mq::DrawTextureParams {
                                    dest_size: Some(mq::vec2(command.bounds.w, command.bounds.h)),
                                    ..Default::default()
                                },
                            );
                        }
                        ImageMode::Tile => draw_texture_tiled(entry, command.bounds, color),
                    }
                }
            }
            layout::DrawKind::ClipStart => {
                let clip = clip_stack
                    .last()
                    .map_or(command.bounds, |top| top.intersect(command.bounds));
                clip_stack.push(clip);
                apply_scissor(Some(clip));
            }
            layout::DrawKind::ClipEnd => {
                clip_stack.pop();
                apply_scissor(clip_stack.last().copied());
            }
            layout::DrawKind::None => {}
        }
    }
}

/// Repeats the texture at its natural size from the top-left of `bounds`;
/// edge tiles draw a partial source rect, so the pattern crops cleanly
/// without touching the scissor state.
fn draw_texture_tiled(entry: &ImageEntry, bounds: layout::Rectangle, color: mq::Color) {
    let tile_w = entry.texture.width();
    let tile_h = entry.texture.height();
    if tile_w <= 0.0 || tile_h <= 0.0 {
        return;
    }
    let mut y = 0.0;
    while y < bounds.h {
        let h = (bounds.h - y).min(tile_h);
        let mut x = 0.0;
        while x < bounds.w {
            let w = (bounds.w - x).min(tile_w);
            mq::draw_texture_ex(
                &entry.texture,
                bounds.x + x,
                bounds.y + y,
                color,
                mq::DrawTextureParams {
                    dest_size: Some(mq::vec2(w, h)),
                    source: Some(mq::Rect::new(0.0, 0.0, w, h)),
                    ..Default::default()
                },
            );
            x += tile_w;
        }
        y += tile_h;
    }
}

fn apply_scissor(clip: Option<layout::Rectangle>) {
    // Macroquad batches draw calls per clip state and converts to GL's
    // bottom-left origin itself, so top-left coordinates pass through.
    unsafe { mq::get_internal_gl() }
        .quad_gl
        .scissor(clip.map(|clip| (clip.x as i32, clip.y as i32, clip.w as i32, clip.h as i32)));
}

const CORNER_SEGMENTS: usize = 8;
const ROUNDED_RECTANGLE_POINTS: usize = 4 * (CORNER_SEGMENTS + 1);

fn rounded_rectangle_points(
    bounds: layout::Rectangle,
    radius: f32,
) -> [mq::Vec2; ROUNDED_RECTANGLE_POINTS] {
    let radius = radius.min(bounds.w * 0.5).min(bounds.h * 0.5);
    let centers = [
        mq::vec2(bounds.x + bounds.w - radius, bounds.y + radius),
        mq::vec2(bounds.x + bounds.w - radius, bounds.y + bounds.h - radius),
        mq::vec2(bounds.x + radius, bounds.y + bounds.h - radius),
        mq::vec2(bounds.x + radius, bounds.y + radius),
    ];
    let mut points = [mq::Vec2::ZERO; ROUNDED_RECTANGLE_POINTS];
    let quarter_turn = std::f32::consts::FRAC_PI_2;
    for (corner, center) in centers.into_iter().enumerate() {
        for step in 0..=CORNER_SEGMENTS {
            let angle = -quarter_turn
                + corner as f32 * quarter_turn
                + step as f32 * quarter_turn / CORNER_SEGMENTS as f32;
            points[corner * (CORNER_SEGMENTS + 1) + step] =
                center + mq::vec2(angle.cos(), angle.sin()) * radius;
        }
    }
    points
}

fn draw_rounded_rectangle(bounds: layout::Rectangle, radius: f32, color: mq::Color) {
    let points = rounded_rectangle_points(bounds, radius);
    let center = mq::vec2(bounds.x + bounds.w * 0.5, bounds.y + bounds.h * 0.5);
    for index in 0..points.len() {
        mq::draw_triangle(
            center,
            points[index],
            points[(index + 1) % points.len()],
            color,
        );
    }
}

fn draw_rounded_rectangle_lines(bounds: layout::Rectangle, radius: f32, width: f32, color: mq::Color) {
    let points = rounded_rectangle_points(bounds, radius);
    for index in 0..points.len() {
        mq::draw_line(
            points[index].x,
            points[index].y,
            points[(index + 1) % points.len()].x,
            points[(index + 1) % points.len()].y,
            width,
            color,
        );
    }
}
