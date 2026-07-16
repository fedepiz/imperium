# Imperium — project style

The game's concept, setting and design pillars live in docs/DESIGN.md — read it
before design-adjacent work, and keep it current: when a change shifts the
game's design (new mechanics, setting decisions, changed direction), update
DESIGN.md in the same breath. It is design-only; technical matters stay here.

How the UI works — script vocabulary, sizing, bindings, lists, style — is
documented in docs/UI.md. Read it before UI work, and update it whenever the
script format, binding model, or style keys change.

Read this before writing or editing code. These are deliberate, project-wide
choices; follow them even where std-idiomatic Rust would do otherwise.

## Arena allocation (default, not exception)

- Allocate phase-scoped data out of `Arena` (`crates/arena`, wrapping bumpalo),
  not the global heap. Memory is freed in bulk via `Arena::reset()` / drop —
  never per-object.
- Arena-resident types must not need `Drop` — the crate enforces this at
  compile time (`const` assert on `mem::needs_drop`). Don't fight the check;
  restructure the type so it's trivially destructible.
- Use `AVec<'a, T>` / `AString<'a>` instead of `Vec<T>` / `String` for data
  tied to an arena's lifetime; freeze them with `into_slice()` / `into_str()`
  when growth is done.
- Prefer `&'a T` / `&'a [T]` borrows from the arena over owning pointers
  (`Box`, `Rc`). Structure code in phases whose scratch memory dies together.

## ZII — Zero Is Initialization

- The all-zeroes value of a type should be a *valid, meaningful* state: empty,
  default, "none". Design so `Default::default()` is the zero value (derive it;
  don't hand-write constructors that establish invariants zeroed memory would
  violate).
- Prefer zero-as-sentinel over `Option<T>` where zero naturally means absent:
  index/handle `0` = null handle, len `0` = empty, id `0` = unassigned.
- No mandatory `new()`-style setup: a zeroed struct must be safe to use
  immediately. If a type can't satisfy that, reconsider its design before
  reaching for constructor discipline.
- Don't define named constants for notable instances of plain-data
  structs (the mostly-zero value with one field set, the "empty" value).
  Build them at the use site from `Default::default()` with struct-update
  syntax; if an instance genuinely recurs, a small function is fine. Such
  constants restate the ZII story and rot as fields are added.

## Fat structs

- Prefer one large, flat struct covering all cases over a web of small types,
  trait objects, and deep hierarchies: a superset of fields, some unused per
  instance — that's fine.
- We don't like `kind` tags on fat structs. Prefer a capability style where
  each feature is independently on or off — signalled by a flag, or ideally
  by the field's meaningful zero (ZII: empty text = no text, alpha 0 = no
  color, index 0 = no link) — and consumers apply every field
  unconditionally instead of dispatching on what a thing "is".
- Reach for an enum only when the variants are genuinely non-overlapping,
  and check fallbacks before believing that: a variant that falls back on
  another variant's payload is overlap — keep the struct. When an enum is
  warranted, use fat variants with shared fields hoisted into the outer
  struct; dispatch with `match`, never `dyn Trait`. Avoid `Box<dyn ...>`
  in data structures.
- Keep data layout flat and contiguous (arrays of fat structs in an arena);
  minimize pointer chasing. Accept wasted bytes per instance as the price of
  simplicity and cache-friendly iteration.

## Mutation locality: the double-buffered day pass

- `World` splits in two: single-instance state mutated only in *direct
  mode* (epoch, seed, ids, names, tags, map) and the double-buffered
  `WorldState` (vars, uvars, activities, relations) — the per-entity
  state the day pass rewrites. Two buffers exist: `world.state` (the
  current one) and `Game::staging` (the write buffer), swapped after
  each pass. Staging is dead scratch between ticks; never read it.
- Direct mode is everything outside the pass — command handling,
  interaction effects, event resolution, bootstrap — and mutates the
  world in place, whole-world writes allowed, through the `World`
  accessors (`get_var`/`set_uvar`/`activity`/`related_via`…).
- The day pass is a pure function of the frozen world: a chunked slot
  loop where each chunk first memcpys its rows forward
  (`copy_chunk_from`), then each live entity's update reads only
  `&World` and writes only its *own* slots in staging. Everyone acts on
  yesterday's world; everything within a day is simultaneous. A new
  `WorldState` field gets one reset line in `spawn` and one
  copy_chunk_from line in the pass.
- Every update receives the pass kit, `Pass` (tick.rs): the bridge
  between one entity's tick and everything that isn't its own rows.
  Consequences go out through its methods (`locate`, `arrive`, `die` —
  new consequences become methods, never signature changes) into the
  pass's sinks: events resolve serially after the swap, in recorded
  order; relation changes merge in the rebuild. Shared scratch (the
  route memo) rides along in it. The chunk loop is the threading seam
  (see the NOTE in tick.rs); per-chunk kits with sinks drained in
  chunk order keep resolution deterministic when that day comes.
- Relations are never mutated in place: a CSR matrix pair, and every
  rebuild is `merge(carry(old), changes)`. Kinds that *carry*
  (Married, SwornTo, Rules) flow forward from the old matrix with the
  changes on top — the last write to a key wins, a zero value deletes;
  kinds that don't (`Relation::is_derived`: LocatedIn) exist only as
  far as each update's Outcome re-emits them. Bootstrap is the same
  call over an empty base. There is no `set()`; a future direct-mode
  write path (oaths, marriages) accumulates change entries for the
  next rebuild to merge. Queries filter dead endpoints and owner-stamp
  against slot reuse, so edges stale since a death are unreadable.
- No rng state: every roll derives its stream via
  `Rng::at(world.seed, epoch, n)` — one per entity per day
  (`n = id.to_bits()`) — so draws are independent of iteration order,
  of other entities, and of dayless ticks.

## Testing

- Do **not** write small behavioural tests for complex game behavior —
  scenario tests that pin "from this state, this command yields that state".
  A sim's state space is too large for point examples to cover anything, and
  they fail on intentional design change rather than on regressions.
- Sim correctness is tested by other means: exemplar (golden-master) runs — a
  checked-in seed and command stream replayed over long stretches of sim
  time, diffed against a blessed transcript and re-blessed on intentional
  change; invariants as `debug_assert!` inside the sim code itself, so every
  run validates them; random-command soak tests that let those asserts do the
  judging, with a determinism check (same seed and commands twice → identical
  history) folded in; and playtesting for content and feel.
- Ordinary unit tests are fine for components — library crates and isolated
  pieces with stable contracts.
- Never write `#[test]` functions that exercise extensive sim behavior —
  long simulated stretches (many in-game years), playthrough-scale runs,
  soaks. The every-run suite must stay fast and small-scoped. Tests of
  that scale are separate programs/utilities (exemplar replays, soak
  binaries), run deliberately, not on every `cargo test`.

## General

- When adding types or APIs, ask: is the zero value valid (ZII)? Can it live
  in an arena (no Drop)? Can it be one flat struct instead of three small
  ones? Default to yes on all three.
