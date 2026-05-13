## C Source Map generator for CodeTracer — V3 (Source Map V3, M2).
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
## Storage model
## -------------
##
## Each section buffer (`Builder.buf`) carries a `SectionStorage`
## attached via the `sourcemapStorage` field on `Builder`. Storage is
## allocated lazily by `emitAt` / `emitRangeAt` the first time
## annotations are recorded on the section. `mergeAppend` and
## `mergePrepend` (defined in `cgen_merge.nim`) rebase the offsets of
## the source's annotations before splicing them into the destination's
## list.
##
## The on-disk byte layout of the `.c` file is byte-identical to a
## build without `--sourcemap:on` — annotations live exclusively in
## the side table.

import std/[tables, json, algorithm]
when defined(nimPreviewSlimSystem):
  import std/syncio

import lineinfos, options, msgs, cbuilderbase, sourcemap_vlq

type
  CSourcemapAnnotation* = tuple[
    startOffset: int,         # byte range start within the section's text
    endOffset: int,           # byte range end (== startOffset for point emits)
    info: TLineInfo,          # Nim position at the start of the range
    endInfo: TLineInfo        # Nim position at the end (kept for future use;
                              # not emitted into V3 output)
  ]

  SectionStorage* = ref object of RootRef
    ## Per-section side table. Lives in `Builder.sourcemapStorage` so
    ## it travels with the section through `mergeAppend`/`mergePrepend`.
    annotations*: seq[CSourcemapAnnotation]

  V3Sourcemap* = ref object
    ## In-memory representation of a single `.c`'s `.map` sidecar.
    file*: string              # basename of the .c
    sources*: seq[string]      # Nim source absolute paths
    sourceIndex*: Table[string, int]
    mappings*: string          # built incrementally during `emitMappings`
    ## Names array is always empty for the C backend — we never refer
    ## to an "identifier" in the V3 sense (the V3 `names` array is for
    ## minified-JS identifier-renaming, not relevant here).

# ---------------------------------------------------------------------------
# SectionStorage helpers

proc getOrCreateStorage*(b: var Builder): SectionStorage {.inline.} =
  ## Returns the section's storage, allocating on first use. Only
  ## called from `emitAt`/`emitRangeAt`, which are themselves gated
  ## on `optSourcemap`.
  if b.sourcemapStorage == nil:
    b.sourcemapStorage = SectionStorage(annotations: @[])
  result = SectionStorage(b.sourcemapStorage)

proc storageOf*(b: Builder): SectionStorage {.inline.} =
  ## Returns the section's storage or `nil` if none has been allocated.
  if b.sourcemapStorage == nil: nil
  else: SectionStorage(b.sourcemapStorage)

# ---------------------------------------------------------------------------
# V3Sourcemap building

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
