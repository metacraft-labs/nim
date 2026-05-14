discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## TF-M4a: regression test for the two-level path cache and workdir
## population.
##
## TF-M5's first snapshot attempt surfaced two issues with the TF-M4
## integration:
##
##   1. The `paths[]` interning table contained duplicate entries when
##      the same physical file was reached through two different
##      FileIndexes (e.g. relative-form during script setup, absolute
##      during expansion).
##   2. `metadata.workdir` was always empty, so the materializer's
##      `FullOpts(stripPaths: true)` (and `ct-print --strip-paths`) was
##      a no-op and absolute `/home/<user>/` paths leaked into golden
##      snapshots.
##
## Both are fixed by the TF-M4a patch on `compiler/vm_trace.nim`:
##
##   * `ensurePath` now consults a two-level cache. The primary cache is
##     unchanged (a `FileIndex.int32`-indexed dense seq, O(1) hot path).
##     On a primary miss we canonicalize the path via `expandFilename`
##     and consult a secondary `Table[string, PathCacheEntry]`. If the
##     canonical form was already classified under a different
##     FileIndex, we reuse its entry; otherwise we classify+register and
##     populate both tables. The canonical string is what we register
##     into the writer's `paths[]` table.
##   * `initVmTracer` now seeds `tracer.writer.metadata.workdir` with
##     `getCurrentDir()`, so the materializer can substitute
##     `<workdir>/...` for paths rooted in the project directory.
##
## See: `codetracer-specs/Recording-Backends/Trace-Filters.milestones.md`
##      § TF-M4a, and `codetracer-trace-format-spec/Trace-Filters.md` § 6.

import std/[os, osproc, assertions, strutils, sequtils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_path_canon"

## A small script that imports a helper module. The compiler resolves
## the script under at least two distinct FileIndexes during its setup
## (project main module, then again as the runtime nimscript module);
## without canonicalization, both end up in `paths[]` as separate
## strings — sometimes one of them ends up relative when the cwd is the
## script's own directory.
const userScript = """
import muser_helper
echo helperEcho(7)
"""

const helperModule = """
proc helperEcho*(x: int): int =
  result = x + 1
"""

proc readPaths(traceFile: string): seq[string] =
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  for i in 0 ..< int(rdr.pathCount):
    let p = rdr.path(uint64(i))
    if p.isOk:
      result.add(p.get)

proc readWorkdir(traceFile: string): string =
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  return openRes.get().meta.workdir

proc runNimE(nim, cwd, scriptArg, traceFile: string): string =
  ## Run `nim e --trace:<traceFile> <scriptArg>` from `cwd`.
  ## We use a shell so `cd` is honored; `execCmdEx` does not accept a
  ## working directory.
  let cmd = "cd " & quoteShell(cwd) & " && " &
            quoteShell(nim) & " e --trace:" & quoteShell(traceFile) &
            " " & scriptArg
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed:\n  cmd: " & cmd &
                          "\n  out: " & output
  return output

proc basename(p: string): string =
  p.extractFilename

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "muser_script.nims"
  let helperFile = buildDir / "muser_helper.nim"
  writeFile(scriptFile, userScript)
  writeFile(helperFile, helperModule)

  # ----- Case 1: workdir population -------------------------------------
  block:
    let traceFile = buildDir / "case1_workdir.ct"
    discard runNimE(nim, getCurrentDir(),
                    quoteShell(scriptFile), traceFile)
    let workdir = readWorkdir(traceFile)
    doAssert workdir.len > 0,
      "case1: metadata.workdir should be populated, got empty string"
    doAssert isAbsolute(workdir),
      "case1: metadata.workdir should be absolute, got: " & workdir
    echo "PASS case 1: workdir populated — workdir=", workdir

  # ----- Case 2: canonicalization dedup (relative vs absolute) ----------
  # Running the same script from `buildDir` (so the script path is
  # relative `muser_script.nims`) vs running with an absolute path from
  # elsewhere previously produced different strings in `paths[]`. With
  # the two-level cache, the canonical form (absolute, realpath) is
  # what we register, so each canonical path appears exactly once.
  block:
    let traceFile = buildDir / "case2_canonical.ct"
    discard runNimE(nim, buildDir, "muser_script.nims", traceFile)
    let paths = readPaths(traceFile)
    let scriptHits = paths.filterIt(it.basename == "muser_script.nims")
    let helperHits = paths.filterIt(it.basename == "muser_helper.nim")
    doAssert scriptHits.len == 1,
      "case2: expected exactly 1 path entry for muser_script.nims, got " &
      $scriptHits.len & " (full paths: " & paths.join(", ") & ")"
    doAssert helperHits.len == 1,
      "case2: expected exactly 1 path entry for muser_helper.nim, got " &
      $helperHits.len & " (full paths: " & paths.join(", ") & ")"
    doAssert isAbsolute(scriptHits[0]),
      "case2: script path should be canonical (absolute), got: " & scriptHits[0]
    doAssert isAbsolute(helperHits[0]),
      "case2: helper path should be canonical (absolute), got: " & helperHits[0]
    echo "PASS case 2: canonical dedup — paths=", paths.len

  # ----- Case 3: cross-cwd canonical stability --------------------------
  # The canonical path for the same physical file must be identical
  # regardless of how it was reached. We invoke with an absolute path
  # from a different cwd and assert the script path matches case 2's
  # canonical form.
  block:
    let traceFile = buildDir / "case3_abs.ct"
    discard runNimE(nim, getCurrentDir(),
                    quoteShell(scriptFile), traceFile)
    let paths = readPaths(traceFile)
    let scriptHits = paths.filterIt(it.basename == "muser_script.nims")
    doAssert scriptHits.len == 1,
      "case3: expected exactly 1 path entry for muser_script.nims, got " &
      $scriptHits.len & " (full paths: " & paths.join(", ") & ")"
    let absScript = expandFilename(scriptFile)
    doAssert scriptHits[0] == absScript,
      "case3: expected canonical path " & absScript &
      ", got: " & scriptHits[0]
    echo "PASS case 3: canonical stable across cwd — path=", scriptHits[0]

  removeDir(buildDir)
  echo "PASS: tvm_trace_path_canonicalization (TF-M4a)"

main()
