//! The UI style, parsed from its own tabula source, once per (re)load.
//!
//! Style is an input to [`crate::ir::compile`], not to the per-frame walk:
//! role font sizes, paddings and palette colors are baked into the
//! compiled nodes, and a style edit is a recompile like any script edit.
//! [`parse`] mirrors [`crate::ir::compile`]: it never fails — every
//! recognized key overrides one [`Style::default`] field, and anything
//! wrong is reported as a warning while the default stands.

use arena::{AVec, Arena};

use crate::layout::Color;

/// Visuals the script format doesn't specify, plus the palette the script
/// refers to by name (`background = accent`). The zero value renders
/// invisibly but harmlessly; [`Style::default`] gives the built-in look.
#[derive(Clone, Copy)]
pub struct Style {
    pub palette: Palette,
    pub button_background: Color,
    pub button_hover: Color,
    pub button_press: Color,
    /// `0.0` = borderless buttons.
    pub button_border_thickness: f32,
    pub button_border_color: Color,
    pub button_corner_radius: f32,
    /// Default size cap for buttons the script doesn't size: they grow
    /// into it. `0.0` = uncapped. (Labels need no counterpart — they fit
    /// their text.)
    pub button_width: f32,
    pub button_height: f32,
    pub tooltip_background: Color,
    /// Tooltip text color, separate from `palette.ink` — the bubble keeps
    /// its own ground, so its text can't follow the panels' ink.
    pub tooltip_ink: Color,
    pub heading_size: u16,
    pub section_size: u16,
    pub text_size: u16,
    pub tooltip_size: u16,
    pub padding: f32,
    pub gap: f32,
    pub corner_radius: f32,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            palette: Palette {
                panel: Color::rgba(0.055, 0.067, 0.10, 0.9),
                dark: Color::rgba(0.03, 0.04, 0.07, 1.0),
                outline: Color::rgba(0.25, 0.29, 0.40, 1.0),
                ink: Color::rgba(0.94, 0.95, 1.0, 1.0),
                muted: Color::rgba(0.57, 0.62, 0.74, 1.0),
                accent: Color::rgba(0.43, 0.32, 0.92, 1.0),
            },
            button_background: Color::rgba(0.08, 0.68, 0.72, 1.0),
            button_hover: Color::rgba(0.16, 0.86, 0.90, 1.0),
            button_press: Color::rgba(0.38, 0.95, 0.98, 1.0),
            button_border_thickness: 0.0,
            button_border_color: Color::rgba(0.0, 0.0, 0.0, 1.0),
            button_corner_radius: 10.0,
            button_width: 0.0,
            button_height: 0.0,
            tooltip_background: Color::rgba(0.02, 0.03, 0.05, 0.95),
            tooltip_ink: Color::rgba(0.94, 0.95, 1.0, 1.0),
            heading_size: 28,
            section_size: 13,
            text_size: 16,
            tooltip_size: 14,
            padding: 12.0,
            gap: 8.0,
            corner_radius: 10.0,
        }
    }
}

/// The named colors scripts refer to (`background = accent`). A fixed,
/// compile-time set — one field per name, no lookup tables. It rides in
/// the compiled module so `$VAR` color names can still resolve per frame.
#[derive(Clone, Copy, Debug, Default)]
pub struct Palette {
    pub panel: Color,
    pub dark: Color,
    pub outline: Color,
    pub ink: Color,
    pub muted: Color,
    /// The one highlight color; everything the script wants to pop
    /// (`box`es, badges, tints) uses this.
    pub accent: Color,
}

impl Palette {
    /// Looks up a script color name. The palette is semantic on purpose —
    /// scripts say what a thing is, not which hue it has. `none` is "no
    /// color" (transparent); unknown names are `None` so callers can warn
    /// or fall back.
    pub fn color(&self, name: &str) -> Option<Color> {
        Some(match name {
            "panel" => self.panel,
            "dark" => self.dark,
            "outline" => self.outline,
            "ink" => self.ink,
            "muted" => self.muted,
            "accent" => self.accent,
            "none" => Color::default(),
            _ => return None,
        })
    }
}

/// A parsed style plus everything wrong with it. Warnings (including the
/// source's parse errors — style problems are never fatal) live in the
/// arena given to [`parse`].
#[derive(Clone, Copy, Default)]
pub struct StyleModule<'a> {
    pub style: Style,
    pub warnings: &'a [&'a str],
}

/// Style keys with a plain number value. Sizes are `u16` font sizes;
/// the metrics are logical points.
const NUMBER_KEYS: [&str; 11] = [
    "heading_size",
    "section_size",
    "text_size",
    "tooltip_size",
    "button_border_thickness",
    "button_corner_radius",
    "button_width",
    "button_height",
    "padding",
    "gap",
    "corner_radius",
];

/// Parse a style source: flat `key = value` pairs, one per [`Style`]
/// field. Colors are arrays `{ r g b a }` in 0-1, alpha optional.
pub fn parse<'a>(arena: &'a Arena, source: &str) -> StyleModule<'a> {
    let scratch = Arena::new();
    let parsed = tabula::parse(&scratch, source);

    let mut warnings = AVec::new_in(arena);
    let mut warn = |message: String| warnings.push(&*arena.alloc_str(&message));
    for error in parsed.errors {
        warn(error.to_string());
    }

    let mut style = Style::default();
    for node in parsed.roots {
        let slot = match node.key {
            "panel_background" => &mut style.palette.panel,
            "dark" => &mut style.palette.dark,
            "outline" => &mut style.palette.outline,
            "ink" => &mut style.palette.ink,
            "muted" => &mut style.palette.muted,
            "accent" => &mut style.palette.accent,
            "button_background" => &mut style.button_background,
            "button_hover" => &mut style.button_hover,
            "button_press" => &mut style.button_press,
            "button_border_color" => &mut style.button_border_color,
            "tooltip_background" => &mut style.tooltip_background,
            "tooltip_ink" => &mut style.tooltip_ink,
            key if NUMBER_KEYS.contains(&key) => {
                if !node.is_block() && node.value.is_number {
                    let number = node.value.number;
                    match key {
                        "heading_size" => style.heading_size = number as u16,
                        "section_size" => style.section_size = number as u16,
                        "text_size" => style.text_size = number as u16,
                        "tooltip_size" => style.tooltip_size = number as u16,
                        "button_border_thickness" => style.button_border_thickness = number,
                        "button_corner_radius" => style.button_corner_radius = number,
                        "button_width" => style.button_width = number,
                        "button_height" => style.button_height = number,
                        "padding" => style.padding = number,
                        "gap" => style.gap = number,
                        "corner_radius" => style.corner_radius = number,
                        _ => {}
                    }
                } else {
                    warn(format!("'{key}' is not a number"));
                }
                continue;
            }
            key => {
                warn(format!("unknown key '{key}'"));
                continue;
            }
        };
        match color(node) {
            Some(color) => *slot = color,
            None => warn(format!("'{}' is not a {{ r g b a }} color", node.key)),
        }
    }

    StyleModule {
        style,
        warnings: warnings.into_slice(),
    }
}

/// Parses a `{ r g b }` or `{ r g b a }` array of numbers, channels in
/// 0-1, alpha defaulting to 1.
fn color(node: &tabula::Node) -> Option<Color> {
    if !node.is_block() || !(3..=4).contains(&node.children.len()) {
        return None;
    }
    let mut channels = [0.0, 0.0, 0.0, 1.0];
    for (slot, child) in channels.iter_mut().zip(node.children) {
        if child.is_block() || !child.value.is_number || !child.key.is_empty() {
            return None;
        }
        *slot = child.value.number;
    }
    Some(Color::rgba(
        channels[0],
        channels[1],
        channels[2],
        channels[3],
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn overrides_defaults_and_keeps_the_rest() {
        let arena = Arena::new();
        let parsed = parse(
            &arena,
            "accent = { 1 0 0.5 }\ntooltip_background = { 0 0 0 0.5 }\ntext_size = 18\npadding = 6",
        );
        assert!(parsed.warnings.is_empty(), "{:?}", parsed.warnings);
        assert_eq!(parsed.style.palette.accent, Color::rgba(1.0, 0.0, 0.5, 1.0));
        assert_eq!(
            parsed.style.tooltip_background,
            Color::rgba(0.0, 0.0, 0.0, 0.5)
        );
        assert_eq!(parsed.style.text_size, 18);
        assert_eq!(parsed.style.padding, 6.0);
        assert_eq!(parsed.style.gap, Style::default().gap);
        assert_eq!(parsed.style.heading_size, Style::default().heading_size);
    }

    #[test]
    fn warns_and_falls_back_on_bad_input() {
        let arena = Arena::new();
        let parsed = parse(
            &arena,
            "accent = 3\ngap = wide\nfrobnicate = 1\nink = { 0.1 0.2 }\nmuted = { 0.1 0.2 x }",
        );
        let warnings = parsed.warnings.join("\n");
        assert!(
            warnings.contains("'accent' is not a { r g b a } color"),
            "{warnings}"
        );
        assert!(warnings.contains("'gap' is not a number"), "{warnings}");
        assert!(warnings.contains("unknown key 'frobnicate'"), "{warnings}");
        assert!(
            warnings.contains("'ink' is not a { r g b a } color"),
            "{warnings}"
        );
        assert!(
            warnings.contains("'muted' is not a { r g b a } color"),
            "{warnings}"
        );
        assert_eq!(parsed.style.palette.accent, Style::default().palette.accent);
        assert_eq!(parsed.style.gap, Style::default().gap);
        assert_eq!(parsed.style.palette.ink, Style::default().palette.ink);
        assert_eq!(parsed.style.palette.muted, Style::default().palette.muted);
    }

    #[test]
    fn zii_empty_style() {
        let arena = Arena::new();
        let parsed = parse(&arena, "");
        assert!(parsed.warnings.is_empty());
        assert_eq!(parsed.style.text_size, Style::default().text_size);
    }
}
