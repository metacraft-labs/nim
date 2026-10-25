discard """
  targets: "c cpp"
  matrix: "--mm:arc; --mm:orc; --mm:arc -d:phantomAlias; --mm:orc -d:phantomAlias; --mm:arc -d:reverseOrder; --mm:orc -d:reverseOrder; --mm:arc -d:phantomAlias -d:reverseOrder; --mm:orc -d:phantomAlias -d:reverseOrder; --mm:yrc; --mm:atomicArc"
  output: ""
"""
# Exercise RTTI destruction in two modules, with both phantom instantiation
# orders. Value ownership and nominal generic hooks guard canonical sharing.
import ./phantomhooks/[owner, second]
proc collectDeferred() =
  # YRC deliberately defers even acyclic destruction until collection.
  # ARC/ORC assertions continue to check destruction at the scope boundary.
  when compileOption("gc", "yrc"): GC_fullCollect()
proc first() =
  when defined(reverseOrder):
    let value = create(secret(1))
  else:
    let value = create(secret("first"))
  doAssert value != nil
first()
makeSecond()
collectDeferred()
doAssert finalized == 2, $finalized
proc values() =
  let a = ValueContainer[Secret[string]](value: secret("value"))
  let b = ValueContainer[Secret[int]](value: secret(3))
  doAssert Token(a.value) != nil and Token(b.value) != nil
values()
collectDeferred()
doAssert finalized == 4, $finalized
proc nominalValues() =
  let a = ValueContainer[Nominal[string]](value: Nominal[string](marker: "a"))
  let b = ValueContainer[Nominal[int]](value: Nominal[int](marker: "b"))
  doAssert a.value.marker == "a" and b.value.marker == "b"
nominalValues()
collectDeferred()
doAssert hooks == [1, 1], $hooks
proc nominalRefs() =
  let a = create(Nominal[string](marker: "a"))
  let b = create(Nominal[int](marker: "b"))
  doAssert a.value.marker == "a" and b.value.marker == "b"
nominalRefs()
collectDeferred()
doAssert hooks == [2, 2], $hooks
