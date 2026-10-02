discard """
  action: "run"
  targets: "c"
"""

## The macro sourcemap is a build side output, so it belongs in the nimcache
## next to the per-module `.c.map` source maps, never in the output
## directory. An output directory is often a source tree (a repository root,
## its `src/` or `bin/`), where a stray `macro_sourcemap_<name>.json` is an
## untracked file.
##
## The output directory and the nimcache are deliberately disjoint siblings
## here, so the test can tell the two locations apart. Both a `--sourcemap:on`
## build and a plain build are checked: the plain build still writes the
## (expansion-free) map.

import std/[os, osproc, strutils, json, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tmacro_sourcemap_location"

const testProgram = """
template twice(x: int): int = x * 2
echo twice(21)
"""

proc sideOutputsIn(dir: string): seq[string] =
  for f in walkDirRec(dir):
    let name = f.extractFilename
    if name.startsWith("macro_sourcemap_") and name.endsWith(".json"):
      result.add f

proc compileAndAssert(label, extraFlags: string) =
  let nim = getCurrentCompilerExe()
  let workDir = buildDir / label
  let srcDir = workDir / "src"
  let outDir = workDir / "out"
  let nimcache = workDir / "nimcache"
  removeDir(workDir)
  createDir(srcDir)
  writeFile(srcDir / "prog.nim", testProgram)

  let cmd = nim & " c --hints:off " & extraFlags &
    " --nimcache:" & nimcache &
    " -o:" & (outDir / "prog") & " " & (srcDir / "prog.nim")
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "[" & label & "] compilation failed:\n" & output
  doAssert fileExists(outDir / "prog"), "[" & label & "] no binary in " & outDir

  let inOutDir = sideOutputsIn(outDir)
  doAssert inOutDir.len == 0,
    "[" & label & "] macro sourcemap written into the output directory: " &
    inOutDir.join(", ")
  let inSrcDir = sideOutputsIn(srcDir)
  doAssert inSrcDir.len == 0,
    "[" & label & "] macro sourcemap written into the source directory: " &
    inSrcDir.join(", ")

  let expected = nimcache / "macro_sourcemap_prog.json"
  doAssert fileExists(expected),
    "[" & label & "] " & expected & " not written; nimcache holds: " &
    sideOutputsIn(nimcache).join(", ")
  let js = parseJson(readFile(expected))
  doAssert js.hasKey("schema") and js["schema"].getInt == 2,
    "[" & label & "] " & expected & " is not a schema-2 macro sourcemap"

proc main() =
  compileAndAssert("sourcemap_on", "--sourcemap:on")
  compileAndAssert("sourcemap_off", "")
  removeDir(buildDir)
  echo "macro sourcemap location test passed"

main()
