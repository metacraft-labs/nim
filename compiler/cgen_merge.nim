## C source-map V3 — `SectionRef` + storage-agnostic merge/emit
## primitives.
##
## A `SectionRef` is a tiny abstraction over a section's text buffer.
## It carries:
##   - `text`: pointer to the underlying `string` buffer.
##   - `builder`: pointer to the owning `Builder` (for lazy storage
##     allocation and for splicing the storage across merges).
##   - `config`: the `ConfigRef` needed to gate annotation recording
##     on `optSourcemap` without parameter churn at every call site.
##
## At M2 the in-band-marker design was retired in favor of a side
## table on the `Builder`. At M3 the side table comes in two flavors
## selected at compile time via `-d:sourcemapStorage=seq|tree`:
##
##   - **seq** (M2 baseline): merges rebase offsets and copy
##     annotation entries linearly.
##   - **tree** (M3 experiment): merges are pure pointer copies; a
##     single tree walk in `cgen.genModule` produces the same flat
##     annotation list at the end.
##
## Both variants share the same public API. Only the implementation
## modules (`c_sourcemap.nim`) carry the `when sourcemapStorage` gate.
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
    storage.addRangeAnnotation(startOff, startOff + content.len,
                               info, info)
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
    storage.addRangeAnnotation(startOff, startOff + content.len,
                               startInfo, endInfo)
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
  storage.addPointAnnotation(startOff, info)

proc recordRangeAt*(sec: SectionRef; startInfo, endInfo: TLineInfo) =
  ## Like `recordAt` but with a distinct end-of-range Nim position.
  if not sourcemapActive(sec): return
  if startInfo.fileIndex == InvalidFileIdx or
      startInfo.line <= 0'u16: return
  let startOff = sec.text[].len
  let storage = getOrCreateStorage(sec.builder[])
  storage.addRangeAnnotation(startOff, startOff, startInfo, endInfo)

# ---------------------------------------------------------------------------
# mergeAppend / mergePrepend — text + annotation splicing.

proc mergeAppend*(src, dst: SectionRef) =
  ## Append `src`'s text to `dst`'s text. Annotations are spliced via
  ## the storage variant's `mergeAppendStorage` primitive — pure
  ## offset-rebased copies under the seq variant, pure pointer
  ## transfers under the tree variant.
  ##
  ## `src` is NOT cleared (matching the pre-M1 `extract(src) +
  ## dst.add(...)` semantics — `extract` returned a copy of the buffer
  ## and the original was either GC-collected with its host scope or
  ## simply not referenced again).
  let dstLen = dst.text[].len
  let srcLen = src.text[].len
  let active =
    (src.config != nil and optSourcemap in src.config.globalOptions) or
    (dst.config != nil and optSourcemap in dst.config.globalOptions) or
    (src.builder != nil and src.builder[].sourcemapStorage != nil) or
    (dst.builder != nil and dst.builder[].sourcemapStorage != nil)
  if active and src.builder != nil and dst.builder != nil:
    mergeAppendStorage(src.builder[], dst.builder[], dstLen, srcLen)
  dst.text[].add(src.text[])

proc mergePrepend*(src, dst: SectionRef) =
  ## Prepend `src`'s text to `dst`'s text. Annotations are spliced via
  ## the storage variant's `mergePrependStorage` primitive.
  ##
  ## Currently no live caller in cgen: kept exported for symmetry with
  ## `mergeAppend` and to document the prepend semantics for future
  ## emit sites that need to splice a fragment at the front of an
  ## existing section.
  let srcLen = src.text[].len
  let active =
    (src.config != nil and optSourcemap in src.config.globalOptions) or
    (dst.config != nil and optSourcemap in dst.config.globalOptions) or
    (src.builder != nil and src.builder[].sourcemapStorage != nil) or
    (dst.builder != nil and dst.builder[].sourcemapStorage != nil)
  if active and src.builder != nil and dst.builder != nil:
    mergePrependStorage(src.builder[], dst.builder[], srcLen)
  let srcText = src.text[]
  dst.text[] = srcText & dst.text[]
