discard """
  action: "run"
  targets: "c"
"""

## Test that `ideTraceExpand` on a non-macro position returns an
## empty/error response and does NOT crash nimsuggest.
##
## The cursor is placed on a `let x = 42` line — there is no macro call
## there, so no trace file should be produced and the response should
## contain no .ct path.

import std/[os, osproc, assertions, strutils]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_expand_non_macro"

const testSource = """
let x = 42
echo x
"""

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)

  let sourceFile = buildDir / "test_non_macro.nim"
  writeFile(sourceFile, testSource)

  # CTFS-M1: ideTraceExpand is available in the regular `nimsuggest` binary —
  # no separate `nimsuggest_trace` build is needed.
  let nimsuggestExe = nim.parentDir / "nimsuggest"
  doAssert fileExists(nimsuggestExe), "nimsuggest binary not found at: " & nimsuggestExe

  # Point traceExpand at line 1: `let x = 42` — not a macro call
  let stdinInput = "traceExpand " & sourceFile & ":1:0\nquit\n"
  let cmd = nimsuggestExe & " --stdin --v3 " & sourceFile
  let (output, exitCode) = execCmdEx(cmd, input = stdinInput)

  # Must not crash (segfault gives exit code >= 128)
  doAssert exitCode >= 0 and exitCode < 128,
    "nimsuggest crashed (exit code " & $exitCode & "): " & output

  # Check that NO .ct trace file path is returned
  var foundTrace = false
  for line in output.splitLines():
    if "macro_trace_" in line and ".ct" in line:
      foundTrace = true
      break

  doAssert not foundTrace,
    "expected no trace file for non-macro position, but got a .ct path in output:\n" & output

  echo "PASS: tvm_trace_expand_non_macro - no trace produced for non-macro position"
  removeDir(buildDir)

main()
