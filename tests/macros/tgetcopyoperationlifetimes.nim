discard """
  targets: "c js"
  matrix: "--mm:arc; --mm:orc"
  output: "CCDDDEFD"
"""
import std/macros
import mcopyinspectionprivate

proc returned(source: Public): Public = source
proc scenario(counts: Counts; source: Public) =
  let original = make(counts, source.read)
  try:
    var target = make(counts, "previous")
    target = original
    let value = returned(original)
    let temporary = (make(counts, "temporary"),)
    doAssert value.read == source.read
    doAssert temporary[0].read == "temporary"
    doAssert target.read == original.read
    raise newException(ValueError, "fixed message")
  except ValueError:
    counts.order.add 'E'
  finally:
    counts.order.add 'F'
  doAssert original.read == source.read

macro inspect(fn: typed): untyped =
  let source = fn.getImpl[3][1][0]
  let operation = source.getCopyOperation
  doAssert operation.kind == nnkSym
  doAssert operation.getImpl.kind == nnkProcDef
  result = newEmptyNode()
when not defined(copyInspectionBaseline): inspect(returned)
let counts = Counts()
block:
  let source = make(Counts(), "retained")
  scenario(counts, source)
echo counts.order
