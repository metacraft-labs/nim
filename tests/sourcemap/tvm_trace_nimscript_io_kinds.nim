discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Each NimScript operation that touches the system is recorded with the
## I/O event kind that describes it (trace-events.md §"EventLogKind"):
##
##   * creating, removing, moving or copying a file or directory writes
##     a named filesystem entry: `WriteFile`;
##   * changing the current directory opens that directory: `OpenDir`;
##   * running a command and changing the environment write to something
##     other than stdout or a named file: `WriteOther`;
##   * `echo` is output to stdout: `Write`.
##
## The kinds round-trip exactly, so the reader reports what the tracer
## recorded. No mocks: the real compiler runs the script against a scratch
## directory.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/io_event_stream

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_nimscript_io_kinds"

const testScript = """
mkDir("d1")
writeFile("d1/f.txt", "x")
cpFile("d1/f.txt", "d1/g.txt")
mvFile("d1/g.txt", "d1/h.txt")
rmFile("d1/h.txt")
cpDir("d1", "d2")
mvDir("d2", "d3")
rmDir("d3")
cd("d1")
cd("..")
putEnv("TVM_TRACE_IO_KINDS", "1")
delEnv("TVM_TRACE_IO_KINDS")
exec("true")
echo "done"
"""

const expected = [
  ("createDir: d1", "WriteFile"),
  ("copyFile: d1/f.txt -> d1/g.txt", "WriteFile"),
  ("moveFile: d1/g.txt -> d1/h.txt", "WriteFile"),
  ("removeFile: d1/h.txt", "WriteFile"),
  ("copyDir: d1 -> d2", "WriteFile"),
  ("moveDir: d2 -> d3", "WriteFile"),
  ("removeDir: d3", "WriteFile"),
  ("setCurrentDir: d1", "OpenDir"),
  ("setCurrentDir: ..", "OpenDir"),
  ("putEnv: TVM_TRACE_IO_KINDS=1", "WriteOther"),
  ("delEnv: TVM_TRACE_IO_KINDS", "WriteOther"),
  ("exec: true", "WriteOther"),
  ("done\n", "Write"),
]

proc main() =
  let nim = getCurrentCompilerExe()
  removeDir(buildDir)
  createDir(buildDir)
  let scriptFile = buildDir / "io.nims"
  let traceFile = buildDir / "io.ct"
  writeFile(scriptFile, testScript)

  let (output, exitCode) = execCmdEx(nim & " e --trace:" & traceFile &
                                     " io.nims", workingDir = buildDir)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  var r = openNewTrace(traceFile).get()
  var got: seq[(string, string)]
  for i in 0'u64 ..< r.ioEventCount().get():
    let ev = r.ioEvent(i).get()
    got.add((cast[string](ev.data), eventLogKindName(ev.kind)))

  doAssert got.len == expected.len,
    "expected " & $expected.len & " I/O events, got " & $got.len & ": " & $got
  for i, (text, kind) in expected:
    doAssert got[i][0] == text,
      "event " & $i & " text: expected " & text.escape & ", got " &
      got[i][0].escape
    doAssert got[i][1] == kind,
      "event " & $i & " (" & text.escape & "): expected kind " & kind &
      ", got " & got[i][1]

  echo "PASS: tvm_trace_nimscript_io_kinds"
  removeDir(buildDir)

main()
