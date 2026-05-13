## Property-test framework for the C sourcemap.
##
## Updated for **Source Map V3** output (M2) and refactored at M4 to
## use nimsuggest as the expression-position oracle instead of the
## compiler's parse AST.
##
## The property under test: for every expression in the Nim source,
## the `.map` sidecar contains at least one mapping segment whose
## Nim-side `(origLine, origCol)` matches the expression's position.
## This is the bidirectional dual of the "go-to-definition" pattern
## in `tests/nimsuggest/tdef*.nim` — same cursor-position-based
## assertion shape, different oracle (the V3 mappings instead of
## nimsuggest).
##
## V3 mapping segments use 0-based line and column numbers. nimsuggest
## reports 1-based line and 0-based column (Nim's AST convention). We
## normalize to the V3 convention before checking.
##
## ## M4 — sem-aware denominator
##
## Earlier milestones imported the compiler's AST modules and
## walked the *untyped* parse AST to collect expression positions.
## That over-counted: `static:` blocks, dead `when` branches, `is`-
## checks resolved at sem time, generic procs that never get
## instantiated, and the bodies of templates/macros are all visible
## to the parse AST but contribute zero C bytes — they can never be
## covered by a mapping segment.
##
## At M4 we replace the denominator with what nimsuggest's sem-time
## observer (`SuggestFileSymbolDatabase`) records. We spawn
## `nimsuggest --stdin --v3 <srcFile>`, issue
##   `highlightRange <srcFile>:0:0 100000:0`
## and parse the response. Each suggest row is one occurrence (def or
## use) of a sem-resolved symbol — exactly the set of positions cgen
## could be expected to emit a mapping for, filtered to the symbol
## kinds that actually correspond to expressions.
##
## API:
##  - `collectExpressionPositions(srcFile)` — spawn nimsuggest, parse.
##  - `verifyCoverage(srcFile, mapPath, strictness)` — run the check.

import std/[json, os, osproc, sets, streams, strutils, tables]

type
  ExpressionPosition* = tuple[file: string; line, col: int]
    ## `line` is 1-based, `col` is 0-based — same convention nimsuggest
    ## (and Nim's AST) uses. We translate to V3 internally.

  CoverageResult* = object
    ok*: bool
    covered*: int
    uncovered*: int
    total*: int
    coveragePercent*: float
    missing*: seq[ExpressionPosition]

const
  alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  continuationBit = 1 shl 5
  valueMask = continuationBit - 1

  ## TSymKind values that correspond to expression-producing
  ## occurrences. Definition sites of these symbols (`skVar foo`,
  ## `skProc bar`, ...) and *uses* of them are both real positions in
  ## the source where cgen has a place to attach a mapping.
  ##
  ## Excluded kinds are purely structural — `skType`, `skModule`,
  ## `skMacro`, `skGenericParam`, `skEnumField` (definition site only)
  ## — they don't generate runtime code.
  ##
  ## **M6:** `skField` removed from this set. Field _declarations_
  ## inside `type T = object` emit no runtime code and therefore have
  ## no segment to attach to. Field _uses_ (`obj.x`) are already
  ## counted via M5's per-expression `recordAt` on the base expression
  ## (`obj`), so dropping the field-declaration positions from the
  ## denominator does not lose any covered numerator entries.
  expressionSymKinds* = [
    "skVar", "skLet", "skConst", "skParam", "skResult",
    "skProc", "skFunc", "skMethod", "skIterator", "skConverter",
    "skTemp", "skForVar",
    "skGlobalVar", "skGlobalLet"
  ]

proc findNimsuggestExe(): string =
  ## Locate the `nimsuggest` binary. Strategy:
  ##  1. Look next to the current compiler binary (`bin/nimsuggest`
  ##     under the same parent directory as the running `nim`).
  ##  2. Look up the compiler source root (`nimsuggest/nimsuggest`).
  ##  3. Fall back to `findExe`.
  let nimExe = getCurrentCompilerExe()
  if nimExe.len > 0:
    let binDir = nimExe.parentDir
    let candidate1 = binDir / "nimsuggest"
    if fileExists(candidate1):
      return candidate1
    when defined(windows):
      let candidate1Exe = candidate1 & ".exe"
      if fileExists(candidate1Exe):
        return candidate1Exe
    let candidate2 = binDir.parentDir / "nimsuggest" / "nimsuggest"
    if fileExists(candidate2):
      return candidate2
    when defined(windows):
      let candidate2Exe = candidate2 & ".exe"
      if fileExists(candidate2Exe):
        return candidate2Exe
  let found = findExe("nimsuggest")
  if found.len > 0:
    return found
  raise newException(IOError, "could not locate nimsuggest binary")

proc parseHighlightRangeRow(line: string): tuple[ok: bool, kind: string,
    qualifiedPath: string, nimLine: int, col: int] =
  ## Parse one nimsuggest text-protocol row produced by
  ## `ideHighlightRange`. The row format is the standard suggest line
  ## emitted by `proc \`$\`*(Suggest)` in the nimsuggest pretty-printer:
  ##
  ##   section\tsymkind\tqualifiedPath\tforth\tfilePath\tline\tcol\tdoc[\tquality]
  ##
  ## (where `\t` is a literal tab). The `doc` field is escaped via
  ## Nim's `escape` proc and may itself contain tabs — but those are
  ## *encoded* in the escape, so a naive split on `\t` is safe as long
  ## as we trust the producer not to inject raw tabs.
  let parts = line.split('\t')
  if parts.len < 7:
    return (false, "", "", 0, 0)
  if parts[0] != "highlightRange":
    return (false, "", "", 0, 0)
  var lineNum, colNum: int
  try:
    lineNum = parseInt(parts[5])
    colNum = parseInt(parts[6])
  except ValueError:
    return (false, "", "", 0, 0)
  return (true, parts[1], parts[2], lineNum, colNum)

type
  OutlineRange* = tuple[startLine, startCol, endLine, endCol: int]
    ## A `(start, end)` source-range emitted by `ideOutline` (v3).
    ## All coordinates: line is 1-based, col is 0-based.

proc parseOutlineRow(line: string): tuple[ok: bool, kind: string,
    startLine, startCol, endLine, endCol: int] =
  ## Parse one nimsuggest text-protocol row produced by `ideOutline`
  ## (`--v3`). The row format mirrors `parseHighlightRangeRow` but
  ## carries two extra fields at the tail (added by the v3 outline
  ## path, see `proc \`$\`*(Suggest)` in `compiler/suggest.nim`):
  ##
  ##   section\tsymkind\tqualifiedPath\tforth\tfilePath\tline\tcol\tdoc\tquality\tendLine\tendCol
  ##
  ## We need the symkind (`parts[1]`) plus the four
  ## (line, col, endLine, endCol) positions.
  let parts = line.split('\t')
  if parts.len < 11:
    return (false, "", 0, 0, 0, 0)
  if parts[0] != "outline":
    return (false, "", 0, 0, 0, 0)
  var sLine, sCol, eLine, eCol: int
  try:
    sLine = parseInt(parts[5])
    sCol = parseInt(parts[6])
    eLine = parseInt(parts[9])
    eCol = parseInt(parts[10])
  except ValueError:
    return (false, "", 0, 0, 0, 0)
  return (true, parts[1], sLine, sCol, eLine, eCol)

proc runNimsuggestHighlightRangeAndOutline(srcFile: string): seq[string] =
  ## Spawn `nimsuggest --stdin --v3 <srcFile>`, send a `highlightRange`
  ## command followed by an `outline` command, then `quit`. Return raw
  ## output lines (already split, with EOF marker stripped).
  ##
  ## `highlightRange` yields the denominator (every sem-resolved
  ## occurrence). `outline` is consulted by `collectExpressionPositions`
  ## to subtract template/macro definition-body interiors, which the
  ## test denominator should not include — see the
  ## `OutlineRange`/`skipRanges` plumbing below.
  let exe = findNimsuggestExe()
  # Use the --v3 protocol — that's where both `ideHighlightRange` and
  # the extended `ideOutline` (with endLine/endCol fields) run.
  let p = startProcess(exe,
    args = @["--stdin", "--v3", srcFile],
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let cmd = "highlightRange " & srcFile & ":0:0 100000:0\n" &
            "outline " & srcFile & ":0:0\n" &
            "quit\n"
  p.inputStream.write(cmd)
  p.inputStream.flush()
  p.inputStream.close()
  result = @[]
  let outs = p.outputStream
  while not outs.atEnd:
    let ln = outs.readLine()
    result.add ln
  discard p.waitForExit()

proc inRange(skipRanges: seq[OutlineRange]; line, col: int): bool =
  ## True iff `(line, col)` is strictly inside the *interior* of any
  ## outline range. We include the range start and exclude the range
  ## end so the definition's own identifier position
  ## (`template foo(...) = ...` → the `foo` token at the start line) is
  ## *not* skipped — only the body interior.
  ##
  ## "Interior" semantics: positions on `startLine` strictly after
  ## `startCol` (i.e. on the same line as the definition header but
  ## past its name) are still considered exterior — they're part of
  ## the signature, not the body. Positions strictly past the header
  ## line are interior up to (but not including) the end line/col.
  for r in skipRanges:
    if line < r.startLine: continue
    if line > r.endLine: continue
    # On the first line: positions are part of the signature, not the
    # body. Don't exclude.
    if line == r.startLine: continue
    # On the last line: nimsuggest's endCol is the column *after* the
    # body, so any col < endCol on endLine is still inside.
    if line == r.endLine and col >= r.endCol: continue
    return true
  return false

proc collectExpressionPositions*(srcFile: string): HashSet[ExpressionPosition] =
  ## Spawn nimsuggest against `srcFile` and collect every
  ## sem-resolved expression's `(file, line, col)` tuple, filtered to
  ## the kinds in `expressionSymKinds`.
  ##
  ## **M6:** also issue an `outline` query to the same subprocess and
  ## use the returned `skTemplate` / `skMacro` ranges to drop
  ## occurrences that fall inside template/macro definition bodies.
  ## Body interiors are non-executable surface — they generate no C
  ## bytes at the body site (call-site expansions are covered via
  ## `bridgeExpansionInfo`).
  ##
  ## Raises `IOError` if nimsuggest produced zero `highlightRange`
  ## rows — that almost always means the subprocess failed to start
  ## the file (e.g. compile error) and would silently turn into a
  ## fake "100% covered, 0 expressions" result downstream.
  result = initHashSet[ExpressionPosition]()
  let lines = runNimsuggestHighlightRangeAndOutline(srcFile)
  let kindSet = block:
    var s = initHashSet[string]()
    for k in expressionSymKinds: s.incl k
    s
  # First pass: collect template/macro body ranges from the outline
  # response. Both responses appear interleaved on stdout from the
  # same subprocess.
  var skipRanges: seq[OutlineRange] = @[]
  for ln in lines:
    if not ln.startsWith("outline"): continue
    let o = parseOutlineRow(ln)
    if not o.ok: continue
    if o.kind != "skTemplate" and o.kind != "skMacro": continue
    if o.endLine < o.startLine: continue
    skipRanges.add((startLine: o.startLine, startCol: o.startCol,
                    endLine: o.endLine, endCol: o.endCol))
  # Second pass: highlightRange rows, with the skipRanges filter.
  var rangeRowCount = 0
  for ln in lines:
    if not ln.startsWith("highlightRange"): continue
    inc rangeRowCount
    let row = parseHighlightRangeRow(ln)
    if not row.ok: continue
    if row.kind notin kindSet: continue
    if row.nimLine <= 0: continue
    # Filter out compile-time magic constants from `system` (e.g.
    # `isMainModule`, `nimVersion`, `defined(...)`). These resolve at
    # sem time and never generate C bytes, so they have no segment to
    # attach to. They appear with `qualifiedPath = system.<name>`.
    if row.kind == "skConst" and row.qualifiedPath.startsWith("system."):
      continue
    # M6: drop occurrences inside template/macro definition bodies.
    if inRange(skipRanges, row.nimLine, row.col): continue
    result.incl((file: srcFile, line: row.nimLine, col: row.col))
  if rangeRowCount == 0:
    raise newException(IOError,
      "nimsuggest returned no highlightRange rows for " & srcFile &
      "; full output (" & $lines.len & " lines):\n" & lines.join("\n"))

proc decodeVLQ(s: string): seq[int] =
  var b64Table: array[128, int]
  for i, c in alphabet: b64Table[c.ord] = i
  var shift = 0
  var value = 0
  for c in s:
    let v = b64Table[c.ord]
    value += (v and valueMask) shl shift
    if (v and continuationBit) != 0:
      shift += 5
      continue
    result.add((value shr 1) * (if (value and 1) != 0: -1 else: 1))
    shift = 0
    value = 0

type
  V3Segment* = tuple[
    genLine, genCol, sourceIdx, origLine, origCol: int
  ]

proc decodeV3Map*(mapPath: string): tuple[
    sources: seq[string],
    segments: seq[V3Segment]] =
  ## Parse a V3 `.map` JSON file and return its `sources` list plus
  ## all decoded segments (with relative deltas resolved to absolute
  ## 0-based coordinates).
  if not fileExists(mapPath):
    return
  let js = parseJson(readFile(mapPath))
  if "sources" notin js or "mappings" notin js:
    return
  for s in js["sources"]:
    result.sources.add(s.getStr)
  let mappings = js["mappings"].getStr
  var src = 0
  var oLine = 0
  var oCol = 0
  var gLine = 0
  for ln in mappings.split(';'):
    var gCol = 0
    for seg in ln.split(','):
      if seg.len == 0: continue
      let v = decodeVLQ(seg)
      if v.len >= 4:
        gCol += v[0]
        src += v[1]
        oLine += v[2]
        oCol += v[3]
        result.segments.add(
          (genLine: gLine, genCol: gCol, sourceIdx: src,
           origLine: oLine, origCol: oCol))
    inc gLine

proc collectAllMaps(mapDir: string;
                    nimSrcAbs: string): tuple[
    nimSrcIdxs: HashSet[int],
    segments: seq[V3Segment]] =
  ## Walk every `.map` file under `mapDir` (which is typically the
  ## nimcache directory of the test build) and aggregate the segments
  ## whose `sourceIdx` resolves to the test's Nim source.
  result.nimSrcIdxs = initHashSet[int]()
  let absSrc =
    try: absolutePath(nimSrcAbs)
    except OSError: nimSrcAbs
  let baseSrc = extractFilename(nimSrcAbs)
  for entry in walkDir(mapDir):
    if not entry.path.endsWith(".c.map"): continue
    let parsed = decodeV3Map(entry.path)
    if parsed.sources.len == 0: continue
    var hits: seq[int] = @[]
    for i, src in parsed.sources:
      if src == absSrc or src == nimSrcAbs:
        hits.add i
        continue
      if extractFilename(src) == baseSrc:
        hits.add i
        continue
      try:
        if fileExists(src) and fileExists(absSrc) and sameFile(src, absSrc):
          hits.add i
      except OSError:
        discard
    if hits.len == 0: continue
    for seg in parsed.segments:
      if seg.sourceIdx in hits:
        result.segments.add seg

type
  CoverageIndex = object
    ## Per-Nim-line set of `origCol` values present in the aggregated
    ## map. M2's emit granularity is mostly per-line (every `genLineDir`
    ## records one segment near the statement's start column), so the
    ## practical coverage check is "is there ANY segment on this Nim
    ## line?". Per-column matching is supported via `byLine[line]`'s
    ## seq when an expression-level emit landed at the exact column.
    byLine: Table[int, seq[int]]

proc buildIndex(segments: seq[V3Segment]): CoverageIndex =
  result.byLine = initTable[int, seq[int]]()
  for s in segments:
    # V3 lines are 0-based; nimsuggest reports 1-based.
    let nimLine = s.origLine + 1
    if nimLine notin result.byLine:
      result.byLine[nimLine] = @[]
    result.byLine[nimLine].add s.origCol

proc isCovered(idx: CoverageIndex; line, col: int): bool =
  ## A position `(line, col)` is covered iff the index has any segment
  ## on the same Nim line. This is line-granular coverage, matching
  ## M2's emit reality (mostly one segment per Nim statement); a more
  ## strict per-column check would require expression-level
  ## migrations at every cgen emit site, which M3 explores.
  if line notin idx.byLine: return false
  result = idx.byLine[line].len > 0

proc verifyCoverage*(srcFile, mapDir: string;
                     strictness: string = "strict"): CoverageResult =
  ## Run the property check.
  ##
  ## `mapDir` is the nimcache directory containing per-`.c` `.map`
  ## sidecars. We aggregate across all `.c.map` files that reference
  ## `srcFile`.
  ##
  ## `strictness`:
  ##  - "strict": ok = (uncovered == 0).
  ##  - "warn":   ok = (coverage >= 90%); prints a warning otherwise.
  ##  - "off":    ok = true (always).
  let positions = collectExpressionPositions(srcFile)
  let collected = collectAllMaps(mapDir, srcFile)
  let idx = buildIndex(collected.segments)
  result.total = positions.len
  for pos in positions:
    if isCovered(idx, pos.line, pos.col):
      inc result.covered
    else:
      inc result.uncovered
      result.missing.add pos
  if result.total > 0:
    result.coveragePercent = result.covered.float / result.total.float * 100.0
  else:
    result.coveragePercent = 100.0
  case strictness
  of "strict":
    result.ok = result.uncovered == 0
  of "warn":
    result.ok = result.coveragePercent >= 90.0
    if result.uncovered > 0:
      echo "[sourcemap-coverage] warning: ", result.uncovered,
           " uncovered expressions (",
           formatFloat(result.coveragePercent, ffDecimal, 2), "% covered)"
  of "off":
    result.ok = true
  else:
    result.ok = result.uncovered == 0

proc reportMissing*(r: CoverageResult; limit: int = 20) =
  let n = min(r.missing.len, limit)
  if n == 0: return
  echo "[sourcemap-coverage] first ", n, " uncovered expressions:"
  for i in 0 ..< n:
    let p = r.missing[i]
    echo "  ", p.file, ":", p.line, ":", p.col
  if r.missing.len > limit:
    echo "  ... and ", (r.missing.len - limit), " more"
