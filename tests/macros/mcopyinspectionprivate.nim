# Real private generic hooks: no mock compiler or replacement lookup.
import std/macros
type
  Counts* = ref object
    order*: string
  Hidden[T] = object
    value: T
    counts: Counts

proc `=destroy`[T](x: var Hidden[T]) =
  if x.counts != nil: x.counts.order.add 'D'
proc `=copy`[T](x: var Hidden[T]; y: Hidden[T]) =
  if y.counts != nil: y.counts.order.add 'C'
  x.value = y.value
  x.counts = y.counts
proc `=dup`[T](y: Hidden[T]): Hidden[T] =
  result.value = y.value
  result.counts = y.counts
type Public* = object
  hidden: Hidden[string]
proc make*(counts: Counts; value: string): Public =
  Public(hidden: Hidden[string](value: value, counts: counts))
proc read*(x: Public): string = x.hidden.value
proc expectedCopy*(): NimNode {.compileTime.} = bindSym"=copy"
proc privateField*(n: NimNode): NimNode {.compileTime.} =
  n.getTypeImpl[2][0][^2]
