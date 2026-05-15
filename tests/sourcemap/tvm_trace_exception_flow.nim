discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M3: end-to-end test for execution-order exception-flow event
## emission.
##
## Pre-CTFS-M3 the VM trace site visited try/except in source order
## (the order opcodes were laid out by vmgen), producing a step
## sequence like
##
##   try(14) -> raise(15) -> echo(17) -> except(16) -> 1
##
## A stepping debugger walking the events forward would see a
## backwards jump from line 17 to line 16, which made the trace
## unusable for source-level exception inspection. CTFS-M3 fixes the
## bug at the source: the trace now emits dedicated `sekRaise` /
## `sekCatch` events from runtime control-flow sites in vm.nim
## (`opcRaise` handler), not from AST-traversal sites in vmgen. The
## resulting event sequence follows execution order
## (`14 -> 15 -> 16 -> 17 -> ...`) and the raise/catch transitions are
## tagged with their own step-kinds for post-trace tooling.
##
## Asserted properties:
##
##   1. A `sekRaise` event appears in the exec stream at the raise
##      statement's source line.
##   2. A `sekCatch` event appears at the matched `except` clause's
##      source line.
##   3. The event sequence is in execution order (no backwards line
##      jumps between raise and the handler body).
##   4. Nested try blocks produce paired sekRaise / sekCatch markers
##      at the correct nesting depth — the inner except catches the
##      inner raise, the outer except catches the outer raise.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/step_encoding
import codetracer_ct_print_lib

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_exception_flow"

# Two-site test program: outer try catches IndexDefect, inner try
# catches ValueError. The inner except re-raises a different type
# so we exercise both intra-frame catch and outer-frame propagation.
#
# Line numbers (1-based) — keep these stable; assertions index by them.
#  1: ## docstring
#  2: try:
#  3:   try:
#  4:     raise newException(ValueError, "inner")
#  5:   except ValueError:
#  6:     raise newException(IndexDefect, "outer")
#  7: except IndexDefect:
#  8:   echo "caught"
const testScript = """## CTFS-M3 nested try test
try:
  try:
    raise newException(ValueError, "inner")
  except ValueError:
    raise newException(IndexDefect, "outer")
except IndexDefect:
  echo "caught"
"""

type
  EventInfo = object
    idx: uint64
    kind: StepEventKind
    line: uint64
    message: string

proc collectEvents(rdr: var NewTraceReader): seq[EventInfo] =
  ## Walk the exec stream and record (idx, kind, line) for every event.
  ## `line` is the GLI-resolved source line — raise/catch inherit from
  ## the preceding step.
  let totalRes = rdr.stepCount
  doAssert totalRes.isOk, "stepCount failed: " & totalRes.error
  let total = totalRes.get()
  let gli = buildGliFromMeta(rdr.meta)

  result = @[]
  for i in 0'u64 ..< total:
    let evRes = rdr.step(i)
    doAssert evRes.isOk, "step[" & $i & "] read failed: " & evRes.error
    let ev = evRes.get()
    let absRes = rdr.stepAbsoluteGlobalLineIndex(i)
    doAssert absRes.isOk,
      "stepAbsoluteGlobalLineIndex[" & $i & "] failed: " & absRes.error
    let (_, line) = resolveGli(gli, absRes.get())
    var msg = ""
    if ev.kind == sekRaise:
      msg = cast[string](ev.message)
    result.add(EventInfo(idx: i, kind: ev.kind, line: line, message: msg))

proc renderEvents(events: seq[EventInfo]): string =
  result = ""
  for e in events:
    result.add("  [" & $e.idx & "] " & $e.kind & " @ line " & $e.line & "\n")

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "nested.nims"
  let traceFile = buildDir / "nested.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "caught" in output,
    "expected 'caught' from the outer handler echo, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  let events = collectEvents(rdr)

  # --- (1) at least one sekRaise event present ------------------------------
  var raiseCount = 0
  var raiseLines: seq[uint64] = @[]
  for e in events:
    if e.kind == sekRaise:
      inc raiseCount
      raiseLines.add(e.line)
  doAssert raiseCount >= 2,
    "expected >= 2 sekRaise events (inner raise on line 4, outer raise " &
    "on line 6); got " & $raiseCount & ":\n" & renderEvents(events)

  # --- (2) at least one sekCatch event present -----------------------------
  var catchCount = 0
  var catchLines: seq[uint64] = @[]
  for e in events:
    if e.kind == sekCatch:
      inc catchCount
      catchLines.add(e.line)
  doAssert catchCount >= 2,
    "expected >= 2 sekCatch events (inner handler on line 5, outer " &
    "handler on line 7); got " & $catchCount & ":\n" & renderEvents(events)

  # --- (3) sekRaise at line 4 (inner raise) --------------------------------
  doAssert 4'u64 in raiseLines,
    "expected a sekRaise event at line 4 (inner raise), got raise " &
    "lines: " & $raiseLines & "\n" & renderEvents(events)

  # --- (4) sekRaise at line 6 (outer raise from inner handler) -------------
  doAssert 6'u64 in raiseLines,
    "expected a sekRaise event at line 6 (outer raise), got raise " &
    "lines: " & $raiseLines & "\n" & renderEvents(events)

  # --- (5) sekCatch at line 5 (inner except) -------------------------------
  doAssert 5'u64 in catchLines,
    "expected a sekCatch event at line 5 (inner except), got catch " &
    "lines: " & $catchLines & "\n" & renderEvents(events)

  # --- (6) sekCatch at line 7 (outer except) -------------------------------
  doAssert 7'u64 in catchLines,
    "expected a sekCatch event at line 7 (outer except), got catch " &
    "lines: " & $catchLines & "\n" & renderEvents(events)

  # --- (7) execution-order property: in the user-source line range
  # 4..8, sekRaise at 4 must precede sekCatch at 5; sekRaise at 6
  # must precede sekCatch at 7. Both pairs must follow each other
  # in event-index order.
  var innerRaiseIdx = high(int)
  var innerCatchIdx = high(int)
  var outerRaiseIdx = high(int)
  var outerCatchIdx = high(int)
  for i, e in events:
    if e.kind == sekRaise and e.line == 4 and innerRaiseIdx == high(int):
      innerRaiseIdx = i
    if e.kind == sekCatch and e.line == 5 and innerCatchIdx == high(int):
      innerCatchIdx = i
    if e.kind == sekRaise and e.line == 6 and outerRaiseIdx == high(int):
      outerRaiseIdx = i
    if e.kind == sekCatch and e.line == 7 and outerCatchIdx == high(int):
      outerCatchIdx = i

  doAssert innerRaiseIdx < innerCatchIdx,
    "expected inner sekRaise (line 4) before inner sekCatch (line 5) " &
    "in event order; got idx " & $innerRaiseIdx & " vs " & $innerCatchIdx &
    "\n" & renderEvents(events)
  doAssert innerCatchIdx < outerRaiseIdx,
    "expected inner sekCatch (line 5) before outer sekRaise (line 6) " &
    "in event order; got idx " & $innerCatchIdx & " vs " & $outerRaiseIdx &
    "\n" & renderEvents(events)
  doAssert outerRaiseIdx < outerCatchIdx,
    "expected outer sekRaise (line 6) before outer sekCatch (line 7) " &
    "in event order; got idx " & $outerRaiseIdx & " vs " & $outerCatchIdx &
    "\n" & renderEvents(events)

  # --- (7b) CTFS-M3.1: each sekRaise carries its exception's .msg field.
  # Inner raise on line 4 raises `newException(ValueError, "inner")`;
  # outer raise on line 6 raises `newException(IndexDefect, "outer")`.
  var innerRaiseMsg = ""
  var outerRaiseMsg = ""
  for e in events:
    if e.kind == sekRaise and e.line == 4 and innerRaiseMsg.len == 0:
      innerRaiseMsg = e.message
    if e.kind == sekRaise and e.line == 6 and outerRaiseMsg.len == 0:
      outerRaiseMsg = e.message
  doAssert innerRaiseMsg == "inner",
    "expected inner sekRaise message 'inner', got " & innerRaiseMsg.repr &
    "\n" & renderEvents(events)
  doAssert outerRaiseMsg == "outer",
    "expected outer sekRaise message 'outer', got " & outerRaiseMsg.repr &
    "\n" & renderEvents(events)

  # --- (8) no backwards-jump in the user-script line range. Walk the
  # events from the inner raise to the outer catch; the line numbers
  # of regular step events (sekAbsoluteStep / sekDeltaStep) must be
  # monotonically non-decreasing across that span.
  var prevLine: uint64 = 0
  for i in innerRaiseIdx .. outerCatchIdx:
    let e = events[i]
    if e.kind notin {sekAbsoluteStep, sekDeltaStep}:
      continue
    # Limit the check to the user-script line range — module-prologue
    # lines may interleave but they're outside the test's scope.
    if e.line < 1 or e.line > 20:
      continue
    doAssert e.line >= prevLine,
      "backwards line jump in step events between innerRaise and " &
      "outerCatch: idx=" & $i & " line=" & $e.line & " < prev=" & $prevLine &
      "\n" & renderEvents(events)
    prevLine = e.line

  removeDir(buildDir)
  echo "PASS: tvm_trace_exception_flow — raises=", raiseCount,
       " catches=", catchCount,
       " innerRaise@line4 innerCatch@line5 outerRaise@line6 outerCatch@line7"

main()
