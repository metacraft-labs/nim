discard """
  action: "run"
  targets: "c"
  matrix: "--gc:refc; --gc:orc"
"""

## Test that --sourcemap:on generates ct_sourcemap_*.json files for the C backend
## and that they contain correct bidirectional Nim-to-C line mappings.

import std/[os, json, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap"

# A small multi-proc Nim program to compile with sourcemap
const testProgram = """
proc add(a, b: int): int =
  result = a + b

proc multiply(a, b: int): int =
  result = a * b

proc greet(name: string): string =
  result = "Hello, " & name

when isMainModule:
  let x = add(3, 4)
  let y = multiply(x, 2)
  echo greet("world")
  echo y
"""

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_sourcemap_prog.nim"
  let outFile = buildDir / "test_sourcemap_prog"

  # Setup
  createDir(buildDir)
  writeFile(srcFile, testProgram)

  # Compile with --sourcemap:on
  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Find the ct_sourcemap file (written next to the output binary)
  var sourcemapFile = ""
  for f in walkDir(buildDir):
    if f.path.extractFilename.startsWith("ct_sourcemap_"):
      sourcemapFile = f.path
      break

  doAssert sourcemapFile.len > 0, "ct_sourcemap_* file not found in " & buildDir

  # Parse the sourcemap JSON
  let content = readFile(sourcemapFile)
  let js = parseJson(content)

  # Verify structure
  doAssert js.hasKey("nimSources"), "Missing nimSources key"
  doAssert js.hasKey("cSources"), "Missing cSources key"
  doAssert js.hasKey("mappings"), "Missing mappings key"

  # Verify we have at least one Nim source and one C source
  doAssert js["nimSources"].len > 0, "No Nim sources in sourcemap"
  doAssert js["cSources"].len > 0, "No C sources in sourcemap"

  # Verify our test file appears in nimSources
  var foundTestFile = false
  for key, val in js["nimSources"]:
    if "test_sourcemap_prog" in key:
      foundTestFile = true
      break
  doAssert foundTestFile, "test_sourcemap_prog.nim not found in nimSources"

  # V2: top-level `version` field marks the format.
  doAssert js.hasKey("version"), "Missing version key"
  doAssert js["version"].getInt == 2,
    "Expected sourcemap version 2, got " & $js["version"]

  # Verify mappings exist and are non-empty
  doAssert js["mappings"].kind == JArray, "mappings should be an array"
  doAssert js["mappings"].len > 0, "mappings array is empty"

  # Verify at least one mapping entry has actual line data with the V2
  # shape (7-tuple). V1 readers indexing only [0]/[1] still see the
  # right values (cPathID and cStartLine).
  var hasLineData = false
  for pathMap in js["mappings"]:
    if pathMap.kind == JObject and pathMap.len > 0:
      for nimLine, groups in pathMap:
        if groups.kind == JArray and groups.len > 0:
          for group in groups:
            if group.kind == JArray and group.len > 0:
              hasLineData = true
              let entry = group[0]
              doAssert entry.kind == JArray,
                "Line entry should be an array"
              # V2 shape: [cPathID, cStartLine, cStartCol,
              #           cEndLine, cEndCol, nimStartCol, nimEndCol].
              doAssert entry.len == 7,
                "V2 line entry should have 7 elements, got " &
                $entry.len & " (" & $entry & ")"
              # V1 compatibility: [0] is still cPathID, [1] is still
              # cStartLine — readers that only look at those continue
              # to work.
              doAssert entry[0].kind == JInt and entry[1].kind == JInt
              break
            if hasLineData: break
        if hasLineData: break
      if hasLineData: break

  doAssert hasLineData, "No actual line mapping data found"

  # Cleanup
  removeDir(buildDir)

  echo "C sourcemap test passed"

main()
