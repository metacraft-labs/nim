discard """
  cmd: "nim e $file"
  targets: "e"
  evalTrace: "skip"
"""

## CTFS-M1 demonstrator (skip path).
##
## Proves the `evalTrace: "skip"` opt-out works end-to-end:
##   - the test runs under target `e` (targetVM),
##   - the runner invokes `nim e --trace:<tmp>.ct $file`,
##   - the harness skips snapshot diffing,
##   - the test passes without writing a `.evaltrace.json` file next to
##     this source.
##
## See: codetracer-specs/Nim-Compiler-Patches.md
## § "CTFS / VM Tracing Coverage" → "CTFS-M1".

let x = 1 + 2
echo x
