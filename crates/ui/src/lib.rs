//! The UI stack, bottom to top:
//!
//! - [`layout`] — renderer-independent immediate-mode layout engine:
//!   declare elements each frame, get draw commands back.
//! - [`ir`] — compiled UI descriptions: tabula script → flat IR, once per
//!   (re)load, plus the data format the UI binds against.
//! - [`run`] — the per-frame interpreter that walks the IR, declares
//!   elements into a layout pass, and collects triggered action ids.

pub mod ir;
pub mod layout;
pub mod run;
