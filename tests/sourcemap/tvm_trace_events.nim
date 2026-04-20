discard """
  action: "run"
  targets: "c"
"""

## Verify that `nim e --trace` produces traces with correct CTFS structure,
## internal file contents (events.fmt, meta.json, paths.json), and non-trivial
## events.log data for a recursive factorial script.

import std/[os, osproc, assertions, strutils, json, sequtils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_events"

const testScript = """
proc factorial(n: int): int =
  if n <= 1: return 1
  return n * factorial(n - 1)

echo factorial(5)
"""

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
  ## Parse CTFS header and file entries from raw data.
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
  let headerSize = 8  # magic+version
  let extHeaderSize = 8  # blockSize + maxRootEntries
  let fileEntrySize = 24

  for i in 0 ..< int(maxRootEntries):
    let off = headerSize + extHeaderSize + i * fileEntrySize
    if off + fileEntrySize > data.len:
      break
    let size = readLE64(data, off)
    let mapBlock = readLE64(data, off + 8)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break  # empty slot = end of entries
    entries.add(CtfsFileEntry(
      size: size,
      mapBlock: mapBlock,
      name: base40Decode(nameEnc),
      nameEncoded: nameEnc,
    ))

  (blockSize, maxRootEntries, entries)

proc readFileContent(data: string, entry: CtfsFileEntry, blockSize: uint32): string =
  ## Read the content of a small CTFS internal file from its data blocks.
  ## This only handles level-1 mapping (files smaller than blockSize * (blockSize/8 - 1)).
  if entry.size == 0:
    return ""

  let usable = int(blockSize) div 8 - 1  # entries per map block minus chain ptr
  var result_str = ""
  var remaining = int(entry.size)
  var blockIdx = 0

  while remaining > 0 and blockIdx < usable:
    # Read pointer from mapping block
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
      result_str.add(data[blockStart + i])

    remaining -= toRead
    blockIdx += 1

  result_str

proc findNimTrace(): string =
  ## Find the trace-enabled compiler (nim_trace) next to the current compiler.
  ## Returns empty string if not found.
  let nimDir = getCurrentCompilerExe().parentDir
  result = nimDir / "nim_trace"
  if not fileExists(result):
    result = ""

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)
  createDir(buildDir)

  let scriptFile = buildDir / "test_factorial.nims"
  let traceFile = buildDir / "test_trace.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  # Verify expected stdout output from factorial(5) = 120
  doAssert "120" in output, "expected factorial(5)=120 in stdout, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let data = readFile(traceFile)

  # 1. Parse and verify CTFS structure
  let (blockSize, _, entries) = parseCtfsHeader(data)
  doAssert entries.len >= 4, "expected at least 4 internal files (events.log, events.fmt, meta.json, paths.json), got " & $entries.len

  # 2. Verify file entry names
  var foundEventsLog = false
  var foundEventsFmt = false
  var foundMetaJson = false
  var foundPathsJson = false
  var eventsLogEntry: CtfsFileEntry
  var eventsFmtEntry: CtfsFileEntry
  var metaJsonEntry: CtfsFileEntry
  var pathsJsonEntry: CtfsFileEntry

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

  doAssert foundEventsLog, "events.log not found in CTFS file entries (found: " &
    entries.mapIt(it.name).join(", ") & ")"
  doAssert foundEventsFmt, "events.fmt not found in CTFS file entries"
  doAssert foundMetaJson, "meta.json not found in CTFS file entries"
  doAssert foundPathsJson, "paths.json not found in CTFS file entries"

  # 3. Verify events.log has substantial content (factorial with recursion)
  doAssert eventsLogEntry.size > 0, "events.log is empty"
  doAssert eventsLogEntry.size > 32, "events.log too small for factorial trace: " & $eventsLogEntry.size & " bytes"

  # 4. Verify events.fmt content says "split-binary"
  let fmtContent = readFileContent(data, eventsFmtEntry, blockSize)
  doAssert fmtContent == "split-binary", "events.fmt should be 'split-binary', got: '" & fmtContent & "'"

  # 5. Verify meta.json is valid JSON with expected fields
  let metaContent = readFileContent(data, metaJsonEntry, blockSize)
  doAssert metaContent.len > 0, "meta.json is empty"
  let metaJson = parseJson(metaContent)
  doAssert metaJson.hasKey("program"), "meta.json missing 'program' field"
  doAssert metaJson.hasKey("args"), "meta.json missing 'args' field"
  doAssert metaJson.hasKey("workdir"), "meta.json missing 'workdir' field"
  # The program field should contain the script path
  let program = metaJson["program"].getStr()
  doAssert "test_factorial" in program, "meta.json program should reference test_factorial, got: " & program

  # 6. Verify paths.json is a valid JSON array with at least one path
  let pathsContent = readFileContent(data, pathsJsonEntry, blockSize)
  doAssert pathsContent.len > 0, "paths.json is empty"
  let pathsJson = parseJson(pathsContent)
  doAssert pathsJson.kind == JArray, "paths.json should be a JSON array"
  doAssert pathsJson.len >= 1, "paths.json should have at least one path entry"
  # At least one path should reference our script file
  var foundScriptPath = false
  for elem in pathsJson:
    if "test_factorial" in elem.getStr():
      foundScriptPath = true
      break
  doAssert foundScriptPath, "paths.json should contain the script file path"

  # 7. Verify events.log starts with valid chunk headers
  #    Each chunk: 16-byte header (compressedSize:u32, eventCount:u32, firstGeid:u64)
  #    followed by compressedSize bytes of zstd-compressed data.
  let eventsData = readFileContent(data, eventsLogEntry, blockSize)
  doAssert eventsData.len >= 16, "events.log data too small for chunk header"

  # Parse first chunk header
  let chunkCompressedSize = readLE32(eventsData, 0)
  let chunkEventCount = readLE32(eventsData, 4)
  let chunkFirstGeid = readLE64(eventsData, 8)

  doAssert chunkCompressedSize > 0, "first chunk compressed size is 0"
  doAssert chunkEventCount > 0, "first chunk event count is 0"
  doAssert chunkFirstGeid == 0, "first chunk firstGeid should be 0, got: " & $chunkFirstGeid

  # For a factorial(5) call: we expect multiple events
  # (path registrations, function definitions, steps, calls, returns, values)
  # The event count should be substantial
  doAssert chunkEventCount >= 10, "expected at least 10 events for factorial(5), got: " & $chunkEventCount

  # Verify the compressed data is present after the header
  doAssert eventsData.len >= int(16 + chunkCompressedSize),
    "events.log truncated: header says " & $chunkCompressedSize &
    " bytes compressed data, but only " & $(eventsData.len - 16) & " available"

  # 8. Verify the compressed data looks like valid Zstd (magic: 0xFD2FB528)
  if chunkCompressedSize >= 4:
    let zstdMagic = readLE32(eventsData, 16)
    doAssert zstdMagic == 0xFD2FB528'u32,
      "compressed chunk doesn't have Zstd magic (got 0x" &
      toHex(zstdMagic) & ")"

  removeDir(buildDir)
  echo "PASS: tvm_trace_events - full structural verification"

main()
