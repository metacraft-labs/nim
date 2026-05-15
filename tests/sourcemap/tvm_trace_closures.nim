discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-Closures: verify that closure invocations surface the
## captured environment in the trace.
##
## A Nim closure compiles to a `(env, prc)` tuple at the VM level —
## the env is an allocated object whose fields are the lexical state
## the lambda captured. Pre-CTFS-M-Closures the trace recorded the
## call event but emitted nothing for the env, so two closures created
## from the same lambda with different captured state (e.g.
## `makeAdder(2)` vs `makeAdder(5)`) were indistinguishable when
## invoked — the call_entry's args[] was empty and the env was
## reachable only as a synthetic hidden parameter the user never sees.
##
## Two changes land here:
##
##   1. `compiler/vm.nim`'s `opcIndCall` handler now passes the closure
##      env PNode (`regs[rb].node[1]`) to `traceCall` when the callee
##      is closure-shaped (`bb.kind == nkTupleConstr`).
##   2. `compiler/vm_trace.nim`'s `traceCall` serialises the env via
##      the existing `serializeNode` walker and emits it as a single
##      `:env` CallArg. Non-closure calls keep the legacy empty-args
##      shape so existing snapshots stay byte-stable.
##
## A third (orthogonal) change improves the function name for
## anonymous closures: `:anonymous` becomes
## `<anon>@<basename>:<line>`, anchored at the lambda definition site
## via `prc.info`. Two lambdas defined on different source lines now
## get distinct functionIds, and the trace UI displays a name a user
## can navigate to.
##
## This test:
##   1. Creates two closures from the same factory (`makeAdder(2)`,
##      `makeAdder(5)`) and invokes each.
##   2. Asserts that the closure body appears in `functions[]` under
##      the new `<anon>@…:<line>` shape (not bare `:anonymous`).
##   3. Asserts that each closure call_entry carries an args[] with a
##      single `:env` arg whose serialised value contains the matching
##      captured `x` (2 for `addTwo`, 5 for `addFive`).

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/cbor
import codetracer_trace_types

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_closures"

const userScript = """
proc makeAdder(x: int): proc(y: int): int =
  result = proc(y: int): int = x + y

let addTwo = makeAdder(2)
let addFive = makeAdder(5)
discard addTwo(10)
discard addFive(20)
"""

proc readFunctions(traceFile: string): seq[string] =
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  for i in 0 ..< int(rdr.functionCount):
    let f = rdr.function(uint64(i))
    if f.isOk:
      result.add(f.get)

proc decodeArgValue(bytes: seq[byte]): ValueRecord =
  ## Decode a CallArg.value back into a ValueRecord. Returns vrkNone on
  ## failure so a downstream `findCapturedInt` cleanly returns the
  ## "not found" sentinel rather than blowing up the test runner.
  var dec = CborDecoder.init(bytes)
  let res = dec.decodeCborValueRecord()
  if res.isOk: res.get()
  else: ValueRecord(kind: vrkNone, noneTypeId: NoneTypeId)

proc findCapturedInt(v: ValueRecord): int =
  ## Walk a ValueRecord searching for the first vrkInt leaf. The env
  ## landed as either a vrkStruct (direct lift) or a vrkReference
  ## wrapping a vrkStruct (heap-allocated env, the common case for
  ## escaping closures — `makeAdder` returns the closure to the outer
  ## scope, so the env must outlive the frame and the VM's
  ## lambdalifting allocates it on the heap). We descend through
  ## vrkReference and vrkStruct uniformly because the captured `x`
  ## sits at the bottom either way.
  case v.kind
  of vrkInt: return int(v.intVal)
  of vrkReference:
    if v.dereferenced.len > 0:
      return findCapturedInt(v.dereferenced[0])
  of vrkStruct:
    for sub in v.fieldValues:
      let r = findCapturedInt(sub)
      if r != int.high: return r
  of vrkTuple:
    for sub in v.tupleElements:
      let r = findCapturedInt(sub)
      if r != int.high: return r
  else: discard
  int.high

proc collectClosureCalls(traceFile: string,
                         closureFuncId: uint64): seq[int] =
  ## Return the captured-`x` value for each call to the closure body,
  ## in entry order. We filter by `functionId` (the synthetic
  ## `<anon>@…:<line>` body) so unrelated trace events don't pollute
  ## the assertion.
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk, "openNewTrace failed: " & openRes.error
  var rdr = openRes.get()
  let cc = rdr.callCount
  doAssert cc.isOk, "callCount failed: " & cc.error
  for i in 0 ..< cc.get:
    let cr = rdr.call(i)
    if cr.isErr: continue
    let rec = cr.get
    if rec.functionId != closureFuncId: continue
    doAssert rec.args.len == 1,
      "closure call expected 1 arg, got " & $rec.args.len
    let arg = rec.args[0]
    let varRes = rdr.varname(arg.varnameId)
    doAssert varRes.isOk, "varname lookup failed for arg"
    doAssert varRes.get == ":env",
      "closure arg name expected ':env', got '" & varRes.get & "'"
    let envVal = decodeArgValue(arg.value)
    let x = findCapturedInt(envVal)
    doAssert x != int.high,
      "no captured int found in env value for call " & $i
    result.add(x)

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "closure_program.nims"
  writeFile(scriptFile, userScript)

  let traceFile = buildDir / "closure.ct"
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  let funcs = readFunctions(traceFile)

  # The closure body must surface as `<anon>@<basename>:<line>` and
  # NOT as the bare `:anonymous` marker. We look for any function entry
  # starting with `<anon>@` and matching the lambda's source line (2).
  var closureName = ""
  var closureFuncId: uint64 = uint64.high
  for i, n in funcs:
    if n.startsWith("<anon>@") and n.endsWith(":2"):
      closureName = n
      closureFuncId = uint64(i)
      break

  doAssert closureName.len > 0,
    "expected an entry of shape '<anon>@…:2' in functions[], got: " &
      funcs.join(", ")
  doAssert ":anonymous" notin funcs,
    "bare ':anonymous' entry leaked into functions[]: " & funcs.join(", ")
  doAssert closureName.contains("closure_program"),
    "expected closureName to mention the script filename, got: " &
      closureName

  # makeAdder is its own ordinary entry — sanity check the trace also
  # captured the factory.
  doAssert "makeAdder" in funcs,
    "expected 'makeAdder' in functions[], got: " & funcs.join(", ")

  # Two invocations: `addTwo(10)` then `addFive(20)`. Each call_entry
  # must carry a single `:env` arg whose deref chain bottoms out at the
  # captured int (`x = 2` then `x = 5`).
  let capturedXs = collectClosureCalls(traceFile, closureFuncId)
  doAssert capturedXs.len == 2,
    "expected 2 closure calls, got " & $capturedXs.len &
      " (captured xs: " & $capturedXs & ")"
  doAssert capturedXs[0] == 2,
    "first closure call expected captured x=2, got " & $capturedXs[0]
  doAssert capturedXs[1] == 5,
    "second closure call expected captured x=5, got " & $capturedXs[1]

  echo "PASS: tvm_trace_closures — closure=", closureName,
       " captured=", capturedXs

  removeDir(buildDir)

main()
