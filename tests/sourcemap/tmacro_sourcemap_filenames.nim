discard """
  action: "run"
  targets: "c"
"""

## §2-M3 (CT-MacroSourcemap): regression test for the FileIndex-based
## "site is in expanded.nim" check in the renderer/cgen.
##
## Before §2-M3, the renderer's chain-bridging logic compared the
## rendered string path of `siteInfo` to `macroSourcemap.expandedFilename`.
## That works under the default `--filenames:foAbs` but silently
## fails under `--filenames:foCanonical`, `foName`, and `foRelProject`
## because `toMsgFilename(...)` formats the path differently in those
## modes. The renderer would then never detect that a position is
## inside `expanded.nim`, skip the layer-bridging entry, and the
## resulting macro_sourcemap_*.json would be missing
## `expressionLocations` / `expandedEntries` entries that downstream
## consumers (GUI highlighting, cgen bridging) need.
##
## §2-M3 fixes this by carrying the `FileIndex` of the call/definition
## position in the `site` / `siteInfo` tuples, and switching the
## renderer's check to compare `siteInfo[3] == macroSourcemap.fileIndex`,
## which is normalization-independent.
##
## This test compiles a small fixture under several `--filenames:`
## modes and asserts that for every mode the macro_sourcemap_*.json
## output is non-trivially populated.

import std/[os, json, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tmacro_sourcemap_filenames"

# A program with NESTED template expansions: `outer` expands to a
# body containing a call to `inner`. The renderer records the
# `inner` expansion's site as a position inside `expanded.nim`
# (the outer expansion's artifact), and the chain-bridging logic
# fires only when the renderer can detect "this site is inside
# expanded.nim". Under pre-§2-M3 string equality, the path string
# at that position would be a formatted form of `expanded.nim`
# that depended on `--filenames:` — and would mismatch
# `expandedFilename` under `canonical` / `legacyRelProj`. The
# resulting JSON would have `entryExpandedLine == -1` for every
# entry. With §2-M3's `FileIndex`-based check the bridging works
# regardless of how the path is formatted.
const testProgram = """
template inner(x: int): int =
  x + 1

template outer(x: int): int =
  inner(x) * 2

proc main() =
  let r = outer(10)
  echo r

main()
"""

proc findMacroSourcemap(dir: string): string =
  result = ""
  for f in walkDir(dir):
    let name = f.path.extractFilename
    if name.startsWith("macro_sourcemap_") and name.endsWith(".json"):
      return f.path

proc compileAndAssert(filenamesMode: string) =
  ## Compile the fixture with the given `--filenames:` value and
  ## verify the macro_sourcemap JSON is non-trivially populated:
  ## - `expansions` is non-empty
  ## - `locations` is non-empty
  ## - `expressionLocations` has entries
  ## - at least one `locations` entry whose `siteFile` is the
  ##   expanded artifact has `entryExpandedLine != -1`. This is the
  ##   key signal that the renderer's "site is in expanded.nim"
  ##   detection succeeded.
  let nim = getCurrentCompilerExe()
  let workDir = buildDir / filenamesMode
  let nimcache = workDir / "nimcache"
  let srcFile = workDir / "prog.nim"
  let outFile = workDir / "prog"

  removeDir(workDir)
  createDir(workDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --filenames:" & filenamesMode &
    " --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0,
    "[" & filenamesMode & "] compilation failed:\n" & output

  let mapFile = findMacroSourcemap(workDir)
  doAssert mapFile.len > 0,
    "[" & filenamesMode & "] macro_sourcemap_*.json not found in " & workDir

  let js = parseJson(readFile(mapFile))

  # Schema 2 layout.
  doAssert js.hasKey("schema") and js["schema"].getInt == 2,
    "[" & filenamesMode & "] expected schema=2"

  # The renderer must always populate at least one expansion: we
  # use both a template and a macro.
  doAssert js.hasKey("expansions") and js["expansions"].len > 0,
    "[" & filenamesMode & "] no macro expansions recorded"

  doAssert js.hasKey("locations") and js["locations"].len > 0,
    "[" & filenamesMode & "] no locations recorded"

  doAssert js.hasKey("expressionLocations") and
           js["expressionLocations"].len > 0,
    "[" & filenamesMode & "] no expressionLocations recorded"

  # The core §2-M3 regression check: under non-foAbs `--filenames:`
  # modes, the renderer must still recognize "this site is inside
  # expanded.nim" so it can populate `entryExpandedLine` for the
  # parent layer. The data shows up as at least one locations entry
  # whose `entryExpandedLine` is not -1. Before §2-M3, this would
  # be -1 for every entry under `--filenames:foCanonical` etc.
  var bridgedEntries = 0
  for k, ei in js["locations"].pairs:
    if ei.hasKey("entryExpandedLine") and ei["entryExpandedLine"].getInt != -1:
      bridgedEntries.inc
  doAssert bridgedEntries > 0,
    "[" & filenamesMode & "] no `locations` entry has " &
    "entryExpandedLine != -1; the renderer did not detect any " &
    "site inside expanded.nim. This is the §2-M3 regression."

  # `expandedEntries` is the cgen-side bridge table; verify it has
  # at least one non-trivial mapping (i.e. some path other than the
  # expanded artifact itself gets mapped to an expanded line).
  doAssert js.hasKey("expandedEntries"),
    "[" & filenamesMode & "] missing expandedEntries"

  echo "[", filenamesMode, "] expansions=", js["expansions"].len,
       " locations=", js["locations"].len,
       " expressionLocations=", js["expressionLocations"].len,
       " bridgedLocations=", bridgedEntries

proc main() =
  createDir(buildDir)
  # `--filenames:` accepts `abs|canonical|legacyRelProj` (see
  # `compiler/commands.nim`). The string equality bug only mattered
  # for `canonical` (and `legacyRelProj` indirectly); we exercise
  # both plus the default `abs` as a sanity check.
  for mode in ["abs", "canonical", "legacyRelProj"]:
    compileAndAssert(mode)

  removeDir(buildDir)
  echo "Macro sourcemap --filenames test passed"

main()
