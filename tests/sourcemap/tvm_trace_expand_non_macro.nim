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

  # Prefer nimsuggest_trace (built with -d:codetracerTracing), fall back to nimsuggest
  let nimsuggestTrace = nim.parentDir / "nimsuggest_trace"
  let nimsuggestPlain = nim.parentDir / "nimsuggest"
  let nimsuggestExe =
    if fileExists(nimsuggestTrace): nimsuggestTrace
    elif fileExists(nimsuggestPlain): nimsuggestPlain
    else:
      removeDir(buildDir)
      echo "SKIP: no nimsuggest binary found at ", nimsuggestTrace, " or ", nimsuggestPlain
      quit(0)
      ""

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

  if "unknown command" in output.toLowerAscii():
    echo "SKIP: traceExpand not recognized (needs -d:codetracerTracing)"
    removeDir(buildDir)
    quit(0)

  doAssert not foundTrace,
    "expected no trace file for non-macro position, but got a .ct path in output:\n" & output

  echo "PASS: tvm_trace_expand_non_macro - no trace produced for non-macro position"
  removeDir(buildDir)

main()
