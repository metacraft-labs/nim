discard """
  action: reject
  targets: "c js"
  errormsg: "copy operation is still being generated"
"""
import std/macros
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
type Hook[T] = object
  value: T
  text: string
var copies = 0
proc `=destroy`[T](value: var Hook[T]) = discard
proc `=copy`[T](dest: var Hook[T]; source: Hook[T]) =
  inspect(dest)
  inc copies
  dest.value = source.value
  dest.text = source.text
let retained = Hook[int](value: 1, text: "retained")
var copied = Hook[int](value: 2, text: "previous")
copied = retained
doAssert copied.text == retained.text and copied.value == retained.value
doAssert copies == 1
