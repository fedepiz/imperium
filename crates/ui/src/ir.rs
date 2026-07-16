//! Compiled UI descriptions: tabula source + style → flat IR, once per
//! (re)load.
//!
//! The layout engine rebuilds every frame, so whatever describes the UI is
//! walked every frame too. The raw tabula tree is the wrong shape for that
//! (string key matching, `yes`/`no` atoms, number re-parsing), so
//! [`compile`] translates it once into [`UiNode`]s: a flat array of fat
//! structs with every field pre-parsed, every `$VAR` string pre-tokenized,
//! and every style value baked in.
//!
//! There is no node "kind": widget names (`panel`, `label`, `button`, ...)
//! are compiler vocabulary only — each one is a set of legal keys plus
//! defaults written into the fields, and every policy decision (what may
//! float, what a button looks like) is made here, once. The per-frame walk
//! in [`crate::run`] is kind-blind: it applies every field of every node.
//!
//! The style is a compile input, not a runtime one: role sizes, paddings
//! and palette colors land in the nodes as plain values. Only `$VAR` color
//! names survive to run time, resolved against [`UiModule::palette`]. A
//! style edit is a recompile, same as a script edit.
//!
//! The IR also defines the data the UI binds against ([`UiData`]): the
//! caller fetches rows from wherever it likes and hands them over in this
//! format, keeping the UI isolated from the rest of the game.

use arena::Arena;

use crate::layout::{Align, Color, Direction, ImageId, Padding};
use crate::style::{Palette, Style};
use util::span::Span;

// Typed spans: each wrapper names the one buffer its span reads, so a
// string span can't be handed to a table (or the wrong buffer's) accessor.
// All inherit ZII from `Span`: the zero value is empty.

/// A string span into [`UiModule::strings`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ModuleStr(pub Span);

impl ModuleStr {
    pub fn is_empty(self) -> bool {
        self.0.is_empty()
    }
}

/// A range into [`UiModule::segs`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SegRange(pub Span);

impl SegRange {
    pub fn is_empty(self) -> bool {
        self.0.is_empty()
    }
}

/// A string span into [`UiData::strings`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DataStr(pub Span);

/// A range into [`UiData::rows`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RowRange(pub Span);

/// A range into [`UiData::bindings`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct BindingRange(pub Span);

/// A pre-parsed script size: `cap[:weight]` per axis.
///
/// The cap is a ceiling — pixels, `N%` of the parent, or `grow` for none;
/// `fit` is sugar for weight 0. The weight is the element's share of the
/// parent's leftover space, `0` meaning "fit content". Every element
/// starts at its content floor, grows by weight, and stops at its cap.
///
/// Zero value = fit content, uncapped. The compiler writes every node's
/// final size — widget defaults are its policy, not the walk's.
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Size {
    /// The ceiling: pixels, or a 0..=1 fraction of the parent when
    /// `fraction` is set. `0.0` = uncapped.
    pub cap: f32,
    pub fraction: bool,
    /// Share of the parent's leftover space; `0.0` = fit content.
    pub weight: f32,
}

impl Size {
    /// "Fill the parent": uncapped, weight 1.
    pub const GROW: Size = Size {
        cap: 0.0,
        fraction: false,
        weight: 1.0,
    };

    /// "Fit content": uncapped, weight 0 — the zero value.
    pub const FIT: Size = Size {
        cap: 0.0,
        fraction: false,
        weight: 0.0,
    };
}

/// One piece of a pre-tokenized string: either a plain literal (`var` is
/// empty) or a `$VAR` reference, in which case `literal` keeps the source
/// spelling (`"$NAME"`) as the fallback when the binding is missing.
/// Spans index [`UiModule::strings`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Seg {
    pub literal: ModuleStr,
    pub var: ModuleStr,
}

/// A string with its `$VAR` references found at compile time, so per-frame
/// interpolation never rescans: a range into [`UiModule::segs`]. Zero
/// value = no text.
#[derive(Clone, Copy, Debug, Default)]
pub struct Text {
    pub segs: SegRange,
}

impl Text {
    pub fn is_empty(&self) -> bool {
        self.segs.is_empty()
    }
}

/// A script color, decided as early as possible. The interpretation: if
/// `name` is non-empty, it is a `$VAR` palette name — interpolate it per
/// frame and look it up in [`UiModule::palette`]; if it is empty or fails
/// to resolve, `color` applies (literal names bake into it at compile
/// time; for a `$VAR` it holds the widget's default). Deliberately not an
/// enum: the variable case falls back on `color`, so the fields overlap.
/// Zero value = no color (alpha 0), which every consumer treats as "draw
/// nothing".
#[derive(Clone, Copy, Debug, Default)]
pub struct Paint {
    pub name: Text,
    pub color: Color,
}

impl Paint {
    pub fn of(color: Color) -> Paint {
        Paint {
            name: Text::default(),
            color,
        }
    }
}

/// One fat struct covers every widget; unused fields stay at their zero
/// value and the walk applies them all — there is no kind to dispatch on.
/// Children are index links into the module's flat node array, with `0`
/// (the reserved null node) meaning "none".
#[derive(Clone, Copy, Debug, Default)]
pub struct UiNode {
    pub first_child: u32,
    pub next_sibling: u32,
    /// Element identity: hover/scroll state, and — with a `template` —
    /// which data list this node stamps.
    pub id: Text,
    /// Click action; non-empty makes the element clickable (click events,
    /// the hover skin).
    pub action: Text,
    /// Visibility, resolved per frame: the interpolated text must be
    /// empty or `yes` to show the element. Conditions come from data via
    /// `$VAR` (row bindings, then globals); a missing binding keeps its
    /// `$NAME` spelling and hides. Zero value = shown.
    pub visible: Text,
    /// Interactivity, resolved per frame on the same channel as `visible`:
    /// empty or `yes` = enabled. Disabled elements draw dimmed, sense
    /// nothing and emit no clicks, and the state cascades to their
    /// children. Zero value = enabled.
    pub enabled: Text,
    /// Hover tooltip text; empty = none.
    pub tooltip: Text,

    // The box: where the element sits and how much room it takes.
    /// `floating = yes` lifts the element out of its parent's flow and
    /// pins it at `x_pos`/`y_pos`. Always set for top-level panels.
    pub floating: bool,
    /// Floating elements: position as a fraction of the parent (the
    /// screen for top-level panels). 0 = flush left/top, 0.5 = centered,
    /// 1 = flush right/bottom.
    pub x_pos: f32,
    pub y_pos: f32,
    pub width: Size,
    pub height: Size,
    /// `0.0` = unconstrained.
    pub min_width: f32,
    pub max_width: f32,
    pub min_height: f32,
    pub max_height: f32,
    pub direction: Direction,
    /// Both axes come from the single `align` key; zero = start.
    pub align_x: Align,
    pub align_y: Align,
    pub padding: Padding,
    pub gap: f32,

    // The skin.
    pub background: Paint,
    /// Replaces `background` while hovered; alpha 0 = no hover skin.
    pub hover_background: Color,
    /// Replaces both while the pointer holds the element down — for the
    /// whole press, not just its first frame; alpha 0 = no press skin.
    pub press_background: Color,
    /// `0.0` = no border.
    pub border_width: f32,
    pub border_color: Color,
    pub corner_radius: f32,

    // Text content.
    pub text: Text,
    pub text_size: u16,
    /// The ink; role defaults are baked in, so this is never "unset".
    pub color: Paint,
    /// Wrap to the element width.
    pub wrap: bool,

    // Image content: the key resolved through [`UiData::images`].
    pub image: Text,
    /// Alpha 0 = untinted.
    pub tint: Paint,
    /// `0.0` = fully opaque.
    pub fade: f32,

    // Interaction.
    pub scroll_x: bool,
    pub scroll_y: bool,
    /// Subtree stamped once per row of the bound data list; `0` = none.
    /// Reached only through this link, never through the sibling chain.
    pub template: u32,
}

/// The tooltip bubble's look, baked from the style. The bubble itself is
/// synthesized by the walk (it has per-frame text), so its style lives at
/// module level rather than on a node.
#[derive(Clone, Copy, Debug, Default)]
pub struct Bubble {
    pub background: Color,
    pub border: Color,
    pub ink: Color,
    pub text_size: u16,
}

/// A compiled UI description plus everything wrong with it, fully owned:
/// flat node array, seg table, and one string buffer. Reload = compile a
/// new one and assign over the old.
#[derive(Clone, Debug, Default)]
pub struct UiModule {
    /// Flat node array. Node 0 is the null node; the top-level panels hang
    /// off its `first_child` chain.
    pub nodes: Vec<UiNode>,
    /// All nodes' [`Text`] segments, ranged into by `Text::segs`.
    pub segs: Vec<Seg>,
    /// Every literal and variable name, addressed by the segs' spans.
    pub strings: String,
    /// The style palette, for `$VAR` color names that only resolve per
    /// frame; literal names are baked into the nodes directly.
    pub palette: Palette,
    /// The tooltip bubble's baked look.
    pub bubble: Bubble,
    /// Non-fatal validation findings (unknown keys, missing `=`, ...), as
    /// key paths — tabula nodes carry no source positions.
    pub warnings: Vec<String>,
    pub errors: Vec<tabula::ParseError>,
}

impl UiModule {
    /// Index of the first top-level panel, `0` if there are none.
    pub fn roots(&self) -> u32 {
        self.nodes.first().map_or(0, |null| null.first_child)
    }

    pub fn str(&self, span: ModuleStr) -> &str {
        span.0.str(&self.strings)
    }

    pub fn segs(&self, text: Text) -> &[Seg] {
        text.segs.0.slice(&self.segs)
    }
}

/// One `$VAR` binding: `key` is the variable name without the `$`. Spans
/// index [`UiData::strings`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Binding {
    pub key: DataStr,
    pub value: DataStr,
}

/// The bindings one stamped-out template instance interpolates from:
/// a range into [`UiData::bindings`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Row {
    pub bindings: BindingRange,
}

/// The rows behind one `list`, matched to it by `id` (a string span);
/// `rows` ranges into [`UiData::rows`].
#[derive(Clone, Copy, Debug, Default)]
pub struct ListData {
    pub id: DataStr,
    pub rows: RowRange,
}

/// One image the script can reference by key (`image = { source = soldier
/// }`), with its renderer handle and natural size.
#[derive(Clone, Copy, Debug, Default)]
pub struct ImageData {
    pub key: DataStr,
    pub image: ImageId,
    pub width: f32,
    pub height: f32,
}

/// Everything the UI binds against this frame, fully owned: flat arrays
/// linked by spans, strings in one buffer. The zero value is valid (no
/// lists, no images); [`UiData::clear`] recycles all buffers so one value
/// can be refilled every frame without reallocating.
///
/// One channel carries all sim-facing data: bindings, resolved current
/// row first, then [`UiData::globals`] — the root scope every element
/// sees, including top-level panels outside any list. Visibility rides
/// the same channel (`visible = "$OPEN"` against a yes/no value).
///
/// Built top-down in declaration order: `begin_list`, then `begin_row` and
/// `bind` for each row, so every list's rows (and every row's bindings)
/// are contiguous. Globals live in their own array, so `bind_global` is
/// legal at any point.
#[derive(Clone, Debug, Default)]
pub struct UiData {
    pub strings: String,
    pub lists: Vec<ListData>,
    pub rows: Vec<Row>,
    pub bindings: Vec<Binding>,
    pub globals: Vec<Binding>,
    pub images: Vec<ImageData>,
}

impl UiData {
    pub fn clear(&mut self) {
        self.strings.clear();
        self.lists.clear();
        self.rows.clear();
        self.bindings.clear();
        self.globals.clear();
        self.images.clear();
    }

    pub fn text(&self, span: DataStr) -> &str {
        span.0.str(&self.strings)
    }

    /// Starts a new list; subsequent `begin_row` calls belong to it.
    pub fn begin_list(&mut self, id: &str) {
        let id = DataStr(Span::push_str(&mut self.strings, id));
        self.lists.push(ListData {
            id,
            rows: RowRange(Span {
                start: self.rows.len() as u32,
                len: 0,
            }),
        });
    }

    /// Starts a new row in the current list; subsequent `bind` calls
    /// belong to it. Without a `begin_list` first, the row is orphaned
    /// (harmless: nothing ranges over it).
    pub fn begin_row(&mut self) {
        let row = Row {
            bindings: BindingRange(Span {
                start: self.bindings.len() as u32,
                len: 0,
            }),
        };
        self.rows.push(row);
        if let Some(list) = self.lists.last_mut() {
            list.rows.0.len += 1;
        }
    }

    /// Adds a `$key = value` binding to the current row. Without a
    /// `begin_row` first, the binding is orphaned (harmless).
    pub fn bind(&mut self, key: &str, value: &str) {
        let binding = Binding {
            key: DataStr(Span::push_str(&mut self.strings, key)),
            value: DataStr(Span::push_str(&mut self.strings, value)),
        };
        self.bindings.push(binding);
        if let Some(row) = self.rows.last_mut() {
            row.bindings.0.len += 1;
        }
    }

    /// Adds a `$key = value` binding to the root scope: visible to every
    /// element, shadowed by a row binding of the same key. Legal at any
    /// point during the fill — globals live outside the row/list spans.
    pub fn bind_global(&mut self, key: &str, value: &str) {
        let binding = Binding {
            key: DataStr(Span::push_str(&mut self.strings, key)),
            value: DataStr(Span::push_str(&mut self.strings, value)),
        };
        self.globals.push(binding);
    }

    pub fn add_image(&mut self, key: &str, image: ImageId, width: f32, height: f32) {
        let key = DataStr(Span::push_str(&mut self.strings, key));
        self.images.push(ImageData {
            key,
            image,
            width,
            height,
        });
    }

    pub fn rows(&self, list: ListData) -> &[Row] {
        list.rows.0.slice(&self.rows)
    }

    pub fn bindings(&self, row: Row) -> &[Binding] {
        row.bindings.0.slice(&self.bindings)
    }
}

/// Parse and compile a UI description against a style. Never fails:
/// whatever could be recovered is compiled, with the rest reported in
/// `errors`/`warnings`. The tabula tree lives in a scratch arena that dies
/// here; only the owned IR (with its strings copied over) survives.
pub fn compile(source: &str, style: &Style) -> UiModule {
    let scratch = Arena::new();
    let parsed = tabula::parse(&scratch, source);

    let mut compiler = Compiler {
        module: UiModule::default(),
        style: *style,
    };
    compiler.nodes.push(UiNode::default()); // node 0: the null node

    compiler.module.palette = style.palette;
    compiler.module.bubble = Bubble {
        background: style.tooltip_background,
        border: style.palette.outline,
        ink: style.tooltip_ink,
        text_size: style.tooltip_size,
    };

    let mut last = 0usize;
    for (index, root) in parsed.roots.iter().enumerate() {
        let path = format!("panel #{}", index + 1);
        if root.key != "panel" || !root.is_block() {
            compiler.warn_misplaced(root, "top level");
            continue;
        }
        let node = compiler.panel(root, &path, true);
        if last == 0 {
            compiler.nodes[0].first_child = node;
        } else {
            compiler.nodes[last].next_sibling = node;
        }
        last = node as usize;
    }

    compiler.module.errors = parsed.errors.to_vec();
    compiler.module
}

/// Keys that declare child widgets rather than properties, allowed wherever
/// widgets can nest.
const ELEMENT_KEYS: [&str; 9] = [
    "panel", "row", "box", "label", "heading", "section", "button", "image", "list",
];

/// Properties every container (panel, row, box, list) understands.
const CONTAINER_PROPS: [&str; 21] = [
    "visible",
    "enabled",
    "width",
    "height",
    "min_width",
    "max_width",
    "min_height",
    "max_height",
    "direction",
    "align",
    "padding",
    "gap",
    "background",
    "background_image",
    "border",
    "scrollable",
    "tooltip",
    "floating",
    "x_pos",
    "y_pos",
    "id",
];

// TODO: Lints. Beyond per-key validation, warn about whole-node mistakes
// that today fail silently on screen — e.g. `scrollable = yes` with a `Fit`
// scroll axis and no `max_*` bound (never scrolls), a `list` id with no
// matching data, or a `$VAR` no binding ever provides.
struct Compiler {
    /// Built in place; `compile` returns it.
    module: UiModule,
    /// Baked into the nodes: the compiler is the only consumer.
    style: Style,
}

/// The compiler is a thin builder over the module it is producing.
impl core::ops::Deref for Compiler {
    type Target = UiModule;

    fn deref(&self) -> &UiModule {
        &self.module
    }
}

impl core::ops::DerefMut for Compiler {
    fn deref_mut(&mut self) -> &mut UiModule {
        &mut self.module
    }
}

impl Compiler {
    fn push(&mut self, node: UiNode) -> u32 {
        let index = self.nodes.len() as u32;
        self.module.nodes.push(node);
        index
    }

    fn warn(&mut self, message: &str) {
        self.module.warnings.push(message.to_string());
    }

    fn warn_misplaced(&mut self, node: &tabula::Node, path: &str) {
        if node.key.is_empty() {
            self.warn(&format!(
                "{path}: bare value or anonymous block — missing '='?"
            ));
        } else {
            self.warn(&format!("{path}: unknown key '{}'", node.key));
        }
    }

    /// Warns about every child key that is in none of the `properties`
    /// groups nor (when `elements` is set) a widget key.
    fn check_keys(
        &mut self,
        src: &tabula::Node,
        path: &str,
        properties: &[&[&str]],
        elements: bool,
    ) {
        for child in src.children {
            let known = properties.iter().any(|group| group.contains(&child.key))
                || (elements && ELEMENT_KEYS.contains(&child.key));
            if !known {
                self.warn_misplaced(child, path);
            }
        }
    }

    /// Tokenizes a source string into literal and `$VAR` segments, copying
    /// everything into the module's string buffer (the source dies with
    /// the scratch arena). Segments land contiguously in the seg table, so
    /// the returned range is only valid because nothing else pushes segs
    /// mid-call.
    fn text(&mut self, source: Option<&str>) -> Text {
        let source = match source {
            Some(source) if !source.is_empty() => source,
            _ => return Text::default(),
        };
        let start = self.segs.len() as u32;
        let bytes = source.as_bytes();
        let (mut pos, mut literal_start) = (0, 0);
        while pos < bytes.len() {
            if bytes[pos] == b'$' {
                let name_start = pos + 1;
                let mut name_end = name_start;
                while name_end < bytes.len()
                    && (bytes[name_end].is_ascii_alphanumeric() || bytes[name_end] == b'_')
                {
                    name_end += 1;
                }
                if name_end > name_start {
                    if literal_start < pos {
                        let literal = ModuleStr(Span::push_str(
                            &mut self.module.strings,
                            &source[literal_start..pos],
                        ));
                        self.module.segs.push(Seg {
                            literal,
                            var: ModuleStr::default(),
                        });
                    }
                    let literal = ModuleStr(Span::push_str(
                        &mut self.module.strings,
                        &source[pos..name_end],
                    ));
                    let var = ModuleStr(Span::push_str(
                        &mut self.module.strings,
                        &source[name_start..name_end],
                    ));
                    self.module.segs.push(Seg { literal, var });
                    pos = name_end;
                    literal_start = name_end;
                    continue;
                }
            }
            pos += 1;
        }
        if literal_start < bytes.len() {
            let literal = ModuleStr(Span::push_str(
                &mut self.module.strings,
                &source[literal_start..],
            ));
            self.module.segs.push(Seg {
                literal,
                var: ModuleStr::default(),
            });
        }
        Text {
            segs: SegRange(Span {
                start,
                len: self.segs.len() as u32 - start,
            }),
        }
    }

    /// Tokenizes a yes/no condition value (`visible`, `enabled`): `yes`/`no`
    /// or data via `$VAR`. A bare name never resolves to `yes`, so it would
    /// silently pin the condition off forever — warn instead.
    fn condition(&mut self, src: &tabula::Node, key: &str, path: &str) -> Text {
        let source = src.get_text(key);
        if let Some(value) = source {
            if !matches!(value, "" | "yes" | "no") && !value.contains('$') {
                self.warn(&format!(
                    "{path}: '{key} = {value}' is not yes/no or a $VAR binding"
                ));
            }
        }
        self.text(source)
    }

    fn yes(&mut self, src: &tabula::Node, key: &str, path: &str) -> bool {
        match src.get_text(key) {
            None => false,
            Some("yes") => true,
            Some("no") => false,
            Some(other) => {
                self.warn(&format!("{path}: '{key} = {other}' is not yes/no"));
                false
            }
        }
    }

    fn direction(&mut self, src: &tabula::Node, path: &str) -> Direction {
        match src.get_text("direction") {
            None | Some("vertical") => Direction::TopToBottom,
            Some("horizontal") => Direction::LeftToRight,
            Some(other) => {
                self.warn(&format!(
                    "{path}: 'direction = {other}' is not vertical/horizontal"
                ));
                Direction::TopToBottom
            }
        }
    }

    /// Bakes one script color: absent = `default`; a literal palette name
    /// (including `none`) bakes to its color, with unknown names warning
    /// and keeping the default; a `$VAR` name is kept for per-frame
    /// resolution with `default` as its fallback.
    fn paint(&mut self, src: &tabula::Node, key: &str, path: &str, default: Color) -> Paint {
        let name = match src.get_text(key) {
            Some(name) if !name.is_empty() => name,
            _ => return Paint::of(default),
        };
        if name.contains('$') {
            return Paint {
                color: default,
                name: self.text(Some(name)),
            };
        }
        match self.style.palette.color(name) {
            Some(color) => Paint::of(color),
            None => {
                self.warn(&format!("{path}: '{key} = {name}' is not a palette color"));
                Paint::of(default)
            }
        }
    }

    /// Parses one size property: `cap[:weight]`, where the cap is a pixel
    /// number, `N%` of the parent, or `grow` (uncapped), and `fit` is
    /// sugar for weight 0. Absent → the caller's default stands.
    fn size(&mut self, src: &tabula::Node, key: &str, path: &str) -> Option<Size> {
        let value = src.get_value(key)?;
        if value.is_number {
            // A bare number caps a default-weight grower.
            return Some(Size {
                cap: value.number.max(0.0),
                fraction: false,
                weight: 1.0,
            });
        }
        let text = value.text.trim();
        let (cap_text, weight) = match text.split_once(':') {
            None => (text, None),
            Some((cap_text, weight_text)) => match weight_text.trim().parse::<f32>() {
                Ok(weight) if weight >= 0.0 => (cap_text.trim(), Some(weight)),
                _ => {
                    self.warn(&format!("{path}: '{key} = {text}' has a bad weight"));
                    return None;
                }
            },
        };
        let mut size = if cap_text == "grow" {
            Size::GROW
        } else if cap_text == "fit" {
            if weight.is_some_and(|weight| weight != 0.0) {
                self.warn(&format!(
                    "{path}: '{key} = {text}' — fit means weight 0; drop the weight or use a cap"
                ));
            }
            return Some(Size::FIT);
        } else if let Some(percent) = cap_text.strip_suffix('%') {
            match percent.trim().parse::<f32>() {
                Ok(percent) => Size {
                    cap: (percent / 100.0).max(0.0),
                    fraction: true,
                    weight: 1.0,
                },
                Err(_) => {
                    self.warn(&format!("{path}: '{key} = {text}' has a bad percentage"));
                    return None;
                }
            }
        } else if let Ok(pixels) = cap_text.parse::<f32>() {
            // Quoted numbers skip tabula's number parsing; accept them.
            Size {
                cap: pixels.max(0.0),
                fraction: false,
                weight: 1.0,
            }
        } else {
            self.warn(&format!(
                "{path}: '{key} = {text}' is not a cap[:weight] — number, N%, grow or fit"
            ));
            return None;
        };
        if let Some(weight) = weight {
            size.weight = weight;
        }
        Some(size)
    }

    /// Reads the min/max constraints shared by every sized widget.
    fn constraints(&mut self, src: &tabula::Node, node: &mut UiNode) {
        node.min_width = src.get_number("min_width").unwrap_or(node.min_width);
        node.max_width = src.get_number("max_width").unwrap_or(node.max_width);
        node.min_height = src.get_number("min_height").unwrap_or(node.min_height);
        node.max_height = src.get_number("max_height").unwrap_or(node.max_height);
    }

    /// Reads the shared container properties into `node` over the caller's
    /// baked defaults.
    fn container(&mut self, src: &tabula::Node, path: &str, node: &mut UiNode) {
        // Floating first: it decides the size defaults below. `|=` so the
        // caller's top-level float can't be unset.
        if src.get("floating").is_some() {
            node.floating |= self.yes(src, "floating", path);
        }
        node.x_pos = src.get_number("x_pos").unwrap_or(node.x_pos);
        node.y_pos = src.get_number("y_pos").unwrap_or(node.y_pos);
        // Floaters have no parent share to claim: they fit unless sized.
        if node.floating {
            node.width = Size::FIT;
            node.height = Size::FIT;
        }
        if let Some(size) = self.size(src, "width", path) {
            node.width = size;
        }
        if let Some(size) = self.size(src, "height", path) {
            node.height = size;
        }
        self.constraints(src, node);
        if src.get("direction").is_some() {
            node.direction = self.direction(src, path);
        }
        match src.get_text("align") {
            None => {}
            Some("start") => (node.align_x, node.align_y) = (Align::Start, Align::Start),
            Some("center") => (node.align_x, node.align_y) = (Align::Center, Align::Center),
            Some("end") => (node.align_x, node.align_y) = (Align::End, Align::End),
            Some(other) => self.warn(&format!(
                "{path}: 'align = {other}' is not start/center/end"
            )),
        }
        if let Some(padding) = src.get_number("padding") {
            node.padding = Padding::all(padding);
        }
        if let Some(gap) = src.get_number("gap") {
            node.gap = gap;
        }
        node.background = self.paint(src, "background", path, node.background.color);
        node.image = self.text(src.get_text("background_image"));
        if self.yes(src, "border", path) {
            node.border_width = 1.0;
            node.border_color = self.style.palette.outline;
        }
        // Scrolling runs along the flow axis.
        if self.yes(src, "scrollable", path) {
            node.scroll_x = node.direction == Direction::LeftToRight;
            node.scroll_y = node.direction == Direction::TopToBottom;
        }
        node.tooltip = self.text(src.get_text("tooltip"));
        node.id = self.text(src.get_text("id"));
        node.visible = self.condition(src, "visible", path);
        node.enabled = self.condition(src, "enabled", path);
    }

    /// Compiles the widget children of a block into a sibling chain,
    /// returning the first index. Property keys are skipped silently — the
    /// caller's `check_keys` pass already vetted them.
    fn elements(&mut self, src: &tabula::Node, path: &str) -> u32 {
        let (mut first, mut last) = (0u32, 0u32);
        for child in src.children {
            let index = match child.key {
                "panel" => self.block(child, path, "panel", Self::nested_panel),
                "row" => self.block(child, path, "row", Self::row),
                "box" => self.block(child, path, "box", Self::boxed),
                "label" | "heading" | "section" => self.label(child, path),
                "button" => self.block(child, path, "button", Self::button),
                "image" => self.block(child, path, "image", Self::image),
                "list" => self.block(child, path, "list", Self::list),
                _ => 0,
            };
            if index == 0 {
                continue;
            }
            if first == 0 {
                first = index;
            } else {
                self.nodes[last as usize].next_sibling = index;
            }
            last = index;
        }
        first
    }

    /// Runs a widget compiler on `src` if it is a block, else warns.
    fn block(
        &mut self,
        src: &tabula::Node,
        path: &str,
        name: &str,
        compile: fn(&mut Self, &tabula::Node, &str) -> u32,
    ) -> u32 {
        if !src.is_block() {
            self.warn(&format!("{path}: '{name}' must be a {{ ... }} block"));
            return 0;
        }
        compile(self, src, &format!("{path} > {name}"))
    }

    fn nested_panel(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.panel(src, path, false)
    }

    fn panel(&mut self, src: &tabula::Node, path: &str, top_level: bool) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS], true);
        let style = self.style;
        let mut node = UiNode {
            // Unlike rows, panels stack vertically unless told otherwise.
            direction: Direction::TopToBottom,
            width: Size::GROW,
            height: Size::GROW,
            padding: Padding::all(style.padding),
            gap: style.gap,
            background: Paint::of(style.palette.panel),
            corner_radius: style.corner_radius,
            // Top-level panels have nothing to be in flow with: always
            // floating.
            floating: top_level,
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        self.nodes[index as usize].first_child = self.elements(src, path);
        index
    }

    /// A `row` is a panel with different defaults: horizontal, transparent,
    /// no padding. Pure compile-time sugar — the walk never knows.
    fn row(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS], true);
        let style = self.style;
        let mut node = UiNode {
            direction: Direction::LeftToRight,
            width: Size::GROW,
            height: Size::GROW,
            gap: style.gap,
            corner_radius: style.corner_radius,
            ..UiNode::default() // padding and background stay zero
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        self.nodes[index as usize].first_child = self.elements(src, path);
        index
    }

    /// A `box` is a pre-styled cell: it fills its slot, centers its
    /// content and gets the accent background. Pure compile-time sugar.
    fn boxed(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS], true);
        let style = self.style;
        let mut node = UiNode {
            direction: Direction::TopToBottom,
            width: Size::GROW,
            height: Size::GROW,
            align_x: Align::Center,
            align_y: Align::Center,
            padding: Padding::all(style.padding),
            gap: style.gap,
            background: Paint::of(style.palette.accent),
            corner_radius: style.corner_radius,
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        self.nodes[index as usize].first_child = self.elements(src, path);
        index
    }

    /// `label`, `heading` and `section` are one widget with different text
    /// roles baked in from the style.
    fn label(&mut self, src: &tabula::Node, path: &str) -> u32 {
        let style = self.style;
        let (role_size, role_color) = match src.key {
            "heading" => (style.heading_size, style.palette.ink),
            "section" => (style.section_size, style.palette.muted),
            _ => (style.text_size, style.palette.ink),
        };
        let node = if src.is_block() {
            let path = &format!("{path} > {}", src.key);
            self.check_keys(
                src,
                path,
                &[&[
                    "id",
                    "text",
                    "size",
                    "color",
                    "wrap",
                    "width",
                    "height",
                    "min_width",
                    "max_width",
                    "min_height",
                    "max_height",
                    "visible",
                    "enabled",
                    "tooltip",
                ]],
                false,
            );
            let mut node = UiNode {
                id: self.text(src.get_text("id")),
                text: self.text(src.get_text("text")),
                text_size: src.get_number("size").map_or(role_size, |size| size as u16),
                color: self.paint(src, "color", path, role_color),
                wrap: self.yes(src, "wrap", path),
                width: self.size(src, "width", path).unwrap_or(Size::FIT),
                height: self.size(src, "height", path).unwrap_or(Size::FIT),
                visible: self.condition(src, "visible", path),
                enabled: self.condition(src, "enabled", path),
                tooltip: self.text(src.get_text("tooltip")),
                ..UiNode::default()
            };
            self.constraints(src, &mut node);
            node
        } else {
            UiNode {
                text: self.text(Some(src.value.text)),
                text_size: role_size,
                color: Paint::of(role_color),
                ..UiNode::default()
            }
        };
        self.push(node)
    }

    fn button(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(
            src,
            path,
            &[&[
                "action",
                "id",
                "text",
                "width",
                "height",
                "min_width",
                "max_width",
                "min_height",
                "max_height",
                "tooltip",
                "visible",
                "enabled",
            ]],
            false,
        );
        let style = self.style;
        // Unsized buttons grow into the style's default caps.
        let default = |cap: f32| Size {
            cap,
            fraction: false,
            weight: 1.0,
        };
        let text = self.text(src.get_text("text"));
        let mut node = UiNode {
            action: self.text(src.get_text("action")),
            id: self.text(src.get_text("id")),
            width: self
                .size(src, "width", path)
                .unwrap_or(default(style.button_width)),
            height: self
                .size(src, "height", path)
                .unwrap_or(default(style.button_height)),
            align_x: Align::Center,
            align_y: Align::Center,
            padding: Padding::symmetric(10.0, 4.0),
            background: Paint::of(style.button_background),
            hover_background: style.button_hover,
            press_background: style.button_press,
            border_width: style.button_border_thickness,
            border_color: style.button_border_color,
            corner_radius: style.button_corner_radius,
            tooltip: self.text(src.get_text("tooltip")),
            visible: self.condition(src, "visible", path),
            enabled: self.condition(src, "enabled", path),
            ..UiNode::default()
        };
        self.constraints(src, &mut node);
        let index = self.push(node);
        if !text.is_empty() {
            // The caption is a plain child node, centered by the button's
            // own alignment.
            let child = self.push(UiNode {
                text,
                text_size: style.text_size,
                color: Paint::of(style.palette.ink),
                ..UiNode::default()
            });
            self.nodes[index as usize].first_child = child;
        }
        index
    }

    fn image(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(
            src,
            path,
            &[&[
                "source",
                "id",
                "width",
                "height",
                "min_width",
                "max_width",
                "min_height",
                "max_height",
                "tint",
                "fade",
                "background",
                "border",
                "tooltip",
                "visible",
                "enabled",
            ]],
            false,
        );
        if src.get("source").is_none() {
            self.warn(&format!("{path}: image without a 'source' draws nothing"));
        }
        let border = self.yes(src, "border", path);
        let mut node = UiNode {
            image: self.text(src.get_text("source")),
            id: self.text(src.get_text("id")),
            // Images fit their natural size; growing is opt-in.
            width: self.size(src, "width", path).unwrap_or(Size::FIT),
            height: self.size(src, "height", path).unwrap_or(Size::FIT),
            tint: self.paint(src, "tint", path, Color::default()),
            fade: src.get_number("fade").unwrap_or(0.0),
            background: self.paint(src, "background", path, Color::default()),
            border_width: if border { 1.0 } else { 0.0 },
            border_color: self.style.palette.outline,
            tooltip: self.text(src.get_text("tooltip")),
            visible: self.condition(src, "visible", path),
            enabled: self.condition(src, "enabled", path),
            ..UiNode::default()
        };
        self.constraints(src, &mut node);
        self.push(node)
    }

    fn list(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS, &["template"]], false);
        let style = self.style;
        let mut node = UiNode {
            direction: Direction::TopToBottom,
            width: Size::GROW,
            height: Size::GROW,
            gap: style.gap,
            corner_radius: style.corner_radius,
            // Padding and background stay zero: a list is stamping
            // machinery, not a visual box, unless the script says
            // otherwise.
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        match src.get("template") {
            Some(template) if template.is_block() => {
                let template_path = format!("{path} > template");
                self.check_keys(template, &template_path, &[], true);
                // A pure anchor for the stamped subtree: the walk splices
                // the template's elements straight into the list, so the
                // node itself never reaches layout.
                let template_index = self.push(UiNode::default());
                self.nodes[template_index as usize].first_child =
                    self.elements(template, &template_path);
                self.nodes[index as usize].template = template_index;
            }
            Some(_) => self.warn(&format!("{path}: 'template' must be a {{ ... }} block")),
            None => self.warn(&format!("{path}: list without a template stamps nothing")),
        }
        index
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tests compile against the default style unless they say otherwise.
    fn compile(source: &str) -> UiModule {
        super::compile(source, &Style::default())
    }

    fn node(module: &UiModule, index: u32) -> UiNode {
        module.nodes[index as usize]
    }

    /// One seg of a node's text, resolved to `(literal, var)` strings.
    fn seg<'m>(module: &'m UiModule, text: Text, index: usize) -> (&'m str, &'m str) {
        let seg = module.segs(text)[index];
        (module.str(seg.literal), module.str(seg.var))
    }

    /// A bare-number size: default-weight grower capped at `cap`.
    fn capped(cap: f32) -> Size {
        Size {
            cap,
            fraction: false,
            weight: 1.0,
        }
    }

    #[test]
    fn compiles_panels_with_properties() {
        let module = compile(
            "panel = { x_pos = 0.1 y_pos = 0.5 border = yes \
             direction = horizontal width = 120 label = \"a\" }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        assert!(panel.floating);
        assert_eq!(panel.border_width, 1.0);
        assert_eq!(panel.border_color, Style::default().palette.outline);
        assert_eq!((panel.x_pos, panel.y_pos), (0.1, 0.5));
        assert_eq!(panel.width, capped(120.0));
        assert_eq!(panel.direction, Direction::LeftToRight);
        // Style values are baked in at compile time.
        assert_eq!(panel.padding, Padding::all(Style::default().padding));
        assert_eq!(panel.gap, Style::default().gap);
        assert_eq!(panel.background.color, Style::default().palette.panel);
        assert!(panel.background.name.is_empty());

        let label = node(&module, panel.first_child);
        assert_eq!(seg(&module, label.text, 0).0, "a");
        assert_eq!(label.text_size, Style::default().text_size);
        assert_eq!(label.color.color, Style::default().palette.ink);
        assert_eq!(label.next_sibling, 0);
    }

    #[test]
    fn parses_logical_sizes_and_layout_properties() {
        let module = compile(
            "panel = { width = 92% max_width = 760 align = center padding = 22 gap = 12 \
             row = { height = 54 \
                 panel = { width = grow min_width = 70 tooltip = \"tip\" } \
                 panel = { width = grow:2 background = accent } } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        assert!(panel.width.fraction);
        assert!((panel.width.cap - 0.92).abs() < 1e-6);
        assert_eq!(panel.width.weight, 1.0);
        assert_eq!(panel.max_width, 760.0);
        assert_eq!(
            (panel.align_x, panel.align_y),
            (Align::Center, Align::Center)
        );
        assert_eq!(panel.padding, Padding::all(22.0));
        assert_eq!(panel.gap, 12.0);

        let row = node(&module, panel.first_child);
        assert_eq!(row.direction, Direction::LeftToRight);
        assert_eq!(row.width, Size::GROW);
        assert_eq!(row.height, capped(54.0));
        // Rows are transparent, flush cells.
        assert_eq!(row.background.color.a, 0.0);
        assert_eq!(row.padding, Padding::all(0.0));

        let one = node(&module, row.first_child);
        assert_eq!(one.width, Size::GROW);
        assert_eq!(one.min_width, 70.0);
        assert_eq!(seg(&module, one.tooltip, 0).0, "tip");

        let two = node(&module, one.next_sibling);
        assert_eq!((two.width.cap, two.width.weight), (0.0, 2.0));
        assert_eq!(two.background.color, Style::default().palette.accent);
    }

    #[test]
    fn cap_weight_grammar_covers_every_form() {
        let module = compile(
            "panel = { \
             panel = { width = \"180:2\" } \
             panel = { width = \"50%:3\" } \
             panel = { width = \"grow:0\" } \
             panel = { width = fit } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let root = node(&module, module.roots());
        let capped_weighted = node(&module, root.first_child);
        assert_eq!(
            (capped_weighted.width.cap, capped_weighted.width.weight),
            (180.0, 2.0)
        );
        let fraction = node(&module, capped_weighted.next_sibling);
        assert!(fraction.width.fraction);
        assert_eq!((fraction.width.cap, fraction.width.weight), (0.5, 3.0));
        let fit_spelled = node(&module, fraction.next_sibling);
        assert_eq!(fit_spelled.width, Size::FIT);
        let fit = node(&module, fit_spelled.next_sibling);
        assert_eq!(fit.width, Size::FIT);
    }

    #[test]
    fn bad_sizes_warn_and_fall_back() {
        let module = compile(
            "panel = { width = \"180:x\" height = \"fit:2\" min_width = 10 \
             panel = { width = wide } }",
        );
        assert!(module.errors.is_empty());
        let warnings = module.warnings.join("\n");
        assert!(warnings.contains("bad weight"), "{warnings}");
        assert!(warnings.contains("fit means weight 0"), "{warnings}");
        assert!(warnings.contains("cap[:weight]"), "{warnings}");

        let panel = node(&module, module.roots());
        // A bad size falls back to the widget's default; a floating
        // top-level panel fits its content.
        assert_eq!(panel.width, Size::FIT);
        assert_eq!(panel.height, Size::FIT, "fit:N keeps fit, drops weight");
        let inner = node(&module, panel.first_child);
        assert_eq!(inner.width, Size::GROW, "nested panels grow by default");
    }

    #[test]
    fn boxes_and_text_roles_carry_their_defaults() {
        let module = compile(
            "panel = { heading = \"Big\" section = \"SMALL\" \
             box = { min_width = 70 label = \"1x\" } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);
        let style = Style::default();

        let panel = node(&module, module.roots());
        let heading = node(&module, panel.first_child);
        assert_eq!(heading.text_size, style.heading_size);
        assert_eq!(heading.color.color, style.palette.ink);

        let section = node(&module, heading.next_sibling);
        assert_eq!(section.text_size, style.section_size);
        assert_eq!(section.color.color, style.palette.muted);

        let cell = node(&module, section.next_sibling);
        assert_eq!((cell.width, cell.height), (Size::GROW, Size::GROW));
        assert_eq!((cell.align_x, cell.align_y), (Align::Center, Align::Center));
        assert_eq!(cell.background.color, style.palette.accent);
        assert_eq!(cell.min_width, 70.0);

        let cell_label = node(&module, cell.first_child);
        assert_eq!(cell_label.text_size, style.text_size);
    }

    #[test]
    fn compiles_labels_images_and_floats() {
        let module = compile(
            "panel = { \
             panel = { floating = yes x_pos = 1 label = { text = \"FLOATING\" size = 13 } } \
             label = { id = body text = \"body\" color = muted wrap = yes width = grow tooltip = \"tip\" } \
             image = { source = soldier width = 96 height = 48 tint = accent fade = 0.5 border = yes } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        let badge = node(&module, panel.first_child);
        assert!(badge.floating);
        assert_eq!((badge.x_pos, badge.y_pos), (1.0, 0.0));
        // Floaters have no parent share to claim: they fit their content.
        assert_eq!((badge.width, badge.height), (Size::FIT, Size::FIT));
        let badge_label = node(&module, badge.first_child);
        assert_eq!(badge_label.text_size, 13);

        let body = node(&module, badge.next_sibling);
        assert!(body.wrap);
        assert_eq!(body.color.color, Style::default().palette.muted);
        assert_eq!(body.width, Size::GROW);
        // Ids and tooltips are orthogonal to widget vocabulary.
        assert_eq!(seg(&module, body.id, 0).0, "body");
        assert_eq!(seg(&module, body.tooltip, 0).0, "tip");

        let image = node(&module, body.next_sibling);
        assert_eq!(seg(&module, image.image, 0).0, "soldier");
        assert_eq!((image.width, image.height), (capped(96.0), capped(48.0)));
        assert_eq!(image.tint.color, Style::default().palette.accent);
        assert_eq!(image.fade, 0.5);
        assert_eq!(image.border_width, 1.0);
    }

    #[test]
    fn sibling_chain_preserves_declaration_order() {
        let module = compile(
            "panel = { label = \"one\" button = { text = \"two\" } label = \"three\" }\n\
             panel = { }",
        );
        let first_panel = node(&module, module.roots());
        let one = node(&module, first_panel.first_child);
        let two = node(&module, one.next_sibling);
        let three = node(&module, two.next_sibling);
        assert_eq!(seg(&module, one.text, 0).0, "one");
        // Buttons are recognizable by their baked hover skin; the caption
        // is a plain child node.
        assert!(two.hover_background.a > 0.0);
        assert_eq!(
            seg(&module, node(&module, two.first_child).text, 0).0,
            "two"
        );
        assert_eq!(seg(&module, three.text, 0).0, "three");
        assert_eq!(three.next_sibling, 0);

        let second_panel = node(&module, first_panel.next_sibling);
        assert_eq!(second_panel.first_child, 0);
    }

    #[test]
    fn tokenizes_variables() {
        let module = compile(
            "panel = { list = { id = l template = { \
             button = { id = \"element_$ID\" action = \"hire $ID\" text = \"$NAME!\" } } } }",
        );
        let panel = node(&module, module.roots());
        let list = node(&module, panel.first_child);
        let template = node(&module, list.template);

        let button = node(&module, template.first_child);
        assert_eq!(seg(&module, button.id, 0), ("element_", ""));
        assert_eq!(seg(&module, button.id, 1), ("$ID", "ID"));
        assert_eq!(seg(&module, button.action, 0), ("hire ", ""));
        assert_eq!(seg(&module, button.action, 1), ("$ID", "ID"));
        let caption = node(&module, button.first_child);
        assert_eq!(seg(&module, caption.text, 0), ("$NAME", "NAME"));
        assert_eq!(seg(&module, caption.text, 1), ("!", ""));
    }

    #[test]
    fn compiles_visible_conditions() {
        let module = compile(
            "panel = { visible = \"$CHARACTER_OPEN\" label = { text = a visible = no } \
             button = { text = b visible = \"$VISIBLE\" } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        assert_eq!(
            seg(&module, panel.visible, 0),
            ("$CHARACTER_OPEN", "CHARACTER_OPEN")
        );
        let label = node(&module, panel.first_child);
        assert_eq!(seg(&module, label.visible, 0).0, "no");
        let button = node(&module, label.next_sibling);
        assert_eq!(seg(&module, button.visible, 0), ("$VISIBLE", "VISIBLE"));
    }

    #[test]
    fn warns_on_bare_visible_names() {
        // Flag-style conditions are gone: a bare name would hide forever.
        let module = compile("panel = { visible = character_open }");
        assert!(module.errors.is_empty());
        let warnings = module.warnings.join("\n");
        assert!(
            warnings.contains("'visible = character_open' is not yes/no or a $VAR binding"),
            "{warnings}"
        );
    }

    #[test]
    fn bakes_the_style_and_keeps_dynamic_color_names() {
        let mut style = Style::default();
        style.padding = 5.0;
        style.heading_size = 40;
        style.button_background = Color::rgba(1.0, 0.0, 0.0, 1.0);
        style.button_hover = Color::rgba(0.0, 1.0, 0.0, 1.0);
        let module = super::compile(
            "panel = { heading = \"H\" button = { action = a text = b } \
             panel = { background = \"$ROW_COLOR\" } }",
            &style,
        );
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        assert_eq!(panel.padding, Padding::all(5.0));
        let heading = node(&module, panel.first_child);
        assert_eq!(heading.text_size, 40);
        let button = node(&module, heading.next_sibling);
        assert_eq!(button.background.color, style.button_background);
        assert_eq!(button.hover_background, style.button_hover);

        // A `$VAR` color keeps its name for per-frame resolution, with the
        // widget default as the fallback.
        let dynamic = node(&module, button.next_sibling);
        assert_eq!(seg(&module, dynamic.background.name, 0).1, "ROW_COLOR");
        assert_eq!(dynamic.background.color, style.palette.panel);

        // The palette rides in the module for those late names.
        assert_eq!(module.palette.accent, style.palette.accent);
    }

    #[test]
    fn warns_on_unknown_palette_names() {
        let module = compile("panel = { background = acent }");
        let warnings = module.warnings.join("\n");
        assert!(
            warnings.contains("'background = acent' is not a palette color"),
            "{warnings}"
        );
        // The default stands.
        let panel = node(&module, module.roots());
        assert_eq!(panel.background.color, Style::default().palette.panel);
    }

    #[test]
    fn globals_bind_outside_the_row_machinery() {
        let mut data = UiData::default();
        data.begin_list("l");
        data.begin_row();
        data.bind("A", "row");
        // Legal mid-fill: globals live in their own array, so the open
        // row's binding span is untouched.
        data.bind_global("STATUS", "Year 700");
        data.bind("B", "row");

        let row = data.rows(data.lists[0])[0];
        assert_eq!(data.bindings(row).len(), 2);
        assert_eq!(data.globals.len(), 1);
        assert_eq!(data.text(data.globals[0].key), "STATUS");
        assert_eq!(data.text(data.globals[0].value), "Year 700");
    }

    #[test]
    fn warns_on_unknown_keys_and_missing_equals() {
        let module = compile("panel = { frobnicate = 3 panel { } }\nlabel = \"top level\"");
        assert!(module.errors.is_empty());
        let warnings = module.warnings.join("\n");
        assert!(warnings.contains("unknown key 'frobnicate'"), "{warnings}");
        assert!(warnings.contains("missing '='"), "{warnings}");
        assert!(warnings.contains("unknown key 'label'"), "{warnings}");
    }

    #[test]
    fn warns_on_bad_sizes_and_flags() {
        let module =
            compile("panel = { width = wide row = { width = grow:fast floating = sideways } }");
        let warnings = module.warnings.join("\n");
        assert!(warnings.contains("not a cap[:weight]"), "{warnings}");
        assert!(warnings.contains("not yes/no"), "{warnings}");
        assert!(warnings.contains("bad weight"), "{warnings}");
        // Bad values fall back to the defaults instead of poisoning the
        // node: a floating top-level panel fits, the row grows.
        let panel = node(&module, module.roots());
        assert_eq!(panel.width, Size::FIT);
        let row = node(&module, panel.first_child);
        assert!(!row.floating);
        assert_eq!(row.width, Size::GROW);
    }

    #[test]
    fn recovers_around_parse_errors() {
        let module = compile("panel = { label = \"ok\" ");
        assert!(!module.errors.is_empty());
        let panel = node(&module, module.roots());
        assert!(panel.floating, "top-level panels always float");
        assert_eq!(
            seg(&module, node(&module, panel.first_child).text, 0).0,
            "ok"
        );
    }

    #[test]
    fn zii_empty_module() {
        let module = compile("");
        assert_eq!(module.roots(), 0);
        assert!(module.errors.is_empty() && module.warnings.is_empty());
        assert_eq!(UiModule::default().roots(), 0);
    }
}
