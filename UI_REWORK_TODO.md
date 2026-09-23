# UI rework — handoff notes (written by Claude, for Claude)

Read this first when picking the UI work back up on another machine. It records how we
work, what exists in `src/ui.odin`, why it is shaped that way, and what comes next.
Everything here was true as of commit `232c876` (clipping, scrolling, scrollbar, drag).

---

## 1. How we work (most important)

- **The user writes the code; Claude suggests and reviews.** Only edit source when the user
  explicitly asks ("do X for me", "implement this"). Otherwise give prose + short snippets
  and point at `file:line`. The user is rebuilding the UI by hand to own the mental model
  and to make sure nothing sneaks in. When they do ask for code, keep it small, match the
  surrounding style, and report exactly what changed.
- **Design dialogue before code.** Converge on the design in conversation first, offer a
  recommendation (not a survey), then implement. The user often pushes back — engage with
  the argument; concede when they are right, hold the point when they are not. When the
  user picks an option (e.g. RAD-style flat reset over a persist sub-struct), follow it.
- **Match the existing style**: comment density (sparse, meaning not pattern labels),
  naming (`Ui_*` types, `ui_*` procs, `UI_*` constants, `UI` global), idioms (fixed-size
  arrays, id 0 = nil, flat loops over whole tables, no heap).
- **Named constants for colors**, never inline color literals (user asked explicitly).
- **No unrequested tests.**
- **Testing etiquette**: `odin check src` after every change; `odin build src -out:<scratch>`
  and run briefly to catch asserts. Screenshot **only the app window** — never the full
  screen (it once captured private content).
  - macOS: `screencapture -l<window id>`, window id via a tiny CoreGraphics swift script.
  - Windows: a small PowerShell script using `user32!PrintWindow` on the process's
    `MainWindowHandle` (kept in the session scratchpad; rewrite it if missing).
  - Run from the repo root so `assets/` resolves.
- **Do not post synthetic mouse events**: it moves the user's real cursor and mixes with
  their clicks (it produced fake "multiple clicks" bug reports). To test interaction
  privately, copy `src/*.odin` into a scratch dir, fake `GLOBAL.input` (wheel, pos, button
  down/pressed, driven by a `@(static)` frame counter) just before `ui_begin` in the copy's
  `main.odin`, build that, and screenshot it. Otherwise ask the user to verify.
  The user may be moving their real mouse over a launched window: an unexpected hover,
  focus ring or scroll in a capture is usually them, not a bug — recapture to confirm.
- To look at the old ui2 demo privately: `git worktree add --detach <scratch>/old 2faa923`,
  build it, screenshot its window, then `git worktree remove` it.
- Source files use CRLF line endings; keep them CRLF when editing with scripts.

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
  widget kinds. Examples: `ui_checkbox` = clickable row + column(spacer, square(mark),
  spacer) + spacer + text box; `ui_scrollbar` = track + (spacer, thumb, spacer) with Grow
  weights. Do not add widget-specific draw code or measuring hacks (ui2 did both).
- **Animation is generic**: `ui_anim(label, target, initial)` returns an eased float; the
  widget decides what it means (alpha, size, offset). Like RAD's `ui_anim`.
- `ui_em(v)` = pixels × current (stack-top) font size, resolved at call time, like RAD.
- Centering is done with Grow spacers (RAD's `UI_Center` uses pct spacers + shrink).
  **No cross-axis alignment feature** — neither RAD nor ui2 have one.
- Labels in RAD are not text-height sized: boxes share a line height and text is centered
  vertically when drawn. `.Text` size kind exists but is mainly used for widths
  (`ui_text_dim()`), like RAD's `ui_text_dim`.
- **Grow weights stand in for percentages**: proportional splits (the scrollbar thumb) are
  Grow children with weights; percent sizing is still deliberately absent.

`src/ui2.odin` (+ `src/ui_demo.odin`) is the older AI-written version, kept for reference
only (commented out / not built). The user liked its demo buttons (Midnight theme); the
demo in `main.odin` now approximates that look.

## 3. What exists (and why)

**Renderer / draw** (`render.odin`, `draw.odin`):
- **Clip is per-instance data**: `Render_Instance.clip: [4]f32`. There is no `Clip_Id`, no
  clip table, no clip uniform. Batches break only on texture. The vertex shader shrinks
  the quad to `dst ∩ clip` and derives `local_position` from the shrunk position, so SDF,
  gradient and UVs stay correct and there is no fragment discard.
- `Draw_Ctx` keeps a stack of clip rects; `draw_begin(..., clip)` takes the base clip (the
  viewport), `draw_clip_push` intersects with the current top, `draw_clip_pop` restores.
  Pushes are free and never break batches, so push/pop per box is fine.
- `Render_Key.sequence` is never set (order falls back to index) — undecided whether it
  stays.

**Storage** (all fixed tables in the `UI` global, no heap):
- `boxes[UI_BOX_MAX]` (id 0 = nil, all zeros — lookups that miss read it harmlessly), free
  stack, `box_order` (pre-order build order), `blob` (interned text, reset each frame),
  parent stack, style stack + `style_next`, `sprites: ^Sprites`.
- **No separate memo table**: `Ui_Box` is flat, in RAD-style sections — per-build fields,
  layout results, persistent fields (`hot_t`, `active_t`, `focus_t`, `disabled_t`,
  `scroll`, `scroll_target`). In `ui_begin`, a kept keyed box has only `key`, `flags`, the
  four tree links, `child_axis` and `text` reset (the user chose this RAD way over a
  persist sub-struct); style fields are overwritten by the base style on build; freed
  slots get `{}`. **Any new per-build field that only some widgets set must be added to
  that reset list.** Layout results (`pos_computed`, `size_computed`, `clip`,
  `content_size`) therefore hold **last frame's values during build** — widgets read them
  by key (the scrollbar does).
- `Ui_Hashtable($Id, $N)`: generic linear-probing key→id map with `ui_hashtable_find` /
  `ui_hashtable_save`. **Rebuilt from scratch every frame** in `ui_begin` from survivors, so
  it never needs deletion/tombstones. Used for boxes (`key_hash_table`) and anims
  (`anim_hash_table`). The pools around them are still duplicated on purpose — merge only
  if a third pool appears.
- Keys: `ui_key_from_string` hashes (fnv64) seeded by the nearest *keyed* ancestor;
  `ui_key_from_string_seeded(str, seed)` scopes under an explicit key (the scrollbar keys
  its track under its pane). `"###"` → key from the tail only; `##` hides the rest from
  display (Dear ImGui rules). Keyed boxes keep the same id across frames. Unkeyed boxes
  get no signal and no persistence. Rows/columns/labels/spacers are unkeyed; panels,
  buttons, checkboxes, scroll panes, scrollbar track/thumb keyed.

**Layout** (`ui_layout`): sizes are `[2]Ui_Size` (plain arrays, not `[Axis]` — enumerated
array literals can't be positional; `[2]T` can still be indexed by `Axis`).
- Kinds: `Pixels`, `Text` (measured + 2×padding), `Fit` (sum/max of children + gaps +
  padding), `Grow` (content-sized like Fit, then takes leftover by weight).
- `strictness` (Fleury): on overflow, children give up `size × (1 − strictness) × fraction`.
  Cross axis: Grow takes the parent's inner size; others are clamped to it (strictness
  ignored, as in RAD). No min/max (removed in favor of strictness).
- **A parent with `.Scroll_X/.Scroll_Y` on an axis skips shrink and cross clamp on that
  axis** (RAD's AllowOverflow folded into the scroll flag, as is ViewClamp).
- Passes: independent sizes → X (bottom-up fit, top-down grow/shrink) → [TODO wrap slot] →
  Y → placement in `box_order` (absolute positions, padding + gap, start-aligned, minus the
  parent's `scroll` floored to whole pixels). Placement also computes `content_size`
  (children + gaps + padding) and `clip`.
- **Every box clips**: `clip = parent.clip ∩ own rect`, root clip = its own rect. There is
  no `.Clip` flag. Floating boxes (future) are the one planned exception.
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

**Drawing** (`ui_draw`, in `box_order` = painter's order): per box `draw_clip_push(box.clip)`
/ pop, then background (faded toward hot/active by `hot_t`/`active_t` for `.Hot_Effects`
boxes), border, text (left at `padding.x`, vertically centered), focus ring (2px,
`focus_border` × `focus_t`). Everything × `alpha = 1 − 0.5 × disabled_t`.
`draw_rectangle` thickness 0 = fill. The shader clamps radius to half the short side, so a
large style radius on a thin box gives a pill (the scrollbar gets it for free).

**Interaction** (all decided in `ui_end` after layout, read by widgets next frame — one
frame of latency, accepted for simplicity):
- Hit test walks `box_order` backwards, only while `input.pos_is_valid`: non-`.Clickable`
  boxes are skipped; the test is `rect_contains(box.clip, mouse)`; `.Clickable & .Disabled`
  **blocks** (stops, nobody hot); clickable boxes must be keyed (asserted). Then
  `active_box` (press → release; while held nothing else is hot), `pressed` (one frame),
  `focus_box` (any press moves focus to the pressed `.Focusable` box or clears it).
  Active/focus are dropped if their box vanished or became disabled.
- **Wheel routing**: topmost box whose clip contains the mouse, then per axis walk up
  parents to the first box scrolling on that axis and add `ui_scroll_from_wheel` (sign
  flip × `UI_SCROLL_STEP` × em of that box's font) to its `scroll_target`.
- `Ui_Signal { hovered, pressed, held, focused, drag, wheel }`. `drag` = mouse − press
  position while held; `wheel` = last frame's wheel notches while hovered.
  `ui_drag_store(v)` / `ui_drag_stored()` keep one widget value for the active drag (the
  value at press, so a dragged thing stays under the cursor). **The user removed
  `clicked`** (release over the same box) and uses `.pressed` as the click; don't
  silently re-add it.
- Easing loop in `ui_end` eases `hot_t, active_t, focus_t, disabled_t` and `scroll` with
  `rate = 1 − exp(−16·dt)`, after clamping `scroll_target` to
  `[0, content_size − size_computed]` (0 on non-scrolling axes); the same rate eases every
  live `ui_anim`.
- `.Disabled` comes from style `disabled`, and children inherit it from their parent.

**Widgets** (bottom of `ui.odin`): `ui_row`, `ui_column`, `ui_panel` (containers via
`@(deferred_out)`, used as `if ui_row() { ... }`, return bool only), `ui_spacer` (forces
0 across the parent axis), `ui_label`, `ui_button`, `ui_checkbox(label, ^bool)` (mark fades
via `ui_anim("checked", ...)` keyed under the row).
- `ui_scroll_panel(label, style, child_axis)`: panel (caller's style/look, laid out across
  the scroll axis) → pane (keyed `"scroll pane"`, scrolls, Grow, takes the panel's gap,
  holds the caller's children) + scrollbar built by `ui_scroll_panel_end` after the
  children. Content is clipped inside the panel's padding.
- `ui_scrollbar(pane_label, axis, style)`: finds the pane by key, reads its last-frame
  `size_computed/content_size/scroll`, builds track (`UI_SCROLLBAR_SIZE`, background) with
  Grow-weighted spacer / thumb (track's `border` color, `.Hot_Effects`) / spacer. Thumb
  drag sets the pane's target and snaps `scroll`; wheel over track or thumb scrolls the
  pane. The bar is always shown (hiding it would make the layout jump).

**main.odin**: `ui_init(&GLOBAL.sprites)`, per frame `draw_begin(..., viewport)` →
`ui_begin(view)` → `demo_build(&demo)` → `ui_end(GLOBAL.input, &draw, dt)`. `Input.wheel`
accumulates `MOUSE_WHEEL` events per frame (notches, SDL sign: +y away from the user; no
un-flipping of natural scrolling). The demo pushes `MIDNIGHT` and uses
`demo_label/demo_button/demo_checkbox` helpers; its third panel is a 180px scroll panel of
20 buttons.

## 4. Next steps (agreed order)

1. ~~**Clipping + scrolling.**~~ **Done** (`161f0cb`, `232c876`): per-instance clip, every
   box clips, scroll flags + eased/clamped offsets, wheel input and routing, scroll panel,
   scrollbar with drag and wheel.
2. **Floating boxes** (menus, popups, tooltips — likely the most important remaining piece
   for a strategy game): excluded from parent fit/grow/cursor, absolute or anchored
   position (anchoring can read another box's last-frame layout by key), clip starts from
   their layer's root instead of `parent.clip`, higher draw layer (`Draw_Ctx.layer`),
   hit-tested first and blocking underneath, close-on-outside-press, clamp to viewport.
   Root boxes currently always start at (0,0).
3. **Wrapped text** in the `TODO: Width-dependent measurements` slot: re-measure height of
   wrap boxes from their final width; needs a measure-only variant of `draw_text_wrapped`.
4. **Images**: an image box first (portraits/icons; `draw_image` exists), then rich text
   with inline icon runs (ui2 had `runs`).
5. Then: ~~drag delta in the signal~~ (done; sliders, splitters and movable windows can
   build on it), right-click / double-click, keyboard focus nav (Tab moves `focus_box`,
   Enter/Space activates), ellipsis truncation, eventually a text input field (biggest
   widget).

Other ideas discussed for later: an `opacity` style field (RAD's `UI_Transparency`),
`text_align` and a separate `text_padding` field, named button styles / a theme table,
`is_animating` to let the main loop idle, hot/active border fades, clicking the scrollbar
track to page.

## 5. Known leftovers / gotchas

- Scrolling: no hand-off between nested scroll panes (a pane at its end still eats the
  wheel); the thumb has no minimum size; the wheel over a scroll panel's padding does
  nothing; the wheel over the bar reaches the pane one frame late.
- `rect_from_pos_size` is the only rect helper that isn't file-private; `draw_clip_push`
  has its own inline copy of the rect intersection.
- The parchment base style constants (`UI_PANEL_*`, `UI_LABEL_COLOR`, ...) are always
  overridden by the demo's `MIDNIGHT` push.
- Hashtable capacity equals pool size (high load factor possible); `2×` or a power of two
  would be cheaper to probe.
- `ui_em` / base style dereference `UI.sprites`: calling them before `ui_init` crashes.
- Parameters in Odin are immutable and not addressable: procs that slice fields (e.g.
  `sprite_of_glyph`'s binary search) must take pointers.
- Odin can't index a compile-time constant array with a runtime index (hence
  `ui_scroll_flag(axis)` is a proc, like `ui_axis_flip`).
