discard """
  action: "run"
  targets: "c"
  matrix: "--gc:orc"
"""

## C sourcemap V3 — 3-way DWARF integration test.
##
## The user-visible feature this milestone enables is three-way
## source view switching in CodeTracer: Nim ↔ C ↔ assembly. The chain
## depends on two facts:
##   1. DWARF (`.debug_line`) maps assembly addresses to real C lines.
##      V1 broke this because it injected `#line` directives that gcc
##      consumed, making DWARF point back to Nim source. V3's .c files
##      are clean, so this must now work.
##   2. The `.map` sidecar (Source Map V3) maps Nim lines to C lines.
##
## This test compiles a small Nim program, parses the V3 `.map` for
## the body of `add`, picks the C lines it maps to, and verifies that
## at least one of those lines has a corresponding DWARF row in the
## compiled `.o`. If the chain is broken (V1 regressed in, or DWARF
## lines reference Nim files instead of the .c) the test fails.

import std/[os, json, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_three_way_dwarf"

  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  continuationBit = 1 shl 5
  valueMask = continuationBit - 1

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

type
  DwarfRow = tuple[address: int, line: int, file: string]
  V3Segment = tuple[genLine, genCol, sourceIdx, origLine, origCol: int]

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

proc decodeMappings(s: string): seq[V3Segment] =
  var src = 0
  var oLine = 0
  var oCol = 0
  var gLine = 0
  for line in s.split(';'):
    var gCol = 0
    for seg in line.split(','):
      if seg.len == 0: continue
      let v = decodeVLQ(seg)
      if v.len >= 4:
        gCol += v[0]
        src += v[1]
        oLine += v[2]
        oCol += v[3]
        result.add (genLine: gLine, genCol: gCol, sourceIdx: src,
                    origLine: oLine, origCol: oCol)
    inc gLine

proc parseGnuDecodedLine(output: string): seq[DwarfRow] =
  ## Parses GNU binutils' `objdump --dwarf=decodedline`, whose table rows
  ## name the file directly: `<file> <line> <0xaddress> [view] [stmt]`.
  ## https://sourceware.org/binutils/docs/binutils/objdump.html
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
    if not parts[2].startsWith("0x"): continue
    try:
      let line = parseInt(parts[1])
      let address = parseHexInt(parts[2])
      result.add (address: address, line: line, file: parts[0])
    except ValueError:
      discard

proc parseLlvmDebugLine(output: string): seq[DwarfRow] =
  ## Parses LLVM's `llvm-dwarfdump --debug-line`. Unlike GNU's decoded
  ## view, its rows carry a file *index*
  ## (`<0xaddress> <line> <column> <file> <isa> ...`) that resolves through
  ## the `file_names[ N]:` / `name: "<file>"` entries of the same line
  ## table's prologue, so the index table is rebuilt for every
  ## `debug_line[...]` unit.
  ## https://llvm.org/docs/CommandGuide/llvm-dwarfdump.html
  var files: seq[(int, string)]   # (index, name) of the current unit
  var pendingIdx = -1             # `file_names[N]:` awaiting its `name:`
  var inTable = false

  proc fileName(files: seq[(int, string)], idx: int): string =
    for (i, n) in files:
      if i == idx: return n
    ""

  for raw in output.splitLines:
    let stripped = raw.strip
    if stripped.startsWith("debug_line["):
      files.setLen 0
      pendingIdx = -1
      inTable = false
    elif stripped.startsWith("file_names["):
      let close = stripped.find(']')
      pendingIdx = -1
      if close > 0:
        try: pendingIdx = parseInt(stripped["file_names[".len ..< close].strip)
        except ValueError: discard
    elif stripped.startsWith("name:") and pendingIdx >= 0:
      files.add (pendingIdx, stripped["name:".len .. ^1].strip.strip(chars = {'"'}))
      pendingIdx = -1
    elif stripped.startsWith("Address") and "Line" in stripped and
        "File" in stripped:
      inTable = true
    elif inTable and stripped.startsWith("0x"):
      let parts = stripped.splitWhitespace
      if parts.len < 4: continue
      try:
        let address = parseHexInt(parts[0])
        let line = parseInt(parts[1])
        let file = fileName(files, parseInt(parts[3]))
        if file.len > 0:
          result.add (address: address, line: line, file: file)
      except ValueError:
        discard

proc dumpDebugLine(objFile: string): seq[DwarfRow] =
  ## Reads the `.debug_line` rows of `objFile` with whichever dumper the
  ## host provides. GNU `objdump` is tried first (Linux). On darwin the
  ## `objdump` on PATH is LLVM's, which rejects `--dwarf=decodedline` with
  ## a non-zero exit, so the test falls through to `llvm-dwarfdump` (put in
  ## the darwin dev shell by `flake.nix`) and parses LLVM's own format.
  let gnu = execCmdEx("objdump --dwarf=decodedline " & quoteShell(objFile))
  if gnu.exitCode == 0:
    result = parseGnuDecodedLine(gnu.output)
    if result.len > 0: return
  let llvm = execCmdEx("llvm-dwarfdump --debug-line " & quoteShell(objFile))
  if llvm.exitCode == 0:
    result = parseLlvmDebugLine(llvm.output)

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "three_way_test.nim"
  let outFile = buildDir / "three_way_test"

  createDir(buildDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --passC:-g --hints:off --warnings:off -o:" &
    outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Locate the V3 .map sidecar for the test module's .c file.
  var mapFile = ""
  var cFile = ""
  for f in walkDir(nimcache):
    let n = f.path.extractFilename
    if n.endsWith(".c.map") and "three_way_test" in n:
      mapFile = f.path
      cFile = mapFile[0 ..< ^4]   # strip ".map"
      break
  doAssert mapFile.len > 0,
    "V3 .map sidecar not found in " & nimcache

  let js = parseJson(readFile(mapFile))
  doAssert js["version"].getInt == 3,
    "Expected Source Map V3, got: " & $js{"version"}

  # Identify the Nim source's index in `sources`.
  var nimSrcIdx = -1
  block findIdx:
    var i = 0
    for src in js["sources"]:
      if "three_way_test" in src.getStr:
        nimSrcIdx = i
        break findIdx
      inc i
  doAssert nimSrcIdx >= 0,
    "three_way_test.nim not in sources: " & $js["sources"]

  let segments = decodeMappings(js["mappings"].getStr)

  # Body lines of `add` are Nim lines 1..2 (0-based after V3 conv).
  # Collect all C lines (1-based, as DWARF uses) that map to those
  # Nim lines from the .map. The V3 origLine is 0-based, so Nim line
  # 1 corresponds to V3 origLine 0.
  var candidateNimLines: seq[int] = @[1, 4, 0, 3]   # 0-based
  var cLinesForNimBody: seq[int]
  var pickedNimLine = -1
  for cand in candidateNimLines:
    for s in segments:
      if s.sourceIdx == nimSrcIdx and s.origLine == cand:
        cLinesForNimBody.add(s.genLine + 1)        # to 1-based
    if cLinesForNimBody.len > 0:
      pickedNimLine = cand
      break
  doAssert cLinesForNimBody.len > 0,
    "No C mappings found for any body line of three_way_test"

  # Locate the .o for the test module.
  var actualObjPath = ""
  for f in walkDirRec(nimcache):
    if f.endsWith(".o") and "three_way_test" in f:
      actualObjPath = f
      break
  doAssert actualObjPath.len > 0,
    "three_way_test.*.o not found in " & nimcache

  let dwarf = dumpDebugLine(actualObjPath)
  doAssert dwarf.len > 0,
    "No DWARF .debug_line entries parsed from " & actualObjPath &
    " (objdump/llvm-dwarfdump unavailable or output format mismatch)"

  var cFileReferenced = false
  for d in dwarf:
    if d.file.endsWith(".c") or d.file.endsWith(".nim.c"):
      cFileReferenced = true
      break
  doAssert cFileReferenced,
    "No DWARF row references a .c file. V1 regression suspected? " &
    "Sample: " & $dwarf[0 .. min(2, dwarf.high)]

  var matched = false
  for cl in cLinesForNimBody:
    for d in dwarf:
      if d.line == cl and
          (d.file.endsWith(".c") or d.file.endsWith(".nim.c")):
        matched = true
        break
    if matched: break
  doAssert matched,
    "Nim line " & $pickedNimLine & " was mapped to C lines " &
    $cLinesForNimBody & " but no DWARF row in " & actualObjPath &
    " references those lines. Nim → C → assembly chain is broken."

  echo "3-way DWARF integration test passed (Nim line ",
       pickedNimLine, ", matched ", cLinesForNimBody.len,
       " candidate C lines, ", dwarf.len, " DWARF rows scanned)"

# `buildDir` lies inside this test category, and testament collects every
# `t*.nim` under it recursively (`isTestFile` in testament/categories.nim),
# so a `three_way_test.nim` left behind would run as an extra test on the
# next `koch tests cat sourcemap`. The directory is therefore removed
# whether `main` passes or fails, and also before it starts, in case an
# earlier run was killed before its `finally` could run.
removeDir(buildDir)
try:
  main()
finally:
  removeDir(buildDir)
