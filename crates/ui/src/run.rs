//! Per-frame interpreter for a compiled [`UiModule`]: walks the IR, emits
//! layout elements, and collects the action ids of everything clicked.
//!
//! All per-frame scratch — interpolated strings and the event list — lands
//! in the caller's frame arena, so the returned events outlive the layout
//! pass and die with the frame.

use arena::{AString, AVec, Arena};

use crate::layout::{
    self as ui, Align, Anchor, Color, Direction, ElementConf, ElementId, LogicalSize, Padding,
    TextConf, V2,
};
use crate::ir::{LabelStyle, NodeKind, Row, Size, SizeKind, Text, UiData, UiModule, UiNode};

/// Visuals the script format doesn't specify, plus the palette the script
/// refers to by name (`background = accent`). The zero value renders
/// invisibly but harmlessly; [`Style::default`] gives the palette below.
#[derive(Clone, Copy)]
pub struct Style {
    pub panel_background: Color,
    pub dark: Color,
    pub outline: Color,
    pub ink: Color,
    pub muted: Color,
    /// The one highlight color; everything the script wants to pop
    /// (`box`es, badges, tints) uses this.
    pub accent: Color,
    pub button_background: Color,
    pub button_hover: Color,
    pub tooltip_background: Color,
    pub title_size: u16,
    pub heading_size: u16,
    pub section_size: u16,
    pub text_size: u16,
    pub padding: f32,
    pub gap: f32,
    pub corner_radius: f32,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            panel_background: Color::rgba(0.055, 0.067, 0.10, 0.9),
            dark: Color::rgba(0.03, 0.04, 0.07, 1.0),
            outline: Color::rgba(0.25, 0.29, 0.40, 1.0),
            ink: Color::rgba(0.94, 0.95, 1.0, 1.0),
            muted: Color::rgba(0.57, 0.62, 0.74, 1.0),
            accent: Color::rgba(0.43, 0.32, 0.92, 1.0),
            button_background: Color::rgba(0.08, 0.68, 0.72, 1.0),
            button_hover: Color::rgba(0.16, 0.86, 0.90, 1.0),
            tooltip_background: Color::rgba(0.02, 0.03, 0.05, 0.95),
            title_size: 20,
            heading_size: 28,
            section_size: 13,
            text_size: 16,
            padding: 12.0,
            gap: 8.0,
            corner_radius: 10.0,
        }
    }
}

impl Style {
    /// Looks up a script color name. The palette is semantic on purpose —
    /// scripts say what a thing is, not which hue it has. `None` means "no
    /// color": both the explicit `none` and anything unknown (which stays
    /// invisible rather than guessing).
    fn color(&self, name: &str) -> Option<Color> {
        Some(match name {
            "panel" => self.panel_background,
            "dark" => self.dark,
            "outline" => self.outline,
            "ink" => self.ink,
            "muted" => self.muted,
            "accent" => self.accent,
            _ => return None,
        })
    }
}

/// Walks the module's panels, declaring them into the current layout pass.
/// Returns the interpolated action ids of every button clicked this frame,
/// in click order, allocated in `frame`.
pub fn run<'f>(
    module: &UiModule<'_>,
    data: UiData<'f>,
    frame: &'f Arena,
    ui: &mut ui::Ui<'_, '_>,
) -> &'f [&'f str] {
    let mut ctx = Ctx {
        frame,
        data,
        events: AVec::new_in(frame),
        style: Style::default(),
        auto_id: 0,
        row: Row::default(),
    };
    walk(&mut ctx, module, ui, module.roots());
    ctx.events.into_slice()
}

/// Everything the walk threads along, one fat struct. One lifetime for all
/// of it: the binding data is required to live as long as the frame arena
/// (in practice the caller builds it there), and everything dies together
/// at the end of the frame.
struct Ctx<'f> {
    frame: &'f Arena,
    data: UiData<'f>,
    events: AVec<'f, &'f str>,
    style: Style,
    /// Counter for elements with no script id that still need one (buttons,
    /// scrollable or tooltipped containers); declaration order is
    /// deterministic, so the synthesized ids are stable across frames.
    auto_id: u32,
    /// Bindings of the template row being stamped; empty outside lists.
    row: Row<'f>,
}

/// Interpolates a pre-tokenized string against the current row. Missing
/// bindings keep their `$NAME` spelling so mistakes show up on screen.
fn resolve<'f>(ctx: &Ctx<'f>, text: Text<'_>) -> &'f str {
    match text.segs {
        [] => "",
        [seg] if seg.var.is_empty() => ctx.frame.alloc_str(seg.literal),
        segs => {
            let mut out = AString::new_in(ctx.frame);
            for seg in segs {
                let binding = ctx.row.bindings.iter().find(|b| b.key == seg.var);
                match binding {
                    Some(binding) if !seg.var.is_empty() => out.push_str(binding.value),
                    _ => out.push_str(seg.literal),
                }
            }
            out.into_str()
        }
    }
}

/// A script size, mapped onto the layout engine's vocabulary.
fn size(size: Size) -> LogicalSize {
    match size.kind {
        SizeKind::Fit => LogicalSize::Fit,
        SizeKind::Pixels => LogicalSize::Pixels(size.value),
        SizeKind::Grow if size.value != 1.0 && size.value > 0.0 => {
            LogicalSize::GrowWeighted(size.value)
        }
        SizeKind::Grow => LogicalSize::Grow,
        SizeKind::Fraction => LogicalSize::Parent(size.value),
    }
}

/// The container's background: empty name = the widget default, `none` (or
/// an unknown name) = no background at all.
fn background(ctx: &Ctx<'_>, node: &UiNode<'_>, default: Option<Color>) -> Option<Color> {
    match resolve(ctx, node.background) {
        "" => default,
        name => ctx.style.color(name),
    }
}

/// The shared container config: everything panels, rows and lists have in
/// common. The caller layers on its per-kind pieces (ids, floats, rows).
fn container_conf(ctx: &Ctx<'_>, node: &UiNode<'_>, default_bg: Option<Color>) -> ElementConf<'static> {
    let style = ctx.style;
    let mut conf = ElementConf::default()
        .direction(node.direction)
        .width(size(node.width))
        .height(size(node.height))
        .align_x(node.align_x)
        .align_y(node.align_y)
        .padding(Padding::all(if node.padding_set {
            node.padding
        } else {
            style.padding
        }))
        .gap(if node.gap_set { node.gap } else { style.gap })
        .corner_radius(style.corner_radius);
    if node.min_width > 0.0 {
        conf = conf.min_width(node.min_width);
    }
    if node.max_width > 0.0 {
        conf = conf.max_width(node.max_width);
    }
    if node.min_height > 0.0 {
        conf = conf.min_height(node.min_height);
    }
    if node.max_height > 0.0 {
        conf = conf.max_height(node.max_height);
    }
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

fn find_image<'f>(ctx: &Ctx<'f>, key: Text<'_>) -> Option<crate::ir::ImageData<'f>> {
    let key = resolve(ctx, key);
    ctx.data.images.iter().find(|image| image.key == key).copied()
}

/// The stable id an interactive container needs (scroll state, tooltips):
/// the script's own id when given, else a synthesized one.
fn element_id(ctx: &mut Ctx<'_>, node: &UiNode<'_>, kind: &'static str) -> ElementId {
    let scripted = resolve(ctx, node.id);
    if scripted.is_empty() {
        ctx.auto_id += 1;
        (kind, ctx.auto_id).into()
    } else {
        scripted.into()
    }
}

/// Declares the floating tooltip bubble inside a hovered element.
fn tooltip(ctx: &Ctx<'_>, ui: &mut ui::Ui<'_, '_>, text: Text<'_>) {
    let style = ctx.style;
    let text = resolve(ctx, text);
    ui.add_with(
        ElementConf::default()
            .floating(Anchor::TopCenter, Anchor::BottomCenter)
            .float_offset(0.0, -8.0)
            .z_index(10)
            .padding(Padding::symmetric(10.0, 6.0))
            .background(style.tooltip_background)
            .border(1.0, style.outline)
            .corner_radius(6.0),
        |ui| {
            ui.add(ElementConf::text(
                TextConf::default().text(text).size(14).color(style.ink),
            ));
        },
    );
}

fn walk(ctx: &mut Ctx<'_>, module: &UiModule<'_>, ui: &mut ui::Ui<'_, '_>, mut index: u32) {
    while index != 0 {
        let node = module.nodes[index as usize];
        match node.kind {
            NodeKind::Panel => panel(ctx, module, ui, node),
            NodeKind::Label => label(ctx, ui, node),
            NodeKind::Button => button(ctx, ui, node),
            NodeKind::Image => image(ctx, ui, node),
            NodeKind::List => list(ctx, module, ui, node),
            NodeKind::None | NodeKind::Template => {}
        }
        index = node.next_sibling;
    }
}

fn panel(ctx: &mut Ctx<'_>, module: &UiModule<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode<'_>) {
    let style = ctx.style;
    let mut conf = container_conf(ctx, &node, Some(style.panel_background));
    // Scroll state and hover sensing both need a stable id.
    let mut hovered = false;
    if node.scrollable || !node.tooltip.is_empty() {
        let id = element_id(ctx, &node, "__script_panel");
        conf = conf.id(id);
        hovered = ui.hovered(id);
    }
    ui.add_with(conf, |ui| {
        if !node.text.is_empty() {
            let title = resolve(ctx, node.text);
            ui.add(ElementConf::text(
                TextConf::default()
                    .text(title)
                    .size(style.title_size)
                    .color(style.ink),
            ));
        }
        walk(ctx, module, ui, node.first_child);
        if hovered && !node.tooltip.is_empty() {
            tooltip(ctx, ui, node.tooltip);
        }
    });
}

fn label(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode<'_>) {
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
    ui.add(
        ElementConf::text(
            TextConf::default()
                .text(text)
                .size(text_size)
                .color(color)
                .wrap(node.wrap),
        )
        .width(size(node.width))
        .height(size(node.height)),
    );
}

fn button(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode<'_>) {
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
    let mut conf = ElementConf::default()
        .id(id)
        .width(size(node.width))
        .height(size(node.height))
        .padding(Padding::symmetric(10.0, 4.0))
        .align_x(Align::Center)
        .align_y(Align::Center)
        .background(if sense.hovered {
            style.button_hover
        } else {
            style.button_background
        })
        .corner_radius(style.corner_radius);
    if node.min_width > 0.0 {
        conf = conf.min_width(node.min_width);
    }
    if node.max_width > 0.0 {
        conf = conf.max_width(node.max_width);
    }
    if node.min_height > 0.0 {
        conf = conf.min_height(node.min_height);
    }
    if node.max_height > 0.0 {
        conf = conf.max_height(node.max_height);
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
        ctx.events.push(action);
    }
}

fn image(ctx: &mut Ctx<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode<'_>) {
    let style = ctx.style;
    let Some(data) = find_image(ctx, node.image) else {
        return; // unknown key: draw nothing, the module already validated
    };
    let mut conf = ElementConf::default()
        .image(
            data.image,
            V2 {
                x: data.width,
                y: data.height,
            },
        )
        .width(size(node.width))
        .height(size(node.height));
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

fn list(ctx: &mut Ctx<'_>, module: &UiModule<'_>, ui: &mut ui::Ui<'_, '_>, node: UiNode<'_>) {
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
    let hovered = ui.hovered(id);
    let rows = ctx
        .data
        .lists
        .iter()
        .find(|list| list.id == list_id)
        .map_or(&[][..], |list| list.rows);
    let template = node.template;
    ui.add_with(conf, |ui| {
        if template != 0 {
            let template_node = module.nodes[template as usize];
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
                    walk(ctx, module, ui, template_node.first_child);
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
    use crate::layout::{Engine, Input, Rectangle};
    use crate::ir::{self, Binding, ListData};

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

    fn people(arena: &Arena) -> UiData<'_> {
        let bindings = arena.alloc_slice_copy(&[
            Binding {
                key: "ID",
                value: "7",
            },
            Binding {
                key: "NAME",
                value: "Livia",
            },
        ]);
        let rows = arena.alloc_slice_copy(&[Row { bindings }]);
        UiData {
            lists: arena.alloc_slice_copy(&[ListData {
                id: "people_list",
                rows,
            }]),
            ..UiData::default()
        }
    }

    #[test]
    fn resolve_interpolates_and_keeps_missing_vars_literal() {
        let frame = Arena::new();
        let bindings = [Binding {
            key: "ID",
            value: "42",
        }];
        let ctx = Ctx {
            frame: &frame,
            data: UiData::default(),
            events: AVec::new_in(&frame),
            style: Style::default(),
            auto_id: 0,
            row: Row {
                bindings: &bindings,
            },
        };
        let segs = [
            crate::ir::Seg {
                literal: "hire ",
                var: "",
            },
            crate::ir::Seg {
                literal: "$ID",
                var: "ID",
            },
            crate::ir::Seg {
                literal: " $MISSING",
                var: "MISSING",
            },
        ];
        let text = Text { segs: &segs };
        assert_eq!(resolve(&ctx, text), "hire 42 $MISSING");
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
        let module_arena = Arena::new();
        let module = ir::compile(&module_arena, SOURCE);
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let mut engine = Engine::default();
        let mut frame = Arena::new();
        let measure = |_: &str, _, _| V2::default();

        // Panel padding 12, gap 8: buttons at y = 12 and 50, the list's row
        // at y = 88. A frame with no input establishes the bounds `sense`
        // reads on the next one.
        let mut click_at = |arena: &mut Arena, x: f32, y: f32, pressed: bool| {
            arena.reset();
            let data = people(arena);
            let mut probe = input(400.0, 400.0);
            probe.mouse_pos = V2 { x, y };
            probe.mouse_pressed = pressed;
            let mut events: Vec<String> = Vec::new();
            engine.layout(probe, measure, |ui| {
                events = run(&module, data, arena, ui)
                    .iter()
                    .map(|action| action.to_string())
                    .collect();
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
    fn logical_sizes_map_to_layout_sizes() {
        let grow = Size {
            kind: SizeKind::Grow,
            value: 1.0,
        };
        let weighted = Size {
            kind: SizeKind::Grow,
            value: 2.0,
        };
        let fraction = Size {
            kind: SizeKind::Fraction,
            value: 0.92,
        };
        assert_eq!(size(Size::default()), LogicalSize::Fit);
        assert_eq!(size(grow), LogicalSize::Grow);
        assert_eq!(size(weighted), LogicalSize::GrowWeighted(2.0));
        assert_eq!(size(fraction), LogicalSize::Parent(0.92));
    }
}
