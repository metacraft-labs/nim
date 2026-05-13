## C source-map V3 — M1: `SectionRef` + `mergeAppend` / `mergePrepend`
##
## This module provides a tiny abstraction layer over the open-coded
## `extract(src) + dst.add(...)` / `extract(src) + dst.prepend(...)`
## patterns scattered across `cgen.nim`.
##
## At M1 (this milestone) the abstraction is **pure refactoring** —
## V2's in-band marker design (see `c_sourcemap.nim`) keeps working
## unchanged. Markers are still emitted into the section's text buffer
## by `emitSourcemapMarker`, and they are still scanned + stripped by
## `stripMarkersAndCollect` after `genModule` concatenates everything.
##
## The reason the refactor is observable-change-free even with the
## marker design is: markers live as plain ASCII control bytes IN the
## section buffer, so any operation that moves the buffer's bytes
## (i.e. our `mergeAppend` / `mergePrepend`) carries the markers along
## for free. There is no separate annotation table to keep in sync.
##
## At M2 the storage will move from in-band markers to a per-section
## `seq[CSourcemapAnnotation]`. The change is fully contained in the
## bodies of `mergeAppend` / `mergePrepend` plus the `*Section`
## constructors — no call-site churn.

import cbuilderbase, cgendata

type
  SectionRef* = object
    ## A pointer into a section's text buffer. At M1 the only field is
    ## `text`; `annotationsOpaque` is reserved for M2's per-section
    ## storage handle (kept as a placeholder so the M1 surface area
    ## already includes the slot M2 will fill).
    text*: ptr string
    annotationsOpaque*: pointer

proc moduleSection*(m: BModule; sec: TCFileSection): SectionRef =
  ## SectionRef into one of the module's top-level C file sections.
  SectionRef(text: addr m.s[sec].buf, annotationsOpaque: nil)

proc procSection*(p: BProc; sec: TCProcSection): SectionRef =
  ## SectionRef into the current (top-most) block of a BProc.
  ## Mirrors the `p.s(section)` accessor in `cgendata.nim`.
  SectionRef(text: addr p.blocks[^1].sections[sec].buf, annotationsOpaque: nil)

proc blockSection*(b: var TBlock; sec: TCProcSection): SectionRef =
  ## SectionRef into a specific block's section. Used when the caller
  ## needs a non-top block (e.g. `m.initProc.blocks[0]`).
  SectionRef(text: addr b.sections[sec].buf, annotationsOpaque: nil)

proc transientSection*(builder: var Builder): SectionRef =
  ## SectionRef into a locally-scoped builder. Used for the temporary
  ## `generatedProc`, `prc`, `prcBody`, `procs`, `res`, etc. builders
  ## inside `cgen.nim`'s proc-generation procs.
  SectionRef(text: addr builder.buf, annotationsOpaque: nil)

proc mergeAppend*(src, dst: SectionRef) =
  ## Append `src`'s text into `dst`'s text. At M1 this is a plain
  ## string append; embedded V2 markers ride along as ordinary bytes
  ## and their textual order is preserved relative to the rest of the
  ## content.
  ##
  ## NOTE: src is NOT cleared here. The pre-refactor pattern
  ## (`dst.add(extract(src))`) didn't clear src either — `extract`
  ## returns a value copy. Preserving this semantics is what makes
  ## the M1 refactor byte-identical to the pre-refactor cgen output.
  ## M2 will revisit ownership when storage moves to a side table.
  dst.text[].add(src.text[])

proc mergePrepend*(src, dst: SectionRef) =
  ## Insert `src`'s text at the FRONT of `dst`'s text. Markers in src
  ## end up at the front of dst, preserving their textual order. As
  ## with `mergeAppend`, src is not cleared at M1 — the (currently
  ## dead) call site in cgen.nim that motivated this primitive used
  ## the rope-level `prepend(a, b)` (= `a = b & a`), which doesn't
  ## clear `b` either.
  let srcText = src.text[]
  dst.text[] = srcText & dst.text[]
