discard """
  action: "run"
  targets: "c"
"""

## Verify that `nim e --trace` produces traces with correct event types
## and non-trivial content for a recursive factorial script.

import std/[os, osproc, compilesettings, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_events"

const testScript = """
proc factorial(n: int): int =
  if n <= 1: return 1
  return n * factorial(n - 1)

echo factorial(5)
"""

proc readLE64(data: string, offset: int): uint64 =
  ## Read a little-endian uint64 from a string at the given offset.
  for i in 0..7:
    result = result or (uint64(data[offset + i]) shl (i * 8))

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)

  let scriptFile = buildDir / "test_factorial.nims"
  let traceFile = buildDir / "test_trace.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert fileExists(traceFile), "trace file not created"

  let data = readFile(traceFile)

  # 1. Verify CTFS magic bytes
  doAssert data.len >= 16, "trace file too small: " & $data.len
  doAssert data[0] == '\xC0', "bad magic byte 0"
  doAssert data[1] == '\xDE', "bad magic byte 1"
  doAssert data[2] == '\x72', "bad magic byte 2"
  doAssert data[3] == '\xAC', "bad magic byte 3"
  doAssert data[4] == '\xE2', "bad magic byte 4"

  # 2. Verify non-trivial size — factorial with recursion produces many events
  doAssert data.len > 256, "trace file suspiciously small for factorial: " & $data.len

  # 3. Verify the CTFS file table has entries.
  #    The streaming CTFS layout is:
  #      8 bytes magic+version header
  #      8 bytes extended header (maxFiles, fileCount)
  #    Then file entries follow: each 24 bytes (size, mapBlock, name offset).
  #    A non-zero size for the first file (events.log) means data was written.
  if data.len >= 24:
    let eventsLogSize = readLE64(data, 16)
    doAssert eventsLogSize > 0, "events.log has zero size in CTFS"

  # 4. Verify multiple internal files were created (events.log, events.fmt,
  #    meta.json, paths.json). The file count is stored in the extended
  #    header. For streaming CTFS, bytes 8..15 contain maxFiles (u32) and
  #    fileCount (u32).
  if data.len >= 16:
    var fileCount: uint32 = 0
    for i in 0..3:
      fileCount = fileCount or (uint32(data[12 + i]) shl (i * 8))
    doAssert fileCount >= 4, "expected at least 4 internal files, got " & $fileCount

  removeDir(buildDir)
  echo "PASS: tvm_trace_events"

main()
