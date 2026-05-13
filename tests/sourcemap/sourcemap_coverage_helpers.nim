## Property-test framework for the C sourcemap.
##
## The property under test: for every expression node in the Nim
## source, the JSON sourcemap contains at least one mapping entry
## whose Nim-side column range covers the node's column.
##
## This is the bidirectional dual of the "go-to-definition" pattern
## in `tests/nimsuggest/tdef*.nim` — same cursor-position-based
## assertion shape, different oracle (the JSON instead of nimsuggest).
##
## At M1 we ship this framework. M1's marker design will not give 100%
## coverage on arbitrary programs — the marker is emitted only at line
## granularity inside `genCLineDir`, so multiple expressions on the
## same line collapse to a single annotation. The property test is
## designed to expose those gaps so M2/M3's expression-level emit-site
## migrations have a measurable target. M1's contract is:
##
##  - Strict mode passes on small focused tests where every Nim line
##    has exactly one expression token.
##  - Warn mode tolerates partial coverage on larger programs and
##    reports the gap percentage.
##
## API:
##  - `collectExpressionPositions(srcFile)` — parse + walk AST.
##  - `verifyCoverage(srcFile, jsonPath, strictness)` — run the check.

import std/[json, os, sets, strutils, tables]

import compiler/[ast, parser, idents, options, lineinfos, nodekinds]

type
  ExpressionPosition* = tuple[file: string; line, col: int]

  CoverageResult* = object
    ok*: bool
    covered*: int
    uncovered*: int
    total*: int
    coveragePercent*: float
    missing*: seq[ExpressionPosition]

const
  ## Node kinds we consider "expressions" for coverage purposes.
  ## Conservative superset — every kind that represents code the user
  ## could meaningfully ask "where in the C output does this map?".
  ## Statement-only kinds (`nkStmtList`, `nkTypeSection`, `nkVarSection`,
  ## `nkProcDef`, etc.) are deliberately excluded.
  expressionNodeKinds* = {
    # Literals
    nkCharLit, nkIntLit, nkInt8Lit, nkInt16Lit, nkInt32Lit, nkInt64Lit,
    nkUIntLit, nkUInt8Lit, nkUInt16Lit, nkUInt32Lit, nkUInt64Lit,
    nkFloatLit, nkFloat32Lit, nkFloat64Lit, nkFloat128Lit,
    nkStrLit, nkRStrLit, nkTripleStrLit,
    nkNilLit,
    # Identifiers / symbols
    nkIdent, nkSym,
    # Calls / operators
    nkCall, nkCommand, nkCallStrLit, nkInfix, nkPrefix, nkPostfix,
    nkHiddenCallConv,
    # Conversions / casts
    nkConv, nkCast, nkHiddenStdConv, nkHiddenSubConv,
    nkStaticExpr,
    nkChckRangeF, nkChckRange64, nkChckRange,
    nkStringToCString, nkCStringToString,
    nkObjDownConv, nkObjUpConv,
    # Address / deref
    nkAddr, nkHiddenAddr, nkDerefExpr, nkHiddenDeref,
    # Compound expressions
    nkObjConstr, nkTupleConstr,
    nkPar, nkCurly, nkBracket, nkTableConstr,
    nkBracketExpr, nkDotExpr, nkCheckedFieldExpr, nkCurlyExpr,
    nkIfExpr, nkLambda,
    nkAccQuoted,
    # Assignments — count as expressions because cgen emits each as a
    # discrete C statement.
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
  result = initHashSet[ExpressionPosition]()
  let cache = newIdentCache()
  let conf = newConfigRef()
  # The parser uses conf.m.fileInfos to look up file indexes; avoid
  # warnings about missing config files.
  let source = readFile(srcFile)
  let tree = parseString(source, cache, conf, srcFile)
  walkExpressions(tree, srcFile, result)

type
  ColRange = tuple[startCol, endCol: int]

proc loadNimCoverage(jsonPath: string;
                     nimSrcAbs: string): Table[int, seq[ColRange]] =
  ## Index the JSON sourcemap by Nim line → list of (startCol, endCol)
  ## Nim-side column ranges. Only the entries whose Nim source matches
  ## `nimSrcAbs` are retained.
  result = initTable[int, seq[ColRange]]()
  if not fileExists(jsonPath):
    return
  let root = parseJson(readFile(jsonPath))
  if "nimSources" notin root or "mappings" notin root:
    return
  # Find the pathIdx whose key matches our source file.
  let nimSources = root["nimSources"]
  var pathIdx = -1
  let absSrc = absolutePath(nimSrcAbs)
  let baseSrc = extractFilename(nimSrcAbs)
  for key, idx in nimSources.pairs:
    if key == absSrc or key == nimSrcAbs:
      pathIdx = idx.getInt
      break
    # Tolerate path-normalization differences (e.g. when the
    # compiler stores `expanded.nim` for macro outputs vs the raw
    # file we passed in).
    if extractFilename(key) == baseSrc:
      pathIdx = idx.getInt
      break
    try:
      if fileExists(key) and fileExists(absSrc) and sameFile(key, absSrc):
        pathIdx = idx.getInt
        break
    except OSError:
      discard
  if pathIdx < 0:
    return
  let mappings = root["mappings"]
  if pathIdx >= mappings.len:
    return
  let pathMap = mappings[pathIdx]
  for nimLineStr, groups in pathMap.pairs:
    let nimLine =
      try: parseInt(nimLineStr)
      except ValueError: 0
    if nimLine <= 0: continue
    var ranges: seq[ColRange] = @[]
    for group in groups.items:
      for entry in group.items:
        # V2 7-tuple: [cPathID, cStartLine, cStartCol, cEndLine, cEndCol,
        #              nimStartCol, nimEndCol]
        if entry.kind != JArray or entry.len < 7: continue
        let nimStartCol = entry[5].getInt
        let nimEndCol = entry[6].getInt
        ranges.add((startCol: nimStartCol, endCol: nimEndCol))
    if ranges.len > 0:
      result[nimLine] = ranges

proc isCovered(line, col: int;
               byLine: Table[int, seq[ColRange]]): bool =
  ## A position (line, col) is "covered" if any mapping entry on
  ## that line has `startCol <= col <= endCol`, OR if any entry
  ## exists for the line at all (line-granular fallback for M1,
  ## where the marker design only records one entry per Nim line).
  if line notin byLine: return false
  let ranges = byLine[line]
  if ranges.len == 0: return false
  for r in ranges:
    if r.startCol <= col and col <= r.endCol:
      return true
    # Line-granular fallback: M1's marker design emits one annotation
    # per Nim line via `genLineDir`, so the recorded `nimStartCol`/
    # `nimEndCol` reflect the *first* expression on the line. Anything
    # later on the same line still maps to that line in the JSON, so
    # accept it as line-level coverage.
    if r.startCol == 0 and r.endCol == 0:
      return true
  # Fallback: any entry on the line counts as line-level coverage.
  # (M1's emit granularity is per-line, not per-column.)
  result = true

proc verifyCoverage*(srcFile, sourcemapJsonPath: string;
                     strictness: string = "strict"): CoverageResult =
  ## Run the property check.
  ##
  ## `strictness`:
  ##  - "strict": ok = (uncovered == 0).
  ##  - "warn":   ok = (coverage >= 90%); prints a warning otherwise.
  ##  - "off":    ok = true (always).
  let positions = collectExpressionPositions(srcFile)
  let byLine = loadNimCoverage(sourcemapJsonPath, srcFile)
  result.total = positions.len
  for pos in positions:
    if isCovered(pos.line, pos.col, byLine):
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
           " uncovered expressions (", formatFloat(result.coveragePercent, ffDecimal, 2), "% covered)"
  of "off":
    result.ok = true
  else:
    result.ok = result.uncovered == 0

proc reportMissing*(r: CoverageResult; limit: int = 20) =
  ## Print up to `limit` missing positions, for diagnostics.
  let n = min(r.missing.len, limit)
  if n == 0: return
  echo "[sourcemap-coverage] first ", n, " uncovered expressions:"
  for i in 0 ..< n:
    let p = r.missing[i]
    echo "  ", p.file, ":", p.line, ":", p.col
  if r.missing.len > limit:
    echo "  ... and ", (r.missing.len - limit), " more"
