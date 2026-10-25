discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
"""
import std/macros
type Empty = object
proc prepared(source: Empty) =
  var dest: Empty
  dest = source
macro inspect(x: typed): untyped =
  let operation = x.getCopyOperation
  doAssert operation.kind == nnkSym
  doAssert operation.getImpl[^1].kind == nnkStmtList
  doAssert operation.getImpl[^1].len == 0,
    "a completed empty callable is distinct from a missing callable"
  result = newEmptyNode()
inspect(Empty)
prepared(Empty())
