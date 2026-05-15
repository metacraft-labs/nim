discard """
  cmd: "nim e $file"
  targets: "e"
"""

## CTFS-M-FunctionAttrTemplate: every step lexically inside a proc body
## must carry that proc's `function` / `function_id` / `depth`, regardless
## of whether the source line came from a template-inlined fragment or
## direct code, and regardless of whether the step physically occurs
## before, between, or after any nested call.
##
## Pre-fix `callForStep` (in codetracer-trace-format-nim) bailed out as
## soon as `stepId > hiCall.exitStep`. Call records are sorted by
## entryStep (= call_key, entry order); when `hi` pointed at a nested
## child that had already returned, an enclosing parent at a lower index
## could still cover `stepId`, but the early-exit dropped the search
## before that case was considered. Concretely: after returning from any
## nested call, the next step inside the *same* caller was reported as
## "not found in any call" by the materializer and emitted with no
## function attribution at all.
##
## The shape below covers two manifestations:
##
##   * Post-return-in-direct-code: `discard 2` after `inner()` in
##     `directCallSite`.
##   * Post-return-via-template-inline: `discard x` after the inlined
##     `inner(x, y)` from `pt(x)` in `pg`.
##
## Both must show `function: "directCallSite"` and `function: "pg(var int)"`
## respectively, with `depth: 0`.

proc inner(a, b: var int) =
  a = 1
  b = 2

template pt(x: untyped) =
  var y: int
  inner(x, y)        # template-inlined nested call
  discard y

proc directCallSite() =
  var a, b: int
  inner(a, b)        # direct nested call
  discard 2          # post-return step, depth 0, in directCallSite

proc pg(x: var int) =
  pt(x)              # expansion ends with `discard y` — post-return step
  discard x          # depth 0, in pg

directCallSite()
var x: int
pg(x)
doAssert x == 1
