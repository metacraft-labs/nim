discard """
  action: "run"
  targets: "c"
"""

## Test that `nim e --trace` produces a valid .ct trace file with correct
## CTFS structure, verifying internal file entries, event data presence,
## and expected program output.

import std/[os, osproc, assertions, strutils, tables]

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

proc main() =
  # CTFS-M1 made the VM trace emitter unconditional in `bin/nim` — the
  # standalone `nim_trace` binary no longer exists. The compiler used to
  # compile this test (`getCurrentCompilerExe()`) is the same binary we
  # invoke with `--trace:` at runtime.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
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

  # 2. Verify version (CTFS v2..v4 all accepted)
  let version = uint8(data[5])
  doAssert version >= 2 and version <= 4, "unexpected CTFS version: " & $version

  # 3. Verify block size and max entries
  let blockSize = readLE32(data, 8)
  let maxRootEntries = readLE32(data, 12)
  doAssert blockSize >= 64, "invalid block size: " & $blockSize
  doAssert maxRootEntries > 0, "zero max root entries"

  # 4. Verify file entries exist and have expected names.
  #    The CTFS container carries different internal-file layouts depending
  #    on which writer the compiler links: the v3 single-stream layout (one
  #    big `events.log` + sidecar `events.fmt` + JSON meta) or the v4
  #    multi-stream layout (per-event-kind `.dat`/`.off` pairs + `meta.dat`).
  #    Accept either.
  var fileNames: seq[string]
  var sizeByName: Table[string, uint64]
  for i in 0 ..< int(maxRootEntries):
    let off = 16 + i * 24
    if off + 24 > data.len:
      break
    let size = readLE64(data, off)
    let mapBlock = readLE64(data, off + 8)
    let nameEnc = readLE64(data, off + 16)
    if nameEnc == 0 and size == 0 and mapBlock == 0:
      break
    let nm = base40Decode(nameEnc)
    fileNames.add(nm)
    sizeByName[nm] = size

  doAssert fileNames.len >= 3, "expected at least 3 internal files, got " &
    $fileNames.len & " (" & fileNames.join(", ") & ")"

  if "events.log" in fileNames:
    # v3 single-stream layout
    doAssert "meta.json" in fileNames,
      "v3 layout missing meta.json: " & fileNames.join(", ")
    doAssert "paths.json" in fileNames,
      "v3 layout missing paths.json: " & fileNames.join(", ")
    doAssert sizeByName.getOrDefault("events.log", 0'u64) > 0,
      "events.log is empty — no events emitted"
  else:
    # v4 multi-stream layout: require the core streams
    for required in ["paths.dat", "funcs.dat", "steps.dat", "calls.dat", "meta.dat"]:
      doAssert required in fileNames,
        "v4 layout missing stream '" & required & "': " & fileNames.join(", ")
    doAssert sizeByName.getOrDefault("steps.dat", 0'u64) > 0,
      "steps.dat is empty — no Step events emitted"
    doAssert sizeByName.getOrDefault("calls.dat", 0'u64) > 0,
      "calls.dat is empty — no Call events emitted for add()"

  # 5. Verify trace file is non-trivial for a function call + echo
  doAssert data.len > 128, "trace file suspiciously small: " & $data.len

  removeDir(buildDir)
  echo "PASS: tvm_trace - structural verification complete"

main()
