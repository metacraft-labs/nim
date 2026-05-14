discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: verify trace contains expected Step/Call/Return event sequence.
##
## Writes a simple NimScript file, runs nim_trace e --trace on it, then
## uses the TraceReader from the trace format library to decode events
## and verify the sequence contains Step, Call, and Return events in the
## expected order.

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  ## Assert Result is Ok, printing the error if not.
  ## Uses unsafeError to avoid side-effect issue with results.nim `error` func.
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_event_seq"

const testScript = """
proc foo() =
  echo "hi"

foo()
"""

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_event_seq.nims"
  let traceFile = buildDir / "test_event_seq.ct"
  writeFile(scriptFile, testScript)

  # Run nim_trace to produce the trace
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "hi" in output, "expected 'hi' in output, got: " & output

  # Open and decode the trace using TraceReader
  doAssert fileExists(traceFile), "trace file not created"
  var readerRes = openTrace(traceFile)
  checkOk readerRes, "failed to open trace: "

  var reader = readerRes.get()
  let eventsRes = reader.readEvents()
  checkOk eventsRes, "failed to read events: "

  doAssert reader.events.len > 0, "no events decoded from trace"

  # Collect event kinds
  var stepCount = 0
  var callCount = 0
  var returnCount = 0
  var functionCount = 0
  var pathCount = 0

  for event in reader.events:
    case event.kind
    of tleStep: stepCount += 1
    of tleCall: callCount += 1
    of tleReturn: returnCount += 1
    of tleFunction: functionCount += 1
    of tlePath: pathCount += 1
    else: discard

  # Verify we have the expected event types
  doAssert pathCount >= 1, "expected at least 1 Path event, got: " & $pathCount
  doAssert functionCount >= 1, "expected at least 1 Function event (for 'foo'), got: " & $functionCount
  doAssert stepCount >= 2, "expected at least 2 Step events, got: " & $stepCount
  doAssert callCount >= 1, "expected at least 1 Call event (for foo()), got: " & $callCount
  doAssert returnCount >= 1, "expected at least 1 Return event (from foo()), got: " & $returnCount

  # Verify function 'foo' is registered
  var foundFoo = false
  for event in reader.events:
    if event.kind == tleFunction and event.functionRecord.name == "foo":
      foundFoo = true
      break
  doAssert foundFoo, "expected a Function event named 'foo'"

  # Verify ordering: there should be a Call followed eventually by a Return.
  # Find the first Call event, then verify a Return appears after it.
  var foundCallIdx = -1
  var foundReturnAfterCall = false
  for i, event in reader.events:
    if event.kind == tleCall and foundCallIdx < 0:
      foundCallIdx = i
    elif event.kind == tleReturn and foundCallIdx >= 0:
      foundReturnAfterCall = true
      break

  doAssert foundCallIdx >= 0, "no Call event found"
  doAssert foundReturnAfterCall,
    "no Return event found after Call at index " & $foundCallIdx

  # Verify that Step events appear before Call (we step through top-level code
  # before calling foo)
  var firstStepIdx = -1
  for i, event in reader.events:
    if event.kind == tleStep:
      firstStepIdx = i
      break
  doAssert firstStepIdx >= 0, "no Step event found"
  doAssert firstStepIdx < foundCallIdx,
    "expected Step (idx=" & $firstStepIdx & ") before Call (idx=" & $foundCallIdx & ")"

  removeDir(buildDir)
  echo "PASS: tvm_trace_event_sequence - decoded " & $reader.events.len &
    " events (Step=" & $stepCount & " Call=" & $callCount &
    " Return=" & $returnCount & " Function=" & $functionCount &
    " Path=" & $pathCount & ")"

main()
