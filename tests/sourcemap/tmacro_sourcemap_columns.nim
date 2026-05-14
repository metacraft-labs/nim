discard """
  action: "run"
  targets: "c"
  matrix: "--gc:refc; --gc:orc"
"""

## §2-M1: verify the macro_sourcemap JSON gains column-level
## position metadata. The renderer must record an entry in the new
## `expressionLocations` table for each sub-expression inside a
## macro/template expansion so the GUI can highlight which
## sub-expression the program counter is currently at.

import std/[os, json, strutils, osproc, sequtils, sets, tables, assertions]
import std/compilesettings

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tmacro_sourcemap_columns"

# A program whose macro expansion produces a multi-sub-expression
# line. `doAssert a + 5 == 47` expands to a call carrying
# `a + 5 == 47` as a sub-expression tree, which the renderer
# should record column entries for.
const testProgram = """
import std/[strutils, assertions]
proc main() =
  let a = 42
  doAssert a + 5 == 47
  doAssert "hello".toUpperAscii() == "HELLO"
main()
"""

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_macro_cols.nim"
  let outFile = buildDir / "test_macro_cols"

  createDir(buildDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --hints:off -o:" & outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # macro_sourcemap_*.json lives next to the output binary
  var macroSourcemapFile = ""
  for f in walkDir(buildDir):
    let name = f.path.extractFilename
    if name.startsWith("macro_sourcemap_") and name.endsWith(".json"):
      macroSourcemapFile = f.path
      break
  doAssert macroSourcemapFile.len > 0,
    "macro_sourcemap_*.json not found in " & buildDir

  let js = parseJson(readFile(macroSourcemapFile))

  # §2-M1: schema marker
  doAssert js.hasKey("schema"), "missing top-level schema field"
  doAssert js["schema"].getInt == 2,
    "expected schema=2, got " & $js["schema"]

  # §2-M1: site / definition objects carry file/line/col
  doAssert js.hasKey("expansions") and js["expansions"].kind == JArray
  doAssert js["expansions"].len > 0, "expected at least one expansion"
  for exp in js["expansions"]:
    let site = exp["site"]
    doAssert site.kind == JObject and site.hasKey("file") and
             site.hasKey("line") and site.hasKey("col"),
      "expansion 'site' should be a {file,line,col} object, got " & $site
    let definition = exp["definition"]
    doAssert definition.kind == JObject and definition.hasKey("file") and
             definition.hasKey("line") and definition.hasKey("col"),
      "expansion 'definition' should be a {file,line,col} object, got " & $definition

  # §2-M1: locations entries carry siteCol / entryExpandedCol
  doAssert js.hasKey("locations") and js["locations"].kind == JObject
  for k, ei in js["locations"].pairs:
    doAssert ei.hasKey("siteFile") and ei.hasKey("siteLine") and
             ei.hasKey("siteCol"),
      "location " & k & " missing siteFile/siteLine/siteCol: " & $ei
    doAssert ei.hasKey("entryExpandedLine") and ei.hasKey("entryExpandedCol"),
      "location " & k & " missing entryExpandedLine/entryExpandedCol: " & $ei

  # §2-M1: expressionLocations exists, has entries, and at least one
  # expansion line has ≥5 distinct columns
  doAssert js.hasKey("expressionLocations"),
    "missing top-level expressionLocations field"
  let exprLocs = js["expressionLocations"]
  doAssert exprLocs.kind == JObject
  doAssert exprLocs.len > 0,
    "expected at least one expressionLocations entry"

  # group keys by line
  var perLine: Table[int, HashSet[int]]
  for k, ei in exprLocs.pairs:
    let parts = k.split(':')
    doAssert parts.len == 2,
      "expressionLocations key must be 'line:col', got " & k
    let lineN = parseInt(parts[0])
    let colN = parseInt(parts[1])
    if not perLine.hasKey(lineN):
      perLine[lineN] = initHashSet[int]()
    perLine[lineN].incl(colN)
    # site should be a real file string (matches what test program supplies)
    doAssert ei["siteFile"].getStr.len > 0,
      "expressionLocations[" & k & "].siteFile must not be empty"

  var maxLine = -1
  var maxCols = 0
  for line, cols in perLine.pairs:
    if cols.len > maxCols:
      maxCols = cols.len
      maxLine = line

  doAssert maxCols >= 5,
    "expected >= 5 distinct columns on at least one expansion line; " &
    "max was " & $maxCols & " on line " & $maxLine

  echo "[§2-M1-test] ", exprLocs.len,
       " expressionLocations entries, ", maxCols,
       " distinct columns on line ", maxLine

  removeDir(buildDir)

main()
