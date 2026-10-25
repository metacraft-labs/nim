discard """
  action: reject
  targets: "c cpp"
  cmd: "nim $target --mm:refc $options $file"
  errormsg: "copy inspection is unsupported for this target or memory manager"
"""
import std/macros
macro inspect(): untyped =
  # Support precedes input eligibility in the diagnostic contract.
  discard newIdentNode("untypedInput").getCopyOperation
  result = newEmptyNode()
inspect()
