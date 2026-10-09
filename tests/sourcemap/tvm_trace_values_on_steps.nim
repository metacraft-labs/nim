discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Every value the VM trace records is readable from a step.
##
## Record N of `values.dat` belongs to exec record N of `steps.dat`. A
## `DeltaColumn` exec record is a column-only nudge, not a logical step
## (trace-events.md §"Execution Stream", §"Recorder Integration — Staging
## Values"), so a value written beside one is unreachable: no step's
## `variables_at` returns it. Several statements on one line, and several
## variables declared by one statement, put assignments at distinct columns
## of the same line, which is exactly where such values would be parked.
##
## Which encoding a position gets depends on where it is: a delta is
## written only when it is shorter than the position (§"Encoding Rules"),
## so the script below starts past position 127, where a column move is a
## one-byte delta and a position takes two bytes.
##
## Asserted:
##   1. No `DeltaColumn` exec record carries a value.
##   2. Every user binding of the script is attached to a logical step,
##      with the value the program assigned.
##   3. No logical step sits at column 1 of an indented line: that column
##      is whitespace, a position the program never executed.

import std/[os, osproc, assertions, strutils, tables]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/full_document_json
import codetracer_trace_writer/step_encoding

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_values_on_steps"

const
  padding = "# padding that moves the code below past position 127 ......\n"
  firstCodeLine = 4  # after three padding lines
  indentedLine = firstCodeLine + 3
  testScript = padding & padding & padding &
               "var a = 1; var b = 2; var c = 3\n" &
               "var x, y, z: int\n" &
               "x = a; y = b; z = c\n" &
               "if a == 1:\n" &
               "  var w = 4\n" &
               "  echo a, b, c, x, y, z, w\n"

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let scriptFile = buildDir / "vals.nims"
  let traceFile = buildDir / "vals.ct"
  writeFile(scriptFile, testScript)

  let (output, exitCode) = execCmdEx(nim & " e --trace:" & traceFile &
                                     " " & scriptFile)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "1231234" in output, "unexpected script output: " & output

  var r = openNewTrace(traceFile).get()
  let n = r.stepCount().get()

  # Last value each binding was given on a logical step.
  var onSteps: Table[string, string]
  for i in 0'u64 ..< n:
    let ev = r.step(i)
    doAssert ev.isOk, "exec record " & $i & ": " & ev.error
    let vals = r.values(i)
    doAssert vals.isOk, "values of exec record " & $i & ": " & vals.error
    let pos = r.decodeGlobalPositionIndex(
      r.stepAbsoluteGlobalLineIndex(i).get()).get()
    if ev.get().kind != sekDeltaColumn:
      doAssert not (pos.line.int in {indentedLine, indentedLine + 1} and
                    pos.column == 1),
        "exec record " & $i & " is a step at column 1 of indented line " &
        $pos.line & ", which holds only whitespace"
    if ev.get().kind == sekDeltaColumn:
      var names: seq[string]
      for v in vals.get():
        names.add r.varname(v.varnameId).get()
      doAssert names.len == 0,
        "exec record " & $i & " is a DeltaColumn nudge but carries values " &
        "no step can reach: " & names.join(", ")
    else:
      for v in vals.get():
        onSteps[r.varname(v.varnameId).get()] =
          $decodeValueBytesToJson(v.data)

  for (name, want) in [("a", 1), ("b", 2), ("c", 3),
                       ("x", 1), ("y", 2), ("z", 3), ("w", 4)]:
    doAssert name in onSteps,
      "binding '" & name & "' is on no logical step; bindings seen: " &
      $onSteps
    doAssert "\"i\":" & $want in onSteps[name],
      "binding '" & name & "' should end at " & $want & ", got " &
      onSteps[name]

  echo "PASS: tvm_trace_values_on_steps"
  removeDir(buildDir)

main()
