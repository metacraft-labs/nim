discard """
  action: "run"
  targets: "c"
  matrix: "--gc:refc; --gc:orc"
"""

## C sourcemap V3 — basic smoke test.
##
## At M2 the C backend writes a Source Map V3 (`.map`) sidecar next
## to every generated `.c` file when `--sourcemap:on` is set. The
## format is the same wire shape Chrome DevTools and Nim's own JS
## backend produce — off-the-shelf parsers read it. This test
## verifies the top-level JSON structure and decodes at least one
## VLQ-encoded segment to confirm the encoder produces valid output.

import std/[os, json, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap"

  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  continuationBit = 1 shl 5
  valueMask = continuationBit - 1

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

proc decodeVLQ(s: string): seq[int] =
  var b64Table: array[128, int]
  for i, c in alphabet: b64Table[c.ord] = i
  var shift = 0
  var value = 0
  for c in s:
    let v = b64Table[c.ord]
    value += (v and valueMask) shl shift
    if (v and continuationBit) != 0:
      shift += 5
      continue
    result.add((value shr 1) * (if (value and 1) != 0: -1 else: 1))
    shift = 0
    value = 0

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_sourcemap_prog.nim"
  let outFile = buildDir / "test_sourcemap_prog"

  createDir(buildDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Find the `.map` sidecar produced for the test program's .c file.
  var mapFile = ""
  for f in walkDir(nimcache):
    let n = f.path.extractFilename
    if n.endsWith(".c.map") and "test_sourcemap_prog" in n:
      mapFile = f.path
      break
  doAssert mapFile.len > 0,
    "expected `.map` sidecar in " & nimcache

  let js = parseJson(readFile(mapFile))

  # V3 envelope
  doAssert js.hasKey("version"), "Missing 'version'"
  doAssert js["version"].getInt == 3,
    "Expected sourcemap version 3, got " & $js["version"]
  doAssert js.hasKey("file"), "Missing 'file'"
  doAssert js.hasKey("sources"), "Missing 'sources'"
  doAssert js.hasKey("names"), "Missing 'names'"
  doAssert js.hasKey("mappings"), "Missing 'mappings'"
  doAssert js.hasKey("sourcesContent"), "Missing 'sourcesContent'"

  doAssert js["sources"].kind == JArray, "sources must be an array"
  doAssert js["sources"].len > 0, "no sources recorded"
  doAssert js["names"].kind == JArray, "names must be an array"
  doAssert js["mappings"].kind == JString, "mappings must be a string"

  # The Nim source file path must appear in `sources`.
  var foundTestFile = false
  for src in js["sources"]:
    if "test_sourcemap_prog" in src.getStr:
      foundTestFile = true
      break
  doAssert foundTestFile,
    "test_sourcemap_prog.nim not in sources: " & $js["sources"]

  let mappings = js["mappings"].getStr
  doAssert mappings.len > 0, "mappings string is empty"

  # Decode at least one segment to confirm VLQ encoding is valid.
  var segmentCount = 0
  var maxFields = 0
  for line in mappings.split(';'):
    for seg in line.split(','):
      if seg.len == 0: continue
      let v = decodeVLQ(seg)
      doAssert v.len in {1, 4, 5},
        "V3 segment must have 1, 4, or 5 VLQs; got " & $v.len &
        " for segment '" & seg & "'"
      maxFields = max(maxFields, v.len)
      inc segmentCount
  doAssert segmentCount > 0, "no mapping segments decoded"
  doAssert maxFields >= 4,
    "expected at least one 4-VLQ segment (genCol, srcIdx, origLine, origCol)"

  removeDir(buildDir)
  echo "C sourcemap V3 basic test passed (",
       segmentCount, " segments decoded)"

main()
