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
