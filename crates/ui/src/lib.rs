//! The UI stack, bottom to top:
//!
//! - [`layout`] — renderer-independent immediate-mode layout engine:
//!   declare elements each frame, get draw commands back.
//! - [`style`] — the cosmetics the scripts leave unspecified (palette,
//!   role font sizes, metrics), parsed from their own source per (re)load.
//! - [`ir`] — compiled UI descriptions: tabula script + style → flat IR,
//!   once per (re)load, with every style value baked in; plus the data
//!   format the UI binds against.
//! - [`run`] — the per-frame interpreter that walks the IR kind-blind,
//!   declares elements into a layout pass, and collects triggered action
//!   ids.

pub mod ir;
pub mod layout;
pub mod run;
pub use util::strings;
pub mod style;
