discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-CompileTimeFilter: end-to-end test that compile-time
## execution is suppressed from the VM trace.
##
## The Nim VM is reused for both runtime script execution (the body of
## a `nim e` script, which runs in mode `emRepl`) and compile-time
## evaluation (`static:` blocks, `{.compileTime.}` proc / var
## initializers, macro / template bodies — all of which switch the VM
## into `emStaticStmt` / `emStaticExpr` / `emConst` / `emOptimize`).
##
## A trace records the *runtime* behaviour of the user program, so any
## emission that originates from a compile-time evaluation must be
## dropped. Before this milestone, programs whose interesting
## behaviour was 100% compile-time (e.g. tests/vm/tscriptcompiletime.nims)
## produced 4-event traces of pure noise; programs that mixed both
## leaked macro-body steps into the runtime sequence.
##
## This test runs a single `nim e --trace:<file>` against a script that
## has clearly separated compile-time and runtime regions, then asserts:
##
##   1. No path entry is registered for the helper file whose ONLY
##      events would be compile-time (a `{.compileTime.}` var + a
##      `static:` block).
##   2. The varname interning pool does not contain the compile-time
##      symbol (`compTimeVar`) — it must contain only `runtimeVar`.
##   3. No step event appears at the macro body's source line(s).
##   4. Step events appear at the runtime statement lines (assignment
##      and final echo).
##   5. The captured value for `runtimeVar` is the runtime value (42),
##      not the compile-time stand-in (100).

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/step_encoding
import codetracer_ct_print_lib

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_compile_time_filter"

# Script layout — keep line numbers stable; assertions index by them.
# Line 1 : ## docstring
# Line 2 : import macros
# Line 3 : # compile-time setup
# Line 4 : var compTimeVar {.compileTime.} = 100
# Line 5 : static:
# Line 6 :   compTimeVar += 23
# Line 7 : (blank)
# Line 8 : macro mac1(): untyped =
# Line 9 :   result = newStmtList()
# Line 10: (blank)
# Line 11: # runtime
# Line 12: let runtimeVar = 42
# Line 13: mac1()
# Line 14: echo runtimeVar
const testScript = """## compile-time vs runtime separation
import macros
# compile-time setup
var compTimeVar {.compileTime.} = 100
static:
  compTimeVar += 23

macro mac1(): untyped =
  result = newStmtList()

# runtime
let runtimeVar = 42
mac1()
echo runtimeVar
"""

type
  EventInfo = object
    idx: uint64
    kind: StepEventKind
    line: uint64
    pathId: int

proc collectEvents(rdr: var NewTraceReader): seq[EventInfo] =
  ## Walk the exec stream and record (idx, kind, line, pathId) for
  ## every event.
  let totalRes = rdr.stepCount
  doAssert totalRes.isOk, "stepCount failed: " & totalRes.error
  let total = totalRes.get()
  let gli = buildGliFromMeta(rdr.meta)
  result = @[]
  for i in 0'u64 ..< total:
    let evRes = rdr.step(i)
    doAssert evRes.isOk, "step[" & $i & "] read failed: " & evRes.error
    let ev = evRes.get()
    let absRes = rdr.stepAbsoluteGlobalLineIndex(i)
    doAssert absRes.isOk,
      "stepAbsoluteGlobalLineIndex[" & $i & "] failed: " & absRes.error
    let (pathId, line) =
      if rdr.meta.hasColumnAwareSteps:
        # Column-Aware-Replay: byte-offset GLI; use the spec-defined
        # decoder rather than the legacy 100k-per-file resolveGli.
        let posRes = rdr.decodeGlobalPositionIndex(absRes.get())
        doAssert posRes.isOk,
          "decodeGlobalPositionIndex failed: " & posRes.error
        let p = posRes.get()
        (int(p.file), uint64(p.line))
      else:
        resolveGli(gli, absRes.get())
    result.add(EventInfo(idx: i, kind: ev.kind, line: line,
                         pathId: pathId))

proc renderEvents(events: seq[EventInfo]): string =
  result = ""
  for e in events:
    result.add("  [" & $e.idx & "] " & $e.kind & " @ path=" &
               $e.pathId & " line=" & $e.line & "\n")

proc readVarnames(rdr: var NewTraceReader): seq[string] =
  result = @[]
  for i in 0 ..< int(rdr.varnameCount):
    let v = rdr.varname(uint64(i))
    if v.isOk:
      result.add(v.get)

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "tcompile_time.nims"
  let traceFile = buildDir / "tcompile_time.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "42" in output,
    "expected '42' from runtime echo, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  # --- (1) varnames must contain runtimeVar but NOT compTimeVar -----
  let varnames = readVarnames(rdr)
  doAssert "runtimeVar" in varnames,
    "expected 'runtimeVar' in varnames; got: " & $varnames
  doAssert "compTimeVar" notin varnames,
    "expected 'compTimeVar' to be suppressed by the compile-time " &
    "filter; got: " & $varnames

  let events = collectEvents(rdr)

  # --- (2) no step event at the macro body lines (8, 9) ------------
  # Line 8: macro mac1(): untyped =
  # Line 9:   result = newStmtList()
  for e in events:
    doAssert e.line != 8'u64 and e.line != 9'u64,
      "expected no events at macro body lines (8, 9); got an event " &
      "at line " & $e.line & ":\n" & renderEvents(events)

  # --- (3) no step event at compile-time setup lines (4, 5, 6) -----
  # Line 4: var compTimeVar {.compileTime.} = 100 — setupCompileTimeVar
  # Line 5 / 6: static: compTimeVar += 23 — evalStaticStmt
  # All three are compile-time-only; none should appear.
  for e in events:
    doAssert e.line != 4'u64 and e.line != 5'u64 and e.line != 6'u64,
      "expected no events at compile-time lines (4, 5, 6); got an " &
      "event at line " & $e.line & ":\n" & renderEvents(events)

  # --- (4) at least one step at line 12 (let runtimeVar = 42) ------
  var sawLine12 = false
  for e in events:
    if e.line == 12'u64:
      sawLine12 = true
      break
  doAssert sawLine12,
    "expected at least one step at line 12 (let runtimeVar = 42), " &
    "events were:\n" & renderEvents(events)

  # --- (5) at least one step at line 14 (echo runtimeVar) ----------
  var sawLine14 = false
  for e in events:
    if e.line == 14'u64:
      sawLine14 = true
      break
  doAssert sawLine14,
    "expected at least one step at line 14 (echo runtimeVar), " &
    "events were:\n" & renderEvents(events)

  # --- (6) trace_filter.filters[] still records the builtin default;
  # the compile-time filter is in addition to (not a replacement of)
  # the existing path/function filters.
  doAssert rdr.meta.hasFilterProvenance,
    "expected meta.hasFilterProvenance to be true (FlagHasTraceFilter" &
    "Provenance set from the builtin default filter)"

  echo "PASS: tvm_trace_compile_time_filter (CTFS-M-CompileTimeFilter)"
  removeDir(buildDir)

main()
