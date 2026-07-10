//! Small, renderer-independent, Clay-inspired immediate-mode UI layout.
//!
//! Deferred features: richer typography, custom render commands, per-edge
//! borders, visibility culling, aspect-ratio-preserving image sizing,
//! floating attachment to arbitrary elements by id, structured errors and
//! duplicate-ID diagnostics, transitions, drag and touch input with pointer
//! capture, and debug inspection.

use std::collections::{BTreeMap, HashMap};

use arena::{AVec, Arena};

#[derive(Clone, Copy)]
pub struct Output<'a> {
    commands: &'a [DrawCommand<'a>],
    is_pointer_over_ui: bool,
    duplicate_ids: &'a [ElementId],
}

impl<'a> Output<'a> {
    pub fn commands(self) -> &'a [DrawCommand<'a>] {
        self.commands
    }

    pub fn is_pointer_over_ui(self) -> bool {
        self.is_pointer_over_ui
    }

    /// Ids declared by more than one element this frame, once per extra
    /// occurrence. Duplicates corrupt everything keyed on identity — sense,
    /// hover, scroll state — so treat any entry as a bug in the UI
    /// declaration. Also fires on the (vanishingly rare) hash collision
    /// between distinct names.
    pub fn duplicate_ids(self) -> &'a [ElementId] {
        self.duplicate_ids
    }
}

impl<'a> core::ops::Deref for Output<'a> {
    type Target = [DrawCommand<'a>];

    fn deref(&self) -> &Self::Target {
        self.commands
    }
}

#[derive(Default)]
pub struct Engine {
    arena: Arena,
    previous_bounds: BTreeMap<ElementId, Rectangle>,
    current_bounds: BTreeMap<ElementId, Rectangle>,
    text_measurements: TextCache,
    scroll_states: BTreeMap<ElementId, ScrollState>,
    // TODO: Persistent transition state belongs here rather than in the
    // frame arena.
}

impl Engine {
    pub fn layout<'a, M, T>(
        &'a mut self,
        input: Input,
        measure_text: M,
        build: impl FnOnce(&mut Ui<'a, '_>),
    ) -> Output<'a>
    where
        M: Fn(&str, FontId, u16) -> T,
        T: Into<TextMetrics>,
    {
        let Self {
            arena,
            previous_bounds,
            current_bounds,
            text_measurements,
            scroll_states,
        } = self;
        arena.reset();
        current_bounds.clear();
        text_measurements.begin_frame();
        apply_wheel(scroll_states, input);

        let mut nodes = AVec::new_in(arena);
        nodes.push(Element {
            id: ElementId::ROOT,
            width: LogicalSize::Grow,
            height: LogicalSize::Grow,
            direction: Direction::TopToBottom,
            bounds: input.bounds,
            ..Element::default()
        });

        let mut parents = AVec::new_in(arena);
        parents.push(0usize);
        {
            let mut ui = Ui {
                arena,
                nodes: &mut nodes,
                parents: &mut parents,
                previous_bounds,
                scroll_states,
                input,
            };
            build(&mut ui);
        }

        measure_text_elements(arena, &mut nodes, text_measurements, &measure_text, false);
        measure_elements(&mut nodes);
        nodes[0].bounds = input.bounds;
        arrange_children(0, &mut nodes);
        measure_text_elements(arena, &mut nodes, text_measurements, &measure_text, true);
        measure_elements(&mut nodes);
        nodes[0].bounds = input.bounds;
        arrange_children(0, &mut nodes);

        let mut duplicate_ids = AVec::new_in(arena);
        record_bounds(0, UNCLIPPED, &nodes, current_bounds, &mut duplicate_ids);

        for state in scroll_states.values_mut() {
            state.live = false;
        }
        for (index, node) in nodes.iter().enumerate() {
            if !node.clip {
                continue;
            }
            let state = scroll_states.entry(node.id).or_default();
            state.max_offset = V2 {
                x: (node.content_size.x
                    - (node.bounds.w - node.padding.left - node.padding.right).max(0.0))
                .max(0.0),
                y: (node.content_size.y
                    - (node.bounds.h - node.padding.top - node.padding.bottom).max(0.0))
                .max(0.0),
            };
            state.offset.x = state.offset.x.clamp(0.0, state.max_offset.x);
            state.offset.y = state.offset.y.clamp(0.0, state.max_offset.y);
            state.horizontal = node.scroll_x;
            state.vertical = node.scroll_y;
            state.order = index as u32;
            state.visible_bounds = current_bounds.get(&node.id).copied().unwrap_or(node.bounds);
            state.live = true;
        }
        scroll_states.retain(|_, state| state.live);

        let mut commands = AVec::new_in(arena);
        emit_children(0, &nodes, &mut commands);
        // Floating subtrees draw above the normal tree, lowest z first;
        // equal z keeps declaration order via the node index.
        let mut floating = AVec::new_in(arena);
        for (index, node) in nodes.iter().enumerate() {
            if node.floating {
                floating.push((node.z_index, index));
            }
        }
        let floating = floating.into_slice();
        floating.sort_unstable();
        for &(_, index) in floating.iter() {
            emit_element(index, &nodes, &mut commands);
        }
        // Invisible containers are layout scaffolding and should not capture
        // map/game input. A visible render primitive defines the UI surface,
        // shrunk to what enclosing clip regions leave visible.
        let mut clip_stack = AVec::new_in(arena);
        let mut is_pointer_over_ui = false;
        for command in commands.iter() {
            match command.kind {
                DrawKind::ClipStart => {
                    let clip = clip_stack.last().copied().unwrap_or(UNCLIPPED);
                    clip_stack.push(clip.intersect(command.bounds));
                }
                DrawKind::ClipEnd => {
                    clip_stack.pop();
                }
                _ => {
                    let clip = clip_stack.last().copied().unwrap_or(UNCLIPPED);
                    is_pointer_over_ui = is_pointer_over_ui
                        || command.bounds.intersect(clip).contains(input.mouse_pos);
                }
            }
        }
        std::mem::swap(previous_bounds, current_bounds);
        Output {
            commands: commands.into_slice(),
            is_pointer_over_ui,
            duplicate_ids: duplicate_ids.into_slice(),
        }
    }

    pub fn clear_text_cache(&mut self) {
        self.text_measurements.clear();
    }
}

/// Persistent scroll state for one clipping element, carried across frames
/// by `ElementId` like `previous_bounds`.
#[derive(Clone, Copy, Default)]
struct ScrollState {
    /// How far the content is scrolled; children shift by its negation.
    offset: V2,
    /// Content overhang beyond the inner bounds as of last frame; `offset`
    /// clamps to `0..=max_offset` per axis.
    max_offset: V2,
    /// Clip-intersected bounds from last frame, for wheel targeting.
    visible_bounds: Rectangle,
    horizontal: bool,
    vertical: bool,
    /// Index in last frame's element tree; children sort after parents, so
    /// the innermost scroll region under the pointer wins.
    order: u32,
    /// Present in the current frame; stale states are pruned.
    live: bool,
}

fn apply_wheel(scroll_states: &mut BTreeMap<ElementId, ScrollState>, input: Input) {
    if input.wheel.x == 0.0 && input.wheel.y == 0.0 {
        return;
    }
    let target = scroll_states
        .iter()
        .filter(|(_, state)| {
            (state.horizontal || state.vertical) && state.visible_bounds.contains(input.mouse_pos)
        })
        .max_by_key(|(_, state)| state.order)
        .map(|(&id, _)| id);
    let Some(state) = target.and_then(|id| scroll_states.get_mut(&id)) else {
        return;
    };
    if state.horizontal {
        state.offset.x = (state.offset.x - input.wheel.x).clamp(0.0, state.max_offset.x);
    }
    if state.vertical {
        state.offset.y = (state.offset.y - input.wheel.y).clamp(0.0, state.max_offset.y);
    }
}

#[derive(Clone, Copy, Default)]
pub struct Input {
    pub bounds: Rectangle,
    pub mouse_pos: V2,
    /// The primary button went down this frame.
    pub mouse_pressed: bool,
    /// The primary button is currently held.
    pub mouse_down: bool,
    /// The primary button came up this frame.
    pub mouse_released: bool,
    /// Scroll delta for this frame; positive `y` (wheel up) scrolls back
    /// toward the start of the content.
    pub wheel: V2,
    // TODO: Add drag, touch, and pointer-capture state.
}

#[derive(Clone, Copy, PartialEq, PartialOrd, Default, Debug)]
pub struct V2 {
    pub x: f32,
    pub y: f32,
}

#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct TextMetrics {
    pub size: V2,
    /// Distance from the top of the measured box to the drawing baseline.
    pub baseline: f32,
}

impl From<V2> for TextMetrics {
    fn from(size: V2) -> Self {
        Self {
            size,
            baseline: size.y,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug, Hash)]
pub struct FontId(pub u64);

/// Opaque handle to a renderer-owned texture; `0` means no image.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug, Hash)]
pub struct ImageId(pub u64);

#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct Rectangle {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rectangle {
    pub fn contains(self, point: V2) -> bool {
        point.x >= self.x
            && point.y >= self.y
            && point.x < self.x + self.w
            && point.y < self.y + self.h
    }

    pub fn intersect(self, other: Rectangle) -> Rectangle {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        Rectangle {
            x,
            y,
            w: ((self.x + self.w).min(other.x + other.w) - x).max(0.0),
            h: ((self.y + self.h).min(other.y + other.h) - y).max(0.0),
        }
    }
}

/// The clip state of elements outside any clipping container: a rectangle
/// so large that intersecting with it changes nothing.
const UNCLIPPED: Rectangle = Rectangle {
    x: f32::MIN / 2.0,
    y: f32::MIN / 2.0,
    w: f32::MAX,
    h: f32::MAX,
};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct ElementId(pub u64);

impl ElementId {
    const ROOT: Self = Self(u64::MAX);

    pub fn named(name: &str) -> Self {
        let mut hash = 0xcbf29ce484222325u64;
        for byte in name.bytes() {
            hash ^= byte as u64;
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Self(hash.max(1))
    }

    /// A name plus a counter, for elements declared in loops:
    /// `.id(("row", index))`. Distinct from `named(name)` and from every
    /// other index.
    pub fn indexed(name: &str, index: u32) -> Self {
        Self::named(name).child(index)
    }

    fn child(self, index: u32) -> Self {
        let hash = self
            .0
            .wrapping_mul(0x9e3779b185ebca87)
            .wrapping_add(index as u64 + 1);
        Self(hash.max(1))
    }
}

impl From<&str> for ElementId {
    fn from(value: &str) -> Self {
        Self::named(value)
    }
}

impl From<(&str, u32)> for ElementId {
    fn from((name, index): (&str, u32)) -> Self {
        Self::indexed(name, index)
    }
}

#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    pub const fn rgba(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }
}

#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct Padding {
    pub left: f32,
    pub right: f32,
    pub top: f32,
    pub bottom: f32,
}

impl Padding {
    pub const fn all(value: f32) -> Self {
        Self {
            left: value,
            right: value,
            top: value,
            bottom: value,
        }
    }

    pub const fn symmetric(horizontal: f32, vertical: f32) -> Self {
        Self {
            left: horizontal,
            right: horizontal,
            top: vertical,
            bottom: vertical,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Default, Debug)]
pub struct Border {
    pub width: f32,
    pub color: Color,
    pub radius: f32,
    // TODO: Replace the uniform width with per-edge widths.
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum Direction {
    #[default]
    LeftToRight,
    TopToBottom,
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum Align {
    #[default]
    Start,
    Center,
    End,
}

/// A point on a rectangle, for pinning floating elements.
#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum Anchor {
    #[default]
    TopLeft,
    TopCenter,
    TopRight,
    CenterLeft,
    Center,
    CenterRight,
    BottomLeft,
    BottomCenter,
    BottomRight,
}

fn anchor_factors(anchor: Anchor) -> V2 {
    let (x, y) = match anchor {
        Anchor::TopLeft => (0.0, 0.0),
        Anchor::TopCenter => (0.5, 0.0),
        Anchor::TopRight => (1.0, 0.0),
        Anchor::CenterLeft => (0.0, 0.5),
        Anchor::Center => (0.5, 0.5),
        Anchor::CenterRight => (1.0, 0.5),
        Anchor::BottomLeft => (0.0, 1.0),
        Anchor::BottomCenter => (0.5, 1.0),
        Anchor::BottomRight => (1.0, 1.0),
    };
    V2 { x, y }
}

#[derive(Clone, Copy, PartialEq, PartialOrd, Default, Debug)]
pub enum LogicalSize {
    #[default]
    Fit,
    Grow,
    GrowWeighted(f32),
    Pixels(f32),
    Parent(f32),
}

#[derive(Default, Clone, Copy, Debug)]
pub struct Text<'a> {
    pub text: &'a str,
    pub font: FontId,
    pub size: u16,
    pub color: Color,
}

#[derive(Default, Clone, Copy)]
pub struct TextConf<'a> {
    text: &'a str,
    font: FontId,
    size: u16,
    color: Color,
    wrap: bool,
    // TODO: Add line height, letter spacing, and text alignment.
}

impl<'a> TextConf<'a> {
    pub fn text(mut self, text: &'a str) -> Self {
        self.text = text;
        self
    }

    pub fn size(mut self, size: u16) -> Self {
        self.size = size;
        self
    }

    pub fn font(mut self, font: FontId) -> Self {
        self.font = font;
        self
    }

    pub fn color(mut self, color: Color) -> Self {
        self.color = color;
        self
    }

    pub fn wrap(mut self, wrap: bool) -> Self {
        self.wrap = wrap;
        self
    }
}

#[derive(Clone, Copy)]
pub struct ElementConf<'a> {
    id: ElementId,
    width: LogicalSize,
    height: LogicalSize,
    min_width: f32,
    max_width: f32,
    min_height: f32,
    max_height: f32,
    direction: Direction,
    align_x: Align,
    align_y: Align,
    padding: Padding,
    gap: f32,
    background: Color,
    border: Border,
    text: TextConf<'a>,
    clip: bool,
    scroll_x: bool,
    scroll_y: bool,
    floating: bool,
    z_index: i16,
    anchor_parent: V2,
    anchor_self: V2,
    float_offset: V2,
    image: ImageId,
    image_source: V2,
    image_tint: Color,
    image_fade: f32,
    // TODO: Custom data extends the declaration here and becomes additional
    // render commands.
}

impl Default for ElementConf<'_> {
    fn default() -> Self {
        Self {
            id: ElementId::default(),
            width: LogicalSize::Fit,
            height: LogicalSize::Fit,
            min_width: 0.0,
            max_width: 0.0,
            min_height: 0.0,
            max_height: 0.0,
            direction: Direction::default(),
            align_x: Align::default(),
            align_y: Align::default(),
            padding: Padding::default(),
            gap: 0.0,
            background: Color::default(),
            border: Border::default(),
            text: TextConf::default(),
            clip: false,
            scroll_x: false,
            scroll_y: false,
            floating: false,
            z_index: 0,
            anchor_parent: V2 { x: 0.0, y: 0.0 },
            anchor_self: V2 { x: 0.0, y: 0.0 },
            float_offset: V2 { x: 0.0, y: 0.0 },
            image: ImageId::default(),
            image_source: V2 { x: 0.0, y: 0.0 },
            image_tint: Color::default(),
            image_fade: 0.0,
        }
    }
}

impl<'a> ElementConf<'a> {
    pub fn id(mut self, id: impl Into<ElementId>) -> Self {
        self.id = id.into();
        self
    }

    pub fn width(mut self, size: LogicalSize) -> Self {
        self.width = size;
        self
    }

    pub fn height(mut self, size: LogicalSize) -> Self {
        self.height = size;
        self
    }

    pub fn min_width(mut self, width: f32) -> Self {
        self.min_width = width.max(0.0);
        self
    }

    pub fn max_width(mut self, width: f32) -> Self {
        self.max_width = width.max(0.0);
        self
    }

    pub fn min_height(mut self, height: f32) -> Self {
        self.min_height = height.max(0.0);
        self
    }

    pub fn max_height(mut self, height: f32) -> Self {
        self.max_height = height.max(0.0);
        self
    }

    pub fn direction(mut self, direction: Direction) -> Self {
        self.direction = direction;
        self
    }

    pub fn align_x(mut self, align: Align) -> Self {
        self.align_x = align;
        self
    }

    pub fn align_y(mut self, align: Align) -> Self {
        self.align_y = align;
        self
    }

    pub fn padding(mut self, padding: Padding) -> Self {
        self.padding = Padding {
            left: padding.left.max(0.0),
            right: padding.right.max(0.0),
            top: padding.top.max(0.0),
            bottom: padding.bottom.max(0.0),
        };
        self
    }

    pub fn gap(mut self, gap: f32) -> Self {
        self.gap = gap.max(0.0);
        self
    }

    pub fn background(mut self, color: Color) -> Self {
        self.background = color;
        self
    }

    pub fn border(mut self, width: f32, color: Color) -> Self {
        self.border = Border {
            width: width.max(0.0),
            color,
            ..self.border
        };
        self
    }

    pub fn corner_radius(mut self, radius: f32) -> Self {
        self.border.radius = radius.max(0.0);
        self
    }

    /// Clips children and text to this element's bounds.
    pub fn clip(mut self, clip: bool) -> Self {
        self.clip = clip;
        self
    }

    /// Makes this element a scroll region on the given axes; scrolling
    /// implies clipping. Give the element a non-`Fit` size on a scrolling
    /// axis — `Fit` grows to the content, leaving nothing to scroll.
    pub fn scroll(mut self, horizontal: bool, vertical: bool) -> Self {
        self.scroll_x = horizontal;
        self.scroll_y = vertical;
        self.clip = self.clip || horizontal || vertical;
        self
    }

    /// Removes the element from its parent's flow and pins `self_anchor` on
    /// this element to `parent_anchor` on the parent's final bounds instead.
    /// Floating elements take no flow space, escape ancestor clipping, and
    /// draw above the normal tree ordered by `z_index`. `Grow` and `Parent`
    /// sizes resolve against the parent's outer bounds, so a `Grow` float
    /// declared at the top level covers the whole viewport (a modal).
    pub fn floating(self, parent_anchor: Anchor, self_anchor: Anchor) -> Self {
        self.floating_at(anchor_factors(parent_anchor), anchor_factors(self_anchor))
    }

    /// [`floating`](Self::floating) with anchors as fractional factors of
    /// each rectangle instead of the nine named points: `{0.5, 0.5}` is the
    /// center, `{1.0, 0.0}` the top-right. Pinning the same factor on both
    /// rectangles gives CSS background-position semantics — 0.0 flush left,
    /// 0.5 centered, 1.0 flush right, 0.1 inset by 10% of the slack.
    pub fn floating_at(mut self, parent_factors: V2, self_factors: V2) -> Self {
        self.floating = true;
        self.anchor_parent = parent_factors;
        self.anchor_self = self_factors;
        self
    }

    /// Extra displacement applied after the anchors are pinned.
    pub fn float_offset(mut self, x: f32, y: f32) -> Self {
        self.float_offset = V2 { x, y };
        self
    }

    /// Draw order among floating elements; higher draws on top. Ties keep
    /// declaration order.
    pub fn z_index(mut self, z_index: i16) -> Self {
        self.z_index = z_index;
        self
    }

    /// Draws a texture stretched over the element's bounds. `source_size`
    /// is the texture's natural size in pixels; it becomes the element's
    /// intrinsic size, so `Fit` axes take the image's own dimensions while
    /// explicit sizes stretch it. The renderer resolves the handle.
    pub fn image(mut self, image: ImageId, source_size: V2) -> Self {
        self.image = image;
        self.image_source = source_size;
        self
    }

    /// Tint multiplied over the image; the zero color means untinted.
    pub fn image_tint(mut self, color: Color) -> Self {
        self.image_tint = color;
        self
    }

    /// Fades the image toward whatever draws beneath it (the element's
    /// background): `0.0` draws the image fully, `1.0` hides it entirely,
    /// values between blend by transparency.
    pub fn image_fade(mut self, fade: f32) -> Self {
        self.image_fade = fade.clamp(0.0, 1.0);
        self
    }

    pub fn text(text: TextConf<'a>) -> Self {
        Self {
            text,
            ..Self::default()
        }
    }
}

#[derive(Default, Clone, Copy, PartialEq, Eq, Debug)]
pub struct Sense {
    pub clicked: bool,
    pub hovered: bool,
}

pub struct Ui<'arena, 'frame> {
    arena: &'arena Arena,
    nodes: &'frame mut AVec<'arena, Element<'arena>>,
    parents: &'frame mut AVec<'arena, usize>,
    previous_bounds: &'frame BTreeMap<ElementId, Rectangle>,
    scroll_states: &'frame BTreeMap<ElementId, ScrollState>,
    input: Input,
}

impl<'arena, 'frame> Ui<'arena, 'frame> {
    pub fn add(&mut self, conf: ElementConf<'_>) -> Sense {
        let (_, sense) = self.push(conf);
        sense
    }

    pub fn add_with(&mut self, conf: ElementConf<'_>, body: impl FnOnce(&mut Self)) -> Sense {
        assert!(
            conf.text.text.is_empty(),
            "text elements cannot have children"
        );
        let (index, sense) = self.push(conf);
        self.parents.push(index);
        body(self);
        self.parents.pop();
        sense
    }

    fn push(&mut self, conf: ElementConf<'_>) -> (usize, Sense) {
        let parent = *self.parents.last().unwrap();
        let ordinal = self.nodes[parent].child_count;
        let id = if conf.id == ElementId::default() {
            self.nodes[parent].id.child(ordinal)
        } else {
            conf.id
        };
        let sense = self.sense(id);
        let scroll_offset = if conf.clip {
            self.scroll_states
                .get(&id)
                .map_or(V2::default(), |state| state.offset)
        } else {
            V2::default()
        };
        let text = if conf.text.text.is_empty() {
            ""
        } else {
            self.arena.alloc_str(conf.text.text)
        };
        let index = self.nodes.len();
        self.nodes.push(Element {
            id,
            width: conf.width,
            height: conf.height,
            min_width: conf.min_width,
            max_width: conf.max_width,
            min_height: conf.min_height,
            max_height: conf.max_height,
            direction: conf.direction,
            align_x: conf.align_x,
            align_y: conf.align_y,
            padding: conf.padding,
            gap: conf.gap,
            background: conf.background,
            border: conf.border,
            text: Text {
                text,
                font: conf.text.font,
                size: conf.text.size,
                color: conf.text.color,
            },
            wrap_text: conf.text.wrap,
            clip: conf.clip,
            scroll_x: conf.scroll_x,
            scroll_y: conf.scroll_y,
            scroll_offset,
            floating: conf.floating,
            z_index: conf.z_index,
            anchor_parent: conf.anchor_parent,
            anchor_self: conf.anchor_self,
            float_offset: conf.float_offset,
            image: conf.image,
            image_source: conf.image_source,
            image_tint: conf.image_tint,
            image_fade: conf.image_fade,
            ..Element::default()
        });

        let previous = self.nodes[parent].last_child;
        if previous == 0 {
            self.nodes[parent].first_child = index;
        } else {
            self.nodes[previous].next_sibling = index;
        }
        self.nodes[parent].last_child = index;
        self.nodes[parent].child_count += 1;
        (index, sense)
    }

    /// Whether the pointer was over this element last frame. Shorthand for
    /// `sense(id).hovered`.
    pub fn hovered(&self, id: impl Into<ElementId>) -> bool {
        self.sense(id).hovered
    }

    /// The element's interaction state, judged against last frame's clipped
    /// bounds (one frame of latency). Queryable before the element is
    /// declared, which is what styling needs — the `Sense` returned by `add`
    /// arrives after the element's looks are already committed:
    ///
    /// ```ignore
    /// let hovered = ui.sense("button").hovered;
    /// ui.add(conf.id("button").background(if hovered { HI } else { LO }));
    /// ```
    pub fn sense(&self, id: impl Into<ElementId>) -> Sense {
        let id = id.into();
        let hovered = self
            .previous_bounds
            .get(&id)
            .is_some_and(|bounds| bounds.contains(self.input.mouse_pos));
        Sense {
            hovered,
            clicked: hovered && self.input.mouse_pressed,
        }
    }
}

#[derive(Clone, Copy, Default)]
struct TextLine<'a> {
    text: &'a str,
    metrics: TextMetrics,
}

#[derive(Clone, Copy, Default)]
struct Element<'a> {
    id: ElementId,
    first_child: usize,
    last_child: usize,
    next_sibling: usize,
    child_count: u32,
    width: LogicalSize,
    height: LogicalSize,
    min_width: f32,
    max_width: f32,
    min_height: f32,
    max_height: f32,
    direction: Direction,
    align_x: Align,
    align_y: Align,
    padding: Padding,
    gap: f32,
    background: Color,
    border: Border,
    text: Text<'a>,
    wrap_text: bool,
    clip: bool,
    scroll_x: bool,
    scroll_y: bool,
    scroll_offset: V2,
    content_size: V2,
    floating: bool,
    z_index: i16,
    anchor_parent: V2,
    anchor_self: V2,
    float_offset: V2,
    image: ImageId,
    image_source: V2,
    image_tint: Color,
    image_fade: f32,
    text_lines: &'a [TextLine<'a>],
    measured_text: V2,
    intrinsic: V2,
    resolved_main: f32,
    bounds: Rectangle,
}

#[derive(Clone, Copy, PartialEq, Eq, Default, Debug)]
pub enum DrawKind {
    #[default]
    None,
    Rectangle,
    Text,
    Border,
    /// Draw the texture behind `image`, stretched over `bounds` and
    /// multiplied by `color`.
    Image,
    /// Restrict drawing to `bounds` (intersected with any enclosing clip)
    /// until the matching `ClipEnd`.
    ClipStart,
    ClipEnd,
    // TODO: Add custom command kinds here.
}

#[derive(Default, Clone, Copy, Debug)]
pub struct DrawCommand<'a> {
    pub kind: DrawKind,
    pub id: ElementId,
    pub bounds: Rectangle,
    pub color: Color,
    pub text: Text<'a>,
    pub text_baseline: f32,
    pub border_width: f32,
    pub corner_radius: f32,
    pub image: ImageId,
}

fn measure_text_elements<'a, M, T>(
    arena: &'a Arena,
    nodes: &mut [Element<'a>],
    cache: &mut TextCache,
    measure_text: &M,
    wrap: bool,
) where
    M: Fn(&str, FontId, u16) -> T,
    T: Into<TextMetrics>,
{
    for index in 0..nodes.len() {
        let node = nodes[index];
        if wrap && !node.wrap_text {
            continue;
        }
        if node.text.text.is_empty() {
            nodes[index].text_lines = &[];
            nodes[index].measured_text = V2::default();
            continue;
        }
        let max_width = if wrap && node.wrap_text {
            (node.bounds.w - node.padding.left - node.padding.right).max(0.0)
        } else {
            f32::INFINITY
        };
        let (lines, measured) = break_text_lines(arena, node.text, max_width, cache, measure_text);
        nodes[index].text_lines = lines;
        nodes[index].measured_text = measured;
    }
}

fn break_text_lines<'a, M, T>(
    arena: &'a Arena,
    text: Text<'a>,
    max_width: f32,
    cache: &mut TextCache,
    measure_text: &M,
) -> (&'a [TextLine<'a>], V2)
where
    M: Fn(&str, FontId, u16) -> T,
    T: Into<TextMetrics>,
{
    let mut lines = AVec::new_in(arena);
    let mut measured = V2::default();
    if !max_width.is_finite() {
        for line in text.text.split('\n') {
            push_text_line(&mut lines, line, text, cache, measure_text, &mut measured);
        }
        return (lines.into_slice(), measured);
    }
    let mut line_start = 0usize;

    loop {
        if line_start == text.text.len() {
            if text.text.ends_with('\n') {
                push_text_line(&mut lines, "", text, cache, measure_text, &mut measured);
            }
            break;
        }

        let mut cursor = line_start;
        let mut best_end = line_start;
        let mut last_break = None;
        let mut emitted = false;
        while cursor < text.text.len() {
            let character = text.text[cursor..].chars().next().unwrap();
            let next = cursor + character.len_utf8();
            if character == '\n' {
                push_text_line(
                    &mut lines,
                    text.text[line_start..cursor].trim_end(),
                    text,
                    cache,
                    measure_text,
                    &mut measured,
                );
                line_start = next;
                emitted = true;
                break;
            }

            let candidate = text.text[line_start..next].trim_end();
            let candidate_metrics = cache.measure(measure_text, candidate, text.font, text.size);
            if candidate_metrics.size.x > max_width && best_end > line_start {
                let line_end = last_break
                    .filter(|&index| index > line_start)
                    .unwrap_or(best_end);
                push_text_line(
                    &mut lines,
                    text.text[line_start..line_end].trim_end(),
                    text,
                    cache,
                    measure_text,
                    &mut measured,
                );
                line_start = line_end;
                while line_start < text.text.len() {
                    let leading = text.text[line_start..].chars().next().unwrap();
                    if leading == '\n' || !leading.is_whitespace() {
                        break;
                    }
                    line_start += leading.len_utf8();
                }
                emitted = true;
                break;
            }
            if candidate_metrics.size.x > max_width {
                push_text_line(
                    &mut lines,
                    &text.text[line_start..next],
                    text,
                    cache,
                    measure_text,
                    &mut measured,
                );
                line_start = next;
                emitted = true;
                break;
            }

            if character.is_whitespace() {
                last_break = Some(cursor);
            }
            best_end = next;
            cursor = next;
        }

        if emitted {
            continue;
        }
        push_text_line(
            &mut lines,
            text.text[line_start..].trim_end(),
            text,
            cache,
            measure_text,
            &mut measured,
        );
        break;
    }

    (lines.into_slice(), measured)
}

fn push_text_line<'a, M, T>(
    lines: &mut AVec<'a, TextLine<'a>>,
    line: &'a str,
    text: Text<'a>,
    cache: &mut TextCache,
    measure_text: &M,
    measured: &mut V2,
) where
    M: Fn(&str, FontId, u16) -> T,
    T: Into<TextMetrics>,
{
    let mut metrics = cache.measure(
        measure_text,
        if line.is_empty() { " " } else { line },
        text.font,
        text.size,
    );
    if line.is_empty() {
        metrics.size.x = 0.0;
    }
    measured.x = measured.x.max(metrics.size.x);
    measured.y += metrics.size.y;
    lines.push(TextLine {
        text: line,
        metrics,
    });
}

/// A cached measurement. The measured text is never stored — the map key is
/// a hash of (font, size, text) — so a 64-bit hash collision silently shares
/// a measurement, as in Clay.
#[derive(Clone, Copy, Default)]
struct TextCacheEntry {
    /// Frame of the last hit; entries not hit for a full frame are evicted
    /// at the start of the next one.
    generation: u32,
    metrics: TextMetrics,
}

/// Persistent, Clay-style measurement cache. Keying by hash means it borrows
/// nothing from the frame arena, and generational eviction bounds it to
/// roughly the text measured in the last frame.
#[derive(Default)]
struct TextCache {
    entries: HashMap<u64, TextCacheEntry>,
    generation: u32,
}

impl TextCache {
    fn begin_frame(&mut self) {
        let previous = self.generation;
        self.generation = self.generation.wrapping_add(1);
        self.entries.retain(|_, entry| entry.generation == previous);
    }

    fn clear(&mut self) {
        self.entries.clear();
    }

    fn measure<M, T>(
        &mut self,
        measure_text: &M,
        text: &str,
        font: FontId,
        size: u16,
    ) -> TextMetrics
    where
        M: Fn(&str, FontId, u16) -> T,
        T: Into<TextMetrics>,
    {
        let hash = hash_text(text, font, size);
        if let Some(entry) = self.entries.get_mut(&hash) {
            entry.generation = self.generation;
            return entry.metrics;
        }
        let metrics = measure_text(text, font, size).into();
        self.entries.insert(
            hash,
            TextCacheEntry {
                generation: self.generation,
                metrics,
            },
        );
        metrics
    }
}

fn hash_text(text: &str, font: FontId, size: u16) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for byte in font
        .0
        .to_le_bytes()
        .into_iter()
        .chain(size.to_le_bytes())
        .chain(text.bytes())
    {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn measure_elements(nodes: &mut [Element<'_>]) {
    for index in (0..nodes.len()).rev() {
        let node = nodes[index];

        let mut child = node.first_child;
        let mut child_count = 0usize;
        let mut main = 0.0f32;
        let mut cross = 0.0f32;
        while child != 0 {
            // Floating children take no flow space.
            if nodes[child].floating {
                child = nodes[child].next_sibling;
                continue;
            }
            let size = nodes[child].intrinsic;
            match node.direction {
                Direction::LeftToRight => {
                    main += size.x;
                    cross = cross.max(size.y);
                }
                Direction::TopToBottom => {
                    main += size.y;
                    cross = cross.max(size.x);
                }
            }
            child_count += 1;
            child = nodes[child].next_sibling;
        }
        if child_count > 1 {
            main += node.gap * (child_count - 1) as f32;
        }

        let content = match node.direction {
            Direction::LeftToRight => V2 { x: main, y: cross },
            Direction::TopToBottom => V2 { x: cross, y: main },
        };
        // Text, image source size, and children all compete for the
        // element's natural content size.
        let natural = V2 {
            x: (node.measured_text.x.max(node.image_source.x).max(content.x)
                + node.padding.left
                + node.padding.right)
                .max(0.0),
            y: (node.measured_text.y.max(node.image_source.y).max(content.y)
                + node.padding.top
                + node.padding.bottom)
                .max(0.0),
        };
        nodes[index].intrinsic = V2 {
            x: constrain_axis(
                intrinsic_axis(node.width, natural.x),
                node.min_width,
                node.max_width,
            ),
            y: constrain_axis(
                intrinsic_axis(node.height, natural.y),
                node.min_height,
                node.max_height,
            ),
        };
    }
}

fn intrinsic_axis(size: LogicalSize, natural: f32) -> f32 {
    match size {
        LogicalSize::Pixels(value) => value.max(0.0),
        LogicalSize::Parent(_) => 0.0,
        LogicalSize::Fit | LogicalSize::Grow | LogicalSize::GrowWeighted(_) => natural,
    }
}

fn arrange_children(parent_index: usize, nodes: &mut [Element<'_>]) {
    let parent = nodes[parent_index];
    if parent.first_child == 0 {
        return;
    }

    // Scroll offsets shift where children are placed, not how much room
    // they are given.
    let inner = Rectangle {
        x: parent.bounds.x + parent.padding.left - parent.scroll_offset.x,
        y: parent.bounds.y + parent.padding.top - parent.scroll_offset.y,
        w: (parent.bounds.w - parent.padding.left - parent.padding.right).max(0.0),
        h: (parent.bounds.h - parent.padding.top - parent.padding.bottom).max(0.0),
    };
    let horizontal = parent.direction == Direction::LeftToRight;
    let available_main = if horizontal { inner.w } else { inner.h };
    let available_cross = if horizontal { inner.h } else { inner.w };
    let mut child = parent.first_child;
    let mut flow_count = 0u32;
    let mut fixed_main = 0.0;
    let mut fixed_minimum = 0.0;
    let mut has_grow = false;
    let mut grow_minimum = 0.0;
    let mut minimum_positive_weight = f32::INFINITY;
    while child != 0 {
        let node = nodes[child];
        if node.floating {
            child = node.next_sibling;
            continue;
        }
        flow_count += 1;
        let size = if horizontal { node.width } else { node.height };
        let (min, max) = axis_constraints(node, horizontal);
        if let Some(weight) = grow_weight(size) {
            has_grow = true;
            grow_minimum += min;
            if weight > 0.0 {
                minimum_positive_weight = minimum_positive_weight.min(weight);
            }
        } else {
            let resolved = constrain_axis(
                resolve_axis(
                    size,
                    available_main,
                    if horizontal {
                        node.intrinsic.x
                    } else {
                        node.intrinsic.y
                    },
                ),
                min,
                max,
            );
            nodes[child].resolved_main = resolved;
            fixed_main += resolved;
            fixed_minimum += min;
        }
        child = node.next_sibling;
    }
    let gap_total = parent.gap * flow_count.saturating_sub(1) as f32;

    let scrolls_main = if horizontal {
        parent.scroll_x
    } else {
        parent.scroll_y
    };
    // A scrolling main axis lets content overflow instead of compressing it.
    if !scrolls_main
        && fixed_main + grow_minimum + gap_total > available_main
        && fixed_main > fixed_minimum
    {
        let fixed_target = (available_main - grow_minimum - gap_total).max(fixed_minimum);
        let mut low_scale = 0.0;
        let mut high_scale = 1.0;
        if fixed_target > fixed_minimum {
            for _ in 0..32 {
                let scale = (low_scale + high_scale) * 0.5;
                let mut total = 0.0;
                child = parent.first_child;
                while child != 0 {
                    let node = nodes[child];
                    let size = if horizontal { node.width } else { node.height };
                    if !node.floating && grow_weight(size).is_none() {
                        let (min, _) = axis_constraints(node, horizontal);
                        total += (node.resolved_main * scale).max(min);
                    }
                    child = node.next_sibling;
                }
                if total < fixed_target {
                    low_scale = scale;
                } else {
                    high_scale = scale;
                }
            }
        } else {
            high_scale = 0.0;
        }

        fixed_main = 0.0;
        child = parent.first_child;
        while child != 0 {
            let node = nodes[child];
            let size = if horizontal { node.width } else { node.height };
            if !node.floating && grow_weight(size).is_none() {
                let (min, _) = axis_constraints(node, horizontal);
                nodes[child].resolved_main = (node.resolved_main * high_scale).max(min);
                fixed_main += nodes[child].resolved_main;
            }
            child = node.next_sibling;
        }
    }

    if has_grow {
        let grow_target = (available_main - fixed_main - gap_total).max(grow_minimum);
        let mut low_scale = 0.0;
        let mut high_scale = if minimum_positive_weight.is_finite() {
            grow_target / minimum_positive_weight
        } else {
            0.0
        };
        for _ in 0..32 {
            let scale = (low_scale + high_scale) * 0.5;
            let mut total = 0.0;
            child = parent.first_child;
            while child != 0 {
                let node = nodes[child];
                let size = if horizontal { node.width } else { node.height };
                if let Some(weight) = grow_weight(size).filter(|_| !node.floating) {
                    let (min, max) = axis_constraints(node, horizontal);
                    total += constrain_axis(weight * scale, min, max);
                }
                child = node.next_sibling;
            }
            if total < grow_target {
                low_scale = scale;
            } else {
                high_scale = scale;
            }
        }

        child = parent.first_child;
        while child != 0 {
            let node = nodes[child];
            let size = if horizontal { node.width } else { node.height };
            if let Some(weight) = grow_weight(size) {
                let (min, max) = axis_constraints(node, horizontal);
                nodes[child].resolved_main = constrain_axis(weight * high_scale, min, max);
            }
            child = node.next_sibling;
        }
    }

    let mut occupied = fixed_main + gap_total;
    child = parent.first_child;
    while child != 0 {
        if !nodes[child].floating
            && grow_weight(if horizontal {
                nodes[child].width
            } else {
                nodes[child].height
            })
            .is_some()
        {
            occupied += nodes[child].resolved_main;
        }
        child = nodes[child].next_sibling;
    }
    let main_align = if horizontal {
        parent.align_x
    } else {
        parent.align_y
    };
    let mut cursor = align_offset(main_align, available_main, occupied);
    let mut content_cross = 0.0f32;

    child = parent.first_child;
    while child != 0 {
        let node = nodes[child];
        if node.floating {
            child = node.next_sibling;
            continue;
        }
        let cross_size_mode = if horizontal { node.height } else { node.width };
        let cross_intrinsic = if horizontal {
            node.intrinsic.y
        } else {
            node.intrinsic.x
        };
        let (cross_min, cross_max) = axis_constraints(node, !horizontal);
        let main_size = node.resolved_main;
        let cross_size = constrain_axis(
            resolve_axis(cross_size_mode, available_cross, cross_intrinsic),
            cross_min,
            cross_max,
        );
        let cross_align = if horizontal {
            parent.align_y
        } else {
            parent.align_x
        };
        content_cross = content_cross.max(cross_size);
        let cross = align_offset(cross_align, available_cross, cross_size);

        nodes[child].bounds = if horizontal {
            Rectangle {
                x: inner.x + cursor,
                y: inner.y + cross,
                w: main_size,
                h: cross_size,
            }
        } else {
            Rectangle {
                x: inner.x + cross,
                y: inner.y + cursor,
                w: cross_size,
                h: main_size,
            }
        };
        arrange_children(child, nodes);
        cursor += main_size + parent.gap;
        child = node.next_sibling;
    }

    // Floating children are placed after flow layout, against the parent's
    // final bounds: their own anchor point lands on the parent's, plus the
    // configured offset. Sizes resolve against the parent's outer bounds.
    child = parent.first_child;
    while child != 0 {
        let node = nodes[child];
        if !node.floating {
            child = node.next_sibling;
            continue;
        }
        let size = V2 {
            x: constrain_axis(
                resolve_axis(node.width, parent.bounds.w, node.intrinsic.x),
                node.min_width,
                node.max_width,
            ),
            y: constrain_axis(
                resolve_axis(node.height, parent.bounds.h, node.intrinsic.y),
                node.min_height,
                node.max_height,
            ),
        };
        let target = V2 {
            x: parent.bounds.x + parent.bounds.w * node.anchor_parent.x,
            y: parent.bounds.y + parent.bounds.h * node.anchor_parent.y,
        };
        let factors = node.anchor_self;
        nodes[child].bounds = Rectangle {
            x: target.x + node.float_offset.x - size.x * factors.x,
            y: target.y + node.float_offset.y - size.y * factors.y,
            w: size.x,
            h: size.y,
        };
        arrange_children(child, nodes);
        child = node.next_sibling;
    }

    nodes[parent_index].content_size = if horizontal {
        V2 {
            x: occupied,
            y: content_cross,
        }
    } else {
        V2 {
            x: content_cross,
            y: occupied,
        }
    };
}

fn resolve_axis(size: LogicalSize, parent: f32, intrinsic: f32) -> f32 {
    match size {
        LogicalSize::Fit => intrinsic,
        LogicalSize::Grow | LogicalSize::GrowWeighted(_) => parent,
        LogicalSize::Pixels(value) => value.max(0.0),
        LogicalSize::Parent(fraction) => parent * fraction.clamp(0.0, 1.0),
    }
}

fn grow_weight(size: LogicalSize) -> Option<f32> {
    match size {
        LogicalSize::Grow => Some(1.0),
        LogicalSize::GrowWeighted(weight) => Some(weight.max(0.0)),
        LogicalSize::Fit | LogicalSize::Pixels(_) | LogicalSize::Parent(_) => None,
    }
}

fn axis_constraints(node: Element<'_>, horizontal: bool) -> (f32, f32) {
    if horizontal {
        (node.min_width, node.max_width)
    } else {
        (node.min_height, node.max_height)
    }
}

fn effective_max(min: f32, max: f32) -> f32 {
    if max == 0.0 {
        f32::INFINITY
    } else {
        max.max(min)
    }
}

fn constrain_axis(value: f32, min: f32, max: f32) -> f32 {
    value.max(min).min(effective_max(min, max))
}

fn align_offset(align: Align, available: f32, occupied: f32) -> f32 {
    let free = (available - occupied).max(0.0);
    match align {
        Align::Start => 0.0,
        Align::Center => free * 0.5,
        Align::End => free,
    }
}

/// Records every element's on-screen bounds for next frame's `Sense` and
/// wheel targeting, shrunk to what clipping actually leaves visible. An
/// insert that displaces a previous entry means two elements share an id;
/// each extra occurrence is reported as a duplicate.
fn record_bounds(
    parent: usize,
    clip: Rectangle,
    nodes: &[Element<'_>],
    bounds: &mut BTreeMap<ElementId, Rectangle>,
    duplicates: &mut AVec<'_, ElementId>,
) {
    let mut child = nodes[parent].first_child;
    while child != 0 {
        let node = &nodes[child];
        // Floating elements escape ancestor clipping.
        let clip = if node.floating { UNCLIPPED } else { clip };
        let visible = node.bounds.intersect(clip);
        if bounds.insert(node.id, visible).is_some() {
            duplicates.push(node.id);
        }
        record_bounds(
            child,
            if node.clip { visible } else { clip },
            nodes,
            bounds,
            duplicates,
        );
        child = node.next_sibling;
    }
}

fn emit_children<'a>(
    parent: usize,
    nodes: &[Element<'a>],
    commands: &mut AVec<'a, DrawCommand<'a>>,
) {
    let mut child = nodes[parent].first_child;
    while child != 0 {
        // Floating subtrees are emitted in a separate z-ordered pass.
        if !nodes[child].floating {
            emit_element(child, nodes, commands);
        }
        child = nodes[child].next_sibling;
    }
}

fn emit_element<'a>(index: usize, nodes: &[Element<'a>], commands: &mut AVec<'a, DrawCommand<'a>>) {
    let node = nodes[index];
    // TODO: Cull elements against the viewport and active clip stack here.
    if node.background.a > 0.0 {
        commands.push(DrawCommand {
            kind: DrawKind::Rectangle,
            id: node.id,
            bounds: node.bounds,
            color: node.background,
            corner_radius: node.border.radius,
            ..DrawCommand::default()
        });
    }
    if node.image != ImageId::default() && node.image_fade < 1.0 {
        // The zero tint means untinted (ZII), so the renderer can always
        // multiply by the command color. Fade rides the resolved alpha —
        // the image blends toward whatever draws beneath it — and a fully
        // faded image is skipped outright.
        let mut tint = if node.image_tint.a > 0.0 {
            node.image_tint
        } else {
            Color::rgba(1.0, 1.0, 1.0, 1.0)
        };
        tint.a *= 1.0 - node.image_fade;
        commands.push(DrawCommand {
            kind: DrawKind::Image,
            id: node.id,
            bounds: node.bounds,
            color: tint,
            image: node.image,
            ..DrawCommand::default()
        });
    }
    if node.clip {
        commands.push(DrawCommand {
            kind: DrawKind::ClipStart,
            id: node.id,
            bounds: node.bounds,
            ..DrawCommand::default()
        });
    }
    if !node.text.text.is_empty() {
        let text_bounds = Rectangle {
            x: node.bounds.x + node.padding.left,
            y: node.bounds.y + node.padding.top,
            w: (node.bounds.w - node.padding.left - node.padding.right).max(0.0),
            h: (node.bounds.h - node.padding.top - node.padding.bottom).max(0.0),
        };
        let mut y = text_bounds.y;
        for line in node.text_lines {
            if !line.text.is_empty() {
                commands.push(DrawCommand {
                    kind: DrawKind::Text,
                    id: node.id,
                    bounds: Rectangle {
                        y,
                        h: line.metrics.size.y,
                        ..text_bounds
                    },
                    color: node.text.color,
                    text: Text {
                        text: line.text,
                        ..node.text
                    },
                    text_baseline: line.metrics.baseline,
                    ..DrawCommand::default()
                });
            }
            y += line.metrics.size.y;
        }
    }
    emit_children(index, nodes, commands);
    if node.clip {
        commands.push(DrawCommand {
            kind: DrawKind::ClipEnd,
            id: node.id,
            bounds: node.bounds,
            ..DrawCommand::default()
        });
    }
    // The border sits on the element's own edge, outside its clip region.
    if node.border.width > 0.0 && node.border.color.a > 0.0 {
        commands.push(DrawCommand {
            kind: DrawKind::Border,
            id: node.id,
            bounds: node.bounds,
            color: node.border.color,
            border_width: node.border.width,
            corner_radius: node.border.radius,
            ..DrawCommand::default()
        });
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use super::*;

    const RED: Color = Color::rgba(1.0, 0.0, 0.0, 1.0);
    const GREEN: Color = Color::rgba(0.0, 1.0, 0.0, 1.0);
    const BLUE: Color = Color::rgba(0.0, 0.0, 1.0, 1.0);

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

    fn command<'a>(output: Output<'a>, id: &str) -> &'a DrawCommand<'a> {
        let id = ElementId::named(id);
        output
            .commands
            .iter()
            .find(|command| command.id == id)
            .unwrap()
    }

    fn command_kind<'a>(output: Output<'a>, id: &str, kind: DrawKind) -> &'a DrawCommand<'a> {
        let id = ElementId::named(id);
        output
            .commands
            .iter()
            .find(|command| command.id == id && command.kind == kind)
            .unwrap()
    }

    #[test]
    fn grow_siblings_share_remaining_space() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(300.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("fixed")
                                .width(LogicalSize::Pixels(100.0))
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("grow-a")
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Grow)
                                .background(GREEN),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("grow-b")
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Grow)
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        assert_eq!(command(commands, "fixed").bounds.w, 100.0);
        assert_eq!(command(commands, "grow-a").bounds.w, 100.0);
        assert_eq!(command(commands, "grow-b").bounds.w, 100.0);
        assert_eq!(command(commands, "grow-b").bounds.x, 200.0);
    }

    #[test]
    fn weighted_grow_siblings_share_space_by_weight() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(300.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("one")
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("two")
                                .width(LogicalSize::GrowWeighted(2.0))
                                .height(LogicalSize::Grow)
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        assert!((command(commands, "one").bounds.w - 100.0).abs() < 0.001);
        assert!((command(commands, "two").bounds.w - 200.0).abs() < 0.001);
    }

    #[test]
    fn grow_constraints_redistribute_space() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(300.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("capped")
                                .width(LogicalSize::Grow)
                                .max_width(50.0)
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("remainder")
                                .width(LogicalSize::GrowWeighted(2.0))
                                .height(LogicalSize::Grow)
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        assert_eq!(command(commands, "capped").bounds.w, 50.0);
        assert!((command(commands, "remainder").bounds.w - 250.0).abs() < 0.001);
    }

    #[test]
    fn overflowing_children_compress_proportionally() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(150.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        for (id, color) in [("a", RED), ("b", BLUE)] {
                            ui.add(
                                ElementConf::default()
                                    .id(id)
                                    .width(LogicalSize::Pixels(100.0))
                                    .height(LogicalSize::Grow)
                                    .background(color),
                            );
                        }
                    },
                );
            },
        );

        assert!((command(commands, "a").bounds.w - 75.0).abs() < 0.001);
        assert!((command(commands, "b").bounds.w - 75.0).abs() < 0.001);
        assert!((command(commands, "b").bounds.x - 75.0).abs() < 0.001);
    }

    #[test]
    fn overflow_compression_stops_at_minimums() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(150.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("minimum")
                                .width(LogicalSize::Pixels(100.0))
                                .min_width(90.0)
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("compressible")
                                .width(LogicalSize::Pixels(100.0))
                                .height(LogicalSize::Grow)
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        assert_eq!(command(commands, "minimum").bounds.w, 90.0);
        assert!((command(commands, "compressible").bounds.w - 60.0).abs() < 0.001);
    }

    #[test]
    fn compression_reserves_growing_child_minimums() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("fixed")
                                .width(LogicalSize::Pixels(200.0))
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("grow")
                                .width(LogicalSize::Grow)
                                .min_width(50.0)
                                .height(LogicalSize::Grow)
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        assert!((command(commands, "fixed").bounds.w - 150.0).abs() < 0.001);
        assert_eq!(command(commands, "grow").bounds.w, 50.0);
    }

    #[test]
    fn fit_size_respects_minimum_and_maximum() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(300.0, 100.0),
            |text, _, _| V2 {
                x: text.len() as f32 * 10.0,
                y: 10.0,
            },
            |ui| {
                ui.add(
                    ElementConf::text(TextConf::default().text("wide text"))
                        .id("maximum")
                        .max_width(40.0)
                        .background(RED),
                );
                ui.add(
                    ElementConf::default()
                        .id("minimum")
                        .min_width(30.0)
                        .height(LogicalSize::Pixels(10.0))
                        .background(BLUE),
                );
            },
        );

        assert_eq!(command(commands, "maximum").bounds.w, 40.0);
        assert_eq!(command(commands, "minimum").bounds.w, 30.0);
    }

    #[test]
    fn fit_uses_text_measurement_and_padding() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(400.0, 200.0),
            |text, _, size| V2 {
                x: text.len() as f32 * size as f32,
                y: size as f32,
            },
            |ui| {
                ui.add(
                    ElementConf::text(TextConf::default().text("abc").size(10).color(RED))
                        .id("text")
                        .padding(Padding::all(5.0))
                        .background(BLUE),
                );
            },
        );

        assert_eq!(command(commands, "text").bounds.w, 40.0);
        assert_eq!(command(commands, "text").bounds.h, 20.0);
        let text = command_kind(commands, "text", DrawKind::Text);
        assert_eq!(
            text.bounds,
            Rectangle {
                x: 5.0,
                y: 5.0,
                w: 30.0,
                h: 10.0
            }
        );
        assert_eq!(text.text.text, "abc");
    }

    #[test]
    fn vertical_layout_applies_padding_gap_and_alignment() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(200.0, 200.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow)
                        .direction(Direction::TopToBottom)
                        .padding(Padding::all(10.0))
                        .gap(5.0)
                        .align_x(Align::Center)
                        .align_y(Align::End),
                    |ui| {
                        for (id, color) in [("a", RED), ("b", GREEN)] {
                            ui.add(
                                ElementConf::default()
                                    .id(id)
                                    .width(LogicalSize::Pixels(20.0))
                                    .height(LogicalSize::Pixels(30.0))
                                    .background(color),
                            );
                        }
                    },
                );
            },
        );

        assert_eq!(command(commands, "a").bounds.x, 90.0);
        assert_eq!(command(commands, "a").bounds.y, 125.0);
        assert_eq!(command(commands, "b").bounds.y, 160.0);
    }

    #[test]
    fn parent_fraction_resolves_against_inner_size() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow)
                        .padding(Padding::symmetric(10.0, 0.0)),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("half")
                                .width(LogicalSize::Parent(0.5))
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                    },
                );
            },
        );

        assert_eq!(command(commands, "half").bounds.x, 10.0);
        assert_eq!(command(commands, "half").bounds.w, 90.0);
    }

    #[test]
    fn sense_uses_previous_frame_bounds() {
        let mut engine = Engine::default();
        let button = || {
            ElementConf::default()
                .id("button")
                .width(LogicalSize::Pixels(100.0))
                .height(LogicalSize::Pixels(40.0))
                .background(RED)
        };
        let mut first = Sense::default();
        let _ = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                first = ui.add(button());
            },
        );
        assert_eq!(first, Sense::default());

        let mut second = Sense::default();
        let mut second_input = input(200.0, 100.0);
        second_input.mouse_pos = V2 { x: 50.0, y: 20.0 };
        second_input.mouse_pressed = true;
        let _ = engine.layout(
            second_input,
            |_, _, _| V2::default(),
            |ui| {
                second = ui.add(button());
            },
        );
        assert_eq!(
            second,
            Sense {
                hovered: true,
                clicked: true,
            }
        );
    }

    #[test]
    fn structural_ids_are_stable_between_matching_frames() {
        let mut engine = Engine::default();
        let mut first = Sense::default();
        let _ = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                first = ui.add(
                    ElementConf::default()
                        .width(LogicalSize::Pixels(40.0))
                        .height(LogicalSize::Pixels(30.0)),
                );
            },
        );
        assert_eq!(first, Sense::default());

        let mut second_input = input(100.0, 100.0);
        second_input.mouse_pos = V2 { x: 20.0, y: 15.0 };
        let mut second = Sense::default();
        let _ = engine.layout(
            second_input,
            |_, _, _| V2::default(),
            |ui| {
                second = ui.add(
                    ElementConf::default()
                        .width(LogicalSize::Pixels(40.0))
                        .height(LogicalSize::Pixels(30.0)),
                );
            },
        );
        assert!(second.hovered);
    }

    #[test]
    fn commands_do_not_borrow_source_text() {
        let mut engine = Engine::default();
        let commands = {
            let text = String::from("temporary");
            engine.layout(
                input(100.0, 100.0),
                |text, _, _| V2 {
                    x: text.len() as f32,
                    y: 10.0,
                },
                |ui| {
                    ui.add(ElementConf::text(TextConf::default().text(&text).size(10)));
                },
            )
        };

        assert_eq!(commands[0].text.text, "temporary");
    }

    #[test]
    fn emits_background_text_children_then_border() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |_, _, size| V2 {
                x: 20.0,
                y: size as f32,
            },
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .id("panel")
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow)
                        .background(RED)
                        .border(2.0, BLUE),
                    |ui| {
                        ui.add(ElementConf::text(
                            TextConf::default().text("child").size(10).color(GREEN),
                        ));
                    },
                );
            },
        );

        assert_eq!(
            commands
                .iter()
                .map(|command| command.kind)
                .collect::<Vec<_>>(),
            [DrawKind::Rectangle, DrawKind::Text, DrawKind::Border]
        );
        assert_eq!(commands[2].border_width, 2.0);
    }

    #[test]
    fn corner_radius_is_emitted_for_background_and_border() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(
                    ElementConf::default()
                        .id("rounded")
                        .width(LogicalSize::Pixels(50.0))
                        .height(LogicalSize::Pixels(40.0))
                        .background(RED)
                        .border(2.0, BLUE)
                        .corner_radius(8.0),
                );
            },
        );

        assert_eq!(
            command_kind(commands, "rounded", DrawKind::Rectangle).corner_radius,
            8.0
        );
        assert_eq!(
            command_kind(commands, "rounded", DrawKind::Border).corner_radius,
            8.0
        );
    }

    #[test]
    fn text_wraps_at_words_and_updates_layout_height() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |text, font, _| {
                assert_eq!(font, FontId(7));
                V2 {
                    x: text.chars().count() as f32 * 10.0,
                    y: 10.0,
                }
            },
            |ui| {
                ui.add(
                    ElementConf::text(
                        TextConf::default()
                            .text("one two")
                            .font(FontId(7))
                            .size(10)
                            .wrap(true),
                    )
                    .id("wrapped")
                    .width(LogicalSize::Pixels(35.0))
                    .background(RED),
                );
            },
        );

        let background = command_kind(commands, "wrapped", DrawKind::Rectangle);
        let lines = commands
            .iter()
            .filter(|command| {
                command.id == ElementId::named("wrapped") && command.kind == DrawKind::Text
            })
            .collect::<Vec<_>>();
        assert_eq!(background.bounds.h, 20.0);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].text.text, "one");
        assert_eq!(lines[1].text.text, "two");
        assert_eq!(lines[0].text.font, FontId(7));
        assert_eq!(lines[1].bounds.y, 10.0);
    }

    #[test]
    fn wrapping_hard_breaks_long_words_and_preserves_newlines() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |text, _, _| V2 {
                x: text.chars().count() as f32 * 10.0,
                y: 10.0,
            },
            |ui| {
                ui.add(
                    ElementConf::text(TextConf::default().text("abcd\nef").wrap(true))
                        .id("wrapped")
                        .width(LogicalSize::Pixels(25.0)),
                );
            },
        );

        assert_eq!(
            commands
                .iter()
                .map(|command| command.text.text)
                .collect::<Vec<_>>(),
            ["ab", "cd", "ef"]
        );
        assert_eq!(commands[2].bounds.y, 20.0);
    }

    #[test]
    fn text_measurements_are_cached_until_cleared() {
        let mut engine = Engine::default();
        let calls = Cell::new(0usize);
        let measure = |text: &str, _: FontId, _: u16| {
            calls.set(calls.get() + 1);
            V2 {
                x: text.len() as f32 * 10.0,
                y: 10.0,
            }
        };
        let build = |ui: &mut Ui<'_, '_>| {
            ui.add(
                ElementConf::text(
                    TextConf::default()
                        .text("cached text")
                        .font(FontId(3))
                        .size(12)
                        .wrap(true),
                )
                .width(LogicalSize::Pixels(60.0)),
            );
        };

        let _ = engine.layout(input(100.0, 100.0), &measure, build);
        let first_frame_calls = calls.get();
        assert!(first_frame_calls > 0);
        let _ = engine.layout(input(100.0, 100.0), &measure, build);
        assert_eq!(calls.get(), first_frame_calls);

        engine.clear_text_cache();
        let _ = engine.layout(input(100.0, 100.0), &measure, build);
        assert!(calls.get() > first_frame_calls);
    }

    #[test]
    fn text_baseline_is_preserved_in_command() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |_, _, _| TextMetrics {
                size: V2 { x: 20.0, y: 12.0 },
                baseline: 9.0,
            },
            |ui| {
                ui.add(ElementConf::text(TextConf::default().text("gyp").size(12)).id("text"));
            },
        );

        assert_eq!(command(commands, "text").text_baseline, 9.0);
    }

    #[test]
    fn negative_padding_is_clamped() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2 { x: 5.0, y: 5.0 },
            |ui| {
                ui.add(
                    ElementConf::text(TextConf::default().text("x").size(5))
                        .id("text")
                        .padding(Padding::all(-10.0))
                        .background(RED),
                );
            },
        );

        assert_eq!(command(commands, "text").bounds.w, 5.0);
        assert_eq!(command(commands, "text").bounds.h, 5.0);
    }

    #[test]
    #[should_panic(expected = "text elements cannot have children")]
    fn text_elements_cannot_have_children() {
        let mut engine = Engine::default();
        let _ = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::text(TextConf::default().text("parent")),
                    |_| {},
                );
            },
        );
    }

    #[test]
    fn pointer_over_ui_ignores_invisible_layout_containers() {
        let mut engine = Engine::default();
        let mut pointer_input = input(200.0, 100.0);
        pointer_input.mouse_pos = V2 { x: 150.0, y: 50.0 };
        let output = engine.layout(
            pointer_input,
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Grow),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .width(LogicalSize::Pixels(50.0))
                                .height(LogicalSize::Pixels(50.0))
                                .background(RED),
                        );
                    },
                );
            },
        );

        assert!(!output.is_pointer_over_ui());
    }

    #[test]
    fn pointer_over_visible_command_is_over_ui() {
        let mut engine = Engine::default();
        let mut pointer_input = input(200.0, 100.0);
        pointer_input.mouse_pos = V2 { x: 25.0, y: 25.0 };
        let output = engine.layout(
            pointer_input,
            |_, _, _| V2::default(),
            |ui| {
                ui.add(
                    ElementConf::default()
                        .width(LogicalSize::Pixels(50.0))
                        .height(LogicalSize::Pixels(50.0))
                        .background(RED),
                );
            },
        );

        assert!(output.is_pointer_over_ui());
    }

    #[test]
    fn scroll_container_clips_and_scrolls_children() {
        let mut engine = Engine::default();
        let build = |ui: &mut Ui<'_, '_>| {
            ui.add_with(
                ElementConf::default()
                    .id("list")
                    .width(LogicalSize::Pixels(100.0))
                    .height(LogicalSize::Pixels(100.0))
                    .direction(Direction::TopToBottom)
                    .scroll(false, true)
                    .border(2.0, BLUE),
                |ui| {
                    for id in ["row-a", "row-b", "row-c", "row-d"] {
                        ui.add(
                            ElementConf::default()
                                .id(id)
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Pixels(50.0))
                                .background(RED),
                        );
                    }
                },
            );
        };

        let first = engine.layout(input(200.0, 200.0), |_, _, _| V2::default(), build);
        assert_eq!(
            first
                .commands
                .iter()
                .map(|command| command.kind)
                .collect::<Vec<_>>(),
            [
                DrawKind::ClipStart,
                DrawKind::Rectangle,
                DrawKind::Rectangle,
                DrawKind::Rectangle,
                DrawKind::Rectangle,
                DrawKind::ClipEnd,
                DrawKind::Border,
            ]
        );
        // Fixed rows must not be compressed to fit the scrolling axis.
        assert_eq!(command(first, "row-d").bounds.y, 150.0);

        let mut wheel_input = input(200.0, 200.0);
        wheel_input.mouse_pos = V2 { x: 50.0, y: 50.0 };
        wheel_input.wheel = V2 { x: 0.0, y: -30.0 };
        let second = engine.layout(wheel_input, |_, _, _| V2::default(), build);
        assert_eq!(command(second, "row-a").bounds.y, -30.0);

        // Content is 200 tall in a 100-tall viewport: the offset clamps at
        // 100 no matter how far the wheel turns.
        let mut flood_input = input(200.0, 200.0);
        flood_input.mouse_pos = V2 { x: 50.0, y: 50.0 };
        flood_input.wheel = V2 { x: 0.0, y: -1000.0 };
        let third = engine.layout(flood_input, |_, _, _| V2::default(), build);
        assert_eq!(command(third, "row-a").bounds.y, -100.0);
    }

    #[test]
    fn clipped_regions_do_not_sense_or_capture_the_pointer() {
        let mut engine = Engine::default();
        let list = || {
            ElementConf::default()
                .id("list")
                .width(LogicalSize::Pixels(100.0))
                .height(LogicalSize::Pixels(100.0))
                .direction(Direction::TopToBottom)
                .scroll(false, true)
        };
        let row = |id: &'static str| {
            ElementConf::default()
                .id(id)
                .width(LogicalSize::Grow)
                .height(LogicalSize::Pixels(50.0))
                .background(RED)
        };

        let _ = engine.layout(
            input(200.0, 200.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(list(), |ui| {
                    for id in ["row-a", "row-b", "row-c", "row-d"] {
                        ui.add(row(id));
                    }
                });
            },
        );

        // The pointer sits where row-c lies before clipping (y = 100..150),
        // just below the 100-tall scroll viewport.
        let mut probe = input(200.0, 200.0);
        probe.mouse_pos = V2 { x: 50.0, y: 125.0 };
        probe.mouse_pressed = true;
        let mut sensed = Sense {
            hovered: true,
            clicked: true,
        };
        let output = engine.layout(
            probe,
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(list(), |ui| {
                    for id in ["row-a", "row-b", "row-c", "row-d"] {
                        let sense = ui.add(row(id));
                        if id == "row-c" {
                            sensed = sense;
                        }
                    }
                });
            },
        );

        assert_eq!(sensed, Sense::default());
        assert!(!output.is_pointer_over_ui());
    }

    #[test]
    fn floating_elements_leave_flow_and_anchor_to_parent() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add_with(
                    ElementConf::default()
                        .id("panel")
                        .width(LogicalSize::Pixels(100.0))
                        .height(LogicalSize::Pixels(100.0)),
                    |ui| {
                        ui.add(
                            ElementConf::default()
                                .id("flow")
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Grow)
                                .background(RED),
                        );
                        ui.add(
                            ElementConf::default()
                                .id("float")
                                .floating(Anchor::BottomRight, Anchor::TopLeft)
                                .float_offset(5.0, 7.0)
                                .width(LogicalSize::Pixels(30.0))
                                .height(LogicalSize::Pixels(20.0))
                                .background(BLUE),
                        );
                    },
                );
            },
        );

        // The float consumed no flow space: the sibling still fills the
        // whole panel.
        assert_eq!(
            command(commands, "flow").bounds,
            Rectangle {
                x: 0.0,
                y: 0.0,
                w: 100.0,
                h: 100.0,
            }
        );
        // Its own top-left is pinned to the panel's bottom-right + offset.
        assert_eq!(
            command(commands, "float").bounds,
            Rectangle {
                x: 105.0,
                y: 107.0,
                w: 30.0,
                h: 20.0,
            }
        );
        // Floats draw after the normal tree.
        assert_eq!(
            commands.commands.last().unwrap().id,
            ElementId::named("float")
        );
    }

    #[test]
    fn z_index_orders_floating_elements() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(
                    ElementConf::default()
                        .id("high")
                        .floating(Anchor::TopLeft, Anchor::TopLeft)
                        .z_index(2)
                        .width(LogicalSize::Pixels(10.0))
                        .height(LogicalSize::Pixels(10.0))
                        .background(RED),
                );
                ui.add(
                    ElementConf::default()
                        .id("low")
                        .floating(Anchor::TopLeft, Anchor::TopLeft)
                        .z_index(1)
                        .width(LogicalSize::Pixels(10.0))
                        .height(LogicalSize::Pixels(10.0))
                        .background(BLUE),
                );
            },
        );

        let position = |id: &str| {
            commands
                .commands
                .iter()
                .position(|command| command.id == ElementId::named(id))
                .unwrap()
        };
        // Declared first but z 2: "high" draws after (on top of) "low".
        assert!(position("low") < position("high"));
    }

    #[test]
    fn floating_elements_escape_clipping() {
        let mut engine = Engine::default();
        let build = |ui: &mut Ui<'_, '_>| {
            ui.add_with(
                ElementConf::default()
                    .id("list")
                    .width(LogicalSize::Pixels(100.0))
                    .height(LogicalSize::Pixels(100.0))
                    .direction(Direction::TopToBottom)
                    .scroll(false, true),
                |ui| {
                    for id in ["row-a", "row-b", "row-c"] {
                        ui.add(
                            ElementConf::default()
                                .id(id)
                                .width(LogicalSize::Grow)
                                .height(LogicalSize::Pixels(50.0))
                                .background(RED),
                        );
                    }
                    // Hangs below the container: y = 130..150.
                    ui.add(
                        ElementConf::default()
                            .id("float")
                            .floating(Anchor::BottomLeft, Anchor::TopLeft)
                            .float_offset(10.0, 30.0)
                            .width(LogicalSize::Pixels(40.0))
                            .height(LogicalSize::Pixels(20.0))
                            .background(BLUE),
                    );
                },
            );
        };

        let _ = engine.layout(input(200.0, 200.0), |_, _, _| V2::default(), build);

        let mut probe = input(200.0, 200.0);
        probe.mouse_pos = V2 { x: 20.0, y: 140.0 };
        let output = engine.layout(probe, |_, _, _| V2::default(), build);

        // The float's commands come after the scroll region's ClipEnd, so
        // the pointer scan sees them unclipped.
        assert!(output.is_pointer_over_ui());
    }

    #[test]
    fn sense_is_queryable_before_declaration() {
        let mut engine = Engine::default();
        let button = || {
            ElementConf::default()
                .id("button")
                .width(LogicalSize::Pixels(100.0))
                .height(LogicalSize::Pixels(40.0))
                .background(RED)
        };

        let _ = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(button());
            },
        );

        let mut probe = input(200.0, 100.0);
        probe.mouse_pos = V2 { x: 50.0, y: 20.0 };
        probe.mouse_pressed = true;
        let mut before = Sense::default();
        let mut after = Sense::default();
        let _ = engine.layout(
            probe,
            |_, _, _| V2::default(),
            |ui| {
                before = ui.sense("button");
                after = ui.add(button());
            },
        );

        assert_eq!(
            before,
            Sense {
                hovered: true,
                clicked: true,
            }
        );
        assert_eq!(before, after);
    }

    #[test]
    fn image_elements_size_from_source_and_emit_image_commands() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(200.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                // Fit-sized: takes the source dimensions as intrinsic size.
                ui.add(
                    ElementConf::default()
                        .id("natural")
                        .image(ImageId(7), V2 { x: 40.0, y: 30.0 })
                        .background(RED),
                );
                // Explicitly sized: stretches, and carries a tint.
                ui.add(
                    ElementConf::default()
                        .id("stretched")
                        .image(ImageId(7), V2 { x: 40.0, y: 30.0 })
                        .image_tint(GREEN)
                        .width(LogicalSize::Pixels(80.0))
                        .height(LogicalSize::Pixels(20.0)),
                );
            },
        );

        let natural = command_kind(commands, "natural", DrawKind::Image);
        assert_eq!(natural.image, ImageId(7));
        assert_eq!(natural.bounds.w, 40.0);
        assert_eq!(natural.bounds.h, 30.0);
        // Untinted images default to opaque white so renderers can always
        // multiply by the command color.
        assert_eq!(natural.color, Color::rgba(1.0, 1.0, 1.0, 1.0));
        // The element's own background draws beneath its image.
        let backdrop_index = commands
            .commands
            .iter()
            .position(|command| command.kind == DrawKind::Rectangle)
            .unwrap();
        let image_index = commands
            .commands
            .iter()
            .position(|command| command.kind == DrawKind::Image)
            .unwrap();
        assert!(backdrop_index < image_index);

        let stretched = command_kind(commands, "stretched", DrawKind::Image);
        assert_eq!(stretched.bounds.w, 80.0);
        assert_eq!(stretched.bounds.h, 20.0);
        assert_eq!(stretched.color, GREEN);
    }

    #[test]
    fn image_fade_scales_alpha_and_hides_at_one() {
        let mut engine = Engine::default();
        let commands = engine.layout(
            input(300.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(
                    ElementConf::default()
                        .id("half")
                        .image(ImageId(7), V2 { x: 40.0, y: 30.0 })
                        .image_fade(0.5),
                );
                ui.add(
                    ElementConf::default()
                        .id("tinted-half")
                        .image(ImageId(7), V2 { x: 40.0, y: 30.0 })
                        .image_tint(RED)
                        .image_fade(0.5),
                );
                ui.add(
                    ElementConf::default()
                        .id("gone")
                        .image(ImageId(7), V2 { x: 40.0, y: 30.0 })
                        .image_fade(1.0)
                        .background(BLUE),
                );
            },
        );

        // Untinted at fade 0.5: white at half alpha.
        assert_eq!(
            command_kind(commands, "half", DrawKind::Image).color,
            Color::rgba(1.0, 1.0, 1.0, 0.5)
        );
        // Fade multiplies the tint's own alpha.
        assert_eq!(
            command_kind(commands, "tinted-half", DrawKind::Image).color,
            Color::rgba(1.0, 0.0, 0.0, 0.5)
        );
        // Fully faded: no image command at all, background still draws.
        assert!(!commands.commands.iter().any(
            |command| command.id == ElementId::named("gone") && command.kind == DrawKind::Image
        ));
        assert_eq!(
            command_kind(commands, "gone", DrawKind::Rectangle).color,
            BLUE
        );
    }

    #[test]
    fn duplicate_ids_are_reported() {
        let mut engine = Engine::default();
        let square = || {
            ElementConf::default()
                .id("dup")
                .width(LogicalSize::Pixels(10.0))
                .height(LogicalSize::Pixels(10.0))
        };

        let output = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(square());
                ui.add(square().id("unique"));
                ui.add(square());
            },
        );
        assert_eq!(output.duplicate_ids(), [ElementId::named("dup")]);

        let clean = engine.layout(
            input(100.0, 100.0),
            |_, _, _| V2::default(),
            |ui| {
                ui.add(square());
                ui.add(square().id("unique"));
            },
        );
        assert!(clean.duplicate_ids().is_empty());
    }

    #[test]
    fn indexed_ids_are_distinct_and_stable() {
        assert_ne!(ElementId::indexed("row", 0), ElementId::indexed("row", 1));
        assert_ne!(ElementId::indexed("row", 0), ElementId::named("row"));

        let mut engine = Engine::default();
        let build = |ui: &mut Ui<'_, '_>| {
            for index in 0..3u32 {
                ui.add(
                    ElementConf::default()
                        .id(("row", index))
                        .width(LogicalSize::Grow)
                        .height(LogicalSize::Pixels(20.0))
                        .background(RED),
                );
            }
        };

        let first = engine.layout(input(100.0, 100.0), |_, _, _| V2::default(), build);
        assert!(first.duplicate_ids().is_empty());

        // Row 1 spans y = 20..40; the id is stable across frames, so it
        // senses under the pointer on the second frame.
        let mut probe = input(100.0, 100.0);
        probe.mouse_pos = V2 { x: 50.0, y: 30.0 };
        let mut hovered = false;
        let _ = engine.layout(
            probe,
            |_, _, _| V2::default(),
            |ui| {
                hovered = ui.hovered(("row", 1));
                build(ui);
            },
        );
        assert!(hovered);
    }
}
