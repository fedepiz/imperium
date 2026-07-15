# Imperium — UI guide

How the UI system works, from the perspective of someone writing UI —
plus, at the end, the general concepts an implementor needs. Keep this
document current: when the script vocabulary, binding model, or style
keys change, update it in the same change.

## The big picture

The UI is data. Two files under `data/` describe the whole game screen:

- `data/ui.txt` — the layout: panels, widgets, and where data appears.
- `data/style.txt` — the look: palette, fonts sizes, metrics.

Both are in *tabula* format (`key = value` pairs and `{ ... }` blocks).
Press **R** in-game to hot-reload both. Errors are never fatal: whatever
can be compiled is shown, and every problem (unknown key, bad color,
misplaced block) is reported as a warning on stderr while the default
stands. A CI test (`crates/ui/tests/example.rs`) keeps the repo's real
scripts compiling with zero warnings.

The game feeds the UI fresh data every frame; the script pulls it in
with `$VAR` references. The script never computes — it only lays out and
names the data it wants.

## Widgets

Containers (all share the same property set — see below):

- `panel` — vertical stack, panel background, padded. Top-level panels
  float freely on screen and are positioned with `x_pos`/`y_pos`
  (fractions of the screen, `0.5 0.5` = centered).
- `row` — a panel that flows horizontally, transparent, unpadded.
- `box` — a pre-styled accent cell: fills its slot, centers content.
- `list` — stamping machinery for repeated data (see Lists below).

Leaves:

- `label`, `heading`, `section` — one text widget in three roles; each
  role gets its size/color from the style. Shorthand `label = "text"`
  or a block `label = { text = ... size = ... color = ... wrap = yes }`.
- `button` — clickable; `action` is the string sent to the game when
  clicked (after `$VAR` interpolation). Caption via `text`. Unsized
  buttons grow into the style's default width/height caps.
- `image` — a registered image by `source` name, with optional `tint`
  and `fade`.

## Sizing

Every element's `width`/`height` uses one grammar: **cap[:weight]**.
An element starts at its content size, grows by weight (default 1) as
the parent has free space, and stops at its cap.

- `width = 200` — grow up to 200 points.
- `width = grow` — uncapped growth.
- `width = fit` — weight 0: stay at content size.
- `width = 50%` — capped at half the parent.
- `width = "grow:2"` — uncapped, twice the share of a weight-1 sibling.
- `min_width` / `max_width` (and height counterparts) clamp the result.

Equal splitting falls out of the model: several `grow` siblings in a row
split the space evenly.

Growth distributes a parent's *free* space — so a `grow` child inside a
`fit` parent has nothing to grow into and stays content-sized.

## Container properties

All containers accept: `width height min_* max_*`, `direction`
(`vertical`/`horizontal`), `align` (`start`/`center`/`end`), `padding`,
`gap`, `background`, `background_image`, `border` (`yes` = 1px outline),
`scrollable` (scrolls along the flow axis; needs a bounded size),
`tooltip`, `floating` + `x_pos`/`y_pos`, `visible`, `enabled`, `id`.

## Data binding

Text values interpolate `$VAR` references: `label = "$NAME, age $AGE"`.
Actions interpolate too: `action = "remove $ID"`. A missing binding
keeps its literal `$NAME` spelling on screen — visible, greppable.

Bindings come in two scopes:

- **Globals** — bound once per frame by the game (`$DATE`, `$STATUS`).
  Visible everywhere.
- **Row bindings** — provided per row of a list (`$NAME`, `$ID`). They
  shadow globals of the same name inside the stamped row.

`visible` and `enabled` take `yes`, `no`, or a `$VAR` that resolves to
one of those; unset means visible/enabled. Disabled elements dim (their
whole subtree with them) and sense nothing. Bare names like
`visible = character_open` are rejected — conditions are always literal
or a binding.

## Lists

A `list` is a container plus a `template`. The game fills a data list
with the same `id`; the template's elements are stamped once per row —
**spliced directly into the list container**, exactly as if the
template's body had been written out once per row. There is no hidden
wrapper: the list lays out stamped children like literal ones, so e.g. a
horizontal list of `grow` buttons splits the row evenly.

Consequences of splicing:

- A template with several top-level elements contributes them all, per
  row, as loose siblings. Want a per-row unit (background, hover
  surface, tooltip)? Declare your own `panel`/`row` inside the template.
- Identity that must survive rows being added/removed/reordered comes
  from interpolated ids on the elements themselves
  (`id = "person_$ID"`).

```
list = {
    id = "speeds"                # matched to the data list by this id
    direction = horizontal
    template = {
        button = { action = "time_speed $LEVEL" text = "$LEVEL" width = grow enabled = "$ENABLED" }
    }
}
```

## Style and the palette

`data/style.txt` overrides fields of a built-in default, one `key =
value` per line; delete a line and the default stands. Colors are
`{ r g b a }` in 0–1 (alpha optional).

The palette is **semantic on purpose**: scripts say what a thing is,
not which hue it has. Names: `panel`, `dark`, `outline`, `ink`,
`muted`, `accent` (the one highlight color), and `none` (transparent).
`background = accent`, never a raw color in the layout script — hue
decisions live only in style.txt. Current scheme: "Vellum & Oxblood"
(parchment, brown-black ink, oxblood accent, bronze buttons — the UI
as a chronicle; see docs/DESIGN.md for why).

Beyond the palette, style.txt sets button visuals (background, hover,
border, corner radius, default size caps), tooltip background and its
own text color (`tooltip_ink` — separate from `ink`, since the bubble
keeps its own ground), role font sizes (`heading_size`, `section_size`,
`text_size`, `tooltip_size`), and container metrics (`padding`, `gap`,
`corner_radius`).

## The board (out of band)

The map layer under the panels is not script UI: the harness draws it
directly from the sim's render model, and clicks on it never touch the
layout engine. A left-click that isn't over any UI surface (the engine's
`is_pointer_over_ui` decides) is a *board pick*: the harness inverts the
map camera to a cell, asks the game what entity sits there
(`entity_at`), and turns the answer into an ordinary action string
(`travel <cell>`) that rides the same pipeline as any button press. The
sim never sees a click — only actions.

## Implementor's view (concepts only)

- **Compile once, walk flat.** Scripts are parsed and compiled to a
  flat array of fat nodes (the IR) once per (re)load — style values
  baked in, defaults resolved. The per-frame code walks that array; it
  never traverses the raw script tree. A style edit is a recompile like
  any script edit.
- **The walk is kind-blind.** The compiler bakes every widget decision
  into the nodes; the per-frame walk applies every field of every node
  the same way. "Button" or "label" doesn't exist at runtime — only
  fields, applied unconditionally (ZII: empty text = no text, alpha 0 =
  no color).
- **Data crosses one boundary.** The game fills a `UiData` (globals,
  lists of rows of bindings, images) each frame; the walk resolves
  `$VAR`s against it. The sim never touches layout; rendering never
  mutates the sim.
- **Sense-then-declare.** Interaction (hover, click) is sensed against
  *last frame's* bounds by stable element id, then this frame's
  elements are declared. This is why identity/ids matter: retained
  state (hover, scroll, tooltips) follows the id.
- **Never fail, always warn.** Compilation and style parsing recover
  from anything; problems become warnings and defaults stand. Keep it
  that way — a typo in a script must never take down the game.
- **Frame memory is arena memory.** Per-frame scratch (interpolated
  strings, layout) lives in an arena reset each frame; the compiled
  module and events that outlive the frame are owned. See CLAUDE.md
  for the project-wide allocation rules.
