discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
  output: "C"
"""
import std/macros
when not declared(getCopyOperation):
  {.error: "copy inspection capability is unavailable".}
type
  Base = object
    number: int
    text: string
  First = distinct Base
  Second = distinct Base
  Alias = First
var order = ""
proc `=destroy`(value: var First) = discard
proc `=destroy`(value: var Second) = discard
proc `=copy`(dest: var First; source: First)
proc `=dup`(source: First): First
proc `=copy`(dest: var Second; source: Second)
proc `=copy`(dest: var First; source: First) =
  order.add 'C'
  Base(dest).number = Base(source).number
  Base(dest).text = Base(source).text
proc `=dup`(source: First): First =
  order.add 'U'
  Base(result).number = Base(source).number
  Base(result).text = Base(source).text
proc `=copy`(dest: var Second; source: Second) =
  order.add 'X'
  Base(dest).number = Base(source).number
  Base(dest).text = Base(source).text
proc prepared(source: First): int =
  var dest = First(Base(number: 1, text: "previous"))
  dest = source
  Base(dest).number + Base(source).number
proc otherPrepared(source: Second): int =
  var dest: Second
  dest = source
  Base(dest).number + Base(source).number
proc referentPrepared(source: Base): int =
  var dest: Base
  dest = source
  dest.number + source.number
macro inspect(first, second: typed): untyped =
  let source = first.getImpl[3][1][0]
  let other = second.getImpl[3][1][0]
  let actual = source.getCopyOperation
  let allCopies = bindSym"=copy"
  var expected: NimNode
  for candidate in allCopies:
    let impl = candidate.getImpl
    if impl.kind == nnkProcDef and
        impl[3][1][^2].kind == nnkVarTy and
        impl[3][1][^2][0] == bindSym"First": expected = candidate
  doAssert expected != nil, "fixture reference must resolve actual overload"
  doAssert actual == expected, "wrong same-spelled Copy overload"
  doAssert actual != other.getCopyOperation
  doAssert bindSym"Alias".getCopyOperation == actual
  let allDups = bindSym"=dup"
  if allDups.kind == nnkSym: doAssert actual != allDups
  else:
    for candidate in allDups: doAssert actual != candidate, "Dup is not Copy"
  result = newEmptyNode()
when not defined(copyInspectionBaseline): inspect(prepared, otherPrepared)
let retained = First(Base(number: 4, text: "retained"))
doAssert prepared(retained) == 8
doAssert Base(retained).text == "retained"
echo order
