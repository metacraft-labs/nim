discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-MacroEmittedRuntime: end-to-end test that AST nodes
## synthesized by macro execution surface in the runtime trace at the
## macro call site (not at the macro body, nor missing entirely because
## their line info pointed into `lib/core/macros.nim`).
##
## When a macro body executes `result = newCall(bindSym"echo", ...)`,
## the synthesized `nkCall` carries the line info of `newCall` itself
## (inside `lib/core/macros.nim`) — the path filter therefore rejects
## a step at that location and the runtime echo silently disappears
## from the trace. Likewise, when a macro body uses `quote do:`, the
## spliced nodes carry the macro body's own line info, so the step
## emerges at the macro body (which CTFS-M-CompileTimeFilter would
## otherwise suppress; even if it slipped through, the line attributed
## to the user would be inside the macro, not at the call site).
##
## After this milestone, `evalMacroCall` rewrites the spliced AST's
## node info so that:
##   * nodes whose info falls inside the macro definition's source
##     range, AND
##   * nodes whose info points into the Nim standard library (e.g.
##     `lib/core/macros.nim`)
## both get their `info` set to the macro call site instead.
##
## This test runs a single `nim e --trace:<file>` against a script that
## defines two macros — one using `newCall(bindSym"echo", newLit ...)`
## and one using `quote do: echo ...` — invokes each, and asserts:
##
##   1. A step event lands at the `newCall`-style macro's call site.
##   2. A step event lands at the `quote do:` macro's call site.
##   3. No step event lands at the macro body lines.
##   4. The direct (non-macro) runtime echoes between/around the macro
##      calls still produce their own steps.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/step_encoding
import codetracer_ct_print_lib

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_macro_emitted_runtime"

# Script layout — keep line numbers stable; assertions index by them.
# Line 1 : ## docstring
# Line 2 : import macros
# Line 3 : (blank)
# Line 4 : macro emitCall(): void =
# Line 5 :   result = newCall(bindSym"echo", newLit("from newCall"))
# Line 6 : (blank)
# Line 7 : macro emitQuote(): untyped =
# Line 8 :   result = quote do:
# Line 9 :     echo "from quote"
# Line 10: (blank)
# Line 11: echo "before"
# Line 12: emitCall()
# Line 13: emitQuote()
# Line 14: echo "after"
const testScript = """## macro-emitted runtime test
import macros

macro emitCall(): void =
  result = newCall(bindSym"echo", newLit("from newCall"))

macro emitQuote(): untyped =
  result = quote do:
    echo "from quote"

echo "before"
emitCall()
emitQuote()
echo "after"
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
    let (pathId, line) = resolveGli(gli, absRes.get())
    result.add(EventInfo(idx: i, kind: ev.kind, line: line,
                         pathId: pathId))

proc renderEvents(events: seq[EventInfo]): string =
  result = ""
  for e in events:
    result.add("  [" & $e.idx & "] " & $e.kind & " @ path=" &
               $e.pathId & " line=" & $e.line & "\n")

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "tmacro_emit.nims"
  let traceFile = buildDir / "tmacro_emit.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "before" in output and "after" in output,
    "expected runtime echoes 'before' and 'after' in output, got: " & output
  doAssert "from newCall" in output,
    "expected 'from newCall' from emitCall() macro, got: " & output
  doAssert "from quote" in output,
    "expected 'from quote' from emitQuote() macro, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  let events = collectEvents(rdr)

  # --- (1) at least one step at line 11 (echo "before") -------------
  var sawLine11 = false
  for e in events:
    if e.line == 11'u64:
      sawLine11 = true
      break
  doAssert sawLine11,
    "expected at least one step at line 11 (echo \"before\"), " &
    "events were:\n" & renderEvents(events)

  # --- (2) at least one step at line 12 (emitCall() call site) ------
  # Before this milestone the macro-emitted `echo` had `info` pointing
  # into `lib/core/macros.nim` (because that's where `newCall` lives),
  # so the path filter dropped the step entirely.
  var sawLine12 = false
  for e in events:
    if e.line == 12'u64:
      sawLine12 = true
      break
  doAssert sawLine12,
    "expected a step at line 12 (emitCall() macro call site) — the " &
    "macro-emitted echo \"from newCall\" should surface at the call " &
    "site. Events were:\n" & renderEvents(events)

  # --- (3) at least one step at line 13 (emitQuote() call site) -----
  # Before this milestone the `quote do:` spliced nodes carried line
  # info from inside the macro body (line 9), so the step (if any)
  # landed there instead of at the call site.
  var sawLine13 = false
  for e in events:
    if e.line == 13'u64:
      sawLine13 = true
      break
  doAssert sawLine13,
    "expected a step at line 13 (emitQuote() macro call site) — the " &
    "quote-do-emitted echo \"from quote\" should surface at the call " &
    "site, not at the macro body line. Events were:\n" & renderEvents(events)

  # --- (4) at least one step at line 14 (echo "after") --------------
  var sawLine14 = false
  for e in events:
    if e.line == 14'u64:
      sawLine14 = true
      break
  doAssert sawLine14,
    "expected at least one step at line 14 (echo \"after\"), " &
    "events were:\n" & renderEvents(events)

  # --- (5) NO step events at the macro body lines (4, 5, 7, 8, 9) ---
  # The macro bodies execute at compile time (CTFS-M-CompileTimeFilter
  # suppresses those), and after CTFS-M-MacroEmittedRuntime the spliced
  # AST no longer leaks its body-internal line info into the runtime
  # trace either.
  for e in events:
    doAssert e.line notin [4'u64, 5'u64, 7'u64, 8'u64, 9'u64],
      "expected no events at macro body lines (4, 5, 7, 8, 9); got " &
      "an event at line " & $e.line & ":\n" & renderEvents(events)

  echo "PASS: tvm_trace_macro_emitted_runtime (CTFS-M-MacroEmittedRuntime)"
  removeDir(buildDir)

main()
