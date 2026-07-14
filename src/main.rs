mod date;
mod defs;
mod game;
mod world;

use std::collections::HashMap;

use arena::Arena;
use macroquad::prelude as mq;
use ui::{ir, layout, run, style};

fn main() {
    let conf = mq::Conf {
        window_title: "Imperium".to_string(),
        window_width: 1600,
        window_height: 900,
        high_dpi: true,
        ..Default::default()
    };
    macroquad::Window::from_config(conf, amain());
}

/// The external half of time: converts real seconds into `AdvanceTime`
/// requests at a steady cadence. It pumps blindly — whether a request is
/// honored is the sim's business (it declines while the player is idle),
/// and the accumulator drains either way, so declined stretches and frame
/// hitches never burst into a backlog of days.
struct Clock {
    /// Real seconds per requested day, before `speed`.
    seconds_per_day: f32,
    /// dt multiplier in whole levels 0..=5; level 0 stops time on its own.
    speed: f32,
    /// Explicit pause toggle, independent of speed: unpausing resumes at
    /// whatever level the clock was left on.
    paused: bool,
    accumulator: f32,
}

impl Default for Clock {
    fn default() -> Self {
        Clock {
            seconds_per_day: 0.15,
            speed: 1.0,
            paused: false,
            accumulator: 0.0,
        }
    }
}

impl Clock {
    fn is_paused(&self) -> bool {
        self.paused || self.speed == 0.0
    }

    /// Applies the command's clock fields.
    fn apply(&mut self, command: &AppCommand) {
        if command.set_speed != 0 {
            self.speed = (command.set_speed as f32).clamp(0.0, 5.0);
        }
        self.paused ^= command.toggle_pause;
    }

    /// Feed one frame's dt; returns how many days to request this frame
    /// (at most one — the cap that keeps hitches from bursting).
    fn due_days(&mut self, dt: f32) -> u32 {
        if self.is_paused() {
            return 0;
        }
        self.accumulator = (self.accumulator + dt * self.speed).min(self.seconds_per_day);
        if self.accumulator >= self.seconds_per_day {
            self.accumulator = 0.0;
            1
        } else {
            0
        }
    }
}

/// One frame's worth of app-level intent: a superset of fields with
/// meaningful zeros — set_speed 0 = no change, toggle_pause false = leave
/// pause alone, game Idle = nothing for the sim — so `default()` is the
/// do-nothing command. Keys, UI buttons, or anything else produce these;
/// each consumer applies its own fields unconditionally. The clock fields
/// stay in the harness and never enter the sim's history.
#[derive(Clone, Copy, Default)]
struct AppCommand {
    /// Speed level to set, 1..=5; 0 = leave the speed alone.
    set_speed: i32,
    toggle_pause: bool,
    /// The sim's share of the command.
    game: game::Command,
}

impl AppCommand {
    fn parse(action: &str) -> AppCommand {
        if let Some(level) = action.strip_prefix("time_speed ") {
            return AppCommand {
                set_speed: level.trim().parse().unwrap_or(0),
                ..AppCommand::default()
            };
        }
        match action {
            "time_toggle" => AppCommand {
                toggle_pause: true,
                ..AppCommand::default()
            },
            _ => AppCommand {
                game: game::Command::parse(action),
                ..AppCommand::default()
            },
        }
    }
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

    // The module is a plain owned value: reload = recompile and reassign.
    // The style is a compile input, so a style edit reloads the same way.
    let mut ui_module = load_ui_module();

    let mut game = game::Game::new();
    let mut clock = Clock::default();
    // Last tick's report, carried across the frame boundary: input at the
    // top of a frame reacts to what the sim said last.
    let mut game_output = game::Output::default();

    loop {
        if mq::is_key_pressed(mq::KeyCode::R) {
            ui_module = load_ui_module();
        }

        // The sim ticks every frame — Idle when nothing happened — and
        // once more per command; it never renders, rendering never mutates.
        // Real time never enters the sim: the clock converts it into
        // AdvanceTime requests, which the game is free to decline.
        let mut command = AppCommand::default();
        // While the sim force-pauses, the pause controls are locked: the
        // key mirrors the disabled button.
        if mq::is_key_pressed(mq::KeyCode::Space) && !game_output.forced_paused {
            command.toggle_pause = true;
        }
        clock.apply(&command);
        game_output = game.tick(command.game);
        for _ in 0..clock.due_days(mq::get_frame_time()) {
            game_output = game.tick(game::Command::ADVANCE_TIME);
        }

        mq::clear_background(mq::BLACK);
        frame_arena.reset();

        let mut ui_data = ir::UiData::default();
        game.fill_ui_data(&mut ui_data);
        // The external clock's own UI state; the sim knows nothing of it.
        // Pause is the union of both halves: the clock's (speed 0 or the
        // explicit toggle) and the sim's (force-paused while the player
        // idles). Force-pause also locks the button.
        ui_data.bind_global(
            "TIME_BUTTON",
            if clock.is_paused() || game_output.forced_paused {
                "Paused"
            } else {
                "Playing"
            },
        );
        ui_data.bind_global(
            "TIME_ENABLED",
            if game_output.forced_paused {
                "no"
            } else {
                "yes"
            },
        );
        // Speed buttons: the current level is the one you can't press;
        // any kind of pause locks them all.
        for level in 1..=4 {
            ui_data.bind_global(
                &format!("SPEED_{level}"),
                if clock.speed == level as f32 {
                    "no"
                } else {
                    "yes"
                },
            );
        }
        ui_data.add_image(
            "soldier",
            test_image.id,
            test_image.width,
            test_image.height,
        );
        ui_data.add_image("widget", background.id, background.width, background.height);

        let (output, events) = build_ui(&mut layout, &font, &ui_module, &ui_data, &frame_arena);
        if !output.duplicate_ids().is_empty() {
            eprintln!("duplicate element ids: {:?}", output.duplicate_ids());
        }
        render_ui_commands(output, &font, &images);

        for action in events {
            // Every action becomes one AppCommand; the clock and the sim
            // each take their share, no routing.
            let command = AppCommand::parse(&action);
            clock.apply(&command);
            game_output = game.tick(command.game);
        }

        if mq::is_key_pressed(mq::KeyCode::Escape) {
            return;
        }

        if mq::is_mouse_button_pressed(mq::MouseButton::Left) && !output.is_pointer_over_ui() {
            println!("Clicked")
        }

        mq::next_frame().await;
    }
}

fn load_ui_module() -> ir::UiModule {
    let style = load_style();
    let source = std::fs::read_to_string("ui_example.txt").unwrap_or_default();
    let module = ir::compile(&source, &style);
    for error in &module.errors {
        eprintln!("ui_example.txt: {error}");
    }
    for warning in &module.warnings {
        eprintln!("ui_example.txt: {warning}");
    }
    module
}

fn load_style() -> style::Style {
    // Scratch arena for the parse warnings; they are printed and die here.
    let arena = Arena::new();
    let source = std::fs::read_to_string("data/style.txt").unwrap_or_default();
    let parsed = style::parse(&arena, &source);
    for warning in parsed.warnings {
        eprintln!("data/style.txt: {warning}");
    }
    parsed.style
}

fn build_ui<'a>(
    engine: &'a mut layout::Engine,
    font: &mq::Font,
    module: &ir::UiModule,
    data: &ir::UiData,
    frame: &Arena,
) -> (&'a layout::Output, Vec<String>) {
    let (mouse_x, mouse_y) = mq::mouse_position();
    let (wheel_x, wheel_y) = mq::mouse_wheel();

    // The UI works in logical points; only input and rendering know about
    // the physical framebuffer.
    let dpi = mq::screen_dpi_scale();
    let input = layout::Input {
        bounds: layout::Rectangle {
            x: 0.0,
            y: 0.0,
            w: mq::screen_width() / dpi,
            h: mq::screen_height() / dpi,
        },
        mouse_pos: layout::V2 {
            x: mouse_x / dpi,
            y: mouse_y / dpi,
        },
        mouse_pressed: mq::is_mouse_button_pressed(mq::MouseButton::Left),
        wheel: layout::V2 {
            x: wheel_x / dpi,
            y: wheel_y / dpi,
        },
    };
    // Rasterize glyphs at physical resolution, report logical metrics.
    // Raw ink extents only: the layout engine's text cache replaces height
    // and baseline with per-size line metrics from its probe.
    let measure_text = |text: &str, size: u16| {
        let physical = physical_font_size(size, dpi);
        let measured = mq::measure_text(text, Some(font), physical, 1.0 / dpi);
        layout::TextMetrics {
            size: layout::V2 {
                x: measured.width,
                y: measured.height,
            },
            baseline: measured.offset_y,
        }
    };

    let mut events = Vec::new();
    let output = engine.layout(input, measure_text, |ui| {
        events = run::run(module, data, frame, ui);
    });
    (output, events)
}

/// Rounded so glyphs rasterize on whole pixels; `u16` mirrors macroquad.
fn physical_font_size(size: u16, dpi: f32) -> u16 {
    (size as f32 * dpi).round() as u16
}

fn render_ui_commands(output: &layout::Output, font: &mq::Font, images: &ImageMap) {
    // Draw commands are in logical points: scale everything up to physical
    // pixels here, except glyphs, which are rasterized at physical size and
    // drawn at 1/dpi so they stay pixel-exact.
    let dpi = mq::screen_dpi_scale();
    unsafe { mq::get_internal_gl() }
        .quad_gl
        .push_model_matrix(mq::Mat4::from_scale(mq::vec3(dpi, dpi, 1.0)));
    let mut clip_stack: Vec<layout::Rectangle> = Vec::new();
    for command in output.commands() {
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
                // Snap the origin to a whole physical pixel; a fractional
                // start smears every glyph across two pixel rows/columns.
                let snap = |value: f32| (value * dpi).round() / dpi;
                mq::draw_text_ex(
                    output.text(command.text),
                    snap(command.bounds.x),
                    snap(command.bounds.y + command.text_baseline),
                    mq::TextParams {
                        font: Some(font),
                        font_size: physical_font_size(command.text_size, dpi),
                        font_scale: 1.0 / dpi,
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
                apply_scissor(Some(clip), dpi);
            }
            layout::DrawKind::ClipEnd => {
                clip_stack.pop();
                apply_scissor(clip_stack.last().copied(), dpi);
            }
            layout::DrawKind::None => {}
        }
    }
    unsafe { mq::get_internal_gl() }.quad_gl.pop_model_matrix();
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

fn apply_scissor(clip: Option<layout::Rectangle>, dpi: f32) {
    // Macroquad batches draw calls per clip state and converts to GL's
    // bottom-left origin itself, so top-left coordinates pass through. The
    // scissor bypasses the model matrix, so scale to physical pixels here.
    unsafe { mq::get_internal_gl() }
        .quad_gl
        .scissor(clip.map(|clip| {
            (
                (clip.x * dpi) as i32,
                (clip.y * dpi) as i32,
                (clip.w * dpi) as i32,
                (clip.h * dpi) as i32,
            )
        }));
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

/// A watertight ring of triangles between the outline and a copy inset by
/// `width`. Per-segment thick lines overlap at every joint and gap around
/// the corners, which shimmers; corresponding points of two concentric
/// outlines tile exactly.
fn draw_rounded_rectangle_lines(
    bounds: layout::Rectangle,
    radius: f32,
    width: f32,
    color: mq::Color,
) {
    let width = width.min(bounds.w * 0.5).min(bounds.h * 0.5);
    let inset = layout::Rectangle {
        x: bounds.x + width,
        y: bounds.y + width,
        w: bounds.w - 2.0 * width,
        h: bounds.h - 2.0 * width,
    };
    let outer = rounded_rectangle_points(bounds, radius);
    let inner = rounded_rectangle_points(inset, (radius - width).max(0.0));
    for index in 0..outer.len() {
        let next = (index + 1) % outer.len();
        mq::draw_triangle(outer[index], inner[index], outer[next], color);
        mq::draw_triangle(outer[next], inner[index], inner[next], color);
    }
}
