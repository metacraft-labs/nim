discard """
  action: reject
  targets: "c js"
  errormsg: "copy operation is not resolved"
"""
import std/macros
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
type Unprepared = object
  number: int
inspect(Unprepared)
