discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-TrailingProcDefScan: end-to-end test that VM traces do NOT
## contain a trailing scan of proc-definition lines after the last
## user-meaningful execution step.
##
## Pre-milestone behaviour: every `proc` defined at module level was
## wrapped by `genProc` with a leading `opcJmp` that skips over the
## proc body. In normal execution flow the body is entered directly
## via `opcIndCall` (whose target is `procStart + 1`, past the
## skip-jump), so the skip-jump is "dead code" — except that after
## the last top-level statement the dispatch loop falls through past
## the top-level frame's terminal `opcRet` onto those skip-jumps one
## by one before finally hitting `opcEof`. The dispatch-loop
## `traceStep` then fired on each skip-jump, and since each jump's
## `c.debug[pc]` carries the proc-body line info (typically the
## proc-definition line for inline `proc foo() = body` syntax, or
## the body's first executable line for multi-line syntax), the
## trace ended with a series of phantom step events.
##
## Post-milestone: `genProc` overwrites the skip-jump's `c.debug[pc]`
## with `unknownLineInfo`, and the dispatch-loop `traceStep` skips
## any instruction whose debug info is `unknownLineInfo`. Other
## hooks (`traceReturn`, `flushPendingValuesAsStep`) are unaffected.
##
## Test plan:
##   * Build a small NimScript with two `proc foo() = body` inline
##     procs (def and body on the same line, so the skip-jump's
##     line info is the proc-def line). Top-level statements call
##     each proc.
##   * Run nim e --trace, read back the trace and exact step lines.
##   * Pre-milestone: trace ends with 2 trailing steps at lines 1
##     and 3 (the proc-def lines). Post-milestone: trace ends at
##     line 3 (inside `two`'s body) with no trailing steps.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_no_trailing_procdef"

# Script layout (1-indexed). Inline `proc x() = body` form keeps the
# proc-def line and the body line on the same source line, so the
# skip-over `opcJmp` emitted by `genProc` carries that exact line
# info via `body.info`.
#
#   1: proc one() = echo "one"
#   2: <blank>
#   3: proc two() = echo "two"
#   4: <blank>
#   5: one()
#   6: two()
const testScript =
  "proc one() = echo \"one\"\n" &
  "\n" &
  "proc two() = echo \"two\"\n" &
  "\n" &
  "one()\n" &
  "two()\n"

const
  lineOne     = 1'u64      # proc one() body
  lineTwo     = 3'u64      # proc two() body
  lineCallOne = 5'u64      # one() call site
  lineCallTwo = 6'u64      # two() call site

# Column-Aware-Replay: the Nim VM tracer now always enables column-aware
# step encoding; GLI is byte-offset based rather than `path*100k+line`,
# so we resolve `line` via `decodeGlobalPositionIndex`.

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "trailing_procdef.nims"
  let traceFile = buildDir / "trailing_procdef.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "one" in output and "two" in output,
    "expected 'one' and 'two' in script output, got: " & output

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

  # Walk every step and check call context. A "trailing proc-def
  # scan" step is one that:
  #   * lands on a proc-def line (lineOne or lineTwo), AND
  #   * has no enclosing call record covering it.
  # Steps inside `one()`/`two()` legitimately land on those lines
  # but ARE covered by a call record; steps after the last `opcRet`
  # are at the top level (no enclosing call).
  var lines = newSeq[uint64](stepCount)
  for n in 0'u64 ..< stepCount:
    let gliRes = rdr.stepAbsoluteGlobalLineIndex(n)
    doAssert gliRes.isOk,
      "stepAbsoluteGlobalLineIndex(" & $n & ") failed: " & gliRes.error
    let posRes = rdr.decodeGlobalPositionIndex(gliRes.get())
    doAssert posRes.isOk,
      "decodeGlobalPositionIndex failed: " & posRes.error
    lines[int(n)] = uint64(posRes.get().line)

  # Sanity-bound: a 6-line program with 2 calls + 2 echo bodies
  # should have ~4-6 real steps. Pre-milestone we'd have 6 steps
  # (4 real + 2 trailing).
  doAssert stepCount <= 12'u64,
    "expected at most ~12 steps for a 6-line program, got " & $stepCount

  # Every step must be at one of the executing lines.
  let executing = {lineOne, lineTwo, lineCallOne, lineCallTwo}
  for n, line in lines:
    doAssert line in executing,
      "step " & $n & " at line " & $line &
      " is outside the executing-line set " & $executing

  # The crucial post-milestone invariant: the LAST step must be a
  # step inside a proc body (lineOne or lineTwo) reached via the
  # innermost `echo` — NOT a top-level step at a proc-def line.
  #
  # Pre-milestone behaviour: after `two()` returns, the dispatch
  # loop fell through onto the skip-jumps emitted by `genProc(one)`
  # and `genProc(two)`. Each jump's `c.debug[pc]` carried the
  # proc-def line info, producing 2 phantom trailing steps. The
  # last such step was at lineTwo with no enclosing call context.
  #
  # The discriminator: a real "two body" step inside the call to
  # `two()` has an enclosing call record; a phantom trailing step
  # at the same line does not.
  let lastStepIdx = stepCount - 1
  let callRes = rdr.callForStep(lastStepIdx)
  doAssert callRes.isOk,
    "expected the last step to have an enclosing call record; pre-milestone " &
    "trailing proc-def steps had no call context. Reader error: " &
    callRes.error

  let lastCall = callRes.get()
  let fnId = lastCall.functionId
  let fnNameRes = rdr.function(fnId)
  doAssert fnNameRes.isOk,
    "function lookup for last call failed: " & fnNameRes.error
  let fnName = fnNameRes.get()
  doAssert fnName in ["one", "two"],
    "expected last step to be inside one() or two(); got fn=" & fnName

  removeDir(buildDir)
  echo "PASS: tvm_trace_no_trailing_procdef — steps=", stepCount,
       " lastFn=", fnName, " lastLine=", lines[^1]

main()
