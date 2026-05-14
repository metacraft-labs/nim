discard """
  action: "run"
  targets: "c"
"""

## Comprehensive NimScript trace test exercising many language features.
## Verifies CTFS structure and that the per-stream `.dat` files of the v4
## multi-stream layout contain substantive content (steps + calls + values),
## with key function names interned in funcs.dat.
##
## CTFS-M-Fix moved the VM tracer to the v4 multi-stream layout, so the
## v3 zstd-chunked `events.log` decompression path is no longer applicable —
## each event kind has its own raw stream now.

import std/[os, osproc, assertions, strutils, sequtils, tables]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_lang_features"

const testScript = """
# === Types ===
type
  Color = enum
    Red, Green, Blue

  Point = object
    x, y: float

  Shape = object
    kind: string
    center: Point
    color: Color

# === Variables and arithmetic ===
var count = 0
let pi = 3.14159
let name = "CodeTracer"

# === Control flow: if/else ===
proc classify(n: int): string =
  if n < 0:
    return "negative"
  elif n == 0:
    return "zero"
  else:
    return "positive"

# === Control flow: for loop ===
proc sumRange(n: int): int =
  result = 0
  for i in 1..n:
    result += i

# === Control flow: while loop ===
proc countDown(n: int): int =
  var x = n
  result = 0
  while x > 0:
    result += 1
    x -= 1

# === Control flow: case ===
proc colorName(c: Color): string =
  case c
  of Red: "red"
  of Green: "green"
  of Blue: "blue"

# === Objects and constructors ===
proc makePoint(x, y: float): Point =
  Point(x: x, y: y)

# === Sequences ===
proc makeSeq(n: int): seq[int] =
  result = @[]
  for i in 0..<n:
    result.add(i * i)

# === Tuples ===
proc divmod(a, b: int): (int, int) =
  (a div b, a mod b)

# === String operations ===
proc greet(who: string): string =
  "Hello, " & who & "!"

# === Recursion ===
proc fib(n: int): int =
  if n <= 1: return n
  return fib(n-1) + fib(n-2)

# === Exception handling (try/except) ===
proc safeDivide(a, b: int): string =
  try:
    if b == 0:
      raise newException(ValueError, "division by zero")
    let result = a div b
    return "ok: " & $result
  except ValueError:
    return "error: division by zero"

# === Generic proc ===
proc identity[T](x: T): T = x

# === Run everything ===
echo classify(-5)
echo classify(0)
echo classify(7)
echo sumRange(10)
echo countDown(5)
echo colorName(Blue)
let p = makePoint(3.0, 4.0)
echo p.x, " ", p.y
let s = makeSeq(5)
echo s
let (q, r) = divmod(17, 5)
echo q, " ", r
echo greet(name)
echo fib(8)
echo safeDivide(10, 3)
echo safeDivide(10, 0)
echo identity(42)
echo identity("hello")
"""

# Expected output lines from running the script
const expectedOutputLines = [
  "negative",
  "zero",
  "positive",
  "55",
  "5",
  "blue",
  "3.0 4.0",
  "@[0, 1, 4, 9, 16]",
  "3 2",
  "Hello, CodeTracer!",
  "21",
  "ok: 3",
  "error: division by zero",
  "42",
  "hello",
]

proc base40Decode(val: uint64): string =
  const Base40Chars = "\x000123456789abcdefghijklmnopqrstuvwxyz./-"
  var remaining = val
  var lastNonZero = -1
  var chars: array[12, char]
  for i in 0 ..< 12:
    let idx = remaining mod 40
    remaining = remaining div 40
    if idx == 0:
      chars[i] = '\0'
    else:
      chars[i] = Base40Chars[idx]
      lastNonZero = i
  result = ""
  for i in 0 .. lastNonZero:
    result.add(chars[i])

proc readLE32(data: string, offset: int): uint32 =
  for i in 0..3:
    result = result or (uint32(data[offset + i]) shl (i * 8))

proc readLE64(data: string, offset: int): uint64 =
  for i in 0..7:
    result = result or (uint64(data[offset + i]) shl (i * 8))

type
  CtfsFileEntry = object
    size: uint64
    mapBlock: uint64
    name: string
    nameEncoded: uint64

proc parseCtfsHeader(data: string): tuple[blockSize: uint32, maxRootEntries: uint32, entries: seq[CtfsFileEntry]] =
  doAssert data.len >= 16, "file too small for CTFS header"

  # Magic
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and
           data[2] == '\x72' and data[3] == '\xAC' and
           data[4] == '\xE2', "bad CTFS magic"

  # Version
  let version = uint8(data[5])
  doAssert version >= 2 and version <= 4, "unexpected CTFS version: " & $version

  # Extended header
  let blockSize = readLE32(data, 8)
  let maxRootEntries = readLE32(data, 12)

  doAssert blockSize >= 64, "block size too small: " & $blockSize
  doAssert maxRootEntries > 0, "zero max root entries"

  # Parse file entries
  var entries: seq[CtfsFileEntry]
  let headerSize = 8
  let extHeaderSize = 8
  let fileEntrySize = 24

  for i in 0 ..< int(maxRootEntries):
    let off = headerSize + extHeaderSize + i * fileEntrySize
    if off + fileEntrySize > data.len:
      break
    let size = readLE64(data, off)
    let mapBlock = readLE64(data, off + 8)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break
    entries.add(CtfsFileEntry(
      size: size,
      mapBlock: mapBlock,
      name: base40Decode(nameEnc),
      nameEncoded: nameEnc,
    ))

  (blockSize, maxRootEntries, entries)

proc readFileContent(data: string, entry: CtfsFileEntry, blockSize: uint32): string =
  if entry.size == 0:
    return ""

  let usable = int(blockSize) div 8 - 1
  var resultStr = ""
  var remaining = int(entry.size)
  var blockIdx = 0

  while remaining > 0 and blockIdx < usable:
    let mapOff = int(entry.mapBlock) * int(blockSize) + blockIdx * 8
    if mapOff + 8 > data.len:
      break
    let dataBlock = readLE64(data, mapOff)
    if dataBlock == 0:
      break

    let blockStart = int(dataBlock) * int(blockSize)
    let toRead = min(remaining, int(blockSize))
    if blockStart + toRead > data.len:
      break

    for i in 0 ..< toRead:
      resultStr.add(data[blockStart + i])

    remaining -= toRead
    blockIdx += 1

  resultStr

proc findString(data: string, needle: string): bool =
  ## Check if a string appears as a substring in raw binary data.
  needle in data

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)

  let scriptFile = buildDir / "test_lang_features.nims"
  let traceFile = buildDir / "test_trace.ct"
  writeFile(scriptFile, testScript)

  # --- Run the tracer ---
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed (exit " & $exitCode & "): " & output

  # --- Verify stdout output ---
  for line in expectedOutputLines:
    doAssert line in output, "expected output line '" & line & "' not found in stdout:\n" & output

  # --- Parse CTFS structure ---
  doAssert fileExists(traceFile), "trace file not created"
  let data = readFile(traceFile)

  let (blockSize, _, entries) = parseCtfsHeader(data)
  doAssert entries.len >= 3, "expected at least 3 internal files, got " & $entries.len

  # Index entries by name; choose v3 or v4 verification path.
  var byName: Table[string, CtfsFileEntry]
  for entry in entries:
    byName[entry.name] = entry

  let expectedFunctions = ["classify", "sumRange", "countDown", "colorName",
                           "makePoint", "makeSeq", "divmod", "greet", "fib",
                           "safeDivide", "identity"]

  if "events.log" in byName:
    # v3 single-stream layout
    for required in ["events.log", "meta.json", "paths.json"]:
      doAssert required in byName,
        "v3 layout missing '" & required & "': " & entries.mapIt(it.name).join(", ")

    let metaContent = readFileContent(data, byName["meta.json"], blockSize)
    doAssert metaContent.len > 0, "meta.json is empty"
    doAssert "test_lang_features" in metaContent,
      "meta.json should reference the program path 'test_lang_features'"

    let pathsContent = readFileContent(data, byName["paths.json"], blockSize)
    doAssert pathsContent.len > 0, "paths.json is empty"
    doAssert "test_lang_features" in pathsContent,
      "paths.json should contain the script file path"

    # events.log carries the (zstd-compressed) split-binary stream.
    # We can't decompress without linking zstd, so just check substantial size.
    doAssert byName["events.log"].size > 1024,
      "events.log too small for comprehensive script: " & $byName["events.log"].size & " bytes"

    echo "PASS: tvm_trace_language_features (v3 single-stream)"
    echo "  events.log=" & $byName["events.log"].size & "B  meta.json=" & $metaContent.len &
         "B  paths.json=" & $pathsContent.len & "B"
  else:
    # v4 multi-stream layout
    for required in ["paths.dat", "funcs.dat", "steps.dat", "calls.dat", "meta.dat",
                     "values.dat", "varnames.dat"]:
      doAssert required in byName,
        "v4 layout missing stream '" & required & "': " &
        entries.mapIt(it.name).join(", ")

    let metaContent  = readFileContent(data, byName["meta.dat"], blockSize)
    let pathsContent = readFileContent(data, byName["paths.dat"], blockSize)
    let funcsContent = readFileContent(data, byName["funcs.dat"], blockSize)
    let stepsContent = readFileContent(data, byName["steps.dat"], blockSize)
    let callsContent = readFileContent(data, byName["calls.dat"], blockSize)
    let valuesContent = readFileContent(data, byName["values.dat"], blockSize)

    doAssert metaContent.len > 0, "meta.dat is empty"
    doAssert "test_lang_features" in metaContent,
      "meta.dat should reference the program path 'test_lang_features'"

    doAssert pathsContent.len > 0, "paths.dat is empty"
    doAssert "test_lang_features" in pathsContent,
      "paths.dat should contain the script file path"

    # TF-M4 made the builtin filter skip the Nim stdlib, so steps.dat now
    # only contains events from the comprehensive user script — substantially
    # fewer bytes than the pre-M4 unfiltered baseline. The threshold still
    # rejects an effectively-empty stream (no user code stepped at all) while
    # leaving room for the user-code subset's natural size.
    doAssert stepsContent.len > 64,
      "steps.dat too small for comprehensive script: " & $stepsContent.len & " bytes"
    doAssert callsContent.len > 0, "calls.dat is empty — no Call events emitted"
    doAssert valuesContent.len > 0, "values.dat is empty — no Value events emitted"

    # funcs.dat embeds function name records — verify intern hits.
    var foundFunctions: seq[string] = @[]
    for fname in expectedFunctions:
      if findString(funcsContent, fname):
        foundFunctions.add(fname)

    doAssert foundFunctions.len >= 5,
      "expected at least 5 function names interned in funcs.dat, found " &
      $foundFunctions.len & ": " & foundFunctions.join(", ") &
      " (missing: " & expectedFunctions.filterIt(it notin foundFunctions).join(", ") & ")"

    echo "PASS: tvm_trace_language_features (v4 multi-stream)"
    echo "  meta.dat=" & $metaContent.len & "B  paths.dat=" & $pathsContent.len & "B"
    echo "  funcs.dat=" & $funcsContent.len & "B  steps.dat=" & $stepsContent.len & "B"
    echo "  calls.dat=" & $callsContent.len & "B  values.dat=" & $valuesContent.len & "B"
    echo "  Functions found in funcs.dat: " & foundFunctions.join(", ")

  removeDir(buildDir)

main()
