discard """
  action: reject
  targets: "c js"
  errormsg: "copy inspection requires a typed concrete value type"
"""
import std/macros
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
type Value = object
  number: int
type Reference = ref Value
proc prepared(x: Reference): Reference = x
inspect(Reference)
