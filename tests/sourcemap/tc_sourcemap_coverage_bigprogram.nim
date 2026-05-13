discard """
  action: "run"
  targets: "c"
"""

## Stress-test the C sourcemap coverage on a curated 200+ line Nim
## program.
##
## - M1 baseline: ~40% (line-granular `genLineDir`-driven marker
##   design; top-level statements + module-level expressions weren't
##   covered).
## - M2 raised the floor by recording an annotation at the start of
##   *every* generated statement (`genStmts`) and migrating the
##   four V2 marker emit sites to direct side-table primitives.
##
## The remaining headroom toward 95-100% is dominated by
## **compile-time-only expressions** — many `doAssert X is Ordinal`
## and `doAssert high(...) > low(...)` lines in `tsystem_misc.nim`
## reduce to literal `true` at semcheck and generate NO C bytes, so
## they have no mapping to attach to. Pushing coverage further
## requires migrating expression-level `recordAt`/`recordRangeAt`
## calls into the `expr()` dispatch inside `ccgexprs.nim` (M3).
##
## Chosen program: `tests/system/tsystem_misc.nim`.

import std/[os, osproc, strutils, assertions]

import sourcemap_coverage_helpers

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap_coverage_bigprogram"
  sourceFile = testsDir.parentDir / "system" / "tsystem_misc.nim"

  # M2 measured coverage on `tsystem_misc.nim` is 54.24%. The 45%
  # gap to 100% breaks down into two stable categories that are
  # *expected* to remain uncovered at this milestone:
  #   1. Compile-time-only expressions: many `doAssert X is Ordinal`
  #      and `doAssert high(int32) > low(int32)` reduce to literal
  #      `true` at semcheck and generate no C bytes, so they have
  #      no segment to attach to. These should be subtracted from
  #      the denominator (M3 framework refinement: walk the AST
  #      post-semcheck instead of post-parse).
  #   2. Macro-/template-expanded bodies (`doAssertRaises:`,
  #      `doAssert call == ...`'s inner expressions): the C bytes
  #      land at the macro-expansion site, but the outer Nim
  #      position of the body is not the anchor the current
  #      `genStmts`-driven instrumentation hits. M3 should add
  #      expression-level `recordAt`/`recordRangeAt` calls inside
  #      `ccgexprs.nim:expr()` for the canonical kinds.
  # Floor is set a few points below the measured value so an
  # incidental dip (e.g. minor cgen restructure) reports the delta
  # without flapping the test red.
  m2CoverageFloor = 50.0

proc main() =
  doAssert fileExists(sourceFile), "missing source: " & sourceFile

  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcCopy = buildDir / "big_prog.nim"
  let outFile = buildDir / "big_prog"

  removeDir(buildDir)
  createDir(buildDir)
  copyFile(sourceFile, srcCopy)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcCopy
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed:\n" & output

  # V3: per-`.c` sidecars in nimcache. Aggregate across all of them
  # that reference the test source.
  var foundMaps = 0
  for f in walkDir(nimcache):
    if f.path.endsWith(".c.map"): inc foundMaps
  doAssert foundMaps > 0,
    "No V3 `.map` sidecars produced in " & nimcache

  let cov = verifyCoverage(srcCopy, nimcache, strictness = "warn")

  echo "[bigprogram-coverage] source:    ", sourceFile
  echo "[bigprogram-coverage] total:     ", cov.total
  echo "[bigprogram-coverage] covered:   ", cov.covered
  echo "[bigprogram-coverage] uncovered: ", cov.uncovered
  echo "[bigprogram-coverage] coverage:  ",
       formatFloat(cov.coveragePercent, ffDecimal, 2), "%"

  if cov.uncovered > 0:
    cov.reportMissing(30)

  doAssert cov.coveragePercent >= m2CoverageFloor,
    "big-program coverage below M2 floor: " &
      formatFloat(cov.coveragePercent, ffDecimal, 2) & "%"

  echo "Big-program sourcemap coverage test passed"

when isMainModule:
  main()
