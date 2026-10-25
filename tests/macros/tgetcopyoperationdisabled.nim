discard """
  action: reject
  targets: "c js"
  errormsg: "copy operation is disabled"
"""
import std/macros
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
type Disabled = object
  number: int
proc `=copy`(dest: var Disabled; source: Disabled) {.error.}
inspect(Disabled)
