discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-ExceptionTypeRefinement: verify that a variable bound by
## `except T as e:` surfaces in the value stream with a meaningful
## type name (`ref IndexDefect`) rather than the VM's generic
## `node` placeholder.
##
## Pre-fix behaviour: vm_trace's `typeNameForReg` switched only on
## scalar PType kinds (bool/char/string/int/uint/float/enum) and fell
## through to the register-kind fallback for `tyRef`, which returned
## the literal string `"node"` because the bound register slot is
## `rkNode`-shaped. The visible effect was a misleading
## ``type_name: "node"`` on the catch-bound `e` in the trace, with no
## hint that the actual binding type is `ref IndexDefect`.
##
## Fix: extend `typeNameForReg` to recognise `tyRef` (and `tyPtr`)
## explicitly and compose ``"ref <ObjectName>"`` from the underlying
## object type's name. The lookup walks through `tyAlias` /
## `tyGenericInst` so generic instantiations resolve to their
## declared identifier rather than to an anonymous wrapper symbol.
##
## Asserted properties:
##   1. The trace's varname pool contains the user-source binding `e`.
##   2. At least one value record references that varname and carries
##      a type whose name contains the substring `IndexDefect`. The
##      full expected rendering is `ref IndexDefect`, but the test
##      accepts the substring form to stay robust against a future
##      tighter rendering choice (e.g. dropping the `ref` qualifier
##      for ref-typed bindings).

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_exception_type"

# Keep `except IndexDefect as e:` on its own line so the binding type
# resolves through transformExceptBranch's `excType.toRef(idgen)` path
# rather than through any imported-exception shortcut.
const testScript = """try:
  raise newException(IndexDefect, "oops")
except IndexDefect as e:
  discard e
"""

proc readVarnames(rdr: var NewTraceReader): seq[string] =
  result = @[]
  for i in 0 ..< int(rdr.varnameCount):
    let v = rdr.varname(uint64(i))
    if v.isOk:
      result.add(v.get)

proc readTypeNames(rdr: var NewTraceReader): seq[string] =
  result = @[]
  for i in 0 ..< int(rdr.typeCount):
    let t = rdr.typeName(uint64(i))
    if t.isOk:
      result.add(t.get)

proc findVarnameId(rdr: var NewTraceReader, name: string): int =
  result = -1
  for i in 0 ..< int(rdr.varnameCount):
    let v = rdr.varname(uint64(i))
    if v.isOk and v.get == name:
      return i

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "except_type.nims"
  let traceFile = buildDir / "except_type.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert fileExists(traceFile),
    "trace file not created at " & traceFile

  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  # --- (1) `e` is present in the varname pool -------------------------------
  let varnames = readVarnames(rdr)
  let typeNames = readTypeNames(rdr)
  let eId = findVarnameId(rdr, "e")
  doAssert eId >= 0,
    "expected user-bound `e` in varnames[], got: " & varnames.join(", ")

  # --- (2) at least one value record for `e` carries a type name that
  # contains `IndexDefect` ---------------------------------------------------
  let stepsRes = rdr.stepCount
  doAssert stepsRes.isOk, "stepCount failed: " & stepsRes.error
  let steps = stepsRes.get()

  var sawTypeName = ""
  var matched = false
  for s in 0'u64 ..< steps:
    let valsRes = rdr.values(s)
    doAssert valsRes.isOk,
      "values[" & $s & "] failed: " & valsRes.error
    for v in valsRes.get():
      if int(v.varnameId) != eId:
        continue
      let tn = rdr.typeName(v.typeId)
      doAssert tn.isOk,
        "typeName lookup failed for typeId " & $v.typeId & ": " & tn.error
      let name = tn.get
      sawTypeName = name
      if "IndexDefect" in name:
        matched = true
        break
    if matched:
      break

  doAssert matched,
    "expected a value record for `e` whose type_name contains " &
    "'IndexDefect' (full form: `ref IndexDefect`); got type_name=" &
    sawTypeName.repr & " in interning pool " & typeNames.join(", ")

  # The fix produces the qualified form `ref IndexDefect`. We assert the
  # qualified rendering separately so a regression to the bare object
  # name still trips a clear failure (the substring check above already
  # passed). When/if the rendering choice changes intentionally, this
  # second assertion becomes the obvious knob to revisit.
  doAssert sawTypeName == "ref IndexDefect",
    "expected `e`'s type_name to be exactly 'ref IndexDefect'; got " &
    sawTypeName.repr

  removeDir(buildDir)
  echo "PASS: tvm_trace_exception_type — e: " & sawTypeName

main()
