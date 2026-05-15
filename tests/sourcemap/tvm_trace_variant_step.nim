discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-VariantStep: regression test for variant-object case-label line
## attribution.
##
## Compiles a small NimScript program that constructs and inspects a variant
## object, then verifies the produced .ct trace does NOT contain any Step
## events that land inside the type definition's `of <X>:` case-labels.
##
## Before CTFS-M-VariantStep, two unrelated compiler paths leaked the type
## definition's `of <X>:` source position into runtime VM opcodes:
##
##   1. `semfields.semForObjectFields` copied the `nkOfBranch` from the type
##      definition's `nkRecCase` when synthesizing the case statement that
##      walks a variant object's fields (e.g. inside the generic `$` produced
##      by `std/objectdollar`). The cloned branch retained the type-def's
##      `of <X>:` info, which then became the opcBranch's debug info.
##
##   2. `semexprs.lookupInRecordAndBuildCheck` copied the matching-literal
##      nodes (`it[j]`) out of the type-def's `nkRecCase` to build the
##      set-membership runtime check for variant field access. Those literals
##      kept their type-def info, which then became the LdImmInt opcode's
##      debug info when the set was constructed.
##
## A debugger user stepping forward through `$variantValue` (or any other
## auto-generated traversal) would otherwise observe the program jump
## "backward" into the type definition.

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_variant_step"

# The matrix-cell layout in the script below is load-bearing: every line in
# the type definition is asserted absent from the produced trace. Comments
# in the test script reflect the line numbers used downstream.
const testScript = """type
  Color = enum
    red, green, blue
  Shape = object
    case kind: Color           # line 5
    of red:                    # line 6
      r: int                   # line 7
    of green:                  # line 8
      g: float                 # line 9
    of blue:                   # line 10
      b: string                # line 11

proc make(): Shape =           # line 13
  result = Shape(kind: red, r: 42)  # line 14

block:                         # line 16
  const s = make()             # line 17
  doAssert $s == "(kind: red, r: 42)"  # line 18
"""

# Line ranges that must NEVER appear in step events. These are the type
# definition's structural lines — case-label lines and field-declaration
# lines that a debugger user stepping forward should not jump into.
const forbiddenTypeDefLines = @[5, 6, 7, 8, 9, 10, 11]

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "variant_step.nims"
  let traceFile = buildDir / "variant_step.ct"
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

  # Find the path id for our script file. tlePath events are emitted in
  # interning order, so the implicit path-id of the Nth tlePath is N. We
  # match by basename so the test is robust to build-dir relocation.
  var scriptPathId = -1
  let scriptBase = extractFilename(scriptFile)
  var pathIdx = 0
  for ev in reader.events:
    if ev.kind == tlePath:
      if ev.path.endsWith(scriptBase):
        scriptPathId = pathIdx
        break
      pathIdx += 1
  doAssert scriptPathId >= 0,
    "could not find path record for script file " & scriptBase

  # Walk every step event in the script's path and verify it does not land on
  # any line inside the type definition.
  var stepLines: seq[int] = @[]
  var violations: seq[int] = @[]
  for ev in reader.events:
    if ev.kind == tleStep and int(uint64(ev.step.pathId)) == scriptPathId:
      let line = int(int64(ev.step.line))
      stepLines.add line
      if line in forbiddenTypeDefLines:
        violations.add line

  doAssert stepLines.len > 0,
    "no step events found for the script file at all (path_id=" &
    $scriptPathId & ")"
  doAssert violations.len == 0,
    "step events landed inside the variant-object type definition at " &
    "lines " & $violations & " (full step sequence: " & $stepLines & ")"

  # Also assert that the actual construction site (line 14) appears in the
  # trace. Without this, the "no forbidden lines" check would be vacuously
  # true if the construction emitted no steps at all.
  doAssert 14 in stepLines,
    "expected a step at the construction site (line 14); got " & $stepLines

  removeDir(buildDir)
  echo "PASS: tvm_trace_variant_step - step sequence " & $stepLines &
    " (no events inside type definition)"

main()
