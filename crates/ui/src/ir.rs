//! Compiled UI descriptions: tabula source → flat IR, once per (re)load.
//!
//! The layout engine rebuilds every frame, so whatever describes the UI is
//! walked every frame too. The raw tabula tree is the wrong shape for that
//! (string key matching, `yes`/`no` atoms, number re-parsing), so [`compile`]
//! translates it once into [`UiNode`]s: a flat array of fat kind-tagged
//! structs with every field pre-parsed and every `$VAR` string
//! pre-tokenized. The module owns its storage outright (nodes, segs, one
//! string buffer), so it is `'static`, `Send`, and reloaded by
//! reassignment. The per-frame walk lives in [`crate::run`].
//!
//! The IR also defines the data the UI binds against ([`UiData`]): the
//! caller fetches rows from wherever it likes and hands them over in this
//! format, keeping the UI isolated from the rest of the game.

use arena::Arena;

use crate::layout::{Align, Direction, ImageId};
use util::strings::{Span, StrBuf};

/// What a [`UiNode`] is. Zero value = `None`, the reserved null node.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum NodeKind {
    #[default]
    None,
    /// Also `row` in the script: a row is a panel compiled with container
    /// defaults (horizontal, transparent, no padding, grow width).
    Panel,
    Label,
    Button,
    Image,
    List,
    /// The stamped-out subtree of a `List`; reached only through
    /// [`UiNode::template`], never through the sibling chain.
    Template,
}

/// Which of the style's text roles a label renders with. The script picks
/// one by widget key (`label`, `heading`, `section`); sizes and colors live
/// in the style, not the script. Zero value = `Body`.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum LabelStyle {
    #[default]
    Body,
    Heading,
    Section,
}

/// A pre-parsed script size: `cap[:weight]` per axis.
///
/// The cap is a ceiling — pixels, `N%` of the parent, or `grow` for none;
/// `fit` is sugar for weight 0. The weight is the element's share of the
/// parent's leftover space, `0` meaning "fit content". Every element
/// starts at its content floor, grows by weight, and stops at its cap.
///
/// Zero value = unset: the widget's default posture stands (see
/// [`crate::run`]).
#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct Size {
    /// False = the script said nothing for this axis.
    pub set: bool,
    /// The ceiling: pixels, or a 0..=1 fraction of the parent when
    /// `fraction` is set. `0.0` = uncapped.
    pub cap: f32,
    pub fraction: bool,
    /// Share of the parent's leftover space; `0.0` = fit content.
    pub weight: f32,
}

impl Size {
    /// An explicit "fill the parent" size: uncapped, weight 1.
    pub const GROW: Size = Size {
        set: true,
        cap: 0.0,
        fraction: false,
        weight: 1.0,
    };

    /// An explicit "fit content" size: uncapped, weight 0.
    pub const FIT: Size = Size {
        set: true,
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
    pub literal: Span,
    pub var: Span,
}

/// A string with its `$VAR` references found at compile time, so per-frame
/// interpolation never rescans: a range into [`UiModule::segs`]. Zero
/// value = no text.
#[derive(Clone, Copy, Debug, Default)]
pub struct Text {
    pub segs: Span,
}

impl Text {
    pub fn is_empty(&self) -> bool {
        self.segs.is_empty()
    }
}

/// One fat struct covers every widget; unused fields stay at their zero
/// value. Children are index links into the module's flat node array, with
/// `0` (the reserved null node) meaning "none".
#[derive(Clone, Copy, Debug, Default)]
pub struct UiNode {
    pub kind: NodeKind,
    pub first_child: u32,
    pub next_sibling: u32,
    /// Button action id / list binding id / template element id.
    pub id: Text,
    /// Label text / button text.
    pub text: Text,
    /// Floating containers: position as a fraction of the parent (the
    /// screen for top-level panels). 0 = flush left/top, 0.5 = centered,
    /// 1 = flush right/bottom.
    pub x_pos: f32,
    pub y_pos: f32,
    /// `floating = yes` lifts the element out of its parent's flow and
    /// pins it at `x_pos`/`y_pos`. Always set for top-level panels.
    pub floating: bool,
    pub width: Size,
    pub height: Size,
    /// `0.0` = unconstrained.
    pub min_width: f32,
    pub max_width: f32,
    pub min_height: f32,
    pub max_height: f32,
    pub border: bool,
    pub scrollable: bool,
    pub direction: Direction,
    /// Both axes come from the single `align` key; zero = start.
    pub align_x: Align,
    pub align_y: Align,
    /// Style overrides; the `_set` flags distinguish "unset, use the style"
    /// from an explicit zero.
    pub padding: f32,
    pub padding_set: bool,
    pub gap: f32,
    pub gap_set: bool,
    /// Palette name ("accent", "none", ...), interpolatable so rows can
    /// bind it. Empty = the widget's default.
    pub background: Text,
    /// Labels: which style text role to render with.
    pub label_style: LabelStyle,
    /// Labels: palette name for the ink. Empty = the role's default.
    pub color: Text,
    /// Labels: font size override, `0` = the role's default.
    pub text_size: u16,
    /// Labels: wrap to the element width.
    pub wrap: bool,
    /// Image widgets: the image key resolved through [`UiData::images`].
    /// Containers: background image key (tiling is the renderer's call).
    pub image: Text,
    /// Image widgets: palette name to tint with. Empty = untinted.
    pub tint: Text,
    /// Image widgets: `0.0` = fully opaque.
    pub fade: f32,
    /// Visibility, resolved per frame: the interpolated text must be
    /// empty or `yes` to show the element. Conditions come from data via
    /// `$VAR` (row bindings, then globals); a missing binding keeps its
    /// `$NAME` spelling and hides. Zero value = shown.
    pub visible: Text,
    /// Hover tooltip text; empty = none.
    pub tooltip: Text,
    /// `List` only: index of the `Template` node, `0` = none.
    pub template: u32,
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
    pub strings: StrBuf,
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

    pub fn str(&self, span: Span) -> &str {
        self.strings.get(span)
    }

    pub fn segs(&self, text: Text) -> &[Seg] {
        &self.segs[text.segs.range()]
    }
}

/// One `$VAR` binding: `key` is the variable name without the `$`. Spans
/// index [`UiData::strings`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Binding {
    pub key: Span,
    pub value: Span,
}

/// The bindings one stamped-out template instance interpolates from:
/// a range into [`UiData::bindings`].
#[derive(Clone, Copy, Debug, Default)]
pub struct Row {
    pub bindings: Span,
}

/// The rows behind one `list`, matched to it by `id` (a string span);
/// `rows` ranges into [`UiData::rows`].
#[derive(Clone, Copy, Debug, Default)]
pub struct ListData {
    pub id: Span,
    pub rows: Span,
}

/// One image the script can reference by key (`image = { id = soldier }`),
/// with its renderer handle and natural size.
#[derive(Clone, Copy, Debug, Default)]
pub struct ImageData {
    pub key: Span,
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
    pub strings: StrBuf,
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

    pub fn text(&self, span: Span) -> &str {
        self.strings.get(span)
    }

    /// Starts a new list; subsequent `begin_row` calls belong to it.
    pub fn begin_list(&mut self, id: &str) {
        let id = self.strings.push(id);
        self.lists.push(ListData {
            id,
            rows: Span {
                start: self.rows.len() as u32,
                len: 0,
            },
        });
    }

    /// Starts a new row in the current list; subsequent `bind` calls
    /// belong to it. Without a `begin_list` first, the row is orphaned
    /// (harmless: nothing ranges over it).
    pub fn begin_row(&mut self) {
        let row = Row {
            bindings: Span {
                start: self.bindings.len() as u32,
                len: 0,
            },
        };
        self.rows.push(row);
        if let Some(list) = self.lists.last_mut() {
            list.rows.len += 1;
        }
    }

    /// Adds a `$key = value` binding to the current row. Without a
    /// `begin_row` first, the binding is orphaned (harmless).
    pub fn bind(&mut self, key: &str, value: &str) {
        let binding = Binding {
            key: self.strings.push(key),
            value: self.strings.push(value),
        };
        self.bindings.push(binding);
        if let Some(row) = self.rows.last_mut() {
            row.bindings.len += 1;
        }
    }

    /// Adds a `$key = value` binding to the root scope: visible to every
    /// element, shadowed by a row binding of the same key. Legal at any
    /// point during the fill — globals live outside the row/list spans.
    pub fn bind_global(&mut self, key: &str, value: &str) {
        let binding = Binding {
            key: self.strings.push(key),
            value: self.strings.push(value),
        };
        self.globals.push(binding);
    }

    pub fn add_image(&mut self, key: &str, image: ImageId, width: f32, height: f32) {
        let key = self.strings.push(key);
        self.images.push(ImageData {
            key,
            image,
            width,
            height,
        });
    }

    pub fn rows(&self, list: ListData) -> &[Row] {
        &self.rows[list.rows.range()]
    }

    pub fn bindings(&self, row: Row) -> &[Binding] {
        &self.bindings[row.bindings.range()]
    }
}

/// Parse and compile a UI description. Never fails: whatever could be
/// recovered is compiled, with the rest reported in `errors`/`warnings`.
/// The tabula tree lives in a scratch arena that dies here; only the
/// owned IR (with its strings copied over) survives.
pub fn compile(source: &str) -> UiModule {
    let scratch = Arena::new();
    let parsed = tabula::parse(&scratch, source);

    let mut compiler = Compiler {
        module: UiModule::default(),
    };
    compiler.nodes.push(UiNode::default()); // node 0: the null node

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
const CONTAINER_PROPS: [&str; 20] = [
    "visible",
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
                        let literal = self.module.strings.push(&source[literal_start..pos]);
                        self.module.segs.push(Seg {
                            literal,
                            var: Span::default(),
                        });
                    }
                    let literal = self.module.strings.push(&source[pos..name_end]);
                    let var = self.module.strings.push(&source[name_start..name_end]);
                    self.module.segs.push(Seg { literal, var });
                    pos = name_end;
                    literal_start = name_end;
                    continue;
                }
            }
            pos += 1;
        }
        if literal_start < bytes.len() {
            let literal = self.module.strings.push(&source[literal_start..]);
            self.module.segs.push(Seg {
                literal,
                var: Span::default(),
            });
        }
        Text {
            segs: Span {
                start,
                len: self.segs.len() as u32 - start,
            },
        }
    }

    /// Tokenizes a `visible` value. Visibility is `yes`/`no` or comes from
    /// data via `$VAR`; a bare name never resolves to `yes`, so it would
    /// silently hide the element forever — warn instead.
    fn visible(&mut self, src: &tabula::Node, path: &str) -> Text {
        let source = src.get_text("visible");
        if let Some(value) = source {
            if !matches!(value, "" | "yes" | "no") && !value.contains('$') {
                self.warn(&format!(
                    "{path}: 'visible = {value}' is not yes/no or a $VAR binding"
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

    /// Parses one size property: `cap[:weight]`, where the cap is a pixel
    /// number, `N%` of the parent, or `grow` (uncapped), and `fit` is
    /// sugar for weight 0. Absent → the caller's default stands.
    fn size(&mut self, src: &tabula::Node, key: &str, path: &str) -> Option<Size> {
        let value = src.get_value(key)?;
        if value.is_number {
            // A bare number caps a default-weight grower.
            return Some(Size {
                set: true,
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
                    set: true,
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
                set: true,
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

    /// Reads the shared container properties into `node`, leaving whatever
    /// the caller pre-filled (the per-kind defaults) alone for absent keys.
    fn container(&mut self, src: &tabula::Node, path: &str, node: &mut UiNode) {
        if let Some(size) = self.size(src, "width", path) {
            node.width = size;
        }
        if let Some(size) = self.size(src, "height", path) {
            node.height = size;
        }
        node.min_width = src.get_number("min_width").unwrap_or(node.min_width);
        node.max_width = src.get_number("max_width").unwrap_or(node.max_width);
        node.min_height = src.get_number("min_height").unwrap_or(node.min_height);
        node.max_height = src.get_number("max_height").unwrap_or(node.max_height);
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
            node.padding = padding;
            node.padding_set = true;
        }
        if let Some(gap) = src.get_number("gap") {
            node.gap = gap;
            node.gap_set = true;
        }
        if src.get("background").is_some() {
            node.background = self.text(src.get_text("background"));
        }
        node.image = self.text(src.get_text("background_image"));
        if src.get("border").is_some() {
            node.border = self.yes(src, "border", path);
        }
        if src.get("scrollable").is_some() {
            node.scrollable = self.yes(src, "scrollable", path);
        }
        node.tooltip = self.text(src.get_text("tooltip"));
        if src.get("floating").is_some() {
            node.floating = self.yes(src, "floating", path);
        }
        node.x_pos = src.get_number("x_pos").unwrap_or(node.x_pos);
        node.y_pos = src.get_number("y_pos").unwrap_or(node.y_pos);
        node.id = self.text(src.get_text("id"));
        node.visible = self.visible(src, path);
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
                "label" => self.label(child, path, LabelStyle::Body),
                "heading" => self.label(child, path, LabelStyle::Heading),
                "section" => self.label(child, path, LabelStyle::Section),
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
        let mut node = UiNode {
            kind: NodeKind::Panel,
            // Unlike rows, panels stack vertically unless told otherwise.
            direction: Direction::TopToBottom,
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        // Top-level panels have nothing to be in flow with: always floating.
        node.floating |= top_level;
        let index = self.push(node);
        self.nodes[index as usize].first_child = self.elements(src, path);
        index
    }

    /// A `row` is a panel with container defaults: horizontal, transparent,
    /// no padding, grow width. Pure compile-time sugar.
    fn row(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS], true);
        let mut node = UiNode {
            kind: NodeKind::Panel,
            direction: Direction::LeftToRight,
            width: Size::GROW,
            background: self.text(Some("none")),
            padding_set: true, // padding stays 0.0
            ..UiNode::default()
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
        let mut node = UiNode {
            kind: NodeKind::Panel,
            direction: Direction::TopToBottom,
            width: Size::GROW,
            height: Size::GROW,
            align_x: Align::Center,
            align_y: Align::Center,
            background: self.text(Some("accent")),
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        self.nodes[index as usize].first_child = self.elements(src, path);
        index
    }

    fn label(&mut self, src: &tabula::Node, path: &str, style: LabelStyle) -> u32 {
        let node = if src.is_block() {
            let path = &format!("{path} > label");
            self.check_keys(
                src,
                path,
                &[&[
                    "id", "text", "size", "color", "wrap", "width", "height", "visible", "tooltip",
                ]],
                false,
            );
            UiNode {
                kind: NodeKind::Label,
                label_style: style,
                id: self.text(src.get_text("id")),
                text: self.text(src.get_text("text")),
                text_size: src.get_number("size").unwrap_or(0.0) as u16,
                color: self.text(src.get_text("color")),
                wrap: self.yes(src, "wrap", path),
                width: self.size(src, "width", path).unwrap_or_default(),
                height: self.size(src, "height", path).unwrap_or_default(),
                visible: self.visible(src, path),
                tooltip: self.text(src.get_text("tooltip")),
                ..UiNode::default()
            }
        } else {
            UiNode {
                kind: NodeKind::Label,
                label_style: style,
                text: self.text(Some(src.value.text)),
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
            ]],
            false,
        );
        let node = UiNode {
            kind: NodeKind::Button,
            id: self.text(src.get_text("id")),
            text: self.text(src.get_text("text")),
            width: self.size(src, "width", path).unwrap_or_default(),
            height: self.size(src, "height", path).unwrap_or_default(),
            min_width: src.get_number("min_width").unwrap_or(0.0),
            max_width: src.get_number("max_width").unwrap_or(0.0),
            min_height: src.get_number("min_height").unwrap_or(0.0),
            max_height: src.get_number("max_height").unwrap_or(0.0),
            tooltip: self.text(src.get_text("tooltip")),
            visible: self.visible(src, path),
            ..UiNode::default()
        };
        self.push(node)
    }

    fn image(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(
            src,
            path,
            &[&[
                "id",
                "width",
                "height",
                "tint",
                "fade",
                "background",
                "border",
                "tooltip",
                "visible",
            ]],
            false,
        );
        let node = UiNode {
            kind: NodeKind::Image,
            image: self.text(src.get_text("id")),
            width: self.size(src, "width", path).unwrap_or_default(),
            height: self.size(src, "height", path).unwrap_or_default(),
            tint: self.text(src.get_text("tint")),
            fade: src.get_number("fade").unwrap_or(0.0),
            background: self.text(src.get_text("background")),
            border: self.yes(src, "border", path),
            tooltip: self.text(src.get_text("tooltip")),
            visible: self.visible(src, path),
            ..UiNode::default()
        };
        self.push(node)
    }

    fn list(&mut self, src: &tabula::Node, path: &str) -> u32 {
        self.check_keys(src, path, &[&CONTAINER_PROPS, &["template"]], false);
        let mut node = UiNode {
            kind: NodeKind::List,
            direction: Direction::TopToBottom,
            ..UiNode::default()
        };
        self.container(src, path, &mut node);
        let index = self.push(node);
        match src.get("template") {
            Some(template) if template.is_block() => {
                let template_path = format!("{path} > template");
                self.check_keys(template, &template_path, &[&["id"]], true);
                let template_node = UiNode {
                    kind: NodeKind::Template,
                    id: self.text(template.get_text("id")),
                    ..UiNode::default()
                };
                let template_index = self.push(template_node);
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
            set: true,
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
        assert_eq!(panel.kind, NodeKind::Panel);
        assert!(panel.floating && panel.border);
        assert_eq!((panel.x_pos, panel.y_pos), (0.1, 0.5));
        assert_eq!(panel.width, capped(120.0));
        assert_eq!(panel.direction, Direction::LeftToRight);

        let label = node(&module, panel.first_child);
        assert_eq!(label.kind, NodeKind::Label);
        assert_eq!(seg(&module, label.text, 0).0, "a");
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
        assert!(panel.width.set && panel.width.fraction);
        assert!((panel.width.cap - 0.92).abs() < 1e-6);
        assert_eq!(panel.width.weight, 1.0);
        assert_eq!(panel.max_width, 760.0);
        assert_eq!(
            (panel.align_x, panel.align_y),
            (Align::Center, Align::Center)
        );
        assert!(panel.padding_set && panel.padding == 22.0);
        assert!(panel.gap_set && panel.gap == 12.0);

        let row = node(&module, panel.first_child);
        assert_eq!(row.kind, NodeKind::Panel);
        assert_eq!(row.direction, Direction::LeftToRight);
        assert_eq!(row.width, Size::GROW);
        assert_eq!(row.height, capped(54.0));
        assert_eq!(seg(&module, row.background, 0).0, "none");
        assert!(row.padding_set && row.padding == 0.0);

        let one = node(&module, row.first_child);
        assert_eq!(one.width, Size::GROW);
        assert_eq!(one.min_width, 70.0);
        assert_eq!(seg(&module, one.tooltip, 0).0, "tip");

        let two = node(&module, one.next_sibling);
        assert_eq!((two.width.cap, two.width.weight), (0.0, 2.0));
        assert_eq!(seg(&module, two.background, 0).0, "accent");
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
        assert!(!panel.width.set, "bad size falls back to unset");
        assert_eq!(panel.height, Size::FIT, "fit:N keeps fit, drops weight");
    }

    #[test]
    fn boxes_and_text_roles_carry_their_defaults() {
        let module = compile(
            "panel = { heading = \"Big\" section = \"SMALL\" \
             box = { min_width = 70 label = \"1x\" } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        let heading = node(&module, panel.first_child);
        assert_eq!(heading.kind, NodeKind::Label);
        assert_eq!(heading.label_style, LabelStyle::Heading);

        let section = node(&module, heading.next_sibling);
        assert_eq!(section.label_style, LabelStyle::Section);

        let cell = node(&module, section.next_sibling);
        assert_eq!(cell.kind, NodeKind::Panel);
        assert_eq!((cell.width, cell.height), (Size::GROW, Size::GROW));
        assert_eq!((cell.align_x, cell.align_y), (Align::Center, Align::Center));
        assert_eq!(seg(&module, cell.background, 0).0, "accent");
        assert_eq!(cell.min_width, 70.0);

        let cell_label = node(&module, cell.first_child);
        assert_eq!(cell_label.label_style, LabelStyle::Body);
    }

    #[test]
    fn compiles_labels_images_and_floats() {
        let module = compile(
            "panel = { \
             panel = { floating = yes x_pos = 1 label = { text = \"FLOATING\" size = 13 } } \
             label = { id = body text = \"body\" color = muted wrap = yes width = grow tooltip = \"tip\" } \
             image = { id = soldier width = 96 height = 48 tint = accent fade = 0.5 border = yes } }",
        );
        assert!(module.errors.is_empty());
        assert!(module.warnings.is_empty(), "{:?}", module.warnings);

        let panel = node(&module, module.roots());
        let badge = node(&module, panel.first_child);
        assert!(badge.floating);
        assert_eq!((badge.x_pos, badge.y_pos), (1.0, 0.0));
        let badge_label = node(&module, badge.first_child);
        assert_eq!(badge_label.text_size, 13);

        let body = node(&module, badge.next_sibling);
        assert_eq!(body.kind, NodeKind::Label);
        assert!(body.wrap);
        assert_eq!(seg(&module, body.color, 0).0, "muted");
        assert_eq!(body.width, Size::GROW);
        // Ids and tooltips are orthogonal to kind: labels carry them too.
        assert_eq!(seg(&module, body.id, 0).0, "body");
        assert_eq!(seg(&module, body.tooltip, 0).0, "tip");

        let image = node(&module, body.next_sibling);
        assert_eq!(image.kind, NodeKind::Image);
        assert_eq!(seg(&module, image.image, 0).0, "soldier");
        assert_eq!((image.width, image.height), (capped(96.0), capped(48.0)));
        assert_eq!(seg(&module, image.tint, 0).0, "accent");
        assert_eq!(image.fade, 0.5);
        assert!(image.border);
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
        assert_eq!(one.kind, NodeKind::Label);
        assert_eq!(two.kind, NodeKind::Button);
        assert_eq!(three.kind, NodeKind::Label);
        assert_eq!(three.next_sibling, 0);

        let second_panel = node(&module, first_panel.next_sibling);
        assert_eq!(second_panel.kind, NodeKind::Panel);
        assert_eq!(second_panel.first_child, 0);
    }

    #[test]
    fn tokenizes_variables() {
        let module = compile(
            "panel = { list = { id = l template = { id = \"element_$ID\" \
             button = { id = \"hire $ID\" text = \"$NAME!\" } } } }",
        );
        let panel = node(&module, module.roots());
        let list = node(&module, panel.first_child);
        let template = node(&module, list.template);
        assert_eq!(template.kind, NodeKind::Template);

        assert_eq!(seg(&module, template.id, 0), ("element_", ""));
        assert_eq!(seg(&module, template.id, 1), ("$ID", "ID"));

        let button = node(&module, template.first_child);
        assert_eq!(seg(&module, button.text, 0), ("$NAME", "NAME"));
        assert_eq!(seg(&module, button.text, 1), ("!", ""));
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
        // Bad values fall back to the defaults instead of poisoning the node.
        let panel = node(&module, module.roots());
        assert_eq!(panel.width, Size::default());
        let row = node(&module, panel.first_child);
        assert!(!row.floating);
    }

    #[test]
    fn recovers_around_parse_errors() {
        let module = compile("panel = { label = \"ok\" ");
        assert!(!module.errors.is_empty());
        assert_eq!(node(&module, module.roots()).kind, NodeKind::Panel);
    }

    #[test]
    fn zii_empty_module() {
        let module = compile("");
        assert_eq!(module.roots(), 0);
        assert!(module.errors.is_empty() && module.warnings.is_empty());
        assert_eq!(UiModule::default().roots(), 0);
    }
}
