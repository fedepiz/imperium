# Imperium — project style

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
  trait objects, and deep hierarchies. Typical shape: a `kind` tag plus a
  superset of fields (some unused per instance — that's fine), or a Rust enum
  with fat variants and shared fields hoisted into the outer struct.
- Dispatch with `match` on the kind tag, not `dyn Trait`. Avoid `Box<dyn ...>`
  in data structures.
- Keep data layout flat and contiguous (arrays of fat structs in an arena);
  minimize pointer chasing. Accept wasted bytes per instance as the price of
  simplicity and cache-friendly iteration.

## General

- When adding types or APIs, ask: is the zero value valid (ZII)? Can it live
  in an arena (no Drop)? Can it be one flat struct instead of three small
  ones? Default to yes on all three.
