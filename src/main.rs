mod entities;
mod game;
mod layout;

use std::collections::HashMap;

use macroquad::prelude as mq;

use crate::layout::{self as ui, ElementId};

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
    let mut layout = ui::Engine::default();

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

    loop {
        mq::clear_background(mq::BLACK);

        let output = build_ui(&mut layout, &font, test_image, background);
        if !output.duplicate_ids().is_empty() {
            eprintln!("duplicate element ids: {:?}", output.duplicate_ids());
        }
        render_ui_commands(output.commands(), &font, &images);

        if mq::is_key_pressed(mq::KeyCode::Escape) {
            break;
        }

        if mq::is_mouse_button_pressed(mq::MouseButton::Left) && !output.is_pointer_over_ui() {
            println!("Clicked")
        }

        mq::next_frame().await;
    }
}

fn build_ui<'a>(
    engine: &'a mut layout::Engine,
    font: &mq::Font,
    image: Image,
    background: Image,
) -> layout::Output<'a> {
    let (mouse_x, mouse_y) = mq::mouse_position();
    let (wheel_x, wheel_y) = mq::mouse_wheel();

    let input = ui::Input {
        bounds: ui::Rectangle {
            x: 0.0,
            y: 0.0,
            w: mq::screen_width(),
            h: mq::screen_height(),
        },
        mouse_pos: ui::V2 {
            x: mouse_x,
            y: mouse_y,
        },
        mouse_pressed: mq::is_mouse_button_pressed(mq::MouseButton::Left),
        mouse_down: mq::is_mouse_button_down(mq::MouseButton::Left),
        mouse_released: mq::is_mouse_button_released(mq::MouseButton::Left),
        wheel: ui::V2 {
            x: wheel_x,
            y: wheel_y,
        },
    };
    let measure_text = |text: &str, _font: ui::FontId, size| {
        let measured = mq::measure_text(text, Some(font), size, 1.0);
        ui::TextMetrics {
            size: ui::V2 {
                x: measured.width,
                y: measured.height,
            },
            baseline: measured.offset_y,
        }
    };

    let panel = ui::Color::rgba(0.055, 0.067, 0.10, 1.0);
    let outline = ui::Color::rgba(0.25, 0.29, 0.40, 1.0);
    let ink = ui::Color::rgba(0.94, 0.95, 1.0, 1.0);
    let muted = ui::Color::rgba(0.57, 0.62, 0.74, 1.0);
    let violet = ui::Color::rgba(0.43, 0.32, 0.92, 1.0);
    let blue = ui::Color::rgba(0.16, 0.48, 0.87, 1.0);
    let cyan = ui::Color::rgba(0.08, 0.68, 0.72, 1.0);
    let orange = ui::Color::rgba(0.92, 0.43, 0.15, 1.0);

    engine.layout(input, measure_text, |ui| {
        ui.add_with(
            ui::ElementConf::default()
                .width(ui::LogicalSize::Grow)
                .height(ui::LogicalSize::Grow)
                .direction(ui::Direction::TopToBottom)
                .align_x(ui::Align::Center)
                .align_y(ui::Align::Center),
            |ui| {
                ui.add_with(
                    ui::ElementConf::default()
                        .id("layout-showcase")
                        .width(ui::LogicalSize::Parent(0.92))
                        .max_width(760.0)
                        .height(ui::LogicalSize::Fit)
                        .direction(ui::Direction::TopToBottom)
                        .align_x(ui::Align::Center)
                        .padding(ui::Padding::all(22.0))
                        .gap(12.0)
                        .background(panel)
                        .border(2.0, outline)
                        .corner_radius(18.0),
                    |ui| {
                        ui.add_with(
                            ui::ElementConf::default()
                                .floating(ui::Anchor::TopRight, ui::Anchor::Center)
                                .z_index(1)
                                .padding(ui::Padding::symmetric(10.0, 5.0))
                                .background(orange)
                                .corner_radius(8.0),
                            |ui| {
                                ui.add(ui::ElementConf::text(
                                    ui::TextConf::default().text("FLOATING").size(13).color(ink),
                                ));
                            },
                        );
                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("LAYOUT LAB")
                                .size(32)
                                .color(ink),
                        ));
                        ui.add(
                            ui::ElementConf::text(
                                ui::TextConf::default()
                                    .text("Resize to stress the constraints")
                                    .font(ui::FontId(0))
                                    .size(16)
                                    .color(muted)
                                    .wrap(true),
                            )
                            .width(ui::LogicalSize::Grow),
                        );

                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("WEIGHTED GROWTH  1 : 2")
                                .size(14)
                                .color(muted),
                        ));
                        ui.add_with(
                            ui::ElementConf::default()
                                .width(ui::LogicalSize::Grow)
                                .height(ui::LogicalSize::Pixels(54.0))
                                .gap(8.0),
                            |ui| {
                                ui.add_with(
                                    ui::ElementConf::default()
                                        .id("weight-one")
                                        .width(ui::LogicalSize::Grow)
                                        .min_width(70.0)
                                        .height(ui::LogicalSize::Grow)
                                        .direction(ui::Direction::TopToBottom)
                                        .align_x(ui::Align::Center)
                                        .align_y(ui::Align::Center)
                                        .background(violet)
                                        .corner_radius(10.0),
                                    |ui| {
                                        ui.add(ui::ElementConf::text(
                                            ui::TextConf::default().text("1x").size(20).color(ink),
                                        ));
                                        if ui.hovered("weight-one") {
                                            ui.add_with(
                                                ui::ElementConf::default()
                                                    .floating(
                                                        ui::Anchor::TopCenter,
                                                        ui::Anchor::BottomCenter,
                                                    )
                                                    .float_offset(0.0, -8.0)
                                                    .z_index(10)
                                                    .padding(ui::Padding::symmetric(10.0, 6.0))
                                                    .background(ui::Color::rgba(
                                                        0.02, 0.03, 0.05, 0.95,
                                                    ))
                                                    .border(1.0, outline)
                                                    .corner_radius(6.0),
                                                |ui| {
                                                    ui.add(ui::ElementConf::text(
                                                        ui::TextConf::default()
                                                            .text("Floating tooltip: 1 share")
                                                            .size(14)
                                                            .color(ink),
                                                    ));
                                                },
                                            );
                                        }
                                    },
                                );
                                ui.add_with(
                                    ui::ElementConf::default()
                                        .id("weight-two")
                                        .width(ui::LogicalSize::GrowWeighted(2.0))
                                        .min_width(100.0)
                                        .height(ui::LogicalSize::Grow)
                                        .direction(ui::Direction::TopToBottom)
                                        .align_x(ui::Align::Center)
                                        .align_y(ui::Align::Center)
                                        .background(blue)
                                        .corner_radius(10.0),
                                    |ui| {
                                        ui.add(ui::ElementConf::text(
                                            ui::TextConf::default().text("2x").size(20).color(ink),
                                        ));
                                    },
                                );
                            },
                        );

                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("MAX 180 PX + WEIGHTED REST")
                                .size(14)
                                .color(muted),
                        ));
                        ui.add_with(
                            ui::ElementConf::default()
                                .width(ui::LogicalSize::Grow)
                                .height(ui::LogicalSize::Pixels(54.0))
                                .gap(8.0),
                            |ui| {
                                if button(ui, "capped-text", "Capped text") {
                                    println!("Hey")
                                }

                                ui.add_with(
                                    ui::ElementConf::default()
                                        .id("growth-remainder")
                                        .width(ui::LogicalSize::GrowWeighted(2.0))
                                        .min_width(120.0)
                                        .height(ui::LogicalSize::Grow)
                                        .direction(ui::Direction::TopToBottom)
                                        .align_x(ui::Align::Center)
                                        .align_y(ui::Align::Center)
                                        .background(blue)
                                        .corner_radius(10.0),
                                    |ui| {
                                        ui.add(ui::ElementConf::text(
                                            ui::TextConf::default()
                                                .text("remainder")
                                                .size(18)
                                                .color(ink),
                                        ));
                                    },
                                );
                            },
                        );

                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("IMAGE: NATURAL, STRETCHED, TINTED, FADED")
                                .size(14)
                                .color(muted),
                        ));
                        ui.add_with(
                            ui::ElementConf::default()
                                .width(ui::LogicalSize::Grow)
                                .height(ui::LogicalSize::Fit)
                                .gap(8.0),
                            |ui| {
                                let source = ui::V2 {
                                    x: image.width,
                                    y: image.height,
                                };
                                ui.add(
                                    ui::ElementConf::default()
                                        .id("image-natural")
                                        .image(image.id, source),
                                );
                                ui.add(
                                    ui::ElementConf::default()
                                        .id("image-stretched")
                                        .image(image.id, source)
                                        .width(ui::LogicalSize::Pixels(96.0))
                                        .height(ui::LogicalSize::Pixels(48.0))
                                        .border(1.0, outline),
                                );
                                ui.add(
                                    ui::ElementConf::default()
                                        .id("image-tinted")
                                        .image(image.id, source)
                                        .image_tint(orange),
                                );
                                ui.add(
                                    ui::ElementConf::default()
                                        .id("image-faded")
                                        .image(image.id, source)
                                        .image_fade(0.5)
                                        .background(violet),
                                );
                            },
                        );

                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("SCROLL: WHEEL OVER THE LIST")
                                .size(14)
                                .color(muted),
                        ));
                        ui.add_with(
                            ui::ElementConf::default()
                                .id("scroll-list")
                                .width(ui::LogicalSize::Grow)
                                .height(ui::LogicalSize::Pixels(120.0))
                                .direction(ui::Direction::TopToBottom)
                                .scroll(false, true)
                                .padding(ui::Padding::all(8.0))
                                .gap(6.0)
                                .background(ui::Color::rgba(0.03, 0.04, 0.07, 1.0))
                                // Registered as ImageMode::Tile: repeats at
                                // its natural size instead of stretching.
                                .image(
                                    background.id,
                                    ui::V2 {
                                        x: background.width,
                                        y: background.height,
                                    },
                                )
                                .border(2.0, outline)
                                .corner_radius(10.0),
                            |ui| {
                                for index in 0..12u32 {
                                    let label = format!("Row {index:02}");
                                    ui.add_with(
                                        ui::ElementConf::default()
                                            .id(("scroll-row", index))
                                            .width(ui::LogicalSize::Grow)
                                            .height(ui::LogicalSize::Pixels(26.0))
                                            .padding(ui::Padding::symmetric(10.0, 0.0))
                                            .align_y(ui::Align::Center)
                                            .background(if index % 2 == 0 { violet } else { blue })
                                            .corner_radius(6.0),
                                        |ui| {
                                            ui.add(ui::ElementConf::text(
                                                ui::TextConf::default()
                                                    .text(&label)
                                                    .size(16)
                                                    .color(ink),
                                            ));
                                        },
                                    );
                                }
                            },
                        );

                        ui.add(ui::ElementConf::text(
                            ui::TextConf::default()
                                .text("OVERFLOW: 280 PX EACH")
                                .size(14)
                                .color(muted),
                        ));
                        ui.add_with(
                            ui::ElementConf::default()
                                .width(ui::LogicalSize::Grow)
                                .height(ui::LogicalSize::Pixels(54.0))
                                .gap(8.0),
                            |ui| {
                                for (id, label, color, minimum) in [
                                    ("compress-a", "min 80", orange, 80.0),
                                    ("compress-b", "min 60", violet, 60.0),
                                    ("compress-c", "min 60", cyan, 60.0),
                                ] {
                                    ui.add_with(
                                        ui::ElementConf::default()
                                            .id(id)
                                            .width(ui::LogicalSize::Pixels(280.0))
                                            .min_width(minimum)
                                            .height(ui::LogicalSize::Grow)
                                            .direction(ui::Direction::TopToBottom)
                                            .align_x(ui::Align::Center)
                                            .align_y(ui::Align::Center)
                                            .background(color)
                                            .border(2.0, outline)
                                            .corner_radius(10.0),
                                        |ui| {
                                            ui.add(ui::ElementConf::text(
                                                ui::TextConf::default()
                                                    .text(label)
                                                    .size(16)
                                                    .color(ink),
                                            ));
                                        },
                                    );
                                }
                            },
                        );
                    },
                );
            },
        );
    })
}

fn button(ui: &mut ui::Ui, id: impl Into<ElementId>, text: &str) -> bool {
    // Styling from last frame's sense: query
    // before declaring, like a button would.
    let id: ElementId = id.into();
    let sense = ui.sense(id);
    ui.add_with(
        ui::ElementConf::default()
            .id(id)
            .width(ui::LogicalSize::Grow)
            .max_width(180.0)
            .height(ui::LogicalSize::Grow)
            .direction(ui::Direction::TopToBottom)
            .align_x(ui::Align::Center)
            .align_y(ui::Align::Center)
            .background(if sense.hovered {
                ui::Color::rgba(0.16, 0.86, 0.90, 1.0)
            } else {
                ui::Color::rgba(0.08, 0.68, 0.72, 1.0)
            })
            .corner_radius(10.0),
        |ui| {
            let ink = ui::Color::rgba(0.94, 0.95, 1.0, 1.0);
            ui.add(ui::ElementConf::text(
                ui::TextConf::default().text(text).size(18).color(ink),
            ));
        },
    );
    sense.clicked
}
fn render_ui_commands(commands: &[layout::DrawCommand], font: &mq::Font, images: &ImageMap) {
    let mut clip_stack: Vec<ui::Rectangle> = Vec::new();
    for command in commands {
        let color = mq::Color::new(
            command.color.r,
            command.color.g,
            command.color.b,
            command.color.a,
        );
        match command.kind {
            ui::DrawKind::Rectangle => {
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
            ui::DrawKind::Text => {
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
            ui::DrawKind::Border => {
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
            ui::DrawKind::Image => {
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
            ui::DrawKind::ClipStart => {
                let clip = clip_stack
                    .last()
                    .map_or(command.bounds, |top| top.intersect(command.bounds));
                clip_stack.push(clip);
                apply_scissor(Some(clip));
            }
            ui::DrawKind::ClipEnd => {
                clip_stack.pop();
                apply_scissor(clip_stack.last().copied());
            }
            ui::DrawKind::None => {}
        }
    }
}

/// Repeats the texture at its natural size from the top-left of `bounds`;
/// edge tiles draw a partial source rect, so the pattern crops cleanly
/// without touching the scissor state.
fn draw_texture_tiled(entry: &ImageEntry, bounds: ui::Rectangle, color: mq::Color) {
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

fn apply_scissor(clip: Option<ui::Rectangle>) {
    // Macroquad batches draw calls per clip state and converts to GL's
    // bottom-left origin itself, so top-left coordinates pass through.
    unsafe { mq::get_internal_gl() }
        .quad_gl
        .scissor(clip.map(|clip| (clip.x as i32, clip.y as i32, clip.w as i32, clip.h as i32)));
}

const CORNER_SEGMENTS: usize = 8;
const ROUNDED_RECTANGLE_POINTS: usize = 4 * (CORNER_SEGMENTS + 1);

fn rounded_rectangle_points(
    bounds: ui::Rectangle,
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

fn draw_rounded_rectangle(bounds: ui::Rectangle, radius: f32, color: mq::Color) {
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

fn draw_rounded_rectangle_lines(bounds: ui::Rectangle, radius: f32, width: f32, color: mq::Color) {
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
