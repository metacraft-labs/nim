discard """
  action: "run"
  targets: "c"
"""

## Property test: every expression in a small focused Nim program
## must be covered by the JSON sourcemap.
##
## At M1 (`sourcemap-v3-merge-into`), the refactor preserves V2's
## marker-based emit, which is per-line granular. The basic test
## program below has one meaningful expression per line, so a
## per-line marker model trivially gives 100% coverage. This is the
## "smoke check" that the property-test framework is wired up and
## that the marker design isn't dropping mappings on simple input.

import std/[os, osproc, strutils, sequtils, assertions]

import sourcemap_coverage_helpers

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap_coverage_basic"

const testProgram = """
proc add(a, b: int): int =
  result = a + b

proc multiply(a, b: int): int =
  result = a * b

when isMainModule:
  let x = add(3, 4)
  let y = multiply(x, 2)
  echo y
"""

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_prog.nim"
  let outFile = buildDir / "test_prog"

  removeDir(buildDir)
  createDir(buildDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed:\n" & output

  let smPath = buildDir / "ct_sourcemap_test_prog"
  doAssert fileExists(smPath),
    "Expected sourcemap at " & smPath & ", contents of buildDir:\n" &
      toSeq(walkDirRec(buildDir)).join("\n")

  let cov = verifyCoverage(srcFile, smPath, strictness = "warn")

  echo "[basic-coverage] total expressions: ", cov.total
  echo "[basic-coverage] covered:           ", cov.covered
  echo "[basic-coverage] uncovered:         ", cov.uncovered
  echo "[basic-coverage] coverage:          ",
       formatFloat(cov.coveragePercent, ffDecimal, 2), "%"

  if cov.uncovered > 0:
    cov.reportMissing(20)

  # On this curated tiny program the marker design must give us
  # solid line-level coverage. We assert ≥ 90% as the M1 floor —
  # this is a sanity check, not a stress measurement.
  doAssert cov.coveragePercent >= 90.0,
    "basic coverage below threshold: " & $cov.coveragePercent & "%"

  echo "Basic sourcemap coverage test passed"

when isMainModule:
  main()
