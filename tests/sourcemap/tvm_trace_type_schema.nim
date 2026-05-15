discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: CTFS-M-TypeSchema — named struct fields, vrkSet, vrkEnum.
##
## Closes the three structural-fidelity gaps surfaced by
## CTFS-M-ComplexTypes:
##
##   1. Struct field names: `vrkStruct` now carries a parallel
##      `fieldNames` array; the materializer renders
##      `[("x", Int(1)), ("y", Int(2))]` instead of an opaque
##      positional list.
##
##   2. Sets render as `vrkSet` (dedicated variant) rather than
##      leaking through as `vrkSequence` with `tkSet` as the only
##      disambiguating signal.
##
##   3. Enums render as `vrkEnum { name, ordinal, type_id }` rather
##      than `vrkRaw` with the symbol name only.
##
## The test runs a NimScript via `nim e --trace:`, decodes the
## resulting .ct via the public TraceReader, and walks the
## `tleValue` events to verify the new shapes.

import std/[os, osproc, assertions]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_type_schema"

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

let aColor = cBlue
let aPoint = Point(x: 1, y: 2)
let aSet = {1, 3, 5}
let aShape = Shape(kind: cBlue, blue_val: "azure")

echo aPoint, " ", aShape
"""

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_type_schema.nims"
  let traceFile = buildDir / "test_type_schema.ct"
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

  var enumValues: seq[ValueRecord]
  var setValues: seq[ValueRecord]
  var structValues: seq[ValueRecord]
  var variantValues: seq[ValueRecord]

  for event in reader.events:
    if event.kind == tleValue:
      let v = event.fullValue.value
      case v.kind
      of vrkEnum: enumValues.add(v)
      of vrkSet: setValues.add(v)
      of vrkStruct: structValues.add(v)
      of vrkVariant: variantValues.add(v)
      else: discard

  # 1) aColor=cBlue → vrkEnum{name="cBlue", ordinal=2}
  var foundColor = false
  for v in enumValues:
    if v.enumName == "cBlue" and v.enumOrdinal == 2:
      foundColor = true
      break
  doAssert foundColor,
    "expected aColor as vrkEnum{name:\"cBlue\", ordinal:2}; enums seen: " &
    $enumValues.len

  # 2) aPoint=Point(x:1,y:2) → vrkStruct with fieldNames @["x","y"]
  #    paired with fieldValues [Int(1), Int(2)]
  var foundPoint = false
  for v in structValues:
    if v.fieldValues.len == 2 and v.fieldNames.len == 2 and
       v.fieldNames[0] == "x" and v.fieldNames[1] == "y" and
       v.fieldValues[0].kind == vrkInt and v.fieldValues[0].intVal == 1 and
       v.fieldValues[1].kind == vrkInt and v.fieldValues[1].intVal == 2:
      foundPoint = true
      break
  doAssert foundPoint,
    "expected Point(x:1,y:2) as vrkStruct with fieldNames=[\"x\",\"y\"]; " &
    "structs seen: " & $structValues.len

  # 3) aSet={1,3,5} → vrkSet with three int members
  var foundSet = false
  for v in setValues:
    if v.setMembers.len == 3 and
       v.setMembers[0].kind == vrkInt and v.setMembers[0].intVal == 1 and
       v.setMembers[1].kind == vrkInt and v.setMembers[1].intVal == 3 and
       v.setMembers[2].kind == vrkInt and v.setMembers[2].intVal == 5:
      foundSet = true
      break
  doAssert foundSet,
    "expected aSet={1,3,5} as vrkSet; sets seen: " & $setValues.len

  # 4) aShape → vrkVariant discriminator "cBlue", payload vrkStruct
  #    with fieldNames=["blue_val"] and the string "azure".
  var foundShape = false
  for v in variantValues:
    if v.discriminator == "cBlue" and v.contents.len == 1 and
       v.contents[0].kind == vrkStruct and
       v.contents[0].fieldValues.len == 1 and
       v.contents[0].fieldNames.len == 1 and
       v.contents[0].fieldNames[0] == "blue_val" and
       v.contents[0].fieldValues[0].kind == vrkString and
       v.contents[0].fieldValues[0].text == "azure":
      foundShape = true
      break
  doAssert foundShape,
    "expected Shape(kind:cBlue, blue_val:\"azure\") as vrkVariant " &
    "with named payload field; variants seen: " & $variantValues.len

  removeDir(buildDir)
  echo "PASS: tvm_trace_type_schema — named-fields + vrkSet + vrkEnum (" &
    "enums=" & $enumValues.len & ", sets=" & $setValues.len &
    ", structs=" & $structValues.len & ", variants=" &
    $variantValues.len & ")"

main()
