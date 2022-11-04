
{.push stackTrace: off.}

# Make sure we always have these definitions, when `useMalloc` is defined.
# For example in the case when `nimNoLibc` is defined, we do not have these
# definitions, because they come form `system/ansi_c` but it is not imported.
# In the case we need both `nimNoLibc` & `useMalloc` we have to make sure
# they are defined
when defined(useMalloc):
  when defined(lightClientCosmos):
    proc c_malloc(size: csize_t):pointer = discard
    proc c_calloc(nitems: csize_t, size: csize_t):pointer = discard
    proc c_realloc(p: pointer, size: csize_t):pointer = discard
    proc c_free(size: pointer):void = discard
  else:
    proc c_malloc(size: csize_t):pointer {.header: "<stdlib.h>", importc: "malloc".}
    proc c_calloc(nitems: csize_t, size: csize_t):pointer {.header: "<stdlib.h>", importc: "calloc".}
    proc c_realloc(p: pointer, size: csize_t):pointer {.header: "<stdlib.h>", importc: "realloc".}
    proc c_free(size: pointer):void {.header: "<stdlib.h>", importc: "free".}

proc allocImpl(size: Natural): pointer =
  result = c_malloc(size.csize_t)
  when defined(zephyr):
    if result == nil:
      raiseOutOfMem()

proc alloc0Impl(size: Natural): pointer =
  result = c_calloc(size.csize_t, 1)
  when defined(zephyr):
    if result == nil:
      raiseOutOfMem()

proc reallocImpl(p: pointer, newSize: Natural): pointer =
  result = c_realloc(p, newSize.csize_t)
  when defined(zephyr):
    if result == nil:
      raiseOutOfMem()

proc realloc0Impl(p: pointer, oldsize, newSize: Natural): pointer =
  result = realloc(p, newSize.csize_t)
  if newSize > oldSize:
    zeroMem(cast[pointer](cast[int](result) + oldSize), newSize - oldSize)

proc deallocImpl(p: pointer) =
  c_free(p)


# The shared allocators map on the regular ones

proc allocSharedImpl(size: Natural): pointer =
  allocImpl(size)

proc allocShared0Impl(size: Natural): pointer =
  alloc0Impl(size)

proc reallocSharedImpl(p: pointer, newSize: Natural): pointer =
  reallocImpl(p, newSize)

proc reallocShared0Impl(p: pointer, oldsize, newSize: Natural): pointer =
  realloc0Impl(p, oldSize, newSize)

proc deallocSharedImpl(p: pointer) = deallocImpl(p)


# Empty stubs for the GC

proc GC_disable() = discard
proc GC_enable() = discard

when not defined(gcOrc):
  proc GC_fullCollect() = discard
  proc GC_enableMarkAndSweep() = discard
  proc GC_disableMarkAndSweep() = discard

proc GC_setStrategy(strategy: GC_Strategy) = discard

proc getOccupiedMem(): int = discard
proc getFreeMem(): int = discard
proc getTotalMem(): int = discard

proc nimGC_setStackBottom(theStackBottom: pointer) = discard

proc initGC() = discard

proc newObjNoInit(typ: PNimType, size: int): pointer =
  result = alloc(size)

proc growObj(old: pointer, newsize: int): pointer =
  result = realloc(old, newsize)

proc nimGCref(p: pointer) {.compilerproc, inline.} = discard
proc nimGCunref(p: pointer) {.compilerproc, inline.} = discard

when not defined(gcDestructors):
  proc unsureAsgnRef(dest: PPointer, src: pointer) {.compilerproc, inline.} =
    dest[] = src

proc asgnRef(dest: PPointer, src: pointer) {.compilerproc, inline.} =
  dest[] = src
proc asgnRefNoCycle(dest: PPointer, src: pointer) {.compilerproc, inline,
  deprecated: "old compiler compat".} = asgnRef(dest, src)

type
  MemRegion = object

proc alloc(r: var MemRegion, size: int): pointer =
  result = alloc(size)
proc alloc0Impl(r: var MemRegion, size: int): pointer =
  result = alloc0Impl(size)
proc dealloc(r: var MemRegion, p: pointer) = dealloc(p)
proc deallocOsPages(r: var MemRegion) = discard
proc deallocOsPages() = discard

{.pop.}
