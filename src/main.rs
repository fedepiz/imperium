use std::collections::HashMap;

use arena::Arena;
use macroquad::prelude as mq;
use ui::{ir, layout, run, style};

fn main() {
    let (window, conf) = load_conf();
    macroquad::Window::from_config(window, amain(conf));
}

/// The launch knobs that outlive window creation and configure the app
/// itself, conf.txt's other half (the window half is `mq::Conf`).
#[derive(Clone, Copy)]
struct AppConf {
    /// Side of one map cell on screen, in world points.
    map_tile_size: f32,
}

/// Launch knobs from `data/conf.txt` — the settings that must be known
/// before the window exists (backend, vsync, resolution) plus the app's
/// own ([`AppConf`]), tabula like all data. In the usual style, nothing
/// here can fail: a missing file or key means the default below, junk
/// warns and the default stands.
fn load_conf() -> (mq::Conf, AppConf) {
    use macroquad::miniquad::conf::{AppleGfxApi, Platform};

    // Scratch arena for the parse; the tree dies with this function.
    let arena = Arena::new();
    let path = "data/conf.txt";
    let source = std::fs::read_to_string(path).unwrap_or_default();
    let parsed = tabula::parse(&arena, &source);
    for error in parsed.errors {
        eprintln!("{path}: {error}");
    }
    // A synthetic block over the file's roots, so the node accessors
    // apply to the top level too.
    let root = tabula::Node {
        children: parsed.roots,
        ..Default::default()
    };

    // On macOS the opengl backend leaves vsync off by design (it paces
    // frames with CVDisplayLink, which doesn't stop mid-scan swaps —
    // visible tearing); metal presents display-synced. Kept switchable
    // in data in case Metal misbehaves somewhere.
    let apple_gfx_api = match root.get_text("apple_api") {
        Some("metal") | None => AppleGfxApi::Metal,
        Some("opengl") => AppleGfxApi::OpenGl,
        Some(other) => {
            eprintln!("{path}: unknown apple_api '{other}', using metal");
            AppleGfxApi::Metal
        }
    };

    // The GL platforms' vsync hint (Windows/Linux); macOS ignores it.
    let swap_interval = match root.get_text("vsync") {
        Some("yes") | None => 1,
        Some("no") => 0,
        Some(other) => {
            eprintln!("{path}: unknown vsync '{other}', using yes");
            1
        }
    };

    // resolution = { width height }, in points.
    let mut resolution = (1600, 900);
    if let Some(node) = root.get("resolution") {
        match node.children {
            [w, h] if w.value.is_number && h.value.is_number => {
                resolution = (w.value.number as i32, h.value.number as i32);
            }
            _ => eprintln!("{path}: resolution wants two numbers, using {resolution:?}"),
        }
    }

    // Zero or negative would collapse or mirror the board.
    let map_tile_size = match root.get_number("map_tile_size") {
        Some(size) if size > 0.0 => size,
        None => 48.0,
        Some(bad) => {
            eprintln!("{path}: map_tile_size {bad} is not positive, using 48");
            48.0
        }
    };

    let window = mq::Conf {
        window_title: "Imperium".to_string(),
        window_width: resolution.0,
        window_height: resolution.1,
        high_dpi: true,
        platform: Platform {
            apple_gfx_api,
            swap_interval: Some(swap_interval),
            ..Default::default()
        },
        ..Default::default()
    };
    (window, AppConf { map_tile_size })
}

/// The external half of time: converts real seconds into `AdvanceTime`
/// requests at a steady cadence. It pumps blindly — whether a request is
/// honored is the sim's business (it declines while the player is idle),
/// and the accumulator drains either way, so declined stretches and frame
/// hitches never burst into a backlog of days.
struct Clock {
    /// Real seconds per requested day, before `speed`.
    seconds_per_day: f32,
    /// dt multiplier in whole levels 0..=MAX_SPEED; level 0 stops time on its own.
    speed: i32,
    /// Explicit pause toggle, independent of speed: unpausing resumes at
    /// whatever level the clock was left on.
    paused: bool,
    accumulator: f32,
}

impl Default for Clock {
    fn default() -> Self {
        Clock {
            seconds_per_day: 0.15,
            speed: 1,
            paused: false,
            accumulator: 0.0,
        }
    }
}

impl Clock {
    pub const MAX_SPEED: i32 = 5;

    fn is_paused(&self) -> bool {
        self.paused || self.speed == 0
    }

    /// Applies the command's clock fields.
    fn apply(&mut self, command: &AppCommand) {
        if command.set_speed != 0 {
            self.speed = command.set_speed.clamp(0, Self::MAX_SPEED);
        }
        self.paused ^= command.toggle_pause;
    }

    /// Feed one frame's dt; returns how many days to request this frame
    /// (at most one — the cap that keeps hitches from bursting).
    fn due_days(&mut self, dt: f32) -> u32 {
        if self.is_paused() {
            return 0;
        }
        self.accumulator = (self.accumulator + dt * self.speed as f32).min(self.seconds_per_day);
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
    /// Speed level to set, 1..=MAX_SPEED; 0 = leave the speed alone.
    set_speed: i32,
    toggle_pause: bool,
    /// Map pan intent, ±1 per axis; zero = leave the camera alone.
    pan: mq::Vec2,
    /// The sim's share of the command.
    game: game::Command,
}

/// The keyboard's share of the frame's intent, layered onto a command
/// that other sources (UI actions, say) may also have filled: keys only
/// populate fields here; each consumer interprets its own share.
fn gather_keyboard(command: &mut AppCommand, forced_paused: bool) {
    // While the sim force-pauses, the pause controls are locked: the key
    // mirrors the disabled button.
    if mq::is_key_pressed(mq::KeyCode::Space) && !forced_paused {
        command.toggle_pause = true;
    }
    if mq::is_key_down(mq::KeyCode::W) {
        command.pan.y += 1.0;
    }
    if mq::is_key_down(mq::KeyCode::S) {
        command.pan.y -= 1.0;
    }
    if mq::is_key_down(mq::KeyCode::A) {
        command.pan.x -= 1.0;
    }
    if mq::is_key_down(mq::KeyCode::D) {
        command.pan.x += 1.0;
    }
    if mq::is_key_down(mq::KeyCode::LeftShift) {
        command.game.wait = true;
    }
}

impl AppCommand {
    /// Folds one UI action into the frame's command, the actions' twin of
    /// `gather_keyboard`: every source writes into the same singular
    /// command, built fresh each frame from `default()`. The sim's share
    /// is fat and ZII like this one, so actions merge by each setting
    /// their own fields.
    fn parse(&mut self, action: &str) {
        if let Some(level) = action.strip_prefix("time_speed ") {
            self.set_speed = level.trim().parse().unwrap_or(0);
            return;
        }
        match action {
            "time_toggle" => self.toggle_pause = true,
            _ => self.game.parse(action),
        }
    }
}

/// The map layer's viewport: a pan position driven by WASD, in logical
/// points, wrapped around the real `mq::Camera2D` both directions go
/// through — drawing (`set_camera`) and picking (`screen_to_world`) use
/// the same lens, so they can't disagree. Velocity chases the keys'
/// intent through exponential smoothing, so panning eases in and out
/// instead of snapping.
#[derive(Default)]
struct MapCamera {
    camera: mq::Camera2D,
    pos: mq::Vec2,
    velocity: mq::Vec2,
    /// Side of one map cell in world points, from conf.txt. Board
    /// geometry lives on the lens so drawing and picking share it.
    tile_size: f32,
}

impl MapCamera {
    /// Full pan speed, logical points per second.
    const PAN_SPEED: f32 = 700.0;
    /// Smoothing rate: higher = snappier. ~1/RATE seconds to mostly catch up.
    const RATE: f32 = 10.0;

    /// Integrate one frame: the command's pan intent is the target
    /// direction; this never reads input devices itself. Also refits the
    /// lens to the current window: a view logical-points wide, y flipped
    /// to run down, top-left at `pos`.
    fn update(&mut self, command: &AppCommand, dt: f32) {
        let target = command.pan.normalize_or_zero() * Self::PAN_SPEED;
        // Frame-rate independent lerp toward the target velocity.
        let blend = 1.0 - (-dt * Self::RATE).exp();
        self.velocity += (target - self.velocity) * blend;
        self.pos += self.velocity * dt;

        let dpi = mq::screen_dpi_scale();
        let logical = mq::vec2(mq::screen_width(), mq::screen_height()) / dpi;
        self.camera.target = self.pos + logical * 0.5;
        self.camera.zoom = mq::vec2(2.0 / logical.x, -2.0 / logical.y);
    }

    /// The cell under a screen point (`mouse_position()` units), through
    /// the same lens the map is drawn with. The negative quadrant — which
    /// u32 can't say — reads as the zero cell, "nowhere"; anything beyond
    /// the grid is the void to `Map::cell` anyway.
    fn pick_cell(&self, point: mq::Vec2) -> game::CellPos {
        let world = self.camera.screen_to_world(point);
        let cell = (world - mq::vec2(MARGIN, MARGIN)) / self.tile_size;
        if cell.x < 0.0 || cell.y < 0.0 {
            return game::CellPos::default();
        }
        game::CellPos {
            x: cell.x as u32,
            y: cell.y as u32,
        }
    }
}

/// Where the map's top-left sits with the camera at rest, world points.
/// The tile size half of the board's geometry is `MapCamera::tile_size`.
const MARGIN: f32 = 48.0;

/// Rasterize the sim's map render-model, under the UI: plain rectangles
/// and dots, every decision (colors, what has a dot) already made by the
/// sim in `DrawMap`. World units are logical points; the camera maps them
/// to the screen, y down like everything else.
fn draw_map_layer(map: &game::DrawMap, camera: &MapCamera) {
    mq::set_camera(&camera.camera);

    let tile = camera.tile_size;
    let color = |c: game::Rgba| mq::Color::new(c.r, c.g, c.b, c.a);
    for y in 0..map.height {
        for x in 0..map.width {
            let cell = map.cells[(y * map.width + x) as usize];
            let px = MARGIN + x as f32 * tile;
            let py = MARGIN + y as f32 * tile;
            mq::draw_rectangle(px, py, tile, tile, color(cell.fill));
            if cell.dot.a > 0.0 {
                mq::draw_circle(
                    px + tile * 0.5,
                    py + tile * 0.5,
                    tile * 0.3,
                    color(cell.dot),
                );
            }
        }
    }
    mq::set_default_camera();
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

async fn amain(conf: AppConf) {
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
    let mut camera = MapCamera {
        tile_size: conf.map_tile_size,
        ..Default::default()
    };
    // Last tick's report, carried across the frame boundary: input at the
    // top of a frame reacts to what the sim said last.
    let mut game_output = game::Output::default();
    // UI actions surface mid-frame (after the tick), so they fold into
    // the *next* frame's command — a frame of latency nobody can see.
    let mut pending_actions: Vec<String> = Vec::new();

    loop {
        if mq::is_key_pressed(mq::KeyCode::R) {
            ui_module = load_ui_module();
        }

        // The sim ticks exactly once per frame, with the frame's singular
        // command: default (a no-op), then every source folds its share
        // in — last frame's UI actions, the keyboard, and finally the
        // clock, which converts real time into an advance_time request
        // the game is free to decline. It never renders, rendering never
        // mutates, and real time never enters the sim.
        let mut command = AppCommand::default();
        for action in pending_actions.drain(..) {
            command.parse(&action);
        }
        gather_keyboard(&mut command, game_output.forced_paused);
        clock.apply(&command);
        if clock.due_days(mq::get_frame_time()) > 0 {
            command.game.advance_time = true;
        }
        game_output = game::tick(&mut game, command.game);

        mq::clear_background(mq::BLACK);
        frame_arena.reset();

        // The map layer, under the UI.
        camera.update(&command, mq::get_frame_time());
        draw_map_layer(&game.draw_map(), &camera);

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
        // Speed buttons, one list row per level: the current level is the
        // one you can't press, and any kind of pause locks them all.
        let time_stopped = clock.is_paused() || game_output.forced_paused;
        ui_data.begin_list("speeds");
        for level in 1..=Clock::MAX_SPEED {
            ui_data.begin_row();
            ui_data.bind("LEVEL", &level.to_string());
            ui_data.bind(
                "ENABLED",
                if time_stopped || clock.speed == level {
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

        pending_actions = events;

        if mq::is_key_pressed(mq::KeyCode::Escape) {
            return;
        }

        // A click on the board picks whatever entity sits there, and the
        // pick becomes an action string like any button press — riding
        // the same one-frame pipeline, no special path into the sim.
        if mq::is_mouse_button_pressed(mq::MouseButton::Left) && !output.is_pointer_over_ui() {
            let destination = camera.pick_cell(mq::mouse_position().into());
            // Temporary pick diagnostics: every unit assumption in one line.
            println!(
                "pick {:?} | mouse {:?} dpi {} screen {:?} camera.pos {:?} world {:?}",
                destination,
                mq::mouse_position(),
                mq::screen_dpi_scale(),
                (mq::screen_width(), mq::screen_height()),
                camera.pos,
                camera.camera.screen_to_world(mq::mouse_position().into()),
            );
            if destination != game::CellPos::default() {
                pending_actions.push(format!("travel {destination}"));
            }
        }

        mq::next_frame().await;
    }
}

fn load_ui_module() -> ir::UiModule {
    let style = load_style();
    let path = "data/ui.txt";
    let source = std::fs::read_to_string(path).unwrap_or_default();
    let module = ir::compile(&source, &style);
    for error in &module.errors {
        eprintln!("{path}: {error}");
    }
    for warning in &module.warnings {
        eprintln!("{path}: {warning}");
    }
    module
}

fn load_style() -> style::Style {
    // Scratch arena for the parse warnings; they are printed and die here.
    let arena = Arena::new();
    let path = "data/style.txt";
    let source = std::fs::read_to_string(path).unwrap_or_default();
    let parsed = style::parse(&arena, &source);
    for warning in parsed.warnings {
        eprintln!("{path}: {warning}");
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
