discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
  output: "CDD"
"""

import std/macros
import mcopyinspectionprivate
when not declared(getCopyOperation):
  {.error: "copy inspection capability is unavailable".}

proc matches(actual, expected: NimNode): bool {.compileTime.} =
  if expected.kind == nnkSym:
    actual == expected or actual.isInstantiationOf(expected)
  else:
    for candidate in expected:
      if matches(actual, candidate): return true
    false

proc hasExpected(n, expected: NimNode; seen: var seq[NimNode]): bool {.compileTime.} =
  if n.kind == nnkSym and n.symKind == nskProc:
    if matches(n, expected): return true
    if n notin seen:
      seen.add n
      let impl = n.getImpl
      if impl.kind in {nnkProcDef, nnkFuncDef}:
        if hasExpected(impl[^1], expected, seen): return true
  for child in n:
    if hasExpected(child, expected, seen): return true

macro inspect(fn: typed): untyped =
  let impl = fn.getImpl
  let argument = impl[3][1][0]
  let operation = argument.getCopyOperation
  doAssert operation.kind == nnkSym
  doAssert operation.getImpl.kind == nnkProcDef
  var seen: seq[NimNode]
  doAssert hasExpected(operation, expectedCopy(), seen),
    "actual private generic Copy identity must be exposed"
  doAssert argument.getTypeInst.getCopyOperation == operation,
    "typedesc and expression select the same actual binding"
  result = newEmptyNode()

proc prepared(source: Public) =
  var target: Public
  target = source
  doAssert target.read == source.read
when not defined(copyInspectionBaseline): inspect(prepared)

macro inspectPrivateField(fn: typed): untyped =
  let source = fn.getImpl[3][1][0]
  let fieldType = privateField(source)
  let operation = fieldType.getCopyOperation
  doAssert matches(operation, expectedCopy()), "private field's concrete Copy"
  result = newEmptyNode()
when not defined(copyInspectionBaseline): inspectPrivateField(prepared)

type
  Alias = Public
  Aggregate = tuple[value: Public]
  ArrayAggregate = array[2, Public]
  Inherited = object of RootObj
    value: Public
proc aggregatePrepared(source: Aggregate) =
  var target: Aggregate
  target = source
proc arrayPrepared(source: ArrayAggregate) =
  var target: ArrayAggregate
  target = source
proc inheritedPrepared(source: Inherited) =
  var target: Inherited
  target = source
proc varPrepared(source: var Public) =
  var target: Public
  target = source
proc sinkPrepared(source: sink Public) =
  var target: Public
  target = source
when not defined(copyInspectionBaseline):
  inspect(aggregatePrepared)
  inspect(arrayPrepared)
  inspect(inheritedPrepared)
  inspect(varPrepared)
  inspect(sinkPrepared)

let counts = Counts()
block:
  let original = make(counts, "retained")
  var target = make(counts, "previous")
  target = original
  doAssert target.read == "retained"
echo counts.order
