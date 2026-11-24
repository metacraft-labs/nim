discard """
  action: "run"
  targets: "c"
  matrix: "--gc:refc; --gc:orc"
"""

## Every statement of a macro expansion keeps its own line in the C
## source map.
##
## Under `--sourcemap:on` the renderer writes each expansion into the
## nimcache's `expanded.nim` and points the expanded nodes there, and cgen
## maps the C of each statement to that line. A debugger reads the `.c.map`
## to place a stop: a C line that maps into `expanded.nim` is shown inside
## the expansion, with the call site as its parent from the macro
## sourcemap, and a C line that maps to the call site cannot be shown
## inside the expansion at all.
##
## `addTwice(counter, 3)` expands to two statements, on two lines of
## `expanded.nim`. The renderer used to register the expansion's statement
## list against the last line it occupied, so cgen's call-site bridge
## (`bridgeExpansionInfo`) claimed the second statement's line and its C
## mapped only to `main.nim`, while the first statement's C mapped to
## `expanded.nim` (codetracer-pm issue
## 2026-11-17-codetracer-nim-maps-a-macro-expansions-later-statements-to-the-call-site.md).
##
## The test compiles a real program with the compiler under test and reads
## the `.c.map` the way codetracer's native replay does
## (codetracer-native-backend `parse_v3_sourcemap`): a C line maps to the
## last segment at or before its first code column, or, without one, to
## the segment still in effect from the lines above. Nothing is mocked.

import std/[os, osproc, strutils, assertions]
import sourcemap_coverage_helpers

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tmacro_sourcemap_expansion_statements"

# codetracer's test-programs/nim_macro_steps/main.nim, where the issue was
# observed. `addTwice` adds `amount` twice, so each of its statements
# lowers to its own `nimAddInt(counter, 3)` / `nimAddInt(counter, 5)` call.
const testProgram = """
import std/macros

macro addTwice(target: untyped; amount: int): untyped =
  result = newStmtList()
  result.add quote do:
    `target` += `amount`
  result.add quote do:
    `target` += `amount`

template logValue(label: string; value: int) =
  echo label, " ", value

proc main() =
  var counter = 0
  addTwice(counter, 3)
  logValue("counter", counter)
  addTwice(counter, 5)
  logValue("counter", counter)

main()
"""

type MappedLine = tuple[source: string, line: int]  # line is 1-based

proc mapCLine(sources: seq[string]; segments: seq[V3Segment];
              cText: seq[string]; cLine: int): MappedLine =
  ## The Nim position a debugger gives C line `cLine` (0-based), by the
  ## rule codetracer-native-backend's `parse_v3_sourcemap` applies.
  let text = cText[cLine]
  let firstCol = text.len - text.strip(trailing = false).len
  result = ("", -1)
  for s in segments:
    if s.genLine < cLine or (s.genLine == cLine and s.genCol <= firstCol):
      result = (sources[s.sourceIdx], s.origLine + 1)

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  removeDir(buildDir)
  createDir(buildDir)
  let src = buildDir / "main.nim"
  writeFile(src, testProgram)
  let cmd = nim & " c --hints:off --sourcemap:on --compileOnly" &
    " --nimcache:" & nimcache & " " & src
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "compilation failed:\n" & output

  let expandedFile = nimcache / "expanded.nim"
  doAssert fileExists(expandedFile), "no expanded.nim in " & nimcache
  let expanded = readFile(expandedFile).splitLines
  # The expansion's statements and where `expanded.nim` holds them.
  var expectedLines: seq[(int, int)] = @[]   # (amount, 1-based line)
  for i, l in expanded:
    if l.strip == "counter += 3": expectedLines.add (3, i + 1)
    if l.strip == "counter += 5": expectedLines.add (5, i + 1)
  doAssert expectedLines.len == 4,
    "expected two statements per addTwice expansion in expanded.nim:\n" &
    expanded.join("\n")

  let cFile = nimcache / "@mmain.nim.c"
  let (sources, segments) = decodeV3Map(cFile & ".map")
  doAssert segments.len > 0, "no segments in " & cFile & ".map"
  let cText = readFile(cFile).splitLines

  # The C of each statement, in program order: the `nimAddInt` call that
  # adds the amount to `counter`.
  var statementCLines: seq[(int, int)] = @[]  # (amount, 0-based C line)
  for i, l in cText:
    for amount in [3, 5]:
      if "nimAddInt(counter_" in l and ", ((NI) " & $amount & ")" in l:
        statementCLines.add (amount, i)
  doAssert statementCLines.len == 4,
    "expected four nimAddInt statements in " & cFile & ", found " &
    $statementCLines.len

  var failures: seq[string] = @[]
  for k in 0 ..< 4:
    let (amount, cLine) = statementCLines[k]
    let (expAmount, expLine) = expectedLines[k]
    doAssert amount == expAmount
    let mapped = mapCLine(sources, segments, cText, cLine)
    if mapped.source.extractFilename != "expanded.nim" or
        mapped.line != expLine:
      failures.add "C line " & $(cLine + 1) & " (statement " & $(k + 1) &
        ", `counter += " & $amount & "`) maps to " &
        mapped.source.extractFilename & ":" & $mapped.line &
        ", expected expanded.nim:" & $expLine
  doAssert failures.len == 0,
    "expansion statements not mapped to their expanded.nim lines:\n  " &
    failures.join("\n  ")

  # A position inside an expansion names a line that holds code: the
  # expansion's statement list starts on its first statement, not on the
  # blank line after the expansion's header comment.
  var blankTargets: seq[string] = @[]
  for s in segments:
    if sources[s.sourceIdx].extractFilename == "expanded.nim":
      let target = s.origLine   # 0-based
      if target >= expanded.len or expanded[target].strip.len == 0:
        blankTargets.add "C line " & $(s.genLine + 1) & " col " & $s.genCol &
          " -> expanded.nim:" & $(target + 1)
  doAssert blankTargets.len == 0,
    "segments map to blank expanded.nim lines:\n  " & blankTargets.join("\n  ")

  removeDir(buildDir)
  echo "macro expansion statements map to their expanded.nim lines"

main()
