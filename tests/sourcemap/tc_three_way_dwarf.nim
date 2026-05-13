discard """
  action: "run"
  targets: "c"
  matrix: "--gc:orc"
"""

## C Source Map V2 — 3-way DWARF integration test.
##
## The user-visible feature this milestone exists to enable is
## three-way source view switching in CodeTracer: Nim ↔ C ↔ assembly.
## The chain depends on two facts:
##   1. DWARF (`.debug_line`) maps assembly addresses to real C lines.
##      V1 broke this because it injected `#line` directives that
##      gcc consumed, making DWARF point back to Nim source. V2's .c
##      files are clean, so this must now work.
##   2. The JSON sourcemap maps Nim lines to C lines.
##
## This test compiles a small Nim program, reads the JSON, picks the
## body of `add`, follows Nim→C via the JSON, and then verifies that
## at least one of those C lines has a corresponding DWARF
## `.debug_line` entry in the compiled .o. If the chain is broken
## (e.g. V1 regressed back in, or DWARF lines reference Nim files
## instead of the .c) the test fails.

import std/[os, json, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_three_way_dwarf"

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

type DwarfRow = tuple[address: int, line: int, file: string]

proc dumpDebugLine(objFile: string): seq[DwarfRow] =
  ## Parse the `.debug_line` table from `objFile`. Tries
  ## `objdump --dwarf=decodedline` first (binutils), falls back to
  ## `llvm-dwarfdump --debug-line` (LLVM toolchain).
  ##
  ## Both tools' decoded-line output looks roughly like:
  ##   File name      Line number    Starting address    View   Stmt
  ##   foo.c          145            0x40123a                   x
  ## with the exact column whitespace varying.
  proc tryParse(output: string): seq[DwarfRow] =
    var inTable = false
    for raw in output.splitLines:
      let stripped = raw.strip
      if stripped.startsWith("File name") and
          ("Starting address" in stripped or "Address" in stripped):
        inTable = true
        continue
      if not inTable: continue
      if stripped.len == 0: continue
      let parts = stripped.splitWhitespace
      if parts.len < 3: continue
      # Expected: <file> <line> <address> [view] [stmt]
      if not parts[2].startsWith("0x"): continue
      try:
        let line = parseInt(parts[1])
        let address = parseHexInt(parts[2])
        result.add (address: address, line: line, file: parts[0])
      except ValueError:
        discard

  # binutils first
  let bin = execCmdEx("objdump --dwarf=decodedline " & objFile)
  if bin.exitCode == 0:
    result = tryParse(bin.output)
    if result.len > 0: return
  # LLVM fallback
  let llvm = execCmdEx("llvm-dwarfdump --debug-line " & objFile)
  if llvm.exitCode == 0:
    result = tryParse(llvm.output)

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "three_way_test.nim"
  let outFile = buildDir / "three_way_test"

  createDir(buildDir)
  writeFile(srcFile, testProgram)

  # Compile with --sourcemap:on AND `-g` (so gcc emits DWARF).
  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --passC:-g --hints:off --warnings:off -o:" &
    outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Locate the JSON sourcemap (written next to the output binary).
  var sourcemapFile = ""
  for f in walkDir(buildDir):
    if f.path.extractFilename.startsWith("ct_sourcemap_"):
      sourcemapFile = f.path
      break
  doAssert sourcemapFile.len > 0,
    "ct_sourcemap_* not found in " & buildDir
  let js = parseJson(readFile(sourcemapFile))
  doAssert js.hasKey("version") and js["version"].getInt == 3,
    "Expected V3 sourcemap, got: " & $js{"version"}

  # Find the test file in nimSources.
  var testNimPathId = -1
  for k, v in js["nimSources"]:
    if "three_way_test" in k:
      testNimPathId = v.getInt
      break
  doAssert testNimPathId >= 0,
    "three_way_test.nim not in nimSources: " & $js["nimSources"]

  # Gather all (cPathID, cLine) the JSON maps to from the body of
  # `add` (Nim line 2: `result = a + b`). If line 2 has no mapping,
  # try line 5 (`result = a * b`) as a fallback.
  let pathMap = js["mappings"][testNimPathId]
  var candidateLines: seq[string] = @["2", "5", "1", "4"]
  var cLinesForNimBody: seq[(int, int)]
  var pickedNimLine = ""
  for cand in candidateLines:
    if pathMap.hasKey(cand):
      for group in pathMap[cand]:
        for entry in group:
          # V2 entry shape: [cPathID, cStartLine, cStartCol,
          #                  cEndLine, cEndCol, nimStartCol, nimEndCol]
          let cPathID = entry[0].getInt
          let cLine = entry[1].getInt
          cLinesForNimBody.add((cPathID, cLine))
      if cLinesForNimBody.len > 0:
        pickedNimLine = cand
        break
  doAssert cLinesForNimBody.len > 0,
    "No C mappings found for any body line of test_three_way: " &
    $pathMap

  # Locate the .o for the test module.
  var actualObjPath = ""
  for f in walkDirRec(nimcache):
    if f.endsWith(".o") and "three_way_test" in f:
      actualObjPath = f
      break
  doAssert actualObjPath.len > 0,
    "three_way_test.*.o not found in " & nimcache

  # Read DWARF rows.
  let dwarf = dumpDebugLine(actualObjPath)
  doAssert dwarf.len > 0,
    "No DWARF .debug_line entries parsed from " & actualObjPath &
    " (objdump/llvm-dwarfdump unavailable or output format mismatch)"

  # Critical check: at least one DWARF row references a real C file
  # (not a Nim file) AND its line matches one of the C lines the JSON
  # said our Nim body produces. V1 would have failed this — every
  # DWARF row pointed at three_way_test.nim because of injected
  # `#line` directives.
  var cFileReferenced = false
  for d in dwarf:
    if d.file.endsWith(".c") or d.file.endsWith(".nim.c"):
      cFileReferenced = true
      break
  doAssert cFileReferenced,
    "No DWARF row references a .c file. V1 regression suspected " &
    "(all entries point at .nim source)? Sample: " &
    $dwarf[0 .. min(2, dwarf.high)]

  var matched = false
  for c in cLinesForNimBody:
    for d in dwarf:
      if d.line == c[1] and
          (d.file.endsWith(".c") or d.file.endsWith(".nim.c")):
        matched = true
        break
    if matched: break
  doAssert matched,
    "Nim line " & pickedNimLine & " was mapped to C lines " &
    $cLinesForNimBody & " but no DWARF row in " & actualObjPath &
    " references those lines. Nim → C → assembly chain is broken."

  removeDir(buildDir)
  echo "3-way DWARF integration test passed (Nim line ",
       pickedNimLine, ", matched ", cLinesForNimBody.len,
       " candidate C lines, ", dwarf.len, " DWARF rows scanned)"

main()
