discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-ValueAttribution: end-to-end test for source-line accuracy of
## value records.
##
## Pre-milestone behaviour: `traceAssignment` buffered values into
## `pendingValues`, which only flushed on the NEXT `traceStep` event.
## If that next step's source line differed from the assignment's
## (e.g. `let x = 1` on line N followed by a no-write statement on
## line N+M), the value record got attributed to line N+M instead of
## line N — the macro-call site, not the binding site.
##
## Post-milestone: each buffered pending value carries the writing
## opcode's `TLineInfo`. `traceStep` synthesises one intermediate step
## per distinct writing site before emitting the requested step, so
## values land on the source line they were produced from.
##
## Test plan:
##   * Compile and run a tiny NimScript that performs three
##     consecutive assignments on three consecutive lines, followed by
##     a statement (echo) that performs no user-binding write.
##   * Walk the resulting trace and verify that:
##       - the value record for `a = 1` is attached to a step at the
##         line of `let a = 1`,
##       - the value record for `b = 2` is attached to a step at the
##         line of `let b = 2`,
##       - the value record for `c = 3` (`a + b`) is attached to a
##         step at the line of `let c = a + b`,
##       - the step at the `echo` line carries no value records.
##
## Note on flexibility: vmgen may emit multiple register writes per
## binding (literal load + assignment + arithmetic temp). We don't
## assume the count of value records per line — only that each value
## record's source-level varname (a / b / c) lands at the line where
## that binding was written.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_value_attribution"

# The script below is laid out so that each binding is on its own
# source line and the trailing `echo` line performs no user-binding
# write. The line numbers (1-indexed) are:
#   1: let a = 1
#   2: let b = 2
#   3: let c = a + b
#   4: echo a, " ", b, " ", c
const testScript = """let a = 1
let b = 2
let c = a + b
echo a, " ", b, " ", c
"""

const
  lineA = 1'u64
  lineB = 2'u64
  lineC = 3'u64
  lineEcho = 4'u64

# Mirrors the writer's DefaultLinesPerFile (see
# dist/codetracer-trace-format-nim/src/codetracer_trace_writer/multi_stream_writer.nim).
# For a single-path trace the global-line-index reduces to
# `pathId * DefaultLinesPerFile + line`, so `line = gli mod
# DefaultLinesPerFile`.
const DefaultLinesPerFile: uint64 = 100_000

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "attribution.nims"
  let traceFile = buildDir / "attribution.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "1 2 3" in output,
    "expected '1 2 3' in script output, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  let scRes = rdr.stepCount
  doAssert scRes.isOk, "stepCount read failed: " & scRes.error
  let stepCount = scRes.get()

  # Walk every step and bucket value records by (varname, source line).
  # We expect each user binding to show up at least once at its own
  # source line, and the step at the `echo` line to carry no values.
  var sawAtLine: array[5, bool]   # index = source line; only 1..4 used
  var aFoundAtLine: int = -1
  var bFoundAtLine: int = -1
  var cFoundAtLine: int = -1
  var echoStepValueCount = 0
  var echoStepFound = false

  for n in 0'u64 ..< stepCount:
    let gliRes = rdr.stepAbsoluteGlobalLineIndex(n)
    doAssert gliRes.isOk,
      "stepAbsoluteGlobalLineIndex(" & $n & ") failed: " & gliRes.error
    let gli = gliRes.get()
    let line = int(gli mod DefaultLinesPerFile)
    if line >= 1 and line <= 4:
      sawAtLine[line] = true

    let valsRes = rdr.values(n)
    if valsRes.isErr:
      continue
    let vals = valsRes.get()

    if line == int(lineEcho):
      echoStepFound = true
      echoStepValueCount += vals.len

    for vv in vals:
      let vnRes = rdr.varname(vv.varnameId)
      if vnRes.isErr:
        continue
      let name = vnRes.get()
      case name
      of "a":
        if aFoundAtLine < 0: aFoundAtLine = line
      of "b":
        if bFoundAtLine < 0: bFoundAtLine = line
      of "c":
        if cFoundAtLine < 0: cFoundAtLine = line
      else:
        discard

  # Every binding must surface at its writing site.
  doAssert aFoundAtLine == int(lineA),
    "expected `a = 1` at line " & $lineA & ", got line " & $aFoundAtLine
  doAssert bFoundAtLine == int(lineB),
    "expected `b = 2` at line " & $lineB & ", got line " & $bFoundAtLine
  doAssert cFoundAtLine == int(lineC),
    "expected `c = a + b` at line " & $lineC & ", got line " & $cFoundAtLine

  # The trailing echo statement performs no user-binding writes — so
  # no value record may surface at its line. (If a future change
  # widens trace sites to include the `echo` argument evaluation, this
  # assertion will fire; revisit then.)
  doAssert echoStepFound,
    "expected a step at the echo line (" & $lineEcho & ")"
  doAssert echoStepValueCount == 0,
    "expected zero value records at the echo line (" & $lineEcho &
    "), got " & $echoStepValueCount

  removeDir(buildDir)
  echo "PASS: tvm_trace_value_attribution — a@", aFoundAtLine,
       " b@", bFoundAtLine,
       " c@", cFoundAtLine,
       " echoVars=", echoStepValueCount

main()
