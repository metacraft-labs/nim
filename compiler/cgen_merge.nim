## C source-map V3 — M2: `SectionRef` + offset-rebasing
## `mergeAppend` / `mergePrepend` + `emitAt` / `emitRangeAt`.
##
## A `SectionRef` is a tiny abstraction over a section's text buffer.
## It carries:
##   - `text`: pointer to the underlying `string` buffer.
##   - `storage`: the per-section side table of `CSourcemapAnnotation`s
##     (`nil` for transient sections that have never recorded an
##     annotation, which is the common case when `--sourcemap:on` is
##     off — costs nothing).
##   - `config`: the `ConfigRef` needed to gate annotation recording
##     on `optSourcemap` without parameter churn at every call site.
##
## At M1 (predecessor milestone) the only thing this module did was
## provide the abstraction so the V2 in-band-marker design could be
## removed in one place at M2. At M2 (this milestone):
##   - `emitAt` / `emitRangeAt` record annotations directly into the
##     section's side table at the byte offset *inside the section*.
##   - `mergeAppend` rebases src's annotations by `dst.text.len` and
##     splices them onto dst's annotation list, in the right textual
##     order.
##   - `mergePrepend` shifts dst's existing annotations forward by
##     `src.text.len` (because src is being prepended) and puts src's
##     annotations at the front.
##
## When `--sourcemap:on` is off, all annotation work is bypassed and
## the merge primitives degenerate to plain string append/prepend —
## byte-identical to the pre-V2 cgen behavior.

import cbuilderbase, cgendata, c_sourcemap, options, lineinfos

type
  SectionRef* = object
    text*: ptr string             # owning section's text buffer
    builder*: ptr Builder         # owning builder (for lazy storage alloc)
    config*: ConfigRef            # for `optSourcemap` gating; nil = inactive

proc moduleSection*(m: BModule; sec: TCFileSection): SectionRef =
  SectionRef(
    text: addr m.s[sec].buf,
    builder: addr m.s[sec],
    config: m.config
  )

proc procSection*(p: BProc; sec: TCProcSection): SectionRef =
  ## SectionRef into the current (top-most) block of a BProc.
  SectionRef(
    text: addr p.blocks[^1].sections[sec].buf,
    builder: addr p.blocks[^1].sections[sec],
    config: p.module.config
  )

proc blockSection*(b: var TBlock; sec: TCProcSection; m: BModule): SectionRef =
  ## SectionRef into a specific block's section (e.g. a non-top block).
  SectionRef(
    text: addr b.sections[sec].buf,
    builder: addr b.sections[sec],
    config: m.config
  )

proc transientSection*(builder: var Builder): SectionRef =
  ## SectionRef into a locally-scoped builder. The config is left nil:
  ## transient builders are used as the dst of merges, and as the src
  ## of merges of code that was originally emitted into them. Either
  ## way, annotation recording happens at the *original* emit site
  ## (which has a config), and merge primitives only need the storage
  ## ref to be present on the builder.
  SectionRef(
    text: addr builder.buf,
    builder: addr builder,
    config: nil
  )

proc transientSection*(builder: var Builder; m: BModule): SectionRef =
  ## Like `transientSection(builder)` but with the module's config
  ## attached, so direct `emitAt`/`emitRangeAt` into the transient
  ## records annotations when `--sourcemap:on` is in effect.
  SectionRef(
    text: addr builder.buf,
    builder: addr builder,
    config: m.config
  )

# ---------------------------------------------------------------------------
# emitAt / emitRangeAt — record annotation + append content in one call.

proc sourcemapActive(sec: SectionRef): bool {.inline.} =
  sec.config != nil and optSourcemap in sec.config.globalOptions

proc emitAt*(sec: SectionRef; content: string; info: TLineInfo) =
  ## Append `content` to `sec`'s text and, when `--sourcemap:on`, record
  ## an annotation pointing at `info` for the byte range `[start, end)`
  ## of `content` within the section's text.
  if sourcemapActive(sec) and info.fileIndex != InvalidFileIdx and
      info.line > 0'u16:
    let startOff = sec.text[].len
    let storage = getOrCreateStorage(sec.builder[])
    storage.annotations.add(
      (startOffset: startOff,
       endOffset: startOff + content.len,
       info: info,
       endInfo: info))
  sec.text[].add(content)

proc emitRangeAt*(sec: SectionRef; content: string;
                  startInfo, endInfo: TLineInfo) =
  ## Append `content` and record an annotation spanning two distinct
  ## Nim positions (used for expression-level range emits where the
  ## end column matters: e.g. `foo(a, b, c)` start=`foo`, end=`c`).
  if sourcemapActive(sec) and startInfo.fileIndex != InvalidFileIdx and
      startInfo.line > 0'u16:
    let startOff = sec.text[].len
    let storage = getOrCreateStorage(sec.builder[])
    storage.annotations.add(
      (startOffset: startOff,
       endOffset: startOff + content.len,
       info: startInfo,
       endInfo: endInfo))
  sec.text[].add(content)

proc recordAt*(sec: SectionRef; info: TLineInfo) =
  ## Record a zero-width annotation at the current end of `sec.text`,
  ## with no content appended. Used as a replacement for V2's
  ## `genCLineDir` emit sites, where the marker rode in front of
  ## subsequent text not yet generated at that point. The annotation
  ## points at the byte offset where the *next* emitted byte will live.
  if not sourcemapActive(sec): return
  if info.fileIndex == InvalidFileIdx or info.line <= 0'u16: return
  let startOff = sec.text[].len
  let storage = getOrCreateStorage(sec.builder[])
  storage.annotations.add(
    (startOffset: startOff,
     endOffset: startOff,
     info: info,
     endInfo: info))

proc recordRangeAt*(sec: SectionRef; startInfo, endInfo: TLineInfo) =
  ## Like `recordAt` but with a distinct end-of-range Nim position.
  if not sourcemapActive(sec): return
  if startInfo.fileIndex == InvalidFileIdx or
      startInfo.line <= 0'u16: return
  let startOff = sec.text[].len
  let storage = getOrCreateStorage(sec.builder[])
  storage.annotations.add(
    (startOffset: startOff,
     endOffset: startOff,
     info: startInfo,
     endInfo: endInfo))

# ---------------------------------------------------------------------------
# mergeAppend / mergePrepend — text + annotation splicing.

proc mergeAppend*(src, dst: SectionRef) =
  ## Append `src`'s text to `dst`'s text. Annotations in `src` are
  ## rebased by `dst.text.len` (their new origin after splicing) and
  ## appended to `dst`'s annotation seq.
  ##
  ## Annotations are pulled from `src.builder.sourcemapStorage` if
  ## present. `src` is NOT cleared (matching the pre-M1 `extract(src)
  ## + dst.add(...)` semantics — `extract` returned a copy of the
  ## buffer, and the original was either GC-collected with its host
  ## scope or simply not referenced again).
  let baseOffset = dst.text[].len
  let srcStorage =
    if src.builder == nil: nil
    else: storageOf(src.builder[])
  if srcStorage != nil and srcStorage.annotations.len > 0:
    let dstStorage = getOrCreateStorage(dst.builder[])
    for ann in srcStorage.annotations:
      dstStorage.annotations.add(
        (startOffset: ann.startOffset + baseOffset,
         endOffset: ann.endOffset + baseOffset,
         info: ann.info,
         endInfo: ann.endInfo))
  dst.text[].add(src.text[])

proc mergePrepend*(src, dst: SectionRef) =
  ## Prepend `src`'s text to `dst`'s text. Existing annotations in
  ## `dst` are shifted forward by `src.text.len` (their byte origin
  ## moves), then `src`'s annotations are prepended in front.
  ##
  ## Currently no live caller in cgen: kept exported for symmetry
  ## with `mergeAppend` and to document the prepend semantics for
  ## future emit sites that need to splice a fragment at the front
  ## of an existing section (e.g. moving a prelude into a generated
  ## proc body without rebuilding the destination).
  let shift = src.text[].len
  let srcStorage =
    if src.builder == nil: nil
    else: storageOf(src.builder[])
  let dstStorage =
    if dst.builder == nil: nil
    else: storageOf(dst.builder[])
  if dstStorage != nil:
    for ann in dstStorage.annotations.mitems:
      ann.startOffset += shift
      ann.endOffset += shift
  if srcStorage != nil and srcStorage.annotations.len > 0:
    let dst2 = getOrCreateStorage(dst.builder[])
    var newAnns = newSeqOfCap[CSourcemapAnnotation](
      srcStorage.annotations.len + dst2.annotations.len)
    for ann in srcStorage.annotations:
      newAnns.add ann
    for ann in dst2.annotations:
      newAnns.add ann
    dst2.annotations = newAnns
  let srcText = src.text[]
  dst.text[] = srcText & dst.text[]
