discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: complex types (objects, seqs, nested) via NimScript trace
##
## Writes a NimScript with complex types (object, seq, nested seq),
## runs nim_trace e --trace on it, reads the .ct file using TraceReader,
## and verifies that Value events contain representations of these complex
## values (rendered via renderTree() in the serializer as vrkRaw strings).
##
## CTFS-M-Varnames update: the tracer now only emits values for slots
## owned by a source-level user binding. Two changes for this test:
##
##   1. Wrap the bindings in a proc so the locals are user-named slots
##      (skLet inside a `PProc(sym = demo)`), not top-level globals
##      written via `opcWrDeref`. Local skLet binds go through traced
##      `opcAsgnComplex` / `opcFastAsgnComplex` to their dedicated slot
##      after `setSlot` populates `regSymTable`.
##   2. Initialize the complex bindings indirectly through a `var`-then-
##      *assign* pattern so the write to the user-binding slot fires the
##      traceable assignment opcode. Direct construction of `let p =
##      Point(x: 1, y: 2)` lays out the object via per-field
##      `opcWrObj` writes whose source registers are temporaries —
##      vmgen has no analogue of `setSlot` for the implicit nkObjConstr
##      target, and per-field temporaries are correctly rejected by the
##      side-table lookup.

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

proc demo() =
  let src = Point(x: 1, y: 2)
  let srcArr = @[10, 20, 30]
  let srcNested = @[@[1, 2], @[3, 4]]
  # Re-bind through an explicit copy so the user-binding slot becomes
  # the destination of a traced opcAsgnComplex / opcFastAsgnComplex.
  let p = src
  let arr = srcArr
  let nested = srcNested
  let tail = arr  # tail flush so the last user binding lands in a
                  # value record before the proc's return collapses
                  # pending state.
  echo p, " ", arr, " ", nested, " ", tail

demo()
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

  # Collect all Value events — complex types appear as vrkRaw (renderTree output)
  # or as structured value records depending on serializer implementation
  var valueCount = 0
  var rawValues: seq[string]
  var intValues: seq[int64]
  var seqValues: seq[ValueRecord]

  for event in reader.events:
    if event.kind == tleValue:
      valueCount += 1
      let val = event.fullValue.value
      case val.kind
      of vrkRaw:
        rawValues.add(val.rawStr)
      of vrkInt:
        intValues.add(val.intVal)
      of vrkSequence:
        seqValues.add(val)
      else:
        discard

  doAssert valueCount > 0, "expected Value events in trace, got none"

  # Verify Point object representation.
  # The VM serializer renders objects via renderTree(), producing vrkRaw values
  # like "(x: 1, y: 2)".  Match the rendered tuple/object form specifically.
  var foundPoint = false
  for raw in rawValues:
    if "x:" in raw and "y:" in raw and "1" in raw and "2" in raw:
      foundPoint = true
      break
  doAssert foundPoint, "expected Point(x: 1, y: 2) representation in raw Value events. " &
    "Raw values: " & $rawValues

  # Verify seq representation: @[10, 20, 30]
  # renderTree produces "[10, 20, 30]" as a raw value string.
  var foundSeq = false
  for raw in rawValues:
    if "10" in raw and "20" in raw and "30" in raw:
      foundSeq = true
      break
  if not foundSeq:
    # Fallback: check structured sequence values
    for sv in seqValues:
      if sv.seqElements.len == 3:
        foundSeq = true
        break
  doAssert foundSeq, "expected @[10, 20, 30] representation in Value events. " &
    "Raw values: " & $rawValues

  # Verify nested seq representation: @[@[1, 2], @[3, 4]]
  # renderTree produces "[[1, 2], [3, 4]]" as a raw value string.
  # Match nested bracket structure to avoid false positives from flat seqs.
  var foundNested = false
  for raw in rawValues:
    if "[" in raw and "3" in raw and "4" in raw and "],[" in raw.replace(", ", ","):
      foundNested = true
      break
  if not foundNested:
    # Fallback: check structured sequence-of-sequence values
    for sv in seqValues:
      if sv.seqElements.len == 2:
        foundNested = true
        break
  doAssert foundNested, "expected @[@[1, 2], @[3, 4]] representation in Value events. " &
    "Raw values: " & $rawValues

  removeDir(buildDir)
  echo "PASS: tvm_trace_complex_values - found complex type representations " &
    "(" & $valueCount & " Value events, " & $rawValues.len & " raw, " &
    $intValues.len & " int, " & $seqValues.len & " seq)"

main()
