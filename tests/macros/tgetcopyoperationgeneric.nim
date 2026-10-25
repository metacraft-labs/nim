discard """
  action: reject
  targets: "c js"
  errormsg: "copy inspection requires a typed concrete value type"
"""
import std/macros
type Generic[T] = object
  value: T
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
inspect(Generic)
