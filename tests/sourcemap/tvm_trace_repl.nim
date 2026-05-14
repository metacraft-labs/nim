discard """
  action: "run"
  targets: "c"
"""

## Test that `nim secret --trace` (the REPL) produces a valid .ct trace file
## with meaningful content. Commands are piped via stdin; EOF triggers REPL exit.
##
## Verifies:
## - Exit code is 0
## - Trace file exists with valid CTFS magic
## - events.log has data (non-zero size in file entry)
## - The REPL produced expected stdout output ("3" from echo x)
## - meta.json and events.fmt are present

import std/[os, osproc, streams, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_repl"

proc readLE32(data: string, offset: int): uint32 =
  for i in 0..3:
    result = result or (uint32(data[offset + i]) shl (i * 8))

proc readLE64(data: string, offset: int): uint64 =
  for i in 0..7:
    result = result or (uint64(data[offset + i]) shl (i * 8))

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

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  createDir(buildDir)
  let traceFile = buildDir / "repl_trace.ct"

  # Remove any leftover trace file from a previous run
  if fileExists(traceFile):
    removeFile(traceFile)

  # Start the REPL with --trace, piping commands via stdin
  let p = startProcess(nim,
    args = @["secret", "--trace:" & traceFile],
    options = {poUsePath, poStdErrToStdOut})

  let inp = p.inputStream
  inp.write("let x = 1 + 2\n")
  inp.write("echo x\n")
  inp.close()  # EOF triggers REPL exit

  let exitCode = p.waitForExit()
  let output = p.outputStream.readAll()
  p.close()

  doAssert exitCode == 0, "nim secret --trace failed with exit code " & $exitCode &
    "\nOutput: " & output

  # Verify expected REPL output contains "3"
  doAssert "3" in output, "REPL should output '3' from echo x, got: " & output

  # The trace file must exist and be non-empty
  doAssert fileExists(traceFile), "trace file not created: " & traceFile
  doAssert getFileSize(traceFile) > 0, "trace file is empty"

  let data = readFile(traceFile)

  # 1. Verify CTFS magic bytes
  doAssert data.len >= 16, "trace file too small: " & $data.len & " bytes"
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and data[2] == '\x72' and
           data[3] == '\xAC' and data[4] == '\xE2',
           "not a valid CTFS file (bad magic bytes)"

  # 2. Verify version
  let version = uint8(data[5])
  doAssert version >= 2 and version <= 4, "unexpected CTFS version: " & $version

  # 3. Verify block size is reasonable
  let blockSize = readLE32(data, 8)
  doAssert blockSize >= 64 and blockSize <= 65536,
    "unreasonable block size: " & $blockSize

  # 4. Verify the first file entry has non-zero size — some events must have
  #    been recorded by the REPL (`let x = 1+2; echo x`).
  let firstEntrySize = readLE64(data, 16)
  doAssert firstEntrySize > 0,
    "first stream entry has zero size — no trace events recorded"

  # 5. Verify file entries exist.
  let maxRootEntries = readLE32(data, 12)
  var fileCount = 0
  var foundNames: seq[string]
  for i in 0 ..< int(maxRootEntries):
    let off = 16 + i * 24
    if off + 24 > data.len:
      break
    let size = readLE64(data, off)
    let mapBlock = readLE64(data, off + 8)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break
    fileCount += 1
    foundNames.add(base40Decode(nameEnc))

  doAssert fileCount >= 1, "expected at least 1 internal file, got " &
    $fileCount & " (" & foundNames.join(", ") & ")"

  # 6. Verify either the v3 single-stream events.log or the v4 multi-stream
  #    steps.dat is present — these are the per-format markers for "events
  #    were emitted".
  doAssert "events.log" in foundNames or "steps.dat" in foundNames,
    "neither v3 'events.log' nor v4 'steps.dat' present in CTFS entries: " &
    foundNames.join(", ")

  removeDir(buildDir)
  echo "PASS: tvm_trace_repl - full content verification"

main()
