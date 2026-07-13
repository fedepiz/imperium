//! Per-frame interpreter for a compiled [`UiModule`]: walks the IR, emits
//! layout elements, and collects the action ids of everything clicked.
//!
//! Per-frame scratch (interpolated strings) lands in the caller's frame
//! arena; the returned events are owned, so they outlive the frame.

use arena::{AString, Arena};

use crate::ir::{LabelStyle, NodeKind, Row, Size, Text, UiData, UiModule, UiNode};
use crate::layout::{
    self as ui, Align, Color, Direction, ElementConf, ElementId, LogicalSize, Padding, TextConf, V2,
};
use crate::style::Style;

/// Walks the module's panels, declaring them into the current layout pass.
/// Returns the interpolated action ids of every button clicked this frame,
/// in click order.
pub fn run<'f>(
    module: &'f UiModule,
    style: Style,
    data: &'f UiData,
    frame: &'f Arena,
    ui: &mut ui::Ui<'_, '_>,
) -> Vec<String> {
    let mut ctx = Ctx {
        frame,
        module,
        data,
        events: Vec::new(),
        style,
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
    style: Style,
    /// Counter for elements with no script id that still need one (buttons,
    /// scrollable or tooltipped containers); declaration order is
    /// deterministic, so the synthesized ids are stable across frames.
    auto_id: u32,
    /// Bindings of the template row being stamped; empty outside lists.
    row: Row,
}

/// Interpolates a pre-tokenized string against the current row. Missing
/// bindings keep their `$NAME` spelling so mistakes show up on screen.
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
                let binding = ctx
                    .data
                    .bindings(ctx.row)
                    .iter()
                    .find(|b| ctx.data.text(b.key) == var);
                match binding {
                    Some(binding) if !var.is_empty() => out.push_str(ctx.data.text(binding.value)),
                    _ => out.push_str(ctx.module.str(seg.literal)),
                }
            }
            out.into_str()
        }
    }
}

/// A widget's posture when the script gives no size: how eagerly it
/// claims leftover space (0 = fit content) and its default cap (0 =
/// uncapped).
#[derive(Clone, Copy)]
struct SizeDefault {
    weight: f32,
    cap: f32,
}

/// Containers fill their share of the parent.
const GROW: SizeDefault = SizeDefault {
    weight: 1.0,
    cap: 0.0,
};

/// Floating elements and images are their content: floaters have no
/// parent share to claim, images shouldn't silently upscale.
const FIT: SizeDefault = SizeDefault {
    weight: 0.0,
    cap: 0.0,
};

/// One axis mapped onto the engine's vocabulary: the growth mode, plus
/// the pixel and fractional caps to constrain it with.
fn axis(size: Size, default: SizeDefault) -> (LogicalSize, f32, f32) {
    let (cap, fraction, weight) = if size.set {
        (size.cap, size.fraction, size.weight)
    } else {
        (default.cap, false, default.weight)
    };
    let logical = if weight == 0.0 {
        LogicalSize::Fit
    } else if weight == 1.0 {
        LogicalSize::Grow
    } else {
        LogicalSize::GrowWeighted(weight)
    };
    if fraction {
        (logical, 0.0, cap)
    } else {
        (logical, cap, 0.0)
    }
}

/// Applies both script axes onto the conf: the script's `cap[:weight]`
/// when given, else the widget default. Caps combine with the explicit
/// `min_*`/`max_*` keys — the smaller ceiling wins (the engine folds the
/// fractional cap in the same way).
fn sized<'a>(
    mut conf: ElementConf<'a>,
    node: &UiNode,
    width: SizeDefault,
    height: SizeDefault,
) -> ElementConf<'a> {
    let tighter = |a: f32, b: f32| {
        if a > 0.0 && b > 0.0 { a.min(b) } else { a.max(b) }
    };

    let (logical, cap, fraction) = axis(node.width, width);
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

    let (logical, cap, fraction) = axis(node.height, height);
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

/// The container's background: empty name = the widget default, `none` (or
/// an unknown name) = no background at all.
fn background(ctx: &Ctx<'_>, node: &UiNode, default: Option<Color>) -> Option<Color> {
    match resolve(ctx, node.background) {
        "" => default,
        name => ctx.style.color(name),
    }
}

/// The shared container config: everything panels, rows and lists have in
/// common. The caller layers on its per-kind pieces (ids, floats, rows).
fn container_conf(ctx: &Ctx<'_>, node: &UiNode, default_bg: Option<Color>) -> ElementConf<'static> {
    let style = ctx.style;
    // Containers fill by default; floaters (tooltips, badges, top-level
    // panels) have no share to claim and fit their content instead.
    let default = if node.floating { FIT } else { GROW };
    let mut conf = sized(ElementConf::default(), node, default, default)
        .direction(node.direction)
        .align_x(node.align_x)
        .align_y(node.align_y)
        .padding(Padding::all(if node.padding_set {
            node.padding
        } else {
            style.padding
        }))
        .gap(if node.gap_set { node.gap } else { style.gap })
        .corner_radius(style.corner_radius);
    if let Some(color) = background(ctx, node, default_bg) {
        conf = conf.background(color);
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
        }
    }
    if node.border {
        conf = conf.border(1.0, style.outline);
    }
    if node.scrollable {
        conf = conf.scroll(
            node.direction == Direction::LeftToRight,
            node.direction == Direction::TopToBottom,
        );
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

/// The stable id an interactive container needs (scroll state, tooltips):
/// the script's own id when given, else a synthesized one.
fn element_id(ctx: &mut Ctx<'_>, node: &UiNode, kind: &'static str) -> ElementId {
    let scripted = resolve(ctx, node.id);
    if scripted.is_empty() {
        ctx.auto_id += 1;
        (kind, ctx.auto_id).into()
    } else {
        scripted.into()
    }
}

/// Declares the floating tooltip bubble inside a hovered element.
fn tooltip(ctx: &Ctx<'_>, ui: &mut ui::Ui<'_, '_>, text: Text) {
    let style = ctx.style;
    let text = resolve(ctx, text);
    ui.add_with(
        ElementConf::default()
            // Bottom-center of the bubble pinned above the element's
            // top-center.
            .floating_at(V2 { x: 0.5, y: 0.0 }, V2 { x: 0.5, y: 1.0 })
            .float_offset(0.0, -8.0)
            .z_index(10)
            .padding(Padding::symmetric(10.0, 6.0))
            .background(style.tooltip_background)
            .border(1.0, style.outline)
            .corner_radius(6.0),
        |ui| {
            ui.add(ElementConf::text(
                TextConf::default()
                    .text(text)
                    .size(style.tooltip_size)
                    .color(style.ink),
            ));
        },
    );
}

fn walk(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, mut index: u32) {
    while index != 0 {
        let node = ctx.module.nodes[index as usize];
        match node.kind {
            NodeKind::Panel => panel(ctx, ui, node),
            NodeKind::Label => label(ctx, ui, node),
            NodeKind::Button => button(ctx, ui, node),
            NodeKind::Image => image(ctx, ui, node),
            NodeKind::List => list(ctx, ui, node),
            NodeKind::None | NodeKind::Template => {}
        }
        index = node.next_sibling;
    }
}

fn panel(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    let style = ctx.style;
    let mut conf = container_conf(ctx, &node, Some(style.panel_background));
    // Scroll state and hover sensing both need a stable id.
    let mut hovered = false;
    if node.scrollable || !node.tooltip.is_empty() {
        let id = element_id(ctx, &node, "__script_panel");
        conf = conf.id(id);
        hovered = ui.sense(id).hovered;
    }
    ui.add_with(conf, |ui| {
        walk(ctx, ui, node.first_child);
        if hovered && !node.tooltip.is_empty() {
            tooltip(ctx, ui, node.tooltip);
        }
    });
}

fn label(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    let style = ctx.style;
    let text = resolve(ctx, node.text);
    let (role_size, role_color) = match node.label_style {
        LabelStyle::Body => (style.text_size, style.ink),
        LabelStyle::Heading => (style.heading_size, style.ink),
        LabelStyle::Section => (style.section_size, style.muted),
    };
    let text_size = if node.text_size > 0 {
        node.text_size
    } else {
        role_size
    };
    let color = match resolve(ctx, node.color) {
        "" => role_color,
        name => style.color(name).unwrap_or(role_color),
    };
    // Labels fit their text.
    ui.add(sized(
        ElementConf::text(
            TextConf::default()
                .text(text)
                .size(text_size)
                .color(color)
                .wrap(node.wrap),
        ),
        &node,
        FIT,
        FIT,
    ));
}

fn button(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    let style = ctx.style;
    let action = resolve(ctx, node.id);
    let id: ElementId = if action.is_empty() {
        ctx.auto_id += 1;
        ("__script_button", ctx.auto_id).into()
    } else {
        action.into()
    };
    // Sense-then-declare: style from last frame's bounds, like `sense` docs
    // describe.
    let sense = ui.sense(id);
    // Unsized buttons grow into the style's default button caps.
    let default_for = |cap: f32| SizeDefault { weight: 1.0, cap };
    let mut conf = sized(
        ElementConf::default(),
        &node,
        default_for(style.button_width),
        default_for(style.button_height),
    )
    .id(id)
    .padding(Padding::symmetric(10.0, 4.0))
    .align_x(Align::Center)
    .align_y(Align::Center)
    .background(if sense.hovered {
        style.button_hover
    } else {
        style.button_background
    })
    .corner_radius(style.button_corner_radius);
    if style.button_border_thickness > 0.0 {
        conf = conf.border(style.button_border_thickness, style.button_border_color);
    }
    let text = resolve(ctx, node.text);
    ui.add_with(conf, |ui| {
        ui.add(ElementConf::text(
            TextConf::default()
                .text(text)
                .size(style.text_size)
                .color(style.ink),
        ));
        if sense.hovered && !node.tooltip.is_empty() {
            tooltip(ctx, ui, node.tooltip);
        }
    });
    if sense.clicked && !action.is_empty() {
        ctx.events.push(action.to_string());
    }
}

fn image(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    let style = ctx.style;
    let Some(data) = find_image(ctx, node.image) else {
        return; // unknown key: draw nothing, the module already validated
    };
    // Images default to their natural size; growing is opt-in.
    let mut conf = sized(ElementConf::default(), &node, FIT, FIT).image(
        data.image,
        V2 {
            x: data.width,
            y: data.height,
        },
    );
    if let Some(color) = background(ctx, &node, None) {
        conf = conf.background(color);
    }
    if let Some(tint) = style.color(resolve(ctx, node.tint)) {
        conf = conf.image_tint(tint);
    }
    if node.fade > 0.0 {
        conf = conf.image_fade(node.fade);
    }
    if node.border {
        conf = conf.border(1.0, style.outline);
    }
    ui.add(conf);
}

fn list(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode) {
    let list_id = resolve(ctx, node.id);
    // Lists default to no padding, no background: they are stamping
    // machinery, not a visual box, unless the script says otherwise.
    let mut list_node = node;
    if !list_node.padding_set {
        list_node.padding_set = true;
        list_node.padding = 0.0;
    }
    // Stable id keeps the engine's scroll state across frames.
    let id = element_id(ctx, &node, "__script_list");
    let conf = container_conf(ctx, &list_node, None).id(id);
    let hovered = ui.sense(id).hovered;
    let rows = ctx
        .data
        .lists
        .iter()
        .find(|list| ctx.data.text(list.id) == list_id)
        .map_or(&[][..], |list| ctx.data.rows(*list));
    let template = node.template;
    ui.add_with(conf, |ui| {
        if template != 0 {
            let template_node = ctx.module.nodes[template as usize];
            // Rows fill the list's cross axis, so grow-sized template
            // content has room to work with.
            let stamp_conf = match node.direction {
                Direction::TopToBottom => ElementConf::default().width(LogicalSize::Grow),
                Direction::LeftToRight => ElementConf::default().height(LogicalSize::Grow),
            };
            for &row in rows {
                ctx.row = row;
                let row_conf = if template_node.id.is_empty() {
                    // No script id: the engine derives a stable one from
                    // the list id and the child ordinal.
                    stamp_conf
                } else {
                    stamp_conf.id(resolve(ctx, template_node.id))
                };
                ui.add_with(row_conf, |ui| {
                    walk(ctx, ui, template_node.first_child);
                });
            }
            ctx.row = Row::default();
        }
        if hovered && !node.tooltip.is_empty() {
            tooltip(ctx, ui, node.tooltip);
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir;
    use crate::layout::{Engine, Input, Rectangle};

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
    fn resolve_interpolates_and_keeps_missing_vars_literal() {
        let frame = Arena::new();
        let mut data = UiData::default();
        data.begin_list("l");
        data.begin_row();
        data.bind("ID", "42");
        let row = data.rows(data.lists[0])[0];
        // Tokenization is the compiler's job; go through it.
        let module = ir::compile("panel = { label = \"hire $ID $MISSING\" }");
        assert!(module.errors.is_empty() && module.warnings.is_empty());
        let label = module.nodes[module.nodes[module.roots() as usize].first_child as usize];
        let ctx = Ctx {
            frame: &frame,
            module: &module,
            data: &data,
            events: Vec::new(),
            style: Style::default(),
            auto_id: 0,
            row,
        };
        assert_eq!(resolve(&ctx, label.text), "hire 42 $MISSING");
        assert_eq!(resolve(&ctx, Text::default()), "");
    }

    #[test]
    fn clicks_produce_interpolated_events() {
        const SOURCE: &str = "panel = {
            button = { id = \"print OK\" text = go width = 100 height = 30 }
            button = { text = mute width = 100 height = 30 }
            list = {
                id = \"people_list\"
                template = {
                    id = \"element_$ID\"
                    button = { id = \"hire $ID\" text = \"$NAME\" width = 100 height = 30 }
                }
            }
        }";
        let module = ir::compile(SOURCE);
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
                events = run(&module, Style::default(), &data, arena, ui);
            });
            events
        };

        assert!(click_at(&mut frame, 0.0, 0.0, false).is_empty());
        assert_eq!(click_at(&mut frame, 50.0, 25.0, true), ["print OK"]);
        // The id-less button swallows the click without an event.
        assert!(click_at(&mut frame, 50.0, 60.0, true).is_empty());
        assert_eq!(click_at(&mut frame, 50.0, 95.0, true), ["hire 7"]);
    }

    #[test]
    fn sizes_map_to_engine_modes_and_caps() {
        // Unset: the widget default posture stands.
        assert_eq!(
            axis(Size::default(), GROW),
            (LogicalSize::Grow, 0.0, 0.0)
        );
        assert_eq!(axis(Size::default(), FIT), (LogicalSize::Fit, 0.0, 0.0));
        assert_eq!(
            axis(
                Size::default(),
                SizeDefault {
                    weight: 1.0,
                    cap: 140.0
                }
            ),
            (LogicalSize::Grow, 140.0, 0.0)
        );

        // Explicit sizes win over the default.
        let capped_weighted = Size {
            set: true,
            cap: 180.0,
            fraction: false,
            weight: 2.0,
        };
        assert_eq!(
            axis(capped_weighted, FIT),
            (LogicalSize::GrowWeighted(2.0), 180.0, 0.0)
        );
        let fraction = Size {
            set: true,
            cap: 0.92,
            fraction: true,
            weight: 1.0,
        };
        assert_eq!(axis(fraction, FIT), (LogicalSize::Grow, 0.0, 0.92));
        assert_eq!(axis(Size::FIT, GROW), (LogicalSize::Fit, 0.0, 0.0));
    }
}
