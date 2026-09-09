discard """
  action: "run"
  targets: "c"
"""

## Verify that `nim e --trace` produces traces with correct CTFS structure
## and non-trivial stream content for a recursive factorial script.
##
## The trace uses the multi-stream layout (`steps.dat` + `calls.dat` +
## `funcs.dat` + `paths.dat` + `meta.dat` …) and should contain the
## factorial recursion.

import std/[os, osproc, assertions, strutils, sequtils, tables]

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
  doAssert version >= 2 and version <= 4, "unexpected CTFS version: " & $version

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

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
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
  doAssert entries.len >= 3, "expected at least 3 internal files, got " & $entries.len

  # 2. Index entries by name and verify the multi-stream layout.
  var byName: Table[string, CtfsFileEntry]
  for entry in entries:
    byName[entry.name] = entry

  for required in ["paths.dat", "funcs.dat", "steps.dat", "calls.dat", "meta.dat"]:
    doAssert required in byName,
      "missing stream '" & required & "': " &
      entries.mapIt(it.name).join(", ")

  doAssert byName["steps.dat"].size > 32,
    "steps.dat too small for factorial trace: " & $byName["steps.dat"].size & " bytes"
  doAssert byName["calls.dat"].size > 0,
    "calls.dat is empty — no Call events emitted for factorial recursion"

  let metaContent = readFileContent(data, byName["meta.dat"], blockSize)
  doAssert metaContent.len > 0, "meta.dat is empty"
  doAssert "test_factorial" in metaContent,
    "meta.dat should reference the program path 'test_factorial'"

  let pathsContent = readFileContent(data, byName["paths.dat"], blockSize)
  doAssert pathsContent.len > 0, "paths.dat is empty"
  doAssert "test_factorial" in pathsContent,
    "paths.dat should contain the script file path"

  let funcsContent = readFileContent(data, byName["funcs.dat"], blockSize)
  doAssert funcsContent.len > 0, "funcs.dat is empty"
  doAssert "factorial" in funcsContent,
    "funcs.dat should contain the 'factorial' function name"

  echo "PASS: tvm_trace_events - multi-stream structural verification"

  removeDir(buildDir)

main()
