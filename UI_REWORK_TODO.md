# UI rework — handoff notes (written by Claude, for Claude)

Read this first when picking the UI work back up on another machine. It records how we
work, what exists in `src/ui.odin`, why it is shaped that way, and what comes next.
Everything here was true as of commit `d0e77de` plus the uncommitted changes that followed
(style overrides → base style, interaction, animations, checkbox, hashtable merge).

---

## 1. How we work (most important)

- **The user writes the code; Claude suggests and reviews.** Only edit source when the user
  explicitly asks ("do X for me", "implement this"). Otherwise give prose + short snippets
  and point at `file:line`. The user is rebuilding the UI by hand to own the mental model
  and to make sure nothing sneaks in. When they do ask for code, keep it small, match the
  surrounding style, and report exactly what changed.
- **Design dialogue before code.** Converge on the design in conversation first, offer a
  recommendation (not a survey), then implement. The user often pushes back — engage with
  the argument; concede when they are right, hold the point when they are not.
- **Match the existing style**: comment density (sparse, meaning not pattern labels),
  naming (`Ui_*` types, `ui_*` procs, `UI_*` constants, `UI` global), idioms (fixed-size
  arrays, id 0 = nil, flat loops over whole tables, no heap).
- **Named constants for colors**, never inline color literals (user asked explicitly).
- **No unrequested tests.**
- **Testing etiquette**: `odin check src` after every change; `odin build src -out:<scratch>`
  and run briefly to catch asserts. Screenshot **only the app window**
  (`screencapture -l<window id>`, window id via a tiny CoreGraphics swift script) — never the
  full screen (it once captured private content). **Do not post synthetic mouse events**:
  it moves the user's real cursor and mixes with their clicks (it produced fake
  "multiple clicks" bug reports). Ask the user to verify interactions instead.
- To look at the old ui2 demo privately: `git worktree add --detach <scratch>/old 2faa923`,
  build it, screenshot its window, then `git worktree remove` it.

## 2. Guiding design choice: follow RAD Debugger (Ryan Fleury) closely

The user explicitly prefers a **uniform** UI over per-widget custom looks, and trusts RAD's
model as proven. Reference sources (EpicGamesExt/raddebugger, fetch raw with curl):
`src/ui/ui_core.{h,c}`, `src/ui/ui_basic_widgets.{h,c}`, `src/ui/ui.mdesk`,
`src/raddbg/raddbg_core.c`, `src/raddbg/raddbg_widgets.c`.

What that means concretely:
- **Style stack is the source of truth.** A full base style is pushed in `ui_begin`
  (em-based sizes: width 10em, height 1.5em — RAD uses 20em × 3em with a smaller font).
  Precedence in `ui_box_make`: stack top → `next` → widget `forced`. **Widgets force only
  what defines them** (spacer's axis size, flags, text, child axis); callers style.
- **Widgets are compositions of plain boxes**; the renderer/layout know nothing about
  widget kinds. Example: `ui_checkbox` = clickable row + column(spacer, square(mark),
  spacer) + spacer + text box. Do not add widget-specific draw code or measuring hacks.
- **Animation is generic**: `ui_anim(label, target, initial)` returns an eased float; the
  widget decides what it means (alpha, size, offset). Like RAD's `ui_anim`.
- `ui_em(v)` = pixels × current (stack-top) font size, resolved at call time, like RAD.
- Centering is done with Grow spacers (RAD's `UI_Center` uses pct spacers + shrink).
  **No cross-axis alignment feature** — neither RAD nor ui2 have one.
- Labels in RAD are not text-height sized: boxes share a line height and text is centered
  vertically when drawn. `.Text` size kind exists but is mainly used for widths
  (`ui_text_dim()`), like RAD's `ui_text_dim`.

`src/ui2.odin` (+ `src/ui_demo.odin`) is the older AI-written version, kept for reference
only (commented out / not built). The user liked its demo buttons (Midnight theme); the
demo in `main.odin` now approximates that look.

## 3. What exists in `src/ui.odin` (and why)

**Storage** (all fixed tables in the `UI` global, no heap):
- `boxes[UI_BOX_MAX]` (id 0 = nil), free stack, `box_order` (pre-order build order),
  `memos[]` (per-id state that persists for keyed boxes), `blob` (interned text, reset each
  frame), parent stack, style stack + `style_next`, `sprites: ^Sprites`.
- `Ui_Hashtable($Id, $N)`: generic linear-probing key→id map with `ui_hashtable_find` /
  `ui_hashtable_save`. **Rebuilt from scratch every frame** in `ui_begin` from survivors, so
  it never needs deletion/tombstones. Used for boxes (`key_hash_table`) and anims
  (`anim_hash_table`). The pools around them (free stack, alloc, survivor rebuild) are
  still duplicated on purpose — merge only if a third pool appears.
- Keys: `ui_key_from_string` hashes (fnv64) seeded by the nearest *keyed* ancestor;
  `"###"` → key from the tail only; `##` hides the rest from display (Dear ImGui rules).
  Keyed boxes keep the same id across frames (that is what makes memos work). Unkeyed boxes
  get no signal. Rows/columns/labels/spacers are unkeyed; panels, buttons, checkboxes keyed.

**Layout** (`ui_layout`): sizes are `[2]Ui_Size` (plain arrays, not `[Axis]` — enumerated
array literals can't be positional; `[2]T` can still be indexed by `Axis`).
- Kinds: `Pixels`, `Text` (measured + 2×padding), `Fit` (sum/max of children + gaps +
  padding), `Grow` (content-sized like Fit, then takes leftover by weight).
- `strictness` (Fleury): on overflow, children give up `size × (1 − strictness) × fraction`.
  Cross axis: Grow takes the parent's inner size; others are clamped to it (strictness
  ignored, as in RAD). No min/max (removed in favor of strictness).
- Passes: independent sizes → X (bottom-up fit, top-down grow/shrink) → [TODO wrap slot] →
  Y → placement in `box_order` (absolute positions, padding + gap, start-aligned).
- A Fit container blocks Grow children from getting space — by design (user considered and
  rejected "transparent Fit").
- Percent-of-parent was deliberately **not** added (ui2's version had messy Fit
  interactions). If ever needed: resolve top-down only, 0 inside Fit parents.

**Style**: `Ui_Style` is a struct of `Maybe` fields (width, height, padding, gap,
background, hot_background, active_background, border, focus_border, thickness, radius,
font, text_color, disabled). Boxes hold plain inlined fields. `ui_style_push/pop`,
`ui_style_next` (accumulates), every widget takes `style := Ui_Style{}` which is routed
through `next`. Typed literals needed inside Maybe (`[2]f32{8, 8}`, not `{8, 8}`). Styles
containing a `Ui_Size` can't be compile-time constants → package globals. We rejected an
enum-indexed `[Var]Maybe(f32)` style (worse for readers) and a ui2-style tag/theme system
(not needed yet; a theme would just be a table of `Ui_Style` values to push).

**Drawing** (`ui_draw`, in `box_order` = painter's order): background (faded toward
hot/active by memo `hot_t`/`active_t` for `.Hot_Effects` boxes), border, text (left at
`padding.x`, vertically centered, clamped), focus ring (2px, `focus_border` × `focus_t`).
Everything × `alpha = 1 − 0.5 × disabled_t`. `draw_rectangle` thickness 0 = fill (the
`_lines` variant was deleted; beware passing softness positionally into thickness).

**Interaction** (all decided in `ui_end` after layout, read by widgets next frame — one
frame of latency, accepted for simplicity):
- Hit test walks `box_order` backwards: non-`.Clickable` boxes are skipped;
  `.Clickable & .Disabled` **blocks** (stops, nobody hot); clickable boxes must be keyed
  (asserted). Then `active_box` (press → release; while held nothing else is hot),
  `pressed` (one frame), `focus_box` (any press moves focus to the pressed `.Focusable`
  box or clears it). Active/focus are dropped if their box vanished or became disabled.
- `Ui_Signal { hovered, pressed, held, focused }`. **The user removed `clicked`** (release
  over the same box) and uses `.pressed` as the click; don't silently re-add it.
- Memo loop in `ui_end` eases `hot_t, active_t, focus_t, disabled_t` with
  `rate = 1 − exp(−16·dt)`; the same loop style eases every live `ui_anim`.
- `.Disabled` comes from style `disabled`, and children inherit it from their parent.

**Widgets** (bottom of `ui.odin`): `ui_row`, `ui_column`, `ui_panel` (containers via
`@(deferred_out)`, used as `if ui_row() { ... }`, return bool only), `ui_spacer` (forces
0 across the parent axis), `ui_label`, `ui_button`, `ui_checkbox(label, ^bool)` (mark fades
via `ui_anim("checked", ...)` keyed under the row). `ui_block` was removed.

**main.odin**: `ui_init(&GLOBAL.sprites)`, per frame `ui_begin(view)` → `demo_build(&demo)`
→ `ui_end(GLOBAL.input, &draw, dt)`. The demo pushes `MIDNIGHT` (named color constants from
ui2's Midnight palette) and uses `demo_label/demo_button/demo_checkbox` helpers that set
`width = text_dim`/`fit` and side padding via `next`.

## 4. Next steps (agreed order)

1. **Clipping + scrolling.** Clip rect per box (`.Clip` flag) → `draw_clip_push/pop` in
   `ui_draw`; hit test must respect clips; scroll offset per keyed box (memo or `ui_anim`
   for smoothing) applied in placement; content size for clamping. Needs **mouse wheel**
   events captured in `main.odin` (`Input` has no wheel yet). A scrolling axis should
   disable shrink/cross clamp (RAD's `AllowOverflowX/Y`).
2. **Floating boxes** (menus, popups, tooltips): excluded from parent fit/grow/cursor,
   absolute or anchored position, higher draw layer (`Draw_Ctx.layer`), hit-tested first
   and blocking underneath, close-on-outside-press, clamp to viewport. Root boxes currently
   always start at (0,0).
3. **Wrapped text** in the `TODO: Width-dependent measurements` slot: re-measure height of
   wrap boxes from their final width; needs a measure-only variant of `draw_text_wrapped`.
4. **Images**: an image box first (portraits/icons; `draw_image` exists), then rich text
   with inline icon runs (ui2 had `runs`).
5. Then: drag delta in the signal (sliders, scrollbars, movable windows), right-click /
   double-click, keyboard focus nav (Tab moves `focus_box`, Enter/Space activates),
   ellipsis truncation, eventually a text input field (biggest widget).

Other ideas discussed for later: an `opacity` style field (RAD's `UI_Transparency`),
`text_align` and a separate `text_padding` field, named button styles / a theme table,
`is_animating` to let the main loop idle, hot/active border fades.

## 5. Known leftovers / gotchas

- The parchment base style constants (`UI_PANEL_*`, `UI_LABEL_COLOR`, ...) are always
  overridden by the demo's `MIDNIGHT` push.
- Hashtable capacity equals pool size (high load factor possible); `2×` or a power of two
  would be cheaper to probe.
- `ui_em` / base style dereference `UI.sprites`: calling them before `ui_init` crashes.
- Parameters in Odin are immutable and not addressable: procs that slice fields (e.g.
  `sprite_of_glyph`'s binary search) must take pointers.
