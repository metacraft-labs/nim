discard """
  action: "run"
  targets: "c"
  matrix: "--gc:refc; --gc:orc"
"""

## Test that --sourcemap:on generates macro_sourcemap_*.json and expanded.nim
## for programs that use macros and templates.

import std/[os, json, strutils, osproc, compilesettings, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tmacro_sourcemap"

# A Nim program that uses macros and templates
const testProgram = """
import std/macros

template logValue(name: string, value: untyped) =
  echo name, " = ", value

macro generateProcs(n: static int): untyped =
  result = newStmtList()
  for i in 0 ..< n:
    let procName = ident("generatedProc" & $i)
    let body = newLit("I am proc " & $i)
    result.add quote do:
      proc `procName`(): string =
        `body`

generateProcs(3)

when isMainModule:
  logValue("a", 42)
  logValue("b", "hello")
  echo generatedProc0()
  echo generatedProc1()
  echo generatedProc2()
"""

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_macro_prog.nim"
  let outFile = buildDir / "test_macro_prog"

  # Setup
  createDir(buildDir)
  writeFile(srcFile, testProgram)

  # Compile with --sourcemap:on
  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Check for macro_sourcemap_*.json (written next to the output binary)
  var macroSourcemapFile = ""
  for f in walkDir(buildDir):
    let name = f.path.extractFilename
    if name.startsWith("macro_sourcemap_") and name.endsWith(".json"):
      macroSourcemapFile = f.path
      break

  doAssert macroSourcemapFile.len > 0,
    "macro_sourcemap_*.json not found in " & buildDir

  # Parse the macro sourcemap JSON
  let content = readFile(macroSourcemapFile)
  let js = parseJson(content)

  # Verify required keys
  doAssert js.hasKey("expansions"), "Missing expansions key"
  doAssert js.hasKey("locations"), "Missing locations key"
  doAssert js.hasKey("expandedEntries"), "Missing expandedEntries key"
  doAssert js.hasKey("expandedFilename"), "Missing expandedFilename key"

  # Verify expansions contain our macro calls
  let expansions = js["expansions"]
  doAssert expansions.kind == JArray, "expansions should be an array"
  # We should have at least some expansions from our macro/template usage
  # (logValue template and generateProcs macro)
  doAssert expansions.len > 0, "No macro expansions recorded"

  # Check that each expansion has the expected structure
  for exp in expansions:
    doAssert exp.hasKey("path"), "Expansion missing 'path'"
    doAssert exp.hasKey("firstLine"), "Expansion missing 'firstLine'"
    doAssert exp.hasKey("lastLine"), "Expansion missing 'lastLine'"
    doAssert exp.hasKey("site"), "Expansion missing 'site'"
    doAssert exp.hasKey("definition"), "Expansion missing 'definition'"
    doAssert exp.hasKey("name"), "Expansion missing 'name'"

  # Check expanded.nim was generated
  let expandedFilename = js["expandedFilename"].getStr
  if expandedFilename.len > 0:
    doAssert fileExists(expandedFilename),
      "expanded.nim referenced but doesn't exist: " & expandedFilename

    # Verify expanded.nim contains actual code
    let expandedContent = readFile(expandedFilename)
    doAssert expandedContent.len > 0, "expanded.nim is empty"

    # The expanded file should contain some of our generated proc names
    # since generateProcs(3) creates generatedProc0, generatedProc1, generatedProc2
    doAssert "generatedProc" in expandedContent or "proc" in expandedContent,
      "expanded.nim doesn't appear to contain expanded macro code"

  # Verify expandedEntries maps original source locations to expanded lines
  let expandedEntries = js["expandedEntries"]
  doAssert expandedEntries.kind == JObject, "expandedEntries should be an object"

  # Verify locations map expanded lines to site info
  let locations = js["locations"]
  doAssert locations.kind == JObject, "locations should be an object"

  # Cleanup
  removeDir(buildDir)

  echo "Macro sourcemap test passed"

main()
