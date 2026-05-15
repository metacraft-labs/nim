discard """
  action: "run"
  targets: "c"
"""

## CTFS-M-StaticBlockTrace: verify that `ideTraceStatic` nimsuggest
## command triggers VM tracing for a `static:` block at the specified
## cursor position and produces a `.ct` file with non-trivial content.
##
## This mirrors `tvm_trace_expand.nim` (which exercises macros via
## `ideTraceExpand`); the static-block variant matches at
## `evalConstExprAux` entry points instead of `evalMacroCall`.
##
## If `nimsuggest` is missing the test asserts failure — the regular
## build always produces it.

import std/[os, osproc, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_static"

const testSource = """
import std/strtabs

static:
  let t = newStringTable(modeStyleInsensitive)
  t["alpha"] = "1"
  t["beta"]  = "2"
  doAssert t["alpha"] == "1"
  doAssert t["beta"]  == "2"
"""

proc readLE32(data: string, offset: int): uint32 =
  for i in 0..3:
    result = result or (uint32(data[offset + i]) shl (i * 8))

proc readLE64(data: string, offset: int): uint64 =
  for i in 0..7:
    result = result or (uint64(data[offset + i]) shl (i * 8))

proc verifyCtfsStructure(path: string) =
  let data = readFile(path)
  doAssert data.len >= 40, "trace file too small: " & $data.len & " bytes"
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and
           data[2] == '\x72' and data[3] == '\xAC' and
           data[4] == '\xE2', "not a valid CTFS file (bad magic bytes)"
  let version = uint8(data[5])
  doAssert version >= 2 and version <= 4, "unexpected version: " & $version
  let blockSize = readLE32(data, 8)
  doAssert blockSize >= 64, "invalid block size: " & $blockSize
  let eventsLogSize = readLE64(data, 16)
  doAssert eventsLogSize > 0,
    "events.log has zero size — static block produced no trace events"
  doAssert data.len > 2048,
    "trace file unexpectedly small for a strtabs static block: " &
    $data.len & " bytes (expected > 2048)"

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let sourceFile = buildDir / "test_static_file.nim"
  writeFile(sourceFile, testSource)

  # `static:` keyword is on line 3 of testSource (1-indexed). The
  # evalConstExprAux match site uses `n.info` where `n` is the sem'd
  # body — its first stmt (`let t = ...`) is at line 4.
  let nimsuggestExe = nim.parentDir / "nimsuggest"
  doAssert fileExists(nimsuggestExe),
    "nimsuggest binary not found at: " & nimsuggestExe

  let stdinInput = "tracestatic " & sourceFile & ":4:0\nquit\n"
  let cmd = nimsuggestExe & " --stdin --v3 " & sourceFile
  let (output, exitCode) = execCmdEx(cmd, input = stdinInput)

  doAssert exitCode >= 0 and exitCode < 128,
    "nimsuggest crashed (exit code " & $exitCode & "): " & output

  var traceFileVerified = false
  for line in output.splitLines():
    if "static_trace_" in line and ".ct" in line:
      let parts = line.split('\t')
      for part in parts:
        if "static_trace_" in part and ".ct" in part:
          let tracePath = part.strip().strip(chars = {'"'})
          if fileExists(tracePath):
            verifyCtfsStructure(tracePath)
            traceFileVerified = true
            echo "PASS: tvm_trace_static - trace file verified at: ", tracePath
          else:
            doAssert false,
              "trace path reported but file not found: " & tracePath
          break
      break

  if not traceFileVerified:
    doAssert false,
      "nimsuggest did not report a trace file path. Output:\n" & output

  removeDir(buildDir)

main()
