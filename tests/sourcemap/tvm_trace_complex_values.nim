discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: complex types (objects, seqs, nested) via NimScript trace
##
## Writes a NimScript with complex types (object, seq, nested seq),
## runs the compiler with `--trace:` on it, reads the .ct file using
## TraceReader, and verifies the decoded Value events carry structured
## records — not opaque renderTree strings.
##
## CTFS-M-ComplexTypes update: aggregates (object, seq, nested seq)
## are now decoded into vrkStruct / vrkSequence variants rather than
## flattened to vrkRaw. The assertions below walk those nested
## ValueRecords end-to-end.

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_complex_values"

const testScript = """
type Point = object
  x, y: int

let p = Point(x: 1, y: 2)
let arr = @[10, 20, 30]
let nested = @[@[1, 2], @[3, 4]]
echo p, " ", arr, " ", nested
"""

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_complex_values.nims"
  let traceFile = buildDir / "test_complex_values.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  doAssert fileExists(traceFile), "trace file not created"
  var readerRes = openTrace(traceFile)
  checkOk readerRes, "failed to open trace: "

  var reader = readerRes.get()
  let eventsRes = reader.readEvents()
  checkOk eventsRes, "failed to read events: "

  doAssert reader.events.len > 0, "no events decoded from trace"

  # Collect all Value events. CTFS-M-ComplexTypes: aggregates are now
  # surfaced as vrkStruct / vrkSequence — not vrkRaw.
  var valueCount = 0
  var structValues: seq[ValueRecord]
  var seqValues: seq[ValueRecord]
  var rawValues: seq[string]  # only for diagnostics if the assertions fail

  for event in reader.events:
    if event.kind == tleValue:
      valueCount += 1
      let val = event.fullValue.value
      case val.kind
      of vrkStruct:
        structValues.add(val)
      of vrkSequence:
        seqValues.add(val)
      of vrkRaw:
        rawValues.add(val.rawStr)
      else:
        discard

  doAssert valueCount > 0, "expected Value events in trace, got none"

  # Verify Point object → vrkStruct with two int fields {1, 2}.
  var foundPoint = false
  for sv in structValues:
    if sv.fieldValues.len == 2 and
       sv.fieldValues[0].kind == vrkInt and sv.fieldValues[0].intVal == 1 and
       sv.fieldValues[1].kind == vrkInt and sv.fieldValues[1].intVal == 2:
      foundPoint = true
      break
  doAssert foundPoint, "expected Point(x: 1, y: 2) as vrkStruct with " &
    "[1, 2] field values. Struct values seen: " & $structValues.len &
    "; raw fallbacks: " & $rawValues

  # Verify @[10, 20, 30] → vrkSequence of three vrkInt values.
  var foundSeq = false
  for sv in seqValues:
    if sv.seqElements.len == 3 and
       sv.seqElements[0].kind == vrkInt and sv.seqElements[0].intVal == 10 and
       sv.seqElements[1].kind == vrkInt and sv.seqElements[1].intVal == 20 and
       sv.seqElements[2].kind == vrkInt and sv.seqElements[2].intVal == 30:
      foundSeq = true
      break
  doAssert foundSeq, "expected @[10, 20, 30] as a structured vrkSequence. " &
    "Sequence values seen: " & $seqValues.len &
    "; raw fallbacks: " & $rawValues

  # Verify @[@[1, 2], @[3, 4]] → vrkSequence of two vrkSequences of ints.
  var foundNested = false
  for sv in seqValues:
    if sv.seqElements.len == 2 and
       sv.seqElements[0].kind == vrkSequence and
       sv.seqElements[1].kind == vrkSequence and
       sv.seqElements[0].seqElements.len == 2 and
       sv.seqElements[1].seqElements.len == 2 and
       sv.seqElements[0].seqElements[0].kind == vrkInt and
       sv.seqElements[0].seqElements[0].intVal == 1 and
       sv.seqElements[0].seqElements[1].intVal == 2 and
       sv.seqElements[1].seqElements[0].intVal == 3 and
       sv.seqElements[1].seqElements[1].intVal == 4:
      foundNested = true
      break
  doAssert foundNested, "expected @[@[1, 2], @[3, 4]] as a nested vrkSequence. " &
    "Sequence values seen: " & $seqValues.len &
    "; raw fallbacks: " & $rawValues

  removeDir(buildDir)
  echo "PASS: tvm_trace_complex_values - structured aggregates decoded " &
    "(" & $valueCount & " Value events, " & $structValues.len & " struct, " &
    $seqValues.len & " seq, " & $rawValues.len & " raw fallback)"

main()
