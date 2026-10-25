discard """
  action: reject
  targets: "c js"
  errormsg: "copy inspection requires a typed concrete value type"
"""
import std/macros
macro inspect(): untyped =
  discard newIdentNode("untypedInput").getCopyOperation
  result = newEmptyNode()
inspect()
