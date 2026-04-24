discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test that `ideTraceExpand` produces a .ct file whose Path events
## include the file where the macro is **defined**.
##
## The macro is defined in a separate helper module; the main file only
## calls it. After running traceExpand on the call site, we open the
## resulting .ct with `codetracer_trace_reader` and check that at least
## one Path event points to the helper module (the macro definition file).

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_expand_paths"

# The macro is defined in this helper module.
const helperSource = """
import std/macros

macro myMacro*(x: untyped): untyped =
  result = newStmtList()
  result.add newCall(ident"echo", newLit("expanded"))
"""

# The main file just calls the macro.
const mainSource = """
import macro_helper

myMacro:
  discard
"""

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)

  let helperFile = buildDir / "macro_helper.nim"
  writeFile(helperFile, helperSource)

  let mainFile = buildDir / "test_paths_main.nim"
  writeFile(mainFile, mainSource)

  # The macro call `myMacro:` is on line 3 of mainSource (1-indexed).
  # Prefer nimsuggest_trace (built with -d:codetracerTracing), fall back to nimsuggest
  let nimsuggestTrace = nim.parentDir / "nimsuggest_trace"
  let nimsuggestPlain = nim.parentDir / "nimsuggest"
  let nimsuggestExe =
    if fileExists(nimsuggestTrace): nimsuggestTrace
    elif fileExists(nimsuggestPlain): nimsuggestPlain
    else:
      removeDir(buildDir)
      echo "SKIP: no nimsuggest binary found at ", nimsuggestTrace, " or ", nimsuggestPlain
      quit(0)
      ""

  let stdinInput = "traceExpand " & mainFile & ":3:0\nquit\n"
  let cmd = nimsuggestExe & " --stdin --v3 " & mainFile
  let (output, exitCode) = execCmdEx(cmd, input = stdinInput)

  doAssert exitCode >= 0 and exitCode < 128,
    "nimsuggest crashed (exit code " & $exitCode & "): " & output

  # Extract the .ct path from nimsuggest output
  var tracePath = ""
  for line in output.splitLines():
    if "macro_trace_" in line and ".ct" in line:
      let parts = line.split('\t')
      for part in parts:
        if "macro_trace_" in part and ".ct" in part:
          tracePath = part.strip().strip(chars = {'"'})
          break
      break

  if tracePath == "":
    # Check if the command was not recognized (feature not compiled in)
    if "unknown command" in output.toLowerAscii():
      echo "SKIP: traceExpand not recognized (needs -d:codetracerTracing)"
      removeDir(buildDir)
      quit(0)
    # If the command was recognized but produced no trace, that's a real failure
    doAssert false,
      "traceExpand produced no trace file for macro call. Output:\n" & output

  doAssert fileExists(tracePath), "trace path reported but file not found: " & tracePath

  # Open and decode the trace
  var readerRes = openTrace(tracePath)
  checkOk readerRes, "failed to open trace: "

  var reader = readerRes.get()
  let eventsRes = reader.readEvents()
  checkOk eventsRes, "failed to read events: "

  # Collect all Path events
  var pathEvents: seq[string]
  for event in reader.events:
    if event.kind == tlePath:
      pathEvents.add(event.path)

  doAssert pathEvents.len >= 1,
    "expected at least 1 Path event, got: " & $pathEvents.len

  # Verify that at least one path points to the macro definition file
  var foundMacroDef = false
  for p in pathEvents:
    if "macro_helper" in p:
      foundMacroDef = true
      break

  doAssert foundMacroDef,
    "expected a Path event pointing to macro definition file (macro_helper), " &
    "but got: " & pathEvents.join(", ")

  echo "PASS: tvm_trace_expand_paths - found macro definition file in Path events: " &
    pathEvents.join(", ")

  removeDir(buildDir)

main()
