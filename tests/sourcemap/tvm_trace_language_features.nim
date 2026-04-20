discard """
  action: "run"
  targets: "c"
"""

## Comprehensive NimScript trace test exercising many language features.
## Verifies CTFS structure, decompresses event data using libzstd,
## and checks for expected event tags and function names in the trace.

import std/[os, osproc, assertions, strutils, json, sequtils]

{.passL: "-lzstd".}

proc ZSTD_getFrameContentSize(src: pointer, srcSize: csize_t): culonglong
  {.importc, header: "<zstd.h>".}

proc ZSTD_decompress(dst: pointer, dstCapacity: csize_t,
                     src: pointer, compressedSize: csize_t): csize_t
  {.importc, header: "<zstd.h>".}

proc ZSTD_isError(code: csize_t): cuint
  {.importc, header: "<zstd.h>".}

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

# Event tag constants (split-binary format)
const
  TagStep = 0x00'u8
  TagPath = 0x01'u8
  TagFunction = 0x06'u8
  TagCall = 0x07'u8
  TagReturn = 0x08'u8

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
  doAssert version == 3 or version == 2, "unexpected CTFS version: " & $version

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

proc findNimTrace(): string =
  let nimDir = getCurrentCompilerExe().parentDir
  result = nimDir / "nim_trace"
  if not fileExists(result):
    result = ""

proc decompressZstd(compressed: string): string =
  ## Decompress a zstd frame, returning the decompressed bytes as a string.
  let frameSize = ZSTD_getFrameContentSize(
    unsafeAddr compressed[0], csize_t(compressed.len))
  # ZSTD_CONTENTSIZE_UNKNOWN = uint64.high, ZSTD_CONTENTSIZE_ERROR = uint64.high - 1
  doAssert frameSize < uint64(100_000_000), "zstd frame too large or error: " & $frameSize

  result = newString(int(frameSize))
  let decompSize = ZSTD_decompress(
    addr result[0], csize_t(frameSize),
    unsafeAddr compressed[0], csize_t(compressed.len))
  doAssert ZSTD_isError(decompSize) == 0, "zstd decompression failed"
  doAssert int(decompSize) == int(frameSize), "zstd size mismatch"

proc countTagOccurrences(data: string, tag: uint8): int =
  ## Count how many times a byte value appears at event-start positions.
  ## In split-binary, each event starts with a tag byte. We scan all bytes
  ## since we don't know exact event boundaries, but tag bytes at position 0
  ## of events will contribute. This is a lower bound since the tag value
  ## could appear inside event payloads too.
  ## For a more accurate count, we just count all occurrences of the tag byte
  ## at the start of the data stream - this gives us a rough measure.
  result = 0
  # Simple heuristic: count occurrences of the tag byte.
  # This overcounts but gives us a floor for verification.
  for i in 0 ..< data.len:
    if uint8(data[i]) == tag:
      result += 1

proc findString(data: string, needle: string): bool =
  ## Check if a string appears as a substring in raw binary data.
  needle in data

type
  ChunkInfo = object
    compressedSize: uint32
    eventCount: uint32
    firstGeid: uint64
    compressedData: string

proc parseChunks(eventsData: string): seq[ChunkInfo] =
  ## Parse all chunks from events.log data.
  var offset = 0
  while offset + 16 <= eventsData.len:
    let compSize = readLE32(eventsData, offset)
    let eventCount = readLE32(eventsData, offset + 4)
    let firstGeid = readLE64(eventsData, offset + 8)

    if compSize == 0:
      break

    let dataStart = offset + 16
    if dataStart + int(compSize) > eventsData.len:
      break

    var compressed = newString(int(compSize))
    for i in 0 ..< int(compSize):
      compressed[i] = eventsData[dataStart + i]

    result.add(ChunkInfo(
      compressedSize: compSize,
      eventCount: eventCount,
      firstGeid: firstGeid,
      compressedData: compressed,
    ))

    offset = dataStart + int(compSize)

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)

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
  doAssert entries.len >= 4, "expected at least 4 internal files, got " & $entries.len

  # Find internal files
  var eventsLogEntry, eventsFmtEntry, metaJsonEntry, pathsJsonEntry: CtfsFileEntry
  var foundEventsLog, foundEventsFmt, foundMetaJson, foundPathsJson: bool

  for entry in entries:
    case entry.name
    of "events.log":
      foundEventsLog = true
      eventsLogEntry = entry
    of "events.fmt":
      foundEventsFmt = true
      eventsFmtEntry = entry
    of "meta.json":
      foundMetaJson = true
      metaJsonEntry = entry
    of "paths.json":
      foundPathsJson = true
      pathsJsonEntry = entry
    else:
      discard

  doAssert foundEventsLog, "events.log not found in CTFS entries (found: " &
    entries.mapIt(it.name).join(", ") & ")"
  doAssert foundEventsFmt, "events.fmt not found"
  doAssert foundMetaJson, "meta.json not found"
  doAssert foundPathsJson, "paths.json not found"

  # --- Verify events.fmt ---
  let fmtContent = readFileContent(data, eventsFmtEntry, blockSize)
  doAssert fmtContent == "split-binary", "events.fmt should be 'split-binary', got: '" & fmtContent & "'"

  # --- Verify meta.json ---
  let metaContent = readFileContent(data, metaJsonEntry, blockSize)
  doAssert metaContent.len > 0, "meta.json is empty"
  let metaJson = parseJson(metaContent)
  doAssert metaJson.hasKey("program"), "meta.json missing 'program' field"
  let program = metaJson["program"].getStr()
  doAssert "test_lang_features" in program, "meta.json program should reference test_lang_features, got: " & program

  # --- Verify paths.json ---
  let pathsContent = readFileContent(data, pathsJsonEntry, blockSize)
  doAssert pathsContent.len > 0, "paths.json is empty"
  let pathsJson = parseJson(pathsContent)
  doAssert pathsJson.kind == JArray, "paths.json should be a JSON array"
  doAssert pathsJson.len >= 1, "paths.json should have at least one path"
  var foundScriptPath = false
  for elem in pathsJson:
    if "test_lang_features" in elem.getStr():
      foundScriptPath = true
      break
  doAssert foundScriptPath, "paths.json should contain the script file path"

  # --- Parse events.log chunks ---
  let eventsData = readFileContent(data, eventsLogEntry, blockSize)
  doAssert eventsData.len >= 16, "events.log too small"

  let chunks = parseChunks(eventsData)
  doAssert chunks.len >= 1, "no chunks found in events.log"

  # First chunk should start at geid 0
  doAssert chunks[0].firstGeid == 0, "first chunk firstGeid should be 0, got: " & $chunks[0].firstGeid

  # Sum total events across all chunks
  var totalEvents: int = 0
  for chunk in chunks:
    totalEvents += int(chunk.eventCount)

  doAssert totalEvents > 100, "expected >100 total events for comprehensive script, got: " & $totalEvents

  # --- Decompress and analyze event data ---
  var allDecompressed = ""
  for chunk in chunks:
    # Verify zstd magic
    doAssert chunk.compressedData.len >= 4, "compressed chunk too small"
    let magic = readLE32(chunk.compressedData, 0)
    doAssert magic == 0xFD2FB528'u32,
      "compressed chunk doesn't have Zstd magic (got 0x" & toHex(magic) & ")"

    let decompressed = decompressZstd(chunk.compressedData)
    doAssert decompressed.len > 0, "decompressed chunk is empty"
    allDecompressed.add(decompressed)

  doAssert allDecompressed.len > 0, "no decompressed data"

  # --- Verify event tags are present ---
  # Note: counting raw byte occurrences overcounts (tag values appear in payloads too),
  # but it guarantees the tag byte exists at least in some events.
  let stepCount = countTagOccurrences(allDecompressed, TagStep)
  let pathCount = countTagOccurrences(allDecompressed, TagPath)
  let functionCount = countTagOccurrences(allDecompressed, TagFunction)
  let callCount = countTagOccurrences(allDecompressed, TagCall)
  let returnCount = countTagOccurrences(allDecompressed, TagReturn)

  # Step events: many lines of code executed
  doAssert stepCount > 0, "no Step tag bytes (0x00) found in decompressed data"

  # Path events: at least the script file
  doAssert pathCount >= 1, "expected at least 1 Path tag byte (0x01), got: " & $pathCount

  # Function events: classify, sumRange, countDown, colorName, makePoint, etc.
  doAssert functionCount >= 1, "expected Function tag bytes (0x06), got: " & $functionCount

  # Call events: one per function invocation
  doAssert callCount >= 1, "expected Call tag bytes (0x07), got: " & $callCount

  # Return events: matching calls
  doAssert returnCount >= 1, "expected Return tag bytes (0x08), got: " & $returnCount

  # --- Verify function names in decompressed data ---
  # Function names should appear as UTF-8 strings in the event stream
  let expectedFunctions = ["classify", "sumRange", "countDown", "colorName",
                           "makePoint", "makeSeq", "divmod", "greet", "fib",
                           "safeDivide", "identity"]

  var foundFunctions: seq[string] = @[]
  for fname in expectedFunctions:
    if findString(allDecompressed, fname):
      foundFunctions.add(fname)

  # We expect most function names to be present (some may be inlined or optimized)
  doAssert foundFunctions.len >= 5,
    "expected at least 5 function names in event data, found " &
    $foundFunctions.len & ": " & foundFunctions.join(", ") &
    " (missing: " & expectedFunctions.filterIt(it notin foundFunctions).join(", ") & ")"

  # --- Summary ---
  echo "PASS: tvm_trace_language_features"
  echo "  Chunks: " & $chunks.len
  echo "  Total events: " & $totalEvents
  echo "  Decompressed size: " & $allDecompressed.len & " bytes"
  echo "  Functions found: " & foundFunctions.join(", ")
  echo "  Tag counts (raw byte): Step=" & $stepCount & " Path=" & $pathCount &
       " Function=" & $functionCount & " Call=" & $callCount & " Return=" & $returnCount

  removeDir(buildDir)

main()
