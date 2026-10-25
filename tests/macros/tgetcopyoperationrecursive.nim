discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
"""
import std/macros
type
  Link = ref Value
  Value = object
    label: string
    next: Link
proc prepared(source: Value): Value =
  var dest: Value
  dest = source
  doAssert dest.label == source.label
  dest
macro inspect(fn: typed): untyped =
  let argument = fn.getImpl[3][1][0]
  let first = argument.getCopyOperation
  doAssert first.kind == nnkSym
  doAssert first.getImpl.kind == nnkProcDef
  doAssert first == bindSym"Value".getCopyOperation
  result = newEmptyNode()
inspect(prepared)
let node = Link(label: "retained")
node.next = node
block:
  let copied = prepared(node[])
  doAssert copied.next == node
  doAssert node.next == node
node.next = nil
