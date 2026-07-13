//! The UI stack, bottom to top:
//!
//! - [`layout`] — renderer-independent immediate-mode layout engine:
//!   declare elements each frame, get draw commands back.
//! - [`ir`] — compiled UI descriptions: tabula script → flat IR, once per
//!   (re)load, plus the data format the UI binds against.
//! - [`style`] — the cosmetics the scripts leave unspecified (palette,
//!   role font sizes, metrics), parsed from their own source per (re)load.
//! - [`run`] — the per-frame interpreter that walks the IR, declares
//!   elements into a layout pass (mixing in the style), and collects
//!   triggered action ids.

pub mod ir;
pub mod layout;
pub mod run;
pub use util::strings;
pub mod style;
