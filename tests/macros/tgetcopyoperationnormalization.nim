discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
"""
import std/macros
import mcopyinspectionprivate
type
  Alias = Public
  Borrowed = distinct Public
  Reference = ref Public
proc borrowedPrepared(source: Borrowed) =
  var target: Borrowed
  target = source
proc referencePrepared(source: Reference) =
  discard source[]
proc aliasPrepared(source: Alias) =
  var target: Alias
  target = source
macro inspect(borrowed, reference, aliased: typed): untyped =
  let expected = bindSym"Public".getCopyOperation
  let distinctParam = borrowed.getImpl[3][1][0]
  doAssert distinctParam.getCopyOperation == expected,
    "respect the compiler-selected borrowed/base Copy symbol"
  doAssert aliased.getImpl[3][1][0].getCopyOperation == expected
  proc findReferent(n: NimNode): NimNode =
    if n.kind in {nnkDerefExpr, nnkHiddenDeref}: return n
    for child in n:
      result = findReferent(child)
      if result != nil: return
  let selectedReferent = findReferent(reference.getImpl[^1])
  doAssert selectedReferent != nil
  doAssert selectedReferent.kind in {nnkDerefExpr, nnkHiddenDeref}
  doAssert selectedReferent.getCopyOperation == expected,
    "explicit value referent is separate from ref inspection"
  result = newEmptyNode()
inspect(borrowedPrepared, referencePrepared, aliasPrepared)
var executions = 0
proc expression(): Public =
  inc executions
  make(Counts(), "unused")
macro inspectExpression(x: typed): untyped =
  doAssert x.getCopyOperation == bindSym"Public".getCopyOperation
  result = newEmptyNode()
inspectExpression(expression())
doAssert executions == 0, "inspection must not execute its typed expression"
