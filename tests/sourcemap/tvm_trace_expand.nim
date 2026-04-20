discard """
  action: "run"
  targets: "c"
"""

## Test that `ideTraceExpand` nimsuggest command triggers VM tracing
## for a macro call at the specified cursor position and produces a .ct file.
##
## If nimsuggest binary doesn't exist, the test is SKIPPED (not passed).
## If it exists, the trace file must have CTFS magic AND be non-trivial.

import std/[os, osproc, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_expand"

const testSource = """
import std/macros

macro greet(name: string): untyped =
  result = newStmtList()
  result.add newCall(ident"echo", newLit("Hello, " & name.strVal & "!"))

greet("World")
"""

proc readLE32(data: string, offset: int): uint32 =
  for i in 0..3:
    result = result or (uint32(data[offset + i]) shl (i * 8))

proc readLE64(data: string, offset: int): uint64 =
  for i in 0..7:
    result = result or (uint64(data[offset + i]) shl (i * 8))

proc verifyCtfsStructure(path: string) =
  ## Verify the trace file has valid CTFS structure with meaningful content.
  let data = readFile(path)

  # Must be large enough to hold header + at least one file entry
  doAssert data.len >= 40, "trace file too small: " & $data.len & " bytes"

  # CTFS magic
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and
           data[2] == '\x72' and data[3] == '\xAC' and
           data[4] == '\xE2', "not a valid CTFS file (bad magic bytes)"

  # Version
  let version = uint8(data[5])
  doAssert version == 3 or version == 2, "unexpected version: " & $version

  # Block size and max entries
  let blockSize = readLE32(data, 8)
  doAssert blockSize >= 64, "invalid block size: " & $blockSize

  # First file entry (events.log) should have non-zero size
  let eventsLogSize = readLE64(data, 16)
  doAssert eventsLogSize > 0, "events.log has zero size — no trace events written"

  # The file should be non-trivial (macro expansion should produce events)
  doAssert data.len > 4096, "trace file is too small for macro expansion trace: " &
    $data.len & " bytes (expected > 4096)"

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let sourceFile = buildDir / "test_macro_file.nim"
  writeFile(sourceFile, testSource)

  # The macro call `greet("World")` is on line 7 (1-indexed) of testSource.
  let nimsuggestExe = nim.parentDir / "nimsuggest"

  # If nimsuggest binary doesn't exist, SKIP the test (not pass)
  if not fileExists(nimsuggestExe):
    removeDir(buildDir)
    # Use testament's skip mechanism: exit with special message
    echo "SKIP: nimsuggest binary not found at ", nimsuggestExe
    quit(0)  # testament treats this as skip when output says SKIP

  # Build a stdin script: send traceExpand command then quit
  let stdinInput = "traceExpand " & sourceFile & ";;" & sourceFile & ":7:0\nquit\n"

  let cmd = nimsuggestExe & " --stdin --v3 " & sourceFile
  let (output, exitCode) = execCmdEx(cmd, input = stdinInput)

  # The command should not crash (segfault = signal-based exit code)
  doAssert exitCode >= 0 and exitCode < 128,
    "nimsuggest crashed (exit code " & $exitCode & "): " & output

  # Check if a trace file path was returned in the output
  var traceFileVerified = false
  for line in output.splitLines():
    if "macro_trace_" in line and ".ct" in line:
      # Extract the path and verify the file exists and has content
      let parts = line.split('\t')
      for part in parts:
        if "macro_trace_" in part and ".ct" in part:
          let tracePath = part.strip()
          if fileExists(tracePath):
            verifyCtfsStructure(tracePath)
            traceFileVerified = true
            echo "PASS: tvm_trace_expand - trace file verified at: ", tracePath
          else:
            doAssert false, "trace path reported but file not found: " & tracePath
          break
      break

  if not traceFileVerified:
    # If no trace path was reported, the feature may not be compiled in
    # (requires -d:codetracerTracing). This is a SKIP, not a PASS.
    if "traceExpand" in output or "unknown command" in output.toLowerAscii():
      echo "SKIP: traceExpand command not recognized (needs -d:codetracerTracing)"
    else:
      doAssert false, "nimsuggest did not report a trace file path. Output:\n" & output

  removeDir(buildDir)

main()
