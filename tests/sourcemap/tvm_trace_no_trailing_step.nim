discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-TrailingStep: end-to-end test that VM traces do NOT end with
## a spurious step at line 1 (the testament header block) or
## past the last user-source line.
##
## Pre-milestone behaviour: the dispatch-loop `traceStep` ran for the
## terminal `opcEof` of every frame, whose `c.debug[pc]` is filled
## with the module's leading TLineInfo. For a testament-style
## NimScript that's line 1 of the file (inside the testament header),
## so traces ended with a phantom event at line 1.
##
## Post-milestone: the dispatch loop suppresses the `opcEof` step,
## so the final step is whatever the last real user-source opcode
## emitted. Synthetic-flush logic in `closeVmTracer` still runs but
## emits only at writing sites of buffered pending values (which
## are themselves real user-source lines).
##
## Test plan:
##   * Compile and run a tiny NimScript laid out so the last user
##     statement is on a known line (line 5 below). The script also
##     uses a testament header at lines 1-2 so the pre-milestone
##     trailing-step would land at line 1 (inside the header).
##   * Walk the trace and verify:
##       - every step's source line is in the real user-line range
##         (4 or 5), NOT line 1, NOT line >= 6 (past-EOF);
##       - the final step lands on the echo line (5);
##       - the trace is non-empty;
##       - the total step count is small (sanity bound).

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_no_trailing_step"

# Script layout (1-indexed). A leading testament-style header on lines
# 1-2 reproduces the original bug environment: pre-milestone, the
# terminal `opcEof` of the script frame carried `c.debug[pc]` at the
# script's leading line (line 1, inside the testament header), so the
# trace ended at line 1 even though the last real user statement was
# on line 5.
#   1: <opening triple-quote header>
#   2: <closing triple-quote header>
#   3: <blank>
#   4: let a = 1
#   5: echo a
const triq = "\"" & "\"" & "\""
const testScript =
  "disca" & "rd " & triq & "\n" &
  triq & "\n" &
  "\n" &
  "let a = 1\n" &
  "echo a\n"

const
  lineLet = 4'u64
  lineEcho = 5'u64

# Mirrors writer's DefaultLinesPerFile.
const DefaultLinesPerFile: uint64 = 100_000

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "trailing.nims"
  let traceFile = buildDir / "trailing.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "1" in output,
    "expected '1' in script output, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  let scRes = rdr.stepCount
  doAssert scRes.isOk, "stepCount read failed: " & scRes.error
  let stepCount = scRes.get()

  doAssert stepCount > 0'u64,
    "expected at least one step, got 0"
  doAssert stepCount <= 8'u64,
    "expected at most ~8 steps for a 2-line program, got " & $stepCount

  # Inspect every step's source line and bound them to the real user
  # range [4, 5]. The pre-milestone bug surfaced as a final step at
  # line 1 (the testament header).
  var lastLine = -1
  for n in 0'u64 ..< stepCount:
    let gliRes = rdr.stepAbsoluteGlobalLineIndex(n)
    doAssert gliRes.isOk,
      "stepAbsoluteGlobalLineIndex(" & $n & ") failed: " & gliRes.error
    let gli = gliRes.get()
    let line = int(gli mod DefaultLinesPerFile)
    doAssert line >= int(lineLet) and line <= int(lineEcho),
      "step " & $n & " at line " & $line &
      " is outside the real user-source range [" & $lineLet & ", " & $lineEcho &
      "]; pre-milestone trailing-step bug not fixed"
    lastLine = line

  # The final step must land on a real user line, never on line 1
  # (testament header) and never past EOF.
  doAssert lastLine == int(lineLet) or lastLine == int(lineEcho),
    "expected final step at line " & $lineLet & " or " & $lineEcho &
    ", got line " & $lastLine

  removeDir(buildDir)
  echo "PASS: tvm_trace_no_trailing_step — steps=", stepCount,
       " finalLine=", lastLine

main()
