discard """
  action: reject
  targets: "c js"
  errormsg: "copy operation is not resolved"
"""
import std/macros
macro inspect(x: typed): untyped =
  discard x.getCopyOperation
  result = newEmptyNode()
# The ordinary path has no callable Copy for the empty-element array.
inspect([])
