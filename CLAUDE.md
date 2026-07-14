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

## General

- When adding types or APIs, ask: is the zero value valid (ZII)? Can it live
  in an arena (no Drop)? Can it be one flat struct instead of three small
  ones? Default to yes on all three.
