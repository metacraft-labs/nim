## C Source Map generator for CodeTracer — V3 (Source Map V3, M3).
##
## Output format
## -------------
##
## The on-disk sidecar is a Source Map V3 (`.map`) file alongside the
## generated `.c`, e.g. `nimcache/.../@m..@stestprog.nim.c.map`.
## Same wire format Chrome DevTools / Firefox / Nim's own JS backend
## use — so off-the-shelf parsers in Rust, Python, Node, etc. consume
## it directly. The Rust/Python/frontend consumers in CodeTracer call
## a Source Map V3 crate and no longer need to know anything Nim-specific.
##
## Structure of the JSON:
##
##   { "version":         3,
##     "file":            "<basename of the .c>",
##     "sources":         [ <Nim source absolute paths> ],
##     "sourcesContent":  null,
##     "names":           [],
##     "mappings":        "<base64-VLQ-encoded mapping string>" }
##
## The `mappings` string is built incrementally during `emitMappings`.
## Lines in the generated `.c` are separated by `;`; within a line,
## segments are separated by `,`. Each segment is 4 VLQs encoding
##   [ generatedCol_delta, sourceFile_delta, originalLine_delta,
##     originalCol_delta ]
## with `generatedCol` resetting to zero at every `;` and the other
## three accumulating across the whole file.
##
## Storage model (M3)
## ------------------
##
## A compile-time switch `-d:sourcemapStorage=seq|tree` selects between
## two internal storage representations. The public API
## (`SectionStorage`, `getOrCreateStorage`, `storageOf`,
## `addAnnotation`, `mergeAppendStorage`, `mergePrependStorage`,
## `flattenAnnotations`) is uniform across both variants; only the
## internal layout and the merge cost model differ.
##
##   - **seq variant** (M2 baseline): a flat `seq[CSourcemapAnnotation]`
##     per section. Merges rebase offsets and copy entries linearly.
##
##   - **tree variant** (M3 experiment): a ref-tree of chunks. Each
##     chunk is a `ref` object holding its own internal annotations
##     plus references to transferred sub-chunks. Merges are pure
##     pointer copies — no offset rebasing, no annotation copying.
##     A single tree walk at the end of `genModule` produces the same
##     absolute-offset annotation list as the seq variant.
##
## Both variants produce byte-identical Source Map V3 output. The
## storage representation is internal; the JSON contract is fixed.
##
## When `--sourcemap:on` is off, all annotation work is bypassed and
## the merge primitives degenerate to plain string append/prepend —
## byte-identical to the pre-V2 cgen behavior.

import std/[tables, json, algorithm]
when defined(nimPreviewSlimSystem):
  import std/syncio

import lineinfos, options, msgs, cbuilderbase, sourcemap_vlq

const sourcemapStorage* {.strdefine.} = "seq"
  ## Compile-time switch selecting the internal storage representation
  ## for sourcemap annotations. `"seq"` (default) uses a flat side-table
  ## per section with offset-rebasing merges. `"tree"` uses a ref-tree
  ## of chunks with pure-pointer-copy merges. See module docs above.
  ##
  ## Default rationale: on the Nim compiler bootstrap workload (M3
  ## benchmark, n=10 interleaved, `--sourcemap:on --compileOnly` on
  ## `compiler/nim.nim`) the tree variant showed no measurable win over
  ## seq — user-CPU delta was +0.77 ± 1.83 s and peak-RSS delta was
  ## within ± 1.25 MB, both well inside system-noise bounds. The pure-
  ## pointer-copy merge gain is offset by `ref AnnotationNode` heap
  ## allocations per leaf plus the recursive flatten walk at module
  ## end. Seq stays default; `tree` remains opt-in for workloads where
  ## per-merge transfer-heaviness might tip the balance (e.g. very deep
  ## section nesting, or codegen patterns that splice large already-
  ## annotated builders into others repeatedly).

when sourcemapStorage notin ["seq", "tree"]:
  {.fatal: "unknown -d:sourcemapStorage=" & sourcemapStorage &
           " — expected \"seq\" or \"tree\".".}

type
  CSourcemapAnnotation* = tuple[
    startOffset: int,         # byte range start within the section's text
    endOffset: int,           # byte range end (== startOffset for point emits)
    info: TLineInfo,          # Nim position at the start of the range
    endInfo: TLineInfo        # Nim position at the end (kept for future use;
                              # not emitted into V3 output)
  ]

when sourcemapStorage == "seq":
  type
    SectionStorage* = ref object of RootRef
      ## Per-section side table (seq variant). Lives in
      ## `Builder.sourcemapStorage` so it travels with the section
      ## through `mergeAppend`/`mergePrepend`. Offsets are relative to
      ## the start of the owning section's current text buffer; merges
      ## rebase them as the section grows.
      annotations*: seq[CSourcemapAnnotation]

elif sourcemapStorage == "tree":
  type
    AnnotationKind* = enum akLeaf, akChunk

    AnnotationNode* = ref object
      ## A node in the per-section ref-tree. Leaves carry annotation
      ## payloads; chunks carry transferred sub-sections.
      ##
      ## Critically `ref` so that `dstChildren.add srcRootChunk` is a
      ## pointer copy — the children sequence inside `srcRootChunk` is
      ## not copied. This is the M3 win.
      case kind*: AnnotationKind
      of akLeaf:
        offset*: int             # within the containing chunk's text
        startInfo*: TLineInfo
        endInfo*: TLineInfo
        endOffsetDelta*: int     # endOffset - offset (0 for point emits)
      of akChunk:
        length*: int             # text bytes this chunk contributes
        childOffset*: int        # where this chunk attaches in its
                                 # parent's text (root chunk: ignored)
        children*: seq[AnnotationNode]

    SectionStorage* = ref object of RootRef
      ## Per-section side table (tree variant). The `rootChunk` is
      ## always `akChunk` and represents this section's own contributed
      ## text plus its children (leaves and sub-sections).
      rootChunk*: AnnotationNode

  proc newChunk*(): AnnotationNode {.inline.} =
    AnnotationNode(kind: akChunk, length: 0, childOffset: 0,
                   children: @[])

# ---------------------------------------------------------------------------
# SectionStorage helpers — uniform public API across both variants.

proc getOrCreateStorage*(b: var Builder): SectionStorage {.inline.} =
  ## Returns the section's storage, allocating on first use. Only
  ## called from annotation-recording sites, which are themselves gated
  ## on `optSourcemap`.
  if b.sourcemapStorage == nil:
    when sourcemapStorage == "seq":
      b.sourcemapStorage = SectionStorage(annotations: @[])
    elif sourcemapStorage == "tree":
      b.sourcemapStorage = SectionStorage(rootChunk: newChunk())
  result = SectionStorage(b.sourcemapStorage)

proc storageOf*(b: Builder): SectionStorage {.inline.} =
  ## Returns the section's storage or `nil` if none has been allocated.
  if b.sourcemapStorage == nil: nil
  else: SectionStorage(b.sourcemapStorage)

# ---------------------------------------------------------------------------
# Internal recording — variant-specific. Public `recordAt`/`emitAt` in
# cgen_merge.nim delegates here.

proc addPointAnnotation*(storage: SectionStorage; offset: int;
                         info: TLineInfo) {.inline.} =
  ## Record a zero-width annotation at `offset` within the section's
  ## current text. Used by `recordAt` and by `emitAt`/`emitRangeAt`
  ## after appending the content.
  when sourcemapStorage == "seq":
    storage.annotations.add(
      (startOffset: offset,
       endOffset: offset,
       info: info,
       endInfo: info))
  elif sourcemapStorage == "tree":
    storage.rootChunk.children.add AnnotationNode(
      kind: akLeaf, offset: offset, startInfo: info, endInfo: info,
      endOffsetDelta: 0)

proc addRangeAnnotation*(storage: SectionStorage;
                         startOffset, endOffset: int;
                         startInfo, endInfo: TLineInfo) {.inline.} =
  ## Record an annotation spanning `[startOffset, endOffset)` within
  ## the section's current text.
  when sourcemapStorage == "seq":
    storage.annotations.add(
      (startOffset: startOffset,
       endOffset: endOffset,
       info: startInfo,
       endInfo: endInfo))
  elif sourcemapStorage == "tree":
    storage.rootChunk.children.add AnnotationNode(
      kind: akLeaf, offset: startOffset, startInfo: startInfo,
      endInfo: endInfo, endOffsetDelta: endOffset - startOffset)

# ---------------------------------------------------------------------------
# Merge primitives — variant-specific text+annotation splicing.

proc mergeAppendStorage*(srcBuilder, dstBuilder: var Builder;
                         dstTextLen, srcTextLen: int) =
  ## Invoked by `cgen_merge.mergeAppend` after sourcemap activation has
  ## been confirmed. `dstTextLen` is the length of `dst.text` BEFORE
  ## the src text was appended; `srcTextLen` is the length of the src
  ## text being appended. The text-buffer concatenation itself happens
  ## in the caller.
  let srcStorage =
    if srcBuilder.sourcemapStorage == nil: nil
    else: SectionStorage(srcBuilder.sourcemapStorage)
  when sourcemapStorage == "seq":
    if srcStorage != nil and srcStorage.annotations.len > 0:
      let dstStorage = getOrCreateStorage(dstBuilder)
      for ann in srcStorage.annotations:
        dstStorage.annotations.add(
          (startOffset: ann.startOffset + dstTextLen,
           endOffset: ann.endOffset + dstTextLen,
           info: ann.info,
           endInfo: ann.endInfo))
  elif sourcemapStorage == "tree":
    if srcStorage != nil and srcStorage.rootChunk != nil and
        (srcStorage.rootChunk.children.len > 0 or
         srcStorage.rootChunk.length > 0):
      let dstStorage = getOrCreateStorage(dstBuilder)
      # Pure pointer copy: append src's root chunk under dst's root.
      # The src chunk's `children` seq is NOT copied — `add` takes the
      # ref and stores it. This is the M3 win.
      srcStorage.rootChunk.childOffset = dstTextLen
      # `length` is the authoritative width of the text this chunk
      # contributes to its parent. Always set it from the caller's
      # `srcTextLen` (= src.text[].len at merge time) — that's the
      # ground truth, regardless of any earlier merges into src.
      srcStorage.rootChunk.length = srcTextLen
      dstStorage.rootChunk.children.add srcStorage.rootChunk
      # Reset src so it can be reused as an empty section. (Matches
      # the M2 seq variant which similarly does not clear `src`.)
      srcStorage.rootChunk = newChunk()
      # Update dst's chunk length to reflect the added text:
      dstStorage.rootChunk.length += srcTextLen
    elif dstBuilder.sourcemapStorage != nil:
      # No src content, but dst already has storage — still bump its
      # length so future appends position correctly.
      let dstStorage = SectionStorage(dstBuilder.sourcemapStorage)
      dstStorage.rootChunk.length += srcTextLen
    # If neither has storage yet, defer allocation until something is
    # recorded — keeps the no-sourcemap fast path zero-overhead.

proc mergePrependStorage*(srcBuilder, dstBuilder: var Builder;
                          srcTextLen: int) =
  ## Invoked by `cgen_merge.mergePrepend`. `srcTextLen` is the length
  ## of src's text being prepended onto dst.
  let srcStorage =
    if srcBuilder.sourcemapStorage == nil: nil
    else: SectionStorage(srcBuilder.sourcemapStorage)
  when sourcemapStorage == "seq":
    let dstStorage =
      if dstBuilder.sourcemapStorage == nil: nil
      else: SectionStorage(dstBuilder.sourcemapStorage)
    if dstStorage != nil:
      for ann in dstStorage.annotations.mitems:
        ann.startOffset += srcTextLen
        ann.endOffset += srcTextLen
    if srcStorage != nil and srcStorage.annotations.len > 0:
      let dst2 = getOrCreateStorage(dstBuilder)
      var newAnns = newSeqOfCap[CSourcemapAnnotation](
        srcStorage.annotations.len + dst2.annotations.len)
      for ann in srcStorage.annotations:
        newAnns.add ann
      for ann in dst2.annotations:
        newAnns.add ann
      dst2.annotations = newAnns
  elif sourcemapStorage == "tree":
    # Shift existing dst children forward by srcTextLen.
    let dstStorage =
      if dstBuilder.sourcemapStorage == nil: nil
      else: SectionStorage(dstBuilder.sourcemapStorage)
    if dstStorage != nil and dstStorage.rootChunk != nil:
      for child in dstStorage.rootChunk.children.mitems:
        if child.kind == akChunk:
          child.childOffset += srcTextLen
        else:
          child.offset += srcTextLen
    if srcStorage != nil and srcStorage.rootChunk != nil and
        (srcStorage.rootChunk.children.len > 0 or
         srcStorage.rootChunk.length > 0):
      let dst2 = getOrCreateStorage(dstBuilder)
      # `length` is the authoritative width of src's text; set it from
      # the caller's `srcTextLen` (= src.text[].len at merge time).
      srcStorage.rootChunk.length = srcTextLen
      srcStorage.rootChunk.childOffset = 0
      dst2.rootChunk.children.insert(srcStorage.rootChunk, 0)
      srcStorage.rootChunk = newChunk()
      dst2.rootChunk.length += srcTextLen
    elif dstStorage != nil:
      dstStorage.rootChunk.length += srcTextLen

# ---------------------------------------------------------------------------
# Flatten — turn a SectionStorage into the absolute-offset seq that
# `resolveAnnotations` consumes. Uniform call site in `cgen.nim`.

when sourcemapStorage == "tree":
  proc walkChunk(node: AnnotationNode; baseOffset: int;
                 output: var seq[CSourcemapAnnotation]) =
    case node.kind
    of akLeaf:
      let abs = baseOffset + node.offset
      output.add(
        (startOffset: abs,
         endOffset: abs + node.endOffsetDelta,
         info: node.startInfo,
         endInfo: node.endInfo))
    of akChunk:
      let chunkBase = baseOffset + node.childOffset
      for child in node.children:
        walkChunk(child, chunkBase, output)

proc flattenAnnotations*(storage: SectionStorage): seq[CSourcemapAnnotation] =
  ## Produce the final absolute-offset annotation list for a fully
  ## merged section. Called once per module by `cgen.genModule` after
  ## all per-section merges have settled. The output is the same shape
  ## under both storage variants — that's the M3 invariant.
  ##
  ## **M6 Part C — dedup pass.** M5's per-expression `recordAt`
  ## produces an annotation for every `expr()` visit, so deeply nested
  ## expressions and macro/template expansions (bridged back via
  ## `bridgeExpansionInfo`) can record many annotations at the same
  ## `(startOffset, line, col, fileIndex)`. We drop any annotation
  ## matching the immediately-preceding one on those four keys.
  ##
  ## Note: the spec hypothesized that V3 segments coalesce on identical
  ## positions downstream so `.c.map` output would be byte-identical
  ## pre/post dedup. Empirically that is not the case — `resolveAnnotations`
  ## emits one V3 segment per `CSourcemapAnnotation`, and the duplicates
  ## become redundant zero-delta segments in the `mappings` string.
  ## Removing them changes the byte-level representation but preserves
  ## the logical `(gLine, gCol) → (oLine, oCol)` mapping set — a V3
  ## decoder yields the same coverage either way. All sourcemap tests
  ## pass; only segment counters drop (`tc_sourcemap`: 281 → 155).
  result = @[]
  if storage == nil: return
  var raw: seq[CSourcemapAnnotation]
  when sourcemapStorage == "seq":
    raw = storage.annotations
  elif sourcemapStorage == "tree":
    if storage.rootChunk == nil: return
    if storage.rootChunk.children.len == 0: return
    # The root chunk's `childOffset` is meaningless at the top level
    # (no parent). Walk its children with baseOffset = 0.
    raw = @[]
    for child in storage.rootChunk.children:
      walkChunk(child, 0, raw)
  if raw.len == 0: return
  result = newSeqOfCap[CSourcemapAnnotation](raw.len)
  result.add raw[0]
  for i in 1 ..< raw.len:
    let prev = result[^1]
    let cur = raw[i]
    if cur.startOffset == prev.startOffset and
       cur.info.line == prev.info.line and
       cur.info.col == prev.info.col and
       cur.info.fileIndex == prev.info.fileIndex:
      continue
    result.add cur

# ---------------------------------------------------------------------------
# V3Sourcemap building

type
  V3Sourcemap* = ref object
    ## In-memory representation of a single `.c`'s `.map` sidecar.
    file*: string              # basename of the .c
    sources*: seq[string]      # Nim source absolute paths
    sourceIndex*: Table[string, int]
    mappings*: string          # built incrementally during `emitMappings`
    ## Names array is always empty for the C backend — we never refer
    ## to an "identifier" in the V3 sense (the V3 `names` array is for
    ## minified-JS identifier-renaming, not relevant here).

proc newV3Sourcemap*(file: string): V3Sourcemap =
  V3Sourcemap(
    file: file,
    sources: @[],
    sourceIndex: initTable[string, int](),
    mappings: ""
  )

proc sourceIdx*(sm: V3Sourcemap; path: string): int =
  ## Return the V3 `sources` index for `path`, allocating it on first
  ## encounter. The index is what appears in segments' second VLQ.
  if path in sm.sourceIndex:
    return sm.sourceIndex[path]
  result = sm.sources.len
  sm.sources.add(path)
  sm.sourceIndex[path] = result

type
  ResolvedAnnotation* = tuple[
    genLine: int,         # 0-based — Source Map V3 generated-line index
    genCol: int,          # 0-based generated column
    sourceIdx: int,       # V3 sources[] index
    origLine: int,        # 0-based Nim line
    origCol: int          # 0-based Nim col
  ]

proc resolveAnnotations*(sm: V3Sourcemap;
                         code: string;
                         absStartOffsets: seq[int];
                         anns: seq[CSourcemapAnnotation];
                         conf: ConfigRef): seq[ResolvedAnnotation] =
  ## Walk `code` once, computing (line, col) for every annotation's
  ## start offset. `absStartOffsets[i]` is the absolute byte offset
  ## of annotation `anns[i]` in `code`. Returns a list with each
  ## annotation resolved and its source-file index registered in `sm`.
  ##
  ## Annotations with invalid file index or non-positive line are
  ## silently dropped.
  result = @[]
  if anns.len == 0: return

  # Sort annotation indices by absolute offset so we can do a single
  # pass over `code` updating a (line, col) cursor.
  var order = newSeq[int](anns.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc(a, b: int): int = cmp(absStartOffsets[a], absStartOffsets[b]))

  var line = 0          # 0-based
  var col = 0           # 0-based
  var pos = 0           # byte cursor in `code`
  for k in 0 ..< order.len:
    let i = order[k]
    let target = absStartOffsets[i]
    while pos < target and pos < code.len:
      if code[pos] == '\n':
        inc line
        col = 0
      else:
        inc col
      inc pos
    let ann = anns[i]
    if ann.info.fileIndex == InvalidFileIdx: continue
    let origLine = int(ann.info.line) - 1   # V3 lines are 0-based
    if origLine < 0: continue
    let origCol = int(ann.info.col)
    let nimPath =
      try: toFullPath(conf, ann.info.fileIndex)
      except: ""
    if nimPath.len == 0: continue
    let srcIdx = sm.sourceIdx(nimPath)
    result.add (
      genLine: line,
      genCol: col,
      sourceIdx: srcIdx,
      origLine: origLine,
      origCol: origCol
    )

proc emitMappings*(sm: V3Sourcemap; resolved: var seq[ResolvedAnnotation]) =
  ## Render `resolved` as a Source Map V3 `mappings` string and append
  ## it to `sm.mappings`. Sorts by (genLine, genCol) ASC and emits the
  ## segments with the right relative-delta encoding.
  ##
  ## V3 deltas are accumulated across the whole file for `sourceIdx`,
  ## `origLine`, `origCol`; `genCol` resets at every line boundary.
  if resolved.len == 0:
    return

  resolved.sort(proc(a, b: ResolvedAnnotation): int =
    result = cmp(a.genLine, b.genLine)
    if result == 0: result = cmp(a.genCol, b.genCol))

  # Running state across the whole file:
  var prevSourceIdx = 0
  var prevOrigLine = 0
  var prevOrigCol = 0
  # Per-line state (reset at each ;):
  var curLine = 0
  var prevGenCol = 0
  # The mappings field must contain a `;` for every generated line
  # before the first segment's line, so the line numbers line up.
  # We don't emit any `;` until we have to.

  for ann in resolved:
    # Catch up the `;` separators to reach ann.genLine
    while curLine < ann.genLine:
      sm.mappings.add(';')
      inc curLine
      prevGenCol = 0
    # If we've emitted at least one segment on this line, prepend `,`
    if sm.mappings.len > 0 and
       not (sm.mappings[^1] == ';' or sm.mappings.len == 0):
      # Check if any prior char on the current line — i.e. the last
      # char in `mappings` is not `;` and we are on a non-zero column
      # OR the last char is a VLQ digit, meaning a segment was emitted
      # on this line already.
      if sm.mappings[^1] != ';':
        sm.mappings.add(',')
    sm.mappings.add encodeSegment(
      ann.genCol - prevGenCol,
      ann.sourceIdx - prevSourceIdx,
      ann.origLine - prevOrigLine,
      ann.origCol - prevOrigCol
    )
    prevGenCol = ann.genCol
    prevSourceIdx = ann.sourceIdx
    prevOrigLine = ann.origLine
    prevOrigCol = ann.origCol

# ---------------------------------------------------------------------------
# Serialization / disk write

proc serialize*(sm: V3Sourcemap): string =
  var sourcesArr = newJArray()
  for s in sm.sources: sourcesArr.add(%s)
  let node = %* {
    "version": 3,
    "file": sm.file,
    "sources": sourcesArr,
    "sourcesContent": newJNull(),
    "names": newJArray(),
    "mappings": sm.mappings
  }
  result = pretty(node)

proc writeMapTo*(sm: V3Sourcemap; cFilePath: string) =
  ## Write `<cFilePath>.map` to disk.
  writeFile(cFilePath & ".map", sm.serialize())
