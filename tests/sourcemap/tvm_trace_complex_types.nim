discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: CTFS-M-ComplexTypes — recursive ValueRecord for aggregates.
##
## Runs a NimScript that defines a fresh value of every aggregate
## kind (object, tuple, enum, case-object, sequence, set, nested
## sequence-of-objects), drives `nim e --trace:` on it, then reads
## back the trace via the public TraceReader and walks every
## resulting `tleValue` event to confirm the serializer surfaces
## structured ValueRecord variants instead of the legacy renderTree
## strings.
##
## Each assertion targets a specific shape (e.g. tuple of three
## elements with distinct primitive kinds) so accidental collisions
## with other intermediate values in the trace can't satisfy it.

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_complex_types"

const testScript = """
type
  Color = enum
    cRed, cGreen, cBlue

  Point = object
    x, y: int

  Shape = object
    case kind: Color
    of cRed: red_val: int
    of cGreen: green_val: float
    of cBlue: blue_val: string

let primInt = 42
let primStr = "hello"
let aSeq = @[1, 2, 3]
let aTuple = (10, "world", 3.14)
let aPoint = Point(x: 1, y: 2)
let aColor = cGreen
let aShape = Shape(kind: cBlue, blue_val: "azure")
let aSet = {1, 3, 5}
let nested = @[Point(x: 10, y: 20), Point(x: 30, y: 40)]

echo primInt, " ", aColor
"""

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_complex_types.nims"
  let traceFile = buildDir / "test_complex_types.ct"
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

  # Collect Value events bucketed by variant.
  var intValues: seq[int64]
  var stringValues: seq[string]
  var sequenceValues: seq[ValueRecord]
  var tupleValues: seq[ValueRecord]
  var structValues: seq[ValueRecord]
  var variantValues: seq[ValueRecord]
  var rawValues: seq[string]
  # CTFS-M-TypeSchema: dedicated buckets for the new variants. Sets
  # used to surface as vrkSequence; enums as vrkRaw.
  var setValues: seq[ValueRecord]
  var enumValues: seq[ValueRecord]

  for event in reader.events:
    if event.kind == tleValue:
      let v = event.fullValue.value
      case v.kind
      of vrkInt: intValues.add(v.intVal)
      of vrkString: stringValues.add(v.text)
      of vrkSequence: sequenceValues.add(v)
      of vrkTuple: tupleValues.add(v)
      of vrkStruct: structValues.add(v)
      of vrkVariant: variantValues.add(v)
      of vrkRaw: rawValues.add(v.rawStr)
      of vrkSet: setValues.add(v)
      of vrkEnum: enumValues.add(v)
      else: discard

  # primInt → vrkInt 42
  doAssert 42'i64 in intValues,
    "expected primInt=42 as vrkInt; ints seen: " & $intValues

  # primStr → vrkString "hello"
  var foundPrimStr = false
  for s in stringValues:
    if s == "hello":
      foundPrimStr = true
      break
  doAssert foundPrimStr,
    "expected primStr=\"hello\" as vrkString; strings seen: " & $stringValues

  # aSeq → vrkSequence of [1,2,3]
  var foundASeq = false
  for sv in sequenceValues:
    if sv.seqElements.len == 3 and
       sv.seqElements[0].kind == vrkInt and sv.seqElements[0].intVal == 1 and
       sv.seqElements[1].kind == vrkInt and sv.seqElements[1].intVal == 2 and
       sv.seqElements[2].kind == vrkInt and sv.seqElements[2].intVal == 3:
      foundASeq = true
      break
  doAssert foundASeq,
    "expected aSeq=@[1,2,3] as vrkSequence; seqs seen: " & $sequenceValues.len

  # aTuple → vrkTuple of (10, "world", 3.14)
  var foundATuple = false
  for tv in tupleValues:
    if tv.tupleElements.len == 3 and
       tv.tupleElements[0].kind == vrkInt and tv.tupleElements[0].intVal == 10 and
       tv.tupleElements[1].kind == vrkString and tv.tupleElements[1].text == "world" and
       tv.tupleElements[2].kind == vrkFloat and
       abs(tv.tupleElements[2].floatVal - 3.14) < 1e-9:
      foundATuple = true
      break
  doAssert foundATuple,
    "expected aTuple=(10,\"world\",3.14) as vrkTuple; tuples seen: " &
    $tupleValues.len

  # aPoint → vrkStruct with field values [1, 2]
  var foundAPoint = false
  for sv in structValues:
    if sv.fieldValues.len == 2 and
       sv.fieldValues[0].kind == vrkInt and sv.fieldValues[0].intVal == 1 and
       sv.fieldValues[1].kind == vrkInt and sv.fieldValues[1].intVal == 2:
      foundAPoint = true
      break
  doAssert foundAPoint,
    "expected Point(x:1,y:2) as vrkStruct; structs seen: " & $structValues.len

  # CTFS-M-TypeSchema: aColor=cGreen → vrkEnum{name:"cGreen", ordinal:1}.
  var foundColor = false
  for v in enumValues:
    if v.enumName == "cGreen" and v.enumOrdinal == 1:
      foundColor = true
      break
  doAssert foundColor,
    "expected aColor=cGreen as vrkEnum{name:\"cGreen\", ordinal:1}; " &
    "enums seen: " & $enumValues.len

  # aShape → vrkVariant with discriminator "cBlue" and a vrkStruct payload
  # whose single field is the string "azure".
  var foundAShape = false
  for vv in variantValues:
    if vv.discriminator == "cBlue" and vv.contents.len == 1 and
       vv.contents[0].kind == vrkStruct and
       vv.contents[0].fieldValues.len == 1 and
       vv.contents[0].fieldValues[0].kind == vrkString and
       vv.contents[0].fieldValues[0].text == "azure":
      foundAShape = true
      break
  doAssert foundAShape,
    "expected aShape=Shape(kind:cBlue, blue_val:\"azure\") as vrkVariant; " &
    "variants seen: " & $variantValues.len

  # CTFS-M-TypeSchema: aSet={1,3,5} → dedicated vrkSet with three
  # int members.
  var foundASet = false
  for sv in setValues:
    if sv.setMembers.len == 3 and
       sv.setMembers[0].kind == vrkInt and sv.setMembers[0].intVal == 1 and
       sv.setMembers[1].kind == vrkInt and sv.setMembers[1].intVal == 3 and
       sv.setMembers[2].kind == vrkInt and sv.setMembers[2].intVal == 5:
      foundASet = true
      break
  doAssert foundASet,
    "expected aSet={1,3,5} as vrkSet; sets seen: " & $setValues.len

  # nested = @[Point(10,20), Point(30,40)] → vrkSequence of two vrkStruct
  # with int field pairs.
  var foundNested = false
  for sv in sequenceValues:
    if sv.seqElements.len == 2 and
       sv.seqElements[0].kind == vrkStruct and
       sv.seqElements[1].kind == vrkStruct and
       sv.seqElements[0].fieldValues.len == 2 and
       sv.seqElements[1].fieldValues.len == 2 and
       sv.seqElements[0].fieldValues[0].kind == vrkInt and
       sv.seqElements[0].fieldValues[0].intVal == 10 and
       sv.seqElements[0].fieldValues[1].intVal == 20 and
       sv.seqElements[1].fieldValues[0].intVal == 30 and
       sv.seqElements[1].fieldValues[1].intVal == 40:
      foundNested = true
      break
  doAssert foundNested,
    "expected nested seq of Points as vrkSequence[vrkStruct]; " &
    "sequences seen: " & $sequenceValues.len

  removeDir(buildDir)
  echo "PASS: tvm_trace_complex_types - structured aggregates decoded (" &
    "ints=" & $intValues.len & ", strs=" & $stringValues.len &
    ", seqs=" & $sequenceValues.len & ", tuples=" & $tupleValues.len &
    ", structs=" & $structValues.len & ", variants=" & $variantValues.len &
    ", raws=" & $rawValues.len & ", sets=" & $setValues.len &
    ", enums=" & $enumValues.len & ")"

main()
