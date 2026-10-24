discard """
  action: "run"
  targets: "c"
  matrix: "--gc:orc"
"""

## C Source Map V3 — mappings stay on their lines under line tracing.
##
## With stack traces on (the default of a debug build), the C backend
## first writes each statement's line-trace call as a compact directive
## and only expands it into `nimln_(N);` / `nimlf_(N, "<quoted path>");`
## after the module's code is assembled (`postprocessCode`). The
## sourcemap's annotations are byte offsets into that code. They were
## taken BEFORE the expansion and resolved against the code AFTER it, so
## every mapping behind an `nimlf_` (whose quoted path is far longer than
## the directive it replaces) pointed too early: the Nim lines of a proc
## mapped to generated lines several lines above their code, and a
## debugger that set a breakpoint through the map stopped on the wrong C
## line (in an error branch that never runs, for `return final` below).
##
## This test compiles a small program with line tracing on and checks,
## for each statement line of `calculateSum`, that the map attributes the
## generated line carrying that statement's own `nimln_(N)` call to Nim
## line N. No mocks: the real compiler writes the `.c` and the `.map`.

import std/[os, strutils, osproc, assertions, sets]
import sourcemap_coverage_helpers

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap_line_trace_offsets"

# The statements whose lines are checked. Every one of them is preceded,
# inside `calculateSum`, by the `nimlf_` that names this file (the first
# line-trace call of the proc) and so sits behind at least one expansion.
const testProgram = """
proc calculateSum(a: int, b: int): int =
  let sum = a + b
  let doubled = sum * 2
  let final = doubled + 10
  echo "Sum: ", sum
  echo "Final: ", final
  return final

echo calculateSum(10, 32)
"""

proc lineOf(needle: string): int =
  ## The 1-based line of `needle` in `testProgram`.
  let lines: seq[string] = testProgram.splitLines
  for i, line in lines:
    if needle in line:
      return i + 1
  doAssert false, "no line contains " & needle

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "line_trace_prog.nim"
  let outFile = buildDir / "line_trace_prog"

  removeDir(buildDir)
  createDir(buildDir)
  writeFile(srcFile, testProgram)

  # `--stackTrace:on --lineTrace:on` are a debug build's defaults; spelled
  # out so the test does not depend on them.
  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on --stackTrace:on --lineTrace:on --hints:off -o:" &
    outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  var cFile = ""
  for f in walkDir(nimcache):
    let n = f.path.extractFilename
    if n.endsWith(".nim.c") and "line_trace_prog" in n:
      cFile = f.path
  doAssert cFile.len > 0, "no generated C file for the program in " & nimcache
  let cLines: seq[string] = readFile(cFile).splitLines
  let map = decodeV3Map(cFile & ".map")
  doAssert map.segments.len > 0, "the map of " & cFile & " has no segments"

  var programIdx = -1
  for i, source in map.sources:
    if source.extractFilename == srcFile.extractFilename:
      programIdx = i
  doAssert programIdx >= 0,
    "the map's sources do not name the program: " & $map.sources

  # Positive control: the generated code really carries a file-naming
  # `nimlf_` before the checked statements, so the test exercises the
  # expansion it is about.
  var firstNimlf = -1
  for i, line in cLines:
    if "nimlf_(" in line and srcFile.extractFilename in line:
      firstNimlf = i
      break
  doAssert firstNimlf >= 0,
    "the generated C has no nimlf_ naming the program; line tracing is off?"

  for needle in ["let doubled", "let final", "return final"]:
    let nimLine = lineOf(needle)
    # The generated line that carries this statement's own line-trace
    # call. `nimln_(N);` follows the proc's first `nimlf_`.
    var genLine = -1
    for i, line in cLines:
      if i > firstNimlf and ("nimln_(" & $nimLine & ");") in line:
        genLine = i
        break
    doAssert genLine >= 0,
      "no generated line carries nimln_(" & $nimLine & ") for `" & needle & "`"
    var mapped = initHashSet[int]()
    for seg in map.segments:
      if seg.genLine == genLine and seg.sourceIdx == programIdx:
        mapped.incl seg.origLine + 1
    doAssert nimLine in mapped,
      "`" & needle & "` (Nim line " & $nimLine & ") is generated on C line " &
      $(genLine + 1) & " (" & cLines[genLine].strip & "), but the map " &
      "attributes that line to Nim lines " & $mapped

main()
echo "OK"
