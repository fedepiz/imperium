//! The UI style, parsed from its own tabula source, once per (re)load.
//!
//! Style is a separate input to the per-frame interpreter, not part of the
//! compiled module: [`crate::run::run`] mixes it into the elements it
//! declares (role font sizes, palette colors the script names, paddings).
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
    /// `0.0` = borderless buttons.
    pub button_border_thickness: f32,
    pub button_border_color: Color,
    pub tooltip_background: Color,
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
            panel_background: Color::rgba(0.055, 0.067, 0.10, 0.9),
            dark: Color::rgba(0.03, 0.04, 0.07, 1.0),
            outline: Color::rgba(0.25, 0.29, 0.40, 1.0),
            ink: Color::rgba(0.94, 0.95, 1.0, 1.0),
            muted: Color::rgba(0.57, 0.62, 0.74, 1.0),
            accent: Color::rgba(0.43, 0.32, 0.92, 1.0),
            button_background: Color::rgba(0.08, 0.68, 0.72, 1.0),
            button_hover: Color::rgba(0.16, 0.86, 0.90, 1.0),
            button_border_thickness: 0.0,
            button_border_color: Color::rgba(0.0, 0.0, 0.0, 1.0),
            tooltip_background: Color::rgba(0.02, 0.03, 0.05, 0.95),
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

impl Style {
    /// Looks up a script color name. The palette is semantic on purpose —
    /// scripts say what a thing is, not which hue it has. `None` means "no
    /// color": both the explicit `none` and anything unknown (which stays
    /// invisible rather than guessing).
    pub(crate) fn color(&self, name: &str) -> Option<Color> {
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
const NUMBER_KEYS: [&str; 8] = [
    "heading_size",
    "section_size",
    "text_size",
    "tooltip_size",
    "button_border_thickness",
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
            "panel_background" => &mut style.panel_background,
            "dark" => &mut style.dark,
            "outline" => &mut style.outline,
            "ink" => &mut style.ink,
            "muted" => &mut style.muted,
            "accent" => &mut style.accent,
            "button_background" => &mut style.button_background,
            "button_hover" => &mut style.button_hover,
            "button_border_color" => &mut style.button_border_color,
            "tooltip_background" => &mut style.tooltip_background,
            key if NUMBER_KEYS.contains(&key) => {
                if !node.is_block() && node.value.is_number {
                    let number = node.value.number;
                    match key {
                        "heading_size" => style.heading_size = number as u16,
                        "section_size" => style.section_size = number as u16,
                        "text_size" => style.text_size = number as u16,
                        "tooltip_size" => style.tooltip_size = number as u16,
                        "button_border_thickness" => style.button_border_thickness = number,
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
        assert_eq!(parsed.style.accent, Color::rgba(1.0, 0.0, 0.5, 1.0));
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
        assert_eq!(parsed.style.accent, Style::default().accent);
        assert_eq!(parsed.style.gap, Style::default().gap);
        assert_eq!(parsed.style.ink, Style::default().ink);
        assert_eq!(parsed.style.muted, Style::default().muted);
    }

    #[test]
    fn zii_empty_style() {
        let arena = Arena::new();
        let parsed = parse(&arena, "");
        assert!(parsed.warnings.is_empty());
        assert_eq!(parsed.style.text_size, Style::default().text_size);
    }
}
