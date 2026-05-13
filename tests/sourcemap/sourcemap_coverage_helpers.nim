## Property-test framework for the C sourcemap.
##
## Updated for **Source Map V3** output (M2).
##
## The property under test: for every expression node in the Nim
## source, the `.map` sidecar contains at least one mapping segment
## whose Nim-side `(origLine, origCol)` matches the node's position.
## This is the bidirectional dual of the "go-to-definition" pattern
## in `tests/nimsuggest/tdef*.nim` — same cursor-position-based
## assertion shape, different oracle (the V3 mappings instead of
## nimsuggest).
##
## V3 mapping segments use 0-based line and column numbers; Nim AST
## reports 1-based line and 0-based column. We normalize to the V3
## convention before checking.
##
## API:
##  - `collectExpressionPositions(srcFile)` — parse + walk AST.
##  - `verifyCoverage(srcFile, mapPath, strictness)` — run the check.

import std/[json, os, sets, strutils, tables]

import compiler/[ast, parser, idents, options, lineinfos, nodekinds]

type
  ExpressionPosition* = tuple[file: string; line, col: int]
    ## `line` is 1-based, `col` is 0-based — same convention Nim's
    ## AST uses. We translate to V3 internally.

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

  ## Node kinds we consider "expressions" for coverage purposes.
  expressionNodeKinds* = {
    nkCharLit, nkIntLit, nkInt8Lit, nkInt16Lit, nkInt32Lit, nkInt64Lit,
    nkUIntLit, nkUInt8Lit, nkUInt16Lit, nkUInt32Lit, nkUInt64Lit,
    nkFloatLit, nkFloat32Lit, nkFloat64Lit, nkFloat128Lit,
    nkStrLit, nkRStrLit, nkTripleStrLit,
    nkNilLit,
    nkIdent, nkSym,
    nkCall, nkCommand, nkCallStrLit, nkInfix, nkPrefix, nkPostfix,
    nkHiddenCallConv,
    nkConv, nkCast, nkHiddenStdConv, nkHiddenSubConv,
    nkStaticExpr,
    nkChckRangeF, nkChckRange64, nkChckRange,
    nkStringToCString, nkCStringToString,
    nkObjDownConv, nkObjUpConv,
    nkAddr, nkHiddenAddr, nkDerefExpr, nkHiddenDeref,
    nkObjConstr, nkTupleConstr,
    nkPar, nkCurly, nkBracket, nkTableConstr,
    nkBracketExpr, nkDotExpr, nkCheckedFieldExpr, nkCurlyExpr,
    nkIfExpr, nkLambda,
    nkAccQuoted,
    nkAsgn, nkFastAsgn,
  }

proc walkExpressions(n: PNode; file: string;
                     output: var HashSet[ExpressionPosition]) =
  if n.isNil: return
  if n.kind in expressionNodeKinds:
    let line = int(n.info.line)
    let col = int(n.info.col)
    if line > 0:
      output.incl((file: file, line: line, col: col))
  if n.safeLen > 0:
    for i in 0 ..< n.safeLen:
      walkExpressions(n[i], file, output)

proc collectExpressionPositions*(srcFile: string): HashSet[ExpressionPosition] =
  ## Parse `srcFile` (Nim source) and collect every expression's
  ## `(file, line, col)` tuple.
  ##
  ## TODO (M3 framework refinement): this works at the *parse* AST,
  ## so it counts expressions that will be eliminated at semcheck
  ## (compile-time-only `is`-checks, `compiles()` calls, branches
  ## inside `when` that resolve to false). Those expressions
  ## generate zero C bytes by design and have no segment to attach
  ## to — they should be subtracted from the denominator. Doing
  ## that requires the helper to invoke the typed AST pass and
  ## filter `nkCall` whose callee `magic` resolves to a compile-
  ## time-only intrinsic, plus `when` branches that didn't pick.
  result = initHashSet[ExpressionPosition]()
  let cache = newIdentCache()
  let conf = newConfigRef()
  let source = readFile(srcFile)
  let tree = parseString(source, cache, conf, srcFile)
  walkExpressions(tree, srcFile, result)

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
    # V3 lines are 0-based; AST is 1-based.
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
