# Imperium notes

## Build
For common builds, use:

odin build src -o:minimal (a healthy full build takes under a second; check with -show-timings)

## Odin pitfalls
- Never put a large array or struct in a multi-assignment (`a, b = x, y`)
  or multi-declaration (`a, b := ...`). LLVM stops using memcpy for it and
  build time explodes (one such line in sim/world.odin cost 3s).
  Write separate statements instead.
- How to find a slow package: build with -keep-temp-files, then time each
  .ll with `llc -O0 -filetype=obj -time-passes`.

## Code style
- Functions are for code called from several places, or for module-sized boundaries. Don't extract small
  single-use helpers: write the code inline, in a `{ }` scope if its locals aren't needed after, and bind
  intermediate results to well-named locals. A function is fine to cut down deep rightward nesting.
- Writes must be visible where they happen. A proc that mutates state hides what changes from its call site:
  inline the mutating code so the writes sit in context, or make the proc pure (it returns values and the
  caller writes them). Don't add code paths (e.g. at load) just to pre-fill values nothing needs yet.
- Label sections of a long proc with short comments: `// Step: Walk`, `// Fixed-step update`. No numbering,
  and no header comment listing the sections (it goes stale).
- Group a file's constants and tuning tables together at the top of the file.

## Comments
- Plain, terse technical English. Label intent; don't narrate what the code does.
- Keep comments on struct fields and constants where they add units, sentinels (`0 = none`), invariants or
  meaning not obvious from the name.
- Proc doc comments: only non-obvious contracts (preconditions, what false/nil means, lifetime). Often none.
- Keep the non-obvious *why* (workarounds, ordering constraints, algorithm names). Drop the rest.
