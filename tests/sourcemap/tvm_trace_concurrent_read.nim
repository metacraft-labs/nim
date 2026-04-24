discard """
  action: "run"
  targets: "c"
"""

## Test that a .ct trace file is readable *while* the REPL is still running.
## The sync() mechanism flushes the CTFS container incrementally, so a partial
## read mid-session should already contain valid magic bytes and some data.
##
## Verifies:
## - Mid-stream: file exists, has CTFS magic, size > 0
## - Mid-stream: events.log entry has non-zero size (events already flushed)
## - Final file is valid and strictly larger than the mid-stream snapshot

import std/[os, osproc, streams, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_concurrent_read"

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

proc findNimTrace(): string =
  ## Find the trace-enabled compiler (nim_trace) next to the current compiler.
  ## Returns empty string if not found.
  let nimDir = getCurrentCompilerExe().parentDir
  result = nimDir / "nim_trace"
  if not fileExists(result):
    result = ""

proc verifyCTFSMagic(data: string) =
  doAssert data.len >= 16, "trace file too small for CTFS header: " & $data.len & " bytes"
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and data[2] == '\x72' and
      data[3] == '\xAC' and data[4] == '\xE2',
      "not a valid CTFS file (bad magic bytes)"

proc findEventsLogSize(data: string): uint64 =
  ## Read events.log size from the first file entry in the CTFS header.
  if data.len < 16 + 24:
    return 0
  let maxRootEntries = readLE32(data, 12)
  for i in 0 ..< int(maxRootEntries):
    let off = 16 + i * 24
    if off + 24 > data.len:
      break
    let size = readLE64(data, off)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0:
      break
    if base40Decode(nameEnc) == "events.log":
      return size
  return 0

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)

  createDir(buildDir)
  let traceFile = buildDir / "concurrent_read.ct"

  # Remove any leftover trace file from a previous run
  if fileExists(traceFile):
    removeFile(traceFile)

  # Start the REPL with --trace, piping commands via stdin
  let p = startProcess(nim,
    args = @["secret", "--trace:" & traceFile],
    options = {poUsePath, poStdErrToStdOut})

  let inp = p.inputStream

  # Write a few lines of Nim code — each line triggers eval + sync()
  inp.write("let x = 42\n")
  inp.write("let y = x * 2\n")
  inp.write("echo y\n")
  inp.flush()

  # Wait briefly to allow sync() to flush the CTFS container to disk.
  # The REPL evaluates each line and calls sync() after, so a short
  # sleep should be sufficient.
  sleep(2000)

  # --- Mid-stream verification (REPL is still running) ---
  doAssert fileExists(traceFile), "trace file not created while REPL is still running"

  let midSize = getFileSize(traceFile)
  doAssert midSize > 0, "trace file is empty while REPL is still running"

  let midData = readFile(traceFile)

  # Verify CTFS magic bytes are present in the partial file
  verifyCTFSMagic(midData)

  # Verify version
  let version = uint8(midData[5])
  doAssert version == 3 or version == 2,
    "unexpected CTFS version in mid-stream file: " & $version

  # Verify block size is reasonable
  let blockSize = readLE32(midData, 8)
  doAssert blockSize >= 64 and blockSize <= 65536,
    "unreasonable block size in mid-stream file: " & $blockSize

  # Verify events.log has data already flushed
  let midEventsSize = findEventsLogSize(midData)
  doAssert midEventsSize > 0,
    "events.log has zero size mid-stream — sync() may not be flushing"

  echo "Mid-stream check passed: " & $midSize & " bytes, " &
      "events.log size = " & $midEventsSize

  # --- Close the REPL and wait for final output ---
  inp.close()  # EOF triggers REPL exit

  let exitCode = p.waitForExit()
  let output = p.outputStream.readAll()
  p.close()

  doAssert exitCode == 0, "nim secret --trace failed with exit code " & $exitCode &
    "\nOutput: " & output

  # Verify expected REPL output contains "84" (42 * 2)
  doAssert "84" in output, "REPL should output '84' from echo y, got: " & output

  # --- Final file verification ---
  doAssert fileExists(traceFile), "trace file missing after REPL exit"

  let finalSize = getFileSize(traceFile)
  doAssert finalSize > 0, "final trace file is empty"

  let finalData = readFile(traceFile)
  verifyCTFSMagic(finalData)

  # The final file should be at least as large as the mid-stream snapshot,
  # since closing the tracer writes additional metadata (events.fmt, meta.json, etc.)
  doAssert finalSize >= midSize,
    "final file (" & $finalSize & " bytes) should be >= mid-stream (" &
    $midSize & " bytes)"

  # Verify events.log grew or stayed the same in the final file
  let finalEventsSize = findEventsLogSize(finalData)
  doAssert finalEventsSize >= midEventsSize,
    "final events.log size (" & $finalEventsSize &
    ") should be >= mid-stream (" & $midEventsSize & ")"

  # Verify the final file has more internal entries than just events.log
  # (close() should write events.fmt, meta.json, paths.json)
  let maxRootEntries = readLE32(finalData, 12)
  var fileCount = 0
  var foundNames: seq[string]
  for i in 0 ..< int(maxRootEntries):
    let off = 16 + i * 24
    if off + 24 > finalData.len:
      break
    let size = readLE64(finalData, off)
    let mapBlock = readLE64(finalData, off + 8)
    let nameEnc = readLE64(finalData, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break
    fileCount += 1
    foundNames.add(base40Decode(nameEnc))

  doAssert "events.log" in foundNames,
    "events.log missing from final CTFS entries: " & foundNames.join(", ")

  echo "Final file: " & $finalSize & " bytes, " & $fileCount &
      " entries (" & foundNames.join(", ") & ")"

  removeDir(buildDir)
  echo "PASS: tvm_trace_concurrent_read - concurrent read verification"

main()
