discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
  output: "1"
"""
import std/macros
when not declared(getCopyOperation):
  {.error: "copy inspection capability is unavailable".}
type Late = object
  number: int
  text: string
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
when not defined(copyInspectionBaseline):
  static:
    # Inspection must not prepare/freeze this type. Its later legal custom hook
    # must still bind, and the real assignment must execute that selected hook.
    doAssert not compiles(inspect(Late))
var copies = 0
proc `=destroy`(value: var Late) = discard
proc `=copy`(dest: var Late; source: Late) =
  inc copies
  dest.number = source.number
  dest.text = source.text
proc use(source: Late): int =
  var dest = Late(number: 1, text: "previous")
  dest = source
  result = dest.number + source.number + dest.text.len - source.text.len
let retained = Late(number: 3, text: "retained")
doAssert use(retained) == 6
doAssert retained.number == 3
echo copies
