//! Per-frame interpreter for a compiled [`UiModule`]: walks the IR, emits
//! layout elements, and collects the action ids of everything clicked.
//!
//! The walk is kind-blind — the compiler baked every decision (defaults,
//! style values, what may float) into the nodes, so [`element`] applies
//! every field of every node the same way. Widget identity does not exist
//! here.
//!
//! Per-frame scratch (interpolated strings) lands in the caller's frame
//! arena; the returned events are owned, so they outlive the frame.

use arena::{AString, Arena};

use crate::ir::{Paint, Row, Size, Text, UiData, UiModule, UiNode};
use crate::layout::{
    self as ui, Color, Direction, ElementConf, ElementId, LogicalSize, Padding, Sense, TextConf, V2,
};

/// Walks the module's panels, declaring them into the current layout pass.
/// Returns the interpolated action ids of every button clicked this frame,
/// in click order.
pub fn run<'f>(
    module: &'f UiModule,
    data: &'f UiData,
    frame: &'f Arena,
    ui: &mut ui::Ui<'_, '_>,
) -> Vec<String> {
    let mut ctx = Ctx {
        frame,
        module,
        data,
        events: Vec::new(),
        auto_id: 0,
        row: Row::default(),
    };
    walk(&mut ctx, ui, module.roots());
    ctx.events
}

/// Everything the walk threads along, one fat struct. One lifetime for all
/// of it: the module and data must outlive the frame (they are owned
/// values up the stack), and everything borrowed dies together at the end
/// of the frame.
struct Ctx<'f> {
    frame: &'f Arena,
    module: &'f UiModule,
    data: &'f UiData,
    events: Vec<String>,
    /// Counter for elements with no script id that still need one (an
    /// action, scrolling, a tooltip); declaration order is deterministic,
    /// so the synthesized ids are stable across frames.
    auto_id: u32,
    /// Bindings of the template row being stamped; empty outside lists.
    row: Row,
}

/// Looks a `$VAR` up in the current row's bindings, then in the globals
/// (the root scope every element sees); a row binding shadows a global of
/// the same key.
fn lookup<'f>(ctx: &Ctx<'f>, var: &str) -> Option<&'f str> {
    ctx.data
        .bindings(ctx.row)
        .iter()
        .chain(ctx.data.globals.iter())
        .find(|b| ctx.data.text(b.key) == var)
        .map(|b| ctx.data.text(b.value))
}

/// Interpolates a pre-tokenized string against the current row and the
/// globals. Missing bindings keep their `$NAME` spelling so mistakes show
/// up on screen.
fn resolve<'f>(ctx: &Ctx<'f>, text: Text) -> &'f str {
    match ctx.module.segs(text) {
        [] => "",
        // A plain literal needs no interpolation: the module outlives the
        // frame, so its string is returned as-is, no copy.
        [seg] if seg.var.is_empty() => ctx.module.str(seg.literal),
        segs => {
            let mut out = AString::new_in(ctx.frame);
            for seg in segs {
                let var = ctx.module.str(seg.var);
                let value = if var.is_empty() { None } else { lookup(ctx, var) };
                match value {
                    Some(value) => out.push_str(value),
                    None => out.push_str(ctx.module.str(seg.literal)),
                }
            }
            out.into_str()
        }
    }
}

/// Resolves a paint. Almost always baked: only a `$VAR` name costs
/// anything, interpolated and looked up in the module's palette with the
/// baked color as the fallback.
fn paint(ctx: &Ctx<'_>, paint: Paint) -> Color {
    if paint.name.is_empty() {
        return paint.color;
    }
    let name = resolve(ctx, paint.name);
    ctx.module.palette.color(name).unwrap_or(paint.color)
}

/// One axis mapped onto the engine's vocabulary: the growth mode, plus
/// the pixel and fractional caps to constrain it with.
fn axis(size: Size) -> (LogicalSize, f32, f32) {
    let logical = if size.weight == 0.0 {
        LogicalSize::Fit
    } else if size.weight == 1.0 {
        LogicalSize::Grow
    } else {
        LogicalSize::GrowWeighted(size.weight)
    };
    if size.fraction {
        (logical, 0.0, size.cap)
    } else {
        (logical, size.cap, 0.0)
    }
}

/// Applies both size axes onto the conf. Caps combine with the explicit
/// `min_*`/`max_*` keys — the smaller ceiling wins (the engine folds the
/// fractional cap in the same way).
fn sized<'a>(mut conf: ElementConf<'a>, node: &UiNode) -> ElementConf<'a> {
    let tighter = |a: f32, b: f32| {
        if a > 0.0 && b > 0.0 { a.min(b) } else { a.max(b) }
    };

    let (logical, cap, fraction) = axis(node.width);
    conf = conf.width(logical);
    let max = tighter(cap, node.max_width);
    if max > 0.0 {
        conf = conf.max_width(max);
    }
    if fraction > 0.0 {
        conf = conf.max_width_fraction(fraction);
    }
    if node.min_width > 0.0 {
        conf = conf.min_width(node.min_width);
    }

    let (logical, cap, fraction) = axis(node.height);
    conf = conf.height(logical);
    let max = tighter(cap, node.max_height);
    if max > 0.0 {
        conf = conf.max_height(max);
    }
    if fraction > 0.0 {
        conf = conf.max_height_fraction(fraction);
    }
    if node.min_height > 0.0 {
        conf = conf.min_height(node.min_height);
    }
    conf
}

fn find_image(ctx: &Ctx<'_>, key: Text) -> Option<crate::ir::ImageData> {
    let key = resolve(ctx, key);
    ctx.data
        .images
        .iter()
        .find(|image| ctx.data.text(image.key) == key)
        .copied()
}

/// The stable identity an interactive element senses under: the script's
/// id, else its action (so buttons keep their identity across frames),
/// else one synthesized from declaration order.
fn element_id(ctx: &mut Ctx<'_>, node: &UiNode, action: &str) -> ElementId {
    let scripted = resolve(ctx, node.id);
    if !scripted.is_empty() {
        scripted.into()
    } else if !action.is_empty() {
        action.into()
    } else {
        ctx.auto_id += 1;
        ("__ui", ctx.auto_id).into()
    }
}

/// Declares the floating tooltip bubble inside a hovered element.
fn bubble(ctx: &Ctx<'_>, ui: &mut ui::Ui<'_, '_>, text: Text) {
    let style = ctx.module.bubble;
    let text = resolve(ctx, text);
    ui.add_with(
        ElementConf::default()
            // Bottom-center of the bubble pinned above the element's
            // top-center.
            .floating_at(V2 { x: 0.5, y: 0.0 }, V2 { x: 0.5, y: 1.0 })
            .float_offset(0.0, -8.0)
            .z_index(10)
            .padding(Padding::symmetric(10.0, 6.0))
            .background(style.background)
            .border(1.0, style.border)
            .corner_radius(6.0),
        |ui| {
            ui.add(ElementConf::text(
                TextConf::default()
                    .text(text)
                    .size(style.text_size)
                    .color(style.ink),
            ));
        },
    );
}

/// Evaluates a node's `visible` condition: unset = shown, otherwise the
/// interpolated text must be `yes`. Conditions come from data (`visible =
/// "$OPEN"` against row bindings or globals); a missing binding keeps its
/// `$NAME` spelling, so conditional elements stay hidden until the fill
/// code opts them in.
fn visible(ctx: &Ctx<'_>, node: &UiNode) -> bool {
    matches!(resolve(ctx, node.visible), "" | "yes")
}

fn walk(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, mut index: u32) {
    while index != 0 {
        let node = ctx.module.nodes[index as usize];
        if visible(ctx, &node) {
            element(ctx, ui, node);
        }
        index = node.next_sibling;
    }
}

/// Lowers one node onto the engine, kind-blind: every field of every node
/// applies. What the fields mean was the compiler's decision; here they
/// are only carried out.
fn element(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    // Anything can be interactive: an action, a hover skin, scrolling or
    // a tooltip needs a stable id and hover sensing (sense-then-declare:
    // styling reads last frame's bounds).
    let action = resolve(ctx, node.action);
    let interactive = !action.is_empty()
        || node.hover_background.a > 0.0
        || node.scroll_x
        || node.scroll_y
        || !node.tooltip.is_empty();
    let id = if interactive {
        Some(element_id(ctx, &node, action))
    } else {
        None
    };
    let sense = id.map_or(Sense::default(), |id| ui.sense(id));

    let text = resolve(ctx, node.text);
    let mut conf = if text.is_empty() {
        ElementConf::default()
    } else {
        ElementConf::text(
            TextConf::default()
                .text(text)
                .size(node.text_size)
                .color(paint(ctx, node.color))
                .wrap(node.wrap),
        )
    };
    conf = sized(conf, &node)
        .direction(node.direction)
        .align_x(node.align_x)
        .align_y(node.align_y)
        .padding(node.padding)
        .gap(node.gap)
        .corner_radius(node.corner_radius);
    let background = if sense.hovered && node.hover_background.a > 0.0 {
        node.hover_background
    } else {
        paint(ctx, node.background)
    };
    if background.a > 0.0 {
        conf = conf.background(background);
    }
    if !node.image.is_empty() {
        if let Some(image) = find_image(ctx, node.image) {
            conf = conf.image(
                image.image,
                V2 {
                    x: image.width,
                    y: image.height,
                },
            );
            let tint = paint(ctx, node.tint);
            if tint.a > 0.0 {
                conf = conf.image_tint(tint);
            }
            if node.fade > 0.0 {
                conf = conf.image_fade(node.fade);
            }
        }
    }
    if node.border_width > 0.0 {
        conf = conf.border(node.border_width, node.border_color);
    }
    if node.scroll_x || node.scroll_y {
        conf = conf.scroll(node.scroll_x, node.scroll_y);
    }
    if node.floating {
        // The same fraction on parent and self gives the script's
        // positioning semantics: 0 = flush, 0.5 = centered, 1 = flush
        // right/bottom. The parent is the screen for top-level panels.
        let factors = V2 {
            x: node.x_pos,
            y: node.y_pos,
        };
        conf = conf.floating_at(factors, factors);
    }
    if let Some(id) = id {
        conf = conf.id(id);
    }

    ui.add_with(conf, |ui| {
        walk(ctx, ui, node.first_child);
        if node.template != 0 {
            stamp(ctx, ui, &node);
        }
        if sense.hovered && !node.tooltip.is_empty() {
            bubble(ctx, ui, node.tooltip);
        }
    });
    if sense.clicked && !action.is_empty() {
        ctx.events.push(action.to_string());
    }
}

/// Stamps the node's template once per row of its bound data list (matched
/// by the node's interpolated id).
fn stamp(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: &UiNode) {
    let key = resolve(ctx, node.id);
    let rows = ctx
        .data
        .lists
        .iter()
        .find(|list| ctx.data.text(list.id) == key)
        .map_or(&[][..], |list| ctx.data.rows(*list));
    let template = ctx.module.nodes[node.template as usize];
    // Stack discipline: a nested list must not clobber the row its
    // siblings in the enclosing template still resolve against.
    let outer_row = ctx.row;
    // Rows fill the list's cross axis, so grow-sized template content has
    // room to work with.
    let stamp_conf = match node.direction {
        Direction::TopToBottom => ElementConf::default().width(LogicalSize::Grow),
        Direction::LeftToRight => ElementConf::default().height(LogicalSize::Grow),
    };
    for &row in rows {
        ctx.row = row;
        let row_conf = if template.id.is_empty() {
            // No script id: the engine derives a stable one from the
            // parent id and the child ordinal.
            stamp_conf
        } else {
            stamp_conf.id(resolve(ctx, template.id))
        };
        ui.add_with(row_conf, |ui| {
            walk(ctx, ui, template.first_child);
        });
    }
    ctx.row = outer_row;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir;
    use crate::layout::{Engine, Input, Rectangle};
    use crate::style::Style;

    fn compile(source: &str) -> UiModule {
        ir::compile(source, &Style::default())
    }

    fn input(w: f32, h: f32) -> Input {
        Input {
            bounds: Rectangle {
                x: 0.0,
                y: 0.0,
                w,
                h,
            },
            ..Input::default()
        }
    }

    fn people() -> UiData {
        let mut data = UiData::default();
        data.begin_list("people_list");
        data.begin_row();
        data.bind("ID", "7");
        data.bind("NAME", "Livia");
        data
    }

    #[test]
    fn resolve_interpolates_rows_then_globals_and_keeps_missing_vars_literal() {
        let frame = Arena::new();
        let mut data = UiData::default();
        data.bind_global("ID", "99"); // shadowed by the row's ID
        data.bind_global("YEAR", "700");
        data.begin_list("l");
        data.begin_row();
        data.bind("ID", "42");
        let row = data.rows(data.lists[0])[0];
        // Tokenization is the compiler's job; go through it.
        let module = compile("panel = { label = \"hire $ID in $YEAR $MISSING\" }");
        assert!(module.errors.is_empty() && module.warnings.is_empty());
        let label = module.nodes[module.nodes[module.roots() as usize].first_child as usize];
        let mut ctx = Ctx {
            frame: &frame,
            module: &module,
            data: &data,
            events: Vec::new(),
            auto_id: 0,
            row,
        };
        assert_eq!(resolve(&ctx, label.text), "hire 42 in 700 $MISSING");
        assert_eq!(resolve(&ctx, Text::default()), "");
        // Outside any row (the zero row), globals still resolve.
        ctx.row = Row::default();
        assert_eq!(resolve(&ctx, label.text), "hire 99 in 700 $MISSING");
    }

    #[test]
    fn dynamic_paints_resolve_through_the_palette() {
        let frame = Arena::new();
        let mut data = UiData::default();
        data.bind_global("GOOD", "accent");
        data.bind_global("GONE", "none");
        let module = compile(
            "panel = { \
             panel = { background = \"$GOOD\" } \
             panel = { background = \"$GONE\" } \
             panel = { background = \"$MISSING\" } }",
        );
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);
        let ctx = Ctx {
            frame: &frame,
            module: &module,
            data: &data,
            events: Vec::new(),
            auto_id: 0,
            row: Row::default(),
        };
        let root = module.nodes[module.roots() as usize];
        let good = module.nodes[root.first_child as usize];
        assert_eq!(paint(&ctx, good.background), module.palette.accent);
        let gone = module.nodes[good.next_sibling as usize];
        assert_eq!(paint(&ctx, gone.background).a, 0.0);
        // An unresolvable name falls back to the baked default.
        let missing = module.nodes[gone.next_sibling as usize];
        assert_eq!(paint(&ctx, missing.background), module.palette.panel);
    }

    #[test]
    fn clicks_produce_interpolated_events() {
        const SOURCE: &str = "panel = {
            button = { action = \"print OK\" text = go width = 100 height = 30 }
            button = { text = mute width = 100 height = 30 }
            list = {
                id = \"people_list\"
                template = {
                    id = \"element_$ID\"
                    button = { action = \"hire $ID\" text = \"$NAME\" width = 100 height = 30 }
                }
            }
        }";
        let module = compile(SOURCE);
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let mut engine = Engine::default();
        let mut frame = Arena::new();
        let measure = |_: &str, _| V2::default();

        // Owned data survives the frame arena resets, so build it once.
        let data = people();

        // Panel padding 12, gap 8: buttons at y = 12 and 50, the list's row
        // at y = 88. A frame with no input establishes the bounds `sense`
        // reads on the next one.
        let mut click_at = |arena: &mut Arena, x: f32, y: f32, pressed: bool| {
            arena.reset();
            let mut probe = input(400.0, 400.0);
            probe.mouse_pos = V2 { x, y };
            probe.mouse_pressed = pressed;
            let mut events: Vec<String> = Vec::new();
            engine.layout(probe, measure, |ui| {
                events = run(&module, &data, arena, ui);
            });
            events
        };

        assert!(click_at(&mut frame, 0.0, 0.0, false).is_empty());
        assert_eq!(click_at(&mut frame, 50.0, 25.0, true), ["print OK"]);
        // The action-less button swallows the click without an event.
        assert!(click_at(&mut frame, 50.0, 60.0, true).is_empty());
        assert_eq!(click_at(&mut frame, 50.0, 95.0, true), ["hire 7"]);
    }

    #[test]
    fn visible_conditions_evaluate_against_bindings_and_globals() {
        let frame = Arena::new();
        let mut data = UiData::default();
        data.bind_global("WINDOW_OPEN", "yes");
        data.begin_list("l");
        data.begin_row();
        data.bind("ALIVE", "no");
        let row = data.rows(data.lists[0])[0];
        let module = compile(
            "panel = { \
             label = { text = a } \
             label = { text = b visible = yes } \
             label = { text = c visible = no } \
             label = { text = d visible = \"$WINDOW_OPEN\" } \
             label = { text = e visible = \"$MISSING\" } \
             label = { text = f visible = \"$ALIVE\" } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);
        let ctx = Ctx {
            frame: &frame,
            module: &module,
            data: &data,
            events: Vec::new(),
            auto_id: 0,
            row,
        };
        let panel = module.nodes[module.roots() as usize];
        let mut index = panel.first_child;
        let mut shown = Vec::new();
        while index != 0 {
            let node = module.nodes[index as usize];
            shown.push(visible(&ctx, &node));
            index = node.next_sibling;
        }
        assert_eq!(shown, [true, true, false, true, false, false]);
    }

    #[test]
    fn hidden_nodes_are_not_declared() {
        const SOURCE: &str = "panel = {
            button = { action = never text = a visible = no width = 100 height = 30 }
            button = { action = maybe text = b visible = \"$WINDOW_OPEN\" width = 100 height = 30 }
        }";
        let module = compile(SOURCE);
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let mut engine = Engine::default();
        let mut frame = Arena::new();
        let measure = |_: &str, _| V2::default();

        let mut click_at = |data: &UiData, x: f32, y: f32, pressed: bool| {
            frame.reset();
            let mut probe = input(400.0, 400.0);
            probe.mouse_pos = V2 { x, y };
            probe.mouse_pressed = pressed;
            let mut events: Vec<String> = Vec::new();
            engine.layout(probe, measure, |ui| {
                events = run(&module, data, &frame, ui);
            });
            events
        };

        // Both buttons hidden: the first button's slot (panel padding 12)
        // holds nothing to click.
        let closed = UiData::default();
        assert!(click_at(&closed, 0.0, 0.0, false).is_empty());
        assert!(click_at(&closed, 50.0, 25.0, true).is_empty());

        // Bound to yes: the conditional button is now the panel's first child.
        let mut open = UiData::default();
        open.bind_global("WINDOW_OPEN", "yes");
        assert!(click_at(&open, 0.0, 0.0, false).is_empty());
        assert_eq!(click_at(&open, 50.0, 25.0, true), ["maybe"]);
    }

    #[test]
    fn sizes_map_to_engine_modes_and_caps() {
        // The zero value is fit content, uncapped.
        assert_eq!(axis(Size::default()), (LogicalSize::Fit, 0.0, 0.0));
        assert_eq!(axis(Size::FIT), (LogicalSize::Fit, 0.0, 0.0));
        assert_eq!(axis(Size::GROW), (LogicalSize::Grow, 0.0, 0.0));

        // Caps ride alongside the growth mode.
        let capped = Size {
            cap: 140.0,
            fraction: false,
            weight: 1.0,
        };
        assert_eq!(axis(capped), (LogicalSize::Grow, 140.0, 0.0));
        let capped_weighted = Size {
            cap: 180.0,
            fraction: false,
            weight: 2.0,
        };
        assert_eq!(
            axis(capped_weighted),
            (LogicalSize::GrowWeighted(2.0), 180.0, 0.0)
        );
        let fraction = Size {
            cap: 0.92,
            fraction: true,
            weight: 1.0,
        };
        assert_eq!(axis(fraction), (LogicalSize::Grow, 0.0, 0.92));
    }
}
