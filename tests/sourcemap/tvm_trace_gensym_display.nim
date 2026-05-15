discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-GensymDisplay: verify that varnames in the .ct trace do NOT
## leak Nim's `\`gensymNN` hygiene suffix.
##
## When a template body binds a local (e.g. ``let line = msg`` below),
## the compiler renames the binding to ``line\`gensymNN`` to keep
## expansions hygienic. The renamed string lives on `PSym.name.s` and
## was, pre-fix, registered verbatim into the trace's varname pool —
## producing user-visible entries like ``line\`gensym0``,
## ``line\`gensym1`` that the C/cpp/js backends never expose.
##
## `vm_trace.displayNameForVarname` strips the suffix before
## registration. Per-symbol identity is keyed by `PSym.itemId` in
## `varnameIds`, so distinct gensym'd symbols stay distinct internally
## even when their display strings collide in the writer's interning
## pool — which is exactly what we want: two template expansions binding
## the same local at the source level read as the same varname in the
## trace.
##
## This test:
##   1. Defines a template that binds a local named `line`.
##   2. Invokes it twice (each expansion gensyms `line` differently
##      under the hood).
##   3. Asserts that no entry in `varnames[]` contains the substring
##      ``\`gensym``, and that an entry named exactly `line` is present.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_gensym_display"

const userScript = """
template log(msg: string) =
  let line = msg & " logged"
  discard line

log("hello")
log("world")
"""

proc readVarnames(traceFile: string): seq[string] =
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  for i in 0 ..< int(rdr.varnameCount):
    let v = rdr.varname(uint64(i))
    if v.isOk:
      result.add(v.get)

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "gensym_program.nims"
  writeFile(scriptFile, userScript)

  let traceFile = buildDir / "gensym.ct"
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  let varnames = readVarnames(traceFile)

  # No varname may carry the gensym suffix into the user-visible trace.
  for n in varnames:
    doAssert "`gensym" notin n,
      "gensym suffix leaked into varnames[]: '" & n & "' (full list: " &
        varnames.join(", ") & ")"

  # The template-bound `line` must surface under its bare display name.
  # Both expansions collapse to a single entry in the interning pool
  # (acceptable — they're the same source-level identifier).
  doAssert "line" in varnames,
    "expected stripped 'line' entry in varnames[], got: " &
      varnames.join(", ")

  echo "PASS: tvm_trace_gensym_display — varnames=", varnames

  removeDir(buildDir)

main()
