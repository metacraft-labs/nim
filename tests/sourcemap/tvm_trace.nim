discard """
  action: "run"
  targets: "c"
"""

## Test that `nim e --trace` produces a valid .ct trace file with correct
## CTFS structure, verifying internal file entries, event data presence,
## and expected program output.

import std/[os, osproc, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace"

const testScript = """
proc add(a, b: int): int =
  result = a + b

let x = add(3, 4)
echo x
"""

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

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)
  createDir(buildDir)
  let scriptFile = buildDir / "test_script.nims"
  let traceFile = buildDir / "test_trace.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  # Verify expected program output (add(3, 4) = 7)
  doAssert "7" in output, "expected '7' in output from add(3,4), got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let data = readFile(traceFile)

  # 1. Verify CTFS magic bytes
  doAssert data.len >= 16, "trace file too small: " & $data.len
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and data[2] == '\x72' and
           data[3] == '\xAC' and data[4] == '\xE2', "not a valid CTFS file"

  # 2. Verify version
  let version = uint8(data[5])
  doAssert version == 3 or version == 2, "unexpected CTFS version: " & $version

  # 3. Verify block size and max entries
  let blockSize = readLE32(data, 8)
  let maxRootEntries = readLE32(data, 12)
  doAssert blockSize >= 64, "invalid block size: " & $blockSize
  doAssert maxRootEntries > 0, "zero max root entries"

  # 4. Verify file entries exist and have expected names
  var fileNames: seq[string]
  for i in 0 ..< int(maxRootEntries):
    let off = 16 + i * 24
    if off + 24 > data.len:
      break
    let size = readLE64(data, off)
    let mapBlock = readLE64(data, off + 8)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break
    fileNames.add(base40Decode(nameEnc))

  doAssert fileNames.len >= 4, "expected at least 4 internal files, got " &
    $fileNames.len & " (" & fileNames.join(", ") & ")"
  doAssert "events.log" in fileNames, "events.log missing"
  doAssert "events.fmt" in fileNames, "events.fmt missing"
  doAssert "meta.json" in fileNames, "meta.json missing"
  doAssert "paths.json" in fileNames, "paths.json missing"

  # 5. Verify events.log has non-zero size
  let eventsLogSize = readLE64(data, 16)
  doAssert eventsLogSize > 0, "events.log has zero size"

  # 6. Verify trace file is non-trivial for a function call + echo
  doAssert data.len > 128, "trace file suspiciously small: " & $data.len

  removeDir(buildDir)
  echo "PASS: tvm_trace - structural verification complete"

main()
