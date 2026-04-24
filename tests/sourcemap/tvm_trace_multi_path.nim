discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Test: script with imports produces multiple Path events.
##
## Writes a NimScript that imports a helper module, runs with --trace,
## and verifies the trace contains Path events for both files.

import std/[os, osproc, assertions, strutils]

{.passL: "-lzstd".}

import codetracer_trace_reader

template checkOk(res: untyped, msg: string) =
  ## Assert Result is Ok, printing the error if not.
  ## Uses unsafeError to avoid side-effect issue with results.nim `error` func.
  if res.isErr:
    doAssert false, msg & res.unsafeError

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_multi_path"

const helperModule = """
proc helperAdd*(a, b: int): int =
  result = a + b
"""

const mainScript = """
import helper_mod

let x = helperAdd(10, 20)
echo x
"""

proc findNimTrace(): string =
  let nimDir = getCurrentCompilerExe().parentDir
  result = nimDir / "nim_trace"
  if not fileExists(result):
    result = ""

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)

  createDir(buildDir)

  # Write the helper module (use .nim extension for imports)
  let helperFile = buildDir / "helper_mod.nim"
  writeFile(helperFile, helperModule)

  # Write the main script
  let scriptFile = buildDir / "test_multi_path.nims"
  writeFile(scriptFile, mainScript)

  # Write the trace
  let traceFile = buildDir / "test_multi_path.ct"
  let cmd = nim & " e --trace:" & traceFile & " --path:" & buildDir & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "30" in output, "expected '30' in output, got: " & output

  # Open and decode the trace
  doAssert fileExists(traceFile), "trace file not created"
  var readerRes = openTrace(traceFile)
  checkOk readerRes, "failed to open trace: "

  var reader = readerRes.get()
  let eventsRes = reader.readEvents()
  checkOk eventsRes, "failed to read events: "

  # Check Path events - there should be at least 2 (one for each file)
  var pathEvents: seq[string]
  for event in reader.events:
    if event.kind == tlePath:
      pathEvents.add(event.path)

  doAssert pathEvents.len >= 2,
    "expected at least 2 Path events (main script + helper module), got: " &
    $pathEvents.len & " (" & pathEvents.join(", ") & ")"

  # Also verify via the reader.paths field (populated from meta.dat or paths.json)
  doAssert reader.paths.len >= 2,
    "expected at least 2 paths in reader.paths, got: " &
    $reader.paths.len & " (" & reader.paths.join(", ") & ")"

  # Verify both files are represented
  var foundMain = false
  var foundHelper = false
  for p in pathEvents:
    if "test_multi_path" in p:
      foundMain = true
    if "helper_mod" in p:
      foundHelper = true

  doAssert foundMain, "Path events should contain main script path, got: " &
    pathEvents.join(", ")
  doAssert foundHelper, "Path events should contain helper module path, got: " &
    pathEvents.join(", ")

  removeDir(buildDir)
  echo "PASS: tvm_trace_multi_path - found " & $pathEvents.len &
    " path events: " & pathEvents.join(", ")

main()
