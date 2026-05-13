## C source-map V3 — M2: `SectionRef` + `seq[Annotation]` side-table.
##
## At M2 each section has a parallel `SectionStorage` (a `ref object`
## holding a `seq[CSourcemapAnnotation]`). Annotations are recorded
## with byte offsets into the section's text buffer at emit time
## (`emitAt` / `emitRangeAt`), and `mergeAppend` / `mergePrepend`
## rebase the offsets when section bytes move between buffers.
##
## V2's in-band marker design is gone in M2: nothing ever writes the
## `\14@CTSM\31<idx>\15` byte sequence to a section buffer, so the
## `.c` file on disk is byte-identical to M1's output (M1 markers were
## stripped before write; M2 markers are never written).
##
## The abstraction surface (the four `*Section` constructors plus
## `mergeAppend`/`mergePrepend`) is unchanged from M1 — the only new
## surface is the storage parameter on `transientSection` (which most
## callers pass `nil` for when they don't need annotation tracking on
## that builder).

import options, lineinfos, cbuilderbase, cgendata, c_sourcemap

type
  SectionRef* = object
    ## A pointer into a section's text buffer paired with a handle to
    ## its annotation side-table. `storage` may be `nil` when the
    ## section is a transient builder that does not need annotation
    ## tracking (the emit primitives no-op the side-table update in
    ## that case). `config` lets the emit primitives early-out without
    ## consulting the storage when `--sourcemap:on` is off.
    text*: ptr string
    storage*: SectionStorage
    config*: ConfigRef

proc newSectionStorage*(): SectionStorage =
  SectionStorage(annotations: @[])

proc ensureStorage(m: BModule; sec: TCFileSection): SectionStorage =
  if m.sourcemapStorages[sec] == nil:
    m.sourcemapStorages[sec] = newSectionStorage()
  result = m.sourcemapStorages[sec]

proc ensureStorage(b: var TBlock; sec: TCProcSection): SectionStorage =
  if b.sourcemapStorages[sec] == nil:
    b.sourcemapStorages[sec] = newSectionStorage()
  result = b.sourcemapStorages[sec]

proc moduleSection*(m: BModule; sec: TCFileSection): SectionRef =
  ## SectionRef into one of the module's top-level C file sections.
  let storage =
    if optSourcemap in m.config.globalOptions: ensureStorage(m, sec)
    else: nil
  SectionRef(text: addr m.s[sec].buf, storage: storage, config: m.config)

proc procSection*(p: BProc; sec: TCProcSection): SectionRef =
  ## SectionRef into the current (top-most) block of a BProc.
  ## Mirrors the `p.s(section)` accessor in `cgendata.nim`.
  let storage =
    if optSourcemap in p.module.config.globalOptions:
      ensureStorage(p.blocks[^1], sec)
    else: nil
  SectionRef(text: addr p.blocks[^1].sections[sec].buf,
             storage: storage, config: p.module.config)

proc blockSection*(p: BProc; b: var TBlock; sec: TCProcSection): SectionRef =
  ## SectionRef into a specific block's section. Used when the caller
  ## needs a non-top block (e.g. `m.initProc.blocks[0]`).
  let storage =
    if optSourcemap in p.module.config.globalOptions:
      ensureStorage(b, sec)
    else: nil
  SectionRef(text: addr b.sections[sec].buf,
             storage: storage, config: p.module.config)

proc transientSection*(builder: var Builder; storage: SectionStorage = nil;
                       conf: ConfigRef = nil): SectionRef =
  ## SectionRef into a locally-scoped builder. Used for the temporary
  ## `generatedProc`, `prc`, `prcBody`, `procs`, `res`, etc. builders
  ## inside `cgen.nim`'s proc-generation procs. Callers that need to
  ## record annotations into the transient builder allocate a
  ## per-builder `newSectionStorage()` and pass it as `storage`.
  SectionRef(text: addr builder.buf, storage: storage, config: conf)

proc trackedTransient*(builder: var Builder; conf: ConfigRef): SectionRef =
  ## Convenience: a transient SectionRef with a freshly-allocated
  ## `SectionStorage` so annotations from merges into this builder are
  ## tracked. Caller is responsible for keeping the storage alive (we
  ## allocate it as ref so it lives in `result.storage`).
  let storage =
    if conf != nil and optSourcemap in conf.globalOptions: newSectionStorage()
    else: nil
  SectionRef(text: addr builder.buf, storage: storage, config: conf)

proc mergeAppend*(src, dst: SectionRef) =
  ## Append `src`'s text into `dst`'s text. Annotations from `src` are
  ## translated to absolute offsets in `dst` and appended to
  ## `dst.storage.annotations`.
  ##
  ## NOTE: src is NOT cleared (text or storage). The pre-refactor
  ## pattern (`dst.add(extract(src))`) didn't clear src either —
  ## `extract` returns a value copy. Preserving this semantics is
  ## what keeps both the .c byte output AND the JSON sourcemap stable
  ## across M1 → M2.
  let baseOff = dst.text[].len
  if dst.config != nil and optSourcemap in dst.config.globalOptions and
     src.storage != nil and dst.storage != nil:
    for ann in src.storage.annotations:
      dst.storage.annotations.add(CSourcemapAnnotation(
        startOffset: baseOff + ann.startOffset,
        endOffset: baseOff + ann.endOffset,
        info: ann.info,
        endInfo: ann.endInfo))
  dst.text[].add(src.text[])

proc mergePrepend*(src, dst: SectionRef) =
  ## Insert `src`'s text at the FRONT of `dst`'s text. Existing dst
  ## annotations have their offsets shifted by `src.text.len`, then
  ## src's annotations are inserted at the head of the table.
  let srcLen = src.text[].len
  if dst.config != nil and optSourcemap in dst.config.globalOptions and
     dst.storage != nil:
    for ann in dst.storage.annotations.mitems:
      ann.startOffset += srcLen
      ann.endOffset += srcLen
    if src.storage != nil:
      var combined = newSeqOfCap[CSourcemapAnnotation](
        src.storage.annotations.len + dst.storage.annotations.len)
      for ann in src.storage.annotations:
        combined.add ann
      for ann in dst.storage.annotations:
        combined.add ann
      dst.storage.annotations = combined
  let srcText = src.text[]
  dst.text[] = srcText & dst.text[]

proc emitAt*(sec: SectionRef; content: string; info: TLineInfo) =
  ## V2's `emitSourcemapMarker` replacement: records a side-table
  ## annotation for `content` at the current text offset, then
  ## appends the text. When sourcemap is off or the line info is
  ## missing/invalid, this is a plain `add`.
  if sec.config != nil and optSourcemap in sec.config.globalOptions and
     sec.storage != nil and
     info.fileIndex != InvalidFileIdx and info.line != 0:
    let startOff = sec.text[].len
    sec.storage.annotations.add CSourcemapAnnotation(
      startOffset: startOff,
      endOffset: startOff + content.len,
      info: info,
      endInfo: info)
  sec.text[].add(content)

proc emitRangeAt*(sec: SectionRef; content: string;
                  startInfo, endInfo: TLineInfo) =
  ## V2's `emitSourcemapRangeMarker` replacement: records a range
  ## annotation `(startInfo, endInfo)` for `content`. Used at
  ## expression-level emit sites where the start and end nodes have
  ## distinct Nim positions.
  if sec.config != nil and optSourcemap in sec.config.globalOptions and
     sec.storage != nil and
     startInfo.fileIndex != InvalidFileIdx and startInfo.line != 0:
    let startOff = sec.text[].len
    sec.storage.annotations.add CSourcemapAnnotation(
      startOffset: startOff,
      endOffset: startOff + content.len,
      info: startInfo,
      endInfo: endInfo)
  sec.text[].add(content)

proc markRange*(sec: SectionRef; startOffset, endOffset: int;
                startInfo, endInfo: TLineInfo) =
  ## Records an annotation that spans an already-emitted text range
  ## `[startOffset, endOffset)`. Used by call sites that need to emit
  ## first (via the heavy `cbuilder` API) then annotate after the
  ## fact, e.g. `genLineDir` which now annotates the upcoming
  ## statement's emitted bytes.
  if sec.config != nil and optSourcemap in sec.config.globalOptions and
     sec.storage != nil and
     startInfo.fileIndex != InvalidFileIdx and startInfo.line != 0:
    sec.storage.annotations.add CSourcemapAnnotation(
      startOffset: startOffset,
      endOffset: endOffset,
      info: startInfo,
      endInfo: endInfo)
