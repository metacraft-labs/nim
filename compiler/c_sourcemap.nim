## C Source Map Generator for CodeTracer — V3 (side-table)
##
## V3 design vs V2:
##
## V2 used in-band markers (`"\14@CTSM\31<idx>\15"`) injected into
## section buffers at emit time, then scanned + stripped from the
## final concatenated C code. The marker bytes never reached disk but
## did incur a post-codegen text scan.
##
## V3 stores annotations entirely out-of-band: each section has a
## parallel `SectionStorage` (`seq[CSourcemapAnnotation]`). Each
## annotation carries the byte offsets within the section where the
## C content for the Nim node lives, plus the start/end Nim line
## info. When `mergeAppend` / `mergePrepend` move bytes between
## section buffers, the annotation offsets are rebased so they
## always point into the right buffer.
##
## After `genModule` concatenates all sections into the final `res`
## builder, the annotations on `res.storage` describe the JSON
## sourcemap directly: each annotation's `[startOffset, endOffset)`
## byte range is converted to `(cStartLine, cStartCol, cEndLine,
## cEndCol)` by a single pass over `res.text`.
##
## V3 inherits V1's "no `#line` directives" property — the `.c` file
## on disk contains zero CodeTracer-specific markup. DWARF generated
## by gcc references real C lines, not Nim lines.
##
## The JSON file (`ct_sourcemap_<module>`) keeps V2's shape; the
## `"version"` field is bumped to 3 so consumers can detect the
## storage layer (the on-disk JSON schema is unchanged).

import std/[os, tables, json]
when defined(nimPreviewSlimSystem):
  import std/syncio

import lineinfos, options, msgs

type
  CSourcemapAnnotation* = object
    ## V3 side-table entry. `startOffset` / `endOffset` are byte
    ## offsets within the owning section's text buffer; they are
    ## rebased every time `mergeAppend` / `mergePrepend` moves the
    ## section's bytes into another buffer. After all merges the
    ## offsets are absolute into the final concatenated C source.
    startOffset*, endOffset*: int
    info*: TLineInfo      # Nim file/line/col at the start of the range
    endInfo*: TLineInfo   # Nim file/line/col at the end (== info for
                          # statement-level emits; differs for
                          # expression-level `emitRangeAt` sites)

  CSourcemapEntry* = tuple[
    cPathID: int,
    cStartLine, cStartCol: int,
    cEndLine, cEndCol: int,
    nimStartCol, nimEndCol: int
  ]

  CSourceMap* = ref object
    cSources*: Table[string, int]
    nimSources*: Table[string, int]
    mappings*: seq[TableRef[int, seq[seq[CSourcemapEntry]]]]
    ## For each Nim source (by pathID index), a table mapping Nim line
    ## numbers to groups of consecutive C line ranges.

proc newCSourceMap*(): CSourceMap =
  CSourceMap(
    nimSources: initTable[string, int](),
    cSources: initTable[string, int](),
    mappings: @[]
  )

proc computeLineColIndex(code: string): seq[int] =
  ## Returns a seq where `result[i]` is the byte offset of the start
  ## of line `i+1` in `code`. Used to convert byte offset → (line, col)
  ## by binary search.
  result = @[0]
  for i in 0 ..< code.len:
    if code[i] == '\n':
      result.add(i + 1)

proc offsetToLineCol(code: string; lineStarts: seq[int];
                     offset: int): tuple[line, col: int] =
  ## Convert byte offset `offset` into 1-based (line, col).
  if offset <= 0:
    return (1, 1)
  if offset >= code.len:
    if code.len == 0: return (1, 1)
    let last = lineStarts[^1]
    return (lineStarts.len, offset - last + 1)
  # Binary search for the largest line start <= offset.
  var lo = 0
  var hi = lineStarts.len - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if lineStarts[mid] <= offset:
      lo = mid
    else:
      hi = mid - 1
  result = (lo + 1, offset - lineStarts[lo] + 1)

proc buildSourcemapFromStorage*(
    map: CSourceMap;
    code: string;
    annotations: seq[CSourcemapAnnotation];
    cfile: string;
    conf: ConfigRef) =
  ## V3: walk the final-section's annotation table. Each annotation's
  ## `(startOffset, endOffset)` is already absolute into `code` (it
  ## was rebased every time `mergeAppend`/`mergePrepend` moved the
  ## section bytes between buffers). We translate each pair of byte
  ## offsets into `(cLine, cCol)` and register a JSON mapping entry.
  if cfile notin map.cSources:
    map.cSources[cfile] = map.cSources.len
  let cPathID = map.cSources[cfile]

  let lineStarts = computeLineColIndex(code)

  # Group tracking: consecutive annotations for the same Nim line
  # share a group (mirrors V1's `seq[seq[Line]]` shape).
  var lastNimPathIdx = -1
  var lastNimLine = -1

  for ann in annotations:
    let nimFi = ann.info.fileIndex.int32
    if nimFi.int < 0: continue
    let nimPath =
      try: toFullPath(conf, ann.info.fileIndex)
      except: ""
    if nimPath.len == 0: continue
    if nimPath notin map.nimSources:
      map.nimSources[nimPath] = map.nimSources.len
      map.mappings.add(newTable[int, seq[seq[CSourcemapEntry]]]())
    let pathIdx = map.nimSources[nimPath]
    let nimLine = int(ann.info.line)
    if nimLine <= 0: continue

    # Skip degenerate offsets (e.g. an empty-content emit where
    # start == end and the C position is at EOF).
    let startOff = max(0, min(ann.startOffset, code.len))
    let endOff = max(startOff, min(ann.endOffset, code.len))
    let (cStartLine, cStartCol) = offsetToLineCol(code, lineStarts, startOff)
    let (cEndLine, cEndCol) = offsetToLineCol(code, lineStarts, endOff)

    if pathIdx != lastNimPathIdx or nimLine != lastNimLine or
        nimLine notin map.mappings[pathIdx]:
      if nimLine notin map.mappings[pathIdx]:
        map.mappings[pathIdx][nimLine] = @[]
      map.mappings[pathIdx][nimLine].add(@[])
      lastNimPathIdx = pathIdx
      lastNimLine = nimLine
    let entry: CSourcemapEntry = (
      cPathID: cPathID,
      cStartLine: cStartLine,
      cStartCol: cStartCol,
      cEndLine: cEndLine,
      cEndCol: cEndCol,
      nimStartCol: int(ann.info.col),
      nimEndCol: int(ann.endInfo.col)
    )
    map.mappings[pathIdx][nimLine][^1].add(entry)

proc serializeEntry(e: CSourcemapEntry): JsonNode =
  result = newJArray()
  result.add(%e.cPathID)
  result.add(%e.cStartLine)
  result.add(%e.cStartCol)
  result.add(%e.cEndLine)
  result.add(%e.cEndCol)
  result.add(%e.nimStartCol)
  result.add(%e.nimEndCol)

proc serializePathMap(pathMap: TableRef[int, seq[seq[CSourcemapEntry]]]): JsonNode =
  result = newJObject()
  for nimLine, groups in pathMap:
    var groupsJson = newJArray()
    for group in groups:
      var groupJson = newJArray()
      for entry in group:
        groupJson.add(serializeEntry(entry))
      groupsJson.add(groupJson)
    result[$nimLine] = groupsJson

proc serialize*(map: CSourceMap): string =
  var mappingsJson = newJArray()
  for pathMap in map.mappings:
    mappingsJson.add(serializePathMap(pathMap))
  let jsonNode = %*{
    "version": 3,
    "nimSources": %map.nimSources,
    "cSources": %map.cSources,
    "mappings": mappingsJson
  }
  return pretty(jsonNode)

proc writeSourceMap*(map: CSourceMap, outDir: string, outFileName: string) =
  let path = outDir / "ct_sourcemap_" & outFileName
  writeFile(path, map.serialize())
