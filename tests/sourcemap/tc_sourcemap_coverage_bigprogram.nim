discard """
  action: "run"
  targets: "c"
"""

## Stress-test the C sourcemap coverage on a curated 200+ line Nim
## program.
##
## M2 (side-table storage) added a per-expression annotation in
## `ccgexprs.expr` plus per-statement annotation in `genLineDir`.
## With the side-table design, every expression node that reaches
## the C codegen pipeline now contributes a JSON entry — measured
## coverage on `tsystem_misc.nim` rises from M1's 40.11% baseline
## to ~54%.
##
## The remaining ~46% gap is structural, not addressable by
## additional cgen emit sites:
##  - `tsystem_misc.nim` is heavy in `doAssert` / `doAssertRaises`
##    templates which expand into AST nodes whose `info.fileIndex`
##    points to the synthetic `expanded.nim` file, NOT the user's
##    source. Those annotations land in the JSON under `expanded.nim`,
##    so the per-file coverage check on `big_prog.nim` skips them.
##  - `doAssert not compiles(...)` blocks evaluate at compile time
##    and emit nothing into the C output, so they cannot be mapped.
##
## Closing the gap further is an M3+ topic that requires either:
##  (a) extending the JSON consumer to follow `expanded.nim` → user
##      line provenance chains, or
##  (b) modifying the templates' `{.line: loc.}` to preserve user
##      source info for nested AST nodes.
##
## Chosen program: `tests/system/tsystem_misc.nim` — already in the
## test corpus, exercises high/low/sizeof, type conversions, slicing,
## seq/string ops, distinct types, generics. The test imports
## `strutils` and other stdlib modules; we measure coverage against
## the test file only (not its imports).

import std/[os, osproc, strutils, assertions]

import sourcemap_coverage_helpers

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap_coverage_bigprogram"
  sourceFile = testsDir.parentDir / "system" / "tsystem_misc.nim"

  # M2 floor: per-expression `expr` annotations + per-statement
  # `genLineDir` annotations push coverage to ~54% (up from M1's
  # 40.11%). The remaining gap is structural — see this file's
  # top doc-comment for the macro / `compiles()` analysis. We
  # set the floor at 50% so the test reports the delta without
  # flapping on minor cgen drift.
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

  let smPath = buildDir / "ct_sourcemap_big_prog"
  doAssert fileExists(smPath), "Expected sourcemap at " & smPath

  let cov = verifyCoverage(srcCopy, smPath, strictness = "warn")

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
