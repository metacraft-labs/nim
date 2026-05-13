discard """
  action: "run"
  targets: "c"
"""

## Stress-test the C sourcemap coverage on a curated 200+ line Nim
## program. M1's marker design only emits annotations at the C
## statement boundaries reached via `genLineDir` — top-level Nim
## statements and many module-level expressions never reach that
## path, so the measured coverage is well below 95%.
##
## M1's contract is to RECORD this baseline, not enforce a specific
## floor. The asserted floor (35%) is intentionally low; the
## interesting datum for M2/M3 is the actual percentage printed
## below. M2 (per-section annotation seq + per-emit-site marker
## migrations) is the milestone where coverage rises toward 95%.
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

  # M1's marker design only fires inside proc bodies and a few other
  # codegen paths; top-level statements + module-level expressions
  # are NOT covered. The measured baseline on this program at M1 is
  # around 40%. We set the floor at 35% so the test reports the
  # coverage delta without flapping; M2/M3 should comfortably exceed
  # 90% as per-expression annotations land.
  m1CoverageFloor = 35.0

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

  doAssert cov.coveragePercent >= m1CoverageFloor,
    "big-program coverage below M1 floor: " &
      formatFloat(cov.coveragePercent, ffDecimal, 2) & "%"

  echo "Big-program sourcemap coverage test passed"

when isMainModule:
  main()
