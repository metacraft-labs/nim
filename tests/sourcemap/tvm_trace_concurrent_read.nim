discard """
  action: "run"
  targets: "c"
"""

## Test that a .ct trace file is readable *while* the REPL is still running.
##
## Behaviour depends on which trace writer the compiler links:
##  - v3 single-stream writer: incremental `sync()` flushes the in-flight
##    CTFS container to disk, so a partial read mid-session is a real
##    valid CTFS file with the events emitted up to that point.
##  - v4 multi-stream writer: per CTFS-M-Fix, the container is built in
##    memory and only serialised on close — incremental concurrent
##    reads are not supported. This test detects v4 (no mid-stream file
##    on disk) and falls back to verifying the final file only.

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
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

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
  # v3 streaming writer: file is on disk and incrementally updated.
  # v4 multi-stream writer: container is in-memory only until close — no
  # mid-stream file exists. Detect which mode and proceed accordingly.
  var midSize: BiggestInt = 0
  var midEventsSize: uint64 = 0
  let midStreamSupported = fileExists(traceFile) and getFileSize(traceFile) > 0

  if midStreamSupported:
    midSize = getFileSize(traceFile)
    let midData = readFile(traceFile)

    # Verify CTFS magic bytes are present in the partial file
    verifyCTFSMagic(midData)

    let version = uint8(midData[5])
    doAssert version >= 2 and version <= 4,
      "unexpected CTFS version in mid-stream file: " & $version

    let blockSize = readLE32(midData, 8)
    doAssert blockSize >= 64 and blockSize <= 65536,
      "unreasonable block size in mid-stream file: " & $blockSize

    # v3 layout: events.log present and non-empty mid-stream
    midEventsSize = findEventsLogSize(midData)
    if midEventsSize > 0:
      echo "Mid-stream check passed (v3 streaming): " & $midSize & " bytes, " &
          "events.log size = " & $midEventsSize
    else:
      echo "Mid-stream check: file present but events.log empty (likely v4)"
  else:
    echo "Mid-stream check: no incremental file (v4 multi-stream — close-only writer)"

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

  # If mid-stream was supported, the final file must be at least as large.
  if midStreamSupported:
    doAssert finalSize >= midSize,
      "final file (" & $finalSize & " bytes) should be >= mid-stream (" &
      $midSize & " bytes)"

  # Enumerate the file entries and verify either v3 or v4 layout.
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

  if "events.log" in foundNames:
    # v3: final events.log must be >= mid-stream events.log
    let finalEventsSize = findEventsLogSize(finalData)
    doAssert finalEventsSize >= midEventsSize,
      "final events.log size (" & $finalEventsSize &
      ") should be >= mid-stream (" & $midEventsSize & ")"
  else:
    # v4: at least one of the data streams must be non-empty
    doAssert "steps.dat" in foundNames or "calls.dat" in foundNames,
      "expected v3 events.log or v4 steps.dat/calls.dat in CTFS entries: " &
      foundNames.join(", ")

  echo "Final file: " & $finalSize & " bytes, " & $fileCount &
      " entries (" & foundNames.join(", ") & ")"

  removeDir(buildDir)
  echo "PASS: tvm_trace_concurrent_read - concurrent read verification"

main()
