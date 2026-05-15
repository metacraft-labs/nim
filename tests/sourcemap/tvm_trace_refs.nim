discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: CTFS-M-Refs — dereference walk with cycle protection.
##
## Drives `nim e --trace:` on a NimScript that constructs ref objects
## (including a chain and a self-referencing cyclic ref), then reads
## back the trace via TraceReader and walks every `tleValue` event to
## confirm:
##
##   1. A nil-tailed ref (`a`) is emitted as `vrkReference` with a
##      non-zero `address` and a `dereferenced` payload that is a
##      `vrkStruct` carrying the right field values (`value=42`,
##      `next` as `vrkNone`).
##   2. A ref that points at another ref (`b -> a`) is emitted as a
##      `vrkReference` whose payload struct has `value=100` and an
##      inner `next` that is *also* a vrkReference (pointing at `a`).
##      The inner reference carries `a`'s address.
##   3. A self-cycle (`c.self = c`) is detected: the outer ref's
##      payload struct has its `self` field rendered as a leaf
##      `vrkReference` with the same address as `c`, but an empty
##      `dereferenced` slot — no stack overflow, no exponential blow-
##      up.

import std/[os, osproc, assertions]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_refs"

const testScript = """
type
  Node = ref object
    value: int
    next: Node

  Cyclic = ref object
    name: string
    self: Cyclic

proc makeCyclic(): Cyclic =
  result = Cyclic(name: "self-ref", self: nil)
  result.self = result

let a = Node(value: 42, next: nil)
let b = Node(value: 100, next: a)

# After this `let`, `c` is bound to a ref whose `self` field already
# points back at the same allocation — the cyclic case the
# CTFS-M-Refs serializer must short-circuit on.
let c = makeCyclic()

echo a.value, " ", b.value, " ", c.name
"""

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_refs.nims"
  let traceFile = buildDir / "test_refs.ct"
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

  var referenceValues: seq[ValueRecord]
  for event in reader.events:
    if event.kind == tleValue:
      let v = event.fullValue.value
      if v.kind == vrkReference:
        referenceValues.add(v)

  doAssert referenceValues.len >= 3,
    "expected at least 3 vrkReference values (a, b, c); saw: " &
    $referenceValues.len

  # ---- assertion 1: `a` is a vrkReference whose payload is
  # vrkStruct{value=42, next=vrkNone}.
  var foundA = false
  var aAddress: uint64 = 0
  for rv in referenceValues:
    if rv.address == 0: continue
    if rv.dereferenced.len != 1: continue
    let payload = rv.dereferenced[0]
    if payload.kind != vrkStruct: continue
    if payload.fieldValues.len != 2: continue
    let v0 = payload.fieldValues[0]
    let v1 = payload.fieldValues[1]
    if v0.kind == vrkInt and v0.intVal == 42 and v1.kind == vrkNone:
      foundA = true
      aAddress = rv.address
      break
  doAssert foundA,
    "expected ref `a` -> Node(value:42, next:nil) as " &
    "vrkReference{vrkStruct{42, vrkNone}}; refs seen: " &
    $referenceValues.len

  # ---- assertion 2: `b` is vrkReference whose payload is
  # vrkStruct{value=100, next=vrkReference(addr=aAddress)}.
  var foundB = false
  for rv in referenceValues:
    if rv.dereferenced.len != 1: continue
    let payload = rv.dereferenced[0]
    if payload.kind != vrkStruct: continue
    if payload.fieldValues.len != 2: continue
    let v0 = payload.fieldValues[0]
    let v1 = payload.fieldValues[1]
    if v0.kind != vrkInt or v0.intVal != 100: continue
    if v1.kind != vrkReference: continue
    # The inner `next` ref should carry `a`'s address — that's the
    # identity correlation guaranteed by stable PNode pointers within
    # a single VM run.
    if v1.address != aAddress: continue
    foundB = true
    break
  doAssert foundB,
    "expected ref `b` -> Node(value:100, next:a) as " &
    "vrkReference{vrkStruct{100, vrkReference(addr=a)}}; refs seen: " &
    $referenceValues.len & " aAddress=" & $aAddress

  # ---- assertion 3: `c` is a vrkReference whose payload struct's
  # `self` slot is a vrkReference with the same address as `c` and a
  # *cycle-leaf* payload (no further dereference). The on-disk CBOR
  # encoder always populates `dereferenced` with exactly one element,
  # so the serializer-side empty `@[]` round-trips through the reader
  # as a single `vrkNone` — that's the wire convention for "this ref
  # was short-circuited by cycle detection". The address itself
  # preserves identity correlation so a downstream debugger can still
  # show the user that the slot points back at the outer object.
  var foundC = false
  for rv in referenceValues:
    if rv.dereferenced.len != 1: continue
    let payload = rv.dereferenced[0]
    if payload.kind != vrkStruct: continue
    if payload.fieldValues.len != 2: continue
    let v0 = payload.fieldValues[0]
    let v1 = payload.fieldValues[1]
    if v0.kind != vrkString or v0.text != "self-ref": continue
    if v1.kind != vrkReference: continue
    # Inner ref address must match outer (identity back-edge).
    if v1.address != rv.address: continue
    # Cycle-leaf wire shape: inner.dereferenced is either empty (only
    # possible if the writer is ever upgraded to emit a sentinel) or
    # the conventional single-element-vrkNone sentinel surfaced by the
    # current CBOR reader/writer pair.
    let derefShapeOk =
      v1.dereferenced.len == 0 or
      (v1.dereferenced.len == 1 and v1.dereferenced[0].kind == vrkNone)
    if not derefShapeOk: continue
    foundC = true
    break
  doAssert foundC,
    "expected cyclic ref `c.self = c` to emit an inner " &
    "vrkReference with matching address and a cycle-leaf payload " &
    "(empty dereferenced or single vrkNone); refs seen: " &
    $referenceValues.len

  removeDir(buildDir)
  echo "PASS: tvm_trace_refs - ref dereference + cycle protection (" &
    "refs=" & $referenceValues.len & ")"

main()
