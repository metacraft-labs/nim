discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## Each NimScript operation that touches the system is recorded with the
## I/O event kind that describes it (trace-events.md §"EventLogKind"), the
## reads included, and an operation run at compile time records nothing:
##
##   * creating a directory, or copying a directory tree: `CreateDir`;
##     removing one: `RemoveDir`; removing a file: `RemoveFile`; moving a
##     file or directory: `Rename`; copying a file or writing one:
##     `WriteFile`; changing the current directory: `ChangeDir`;
##   * running a command: `Exec`; setting or removing an environment
##     variable: `WriteEnv`; reading one or testing it: `ReadEnv`;
##   * testing whether a file or directory exists, asking for its
##     searching PATH for a program: `Stat`; listing a directory:
##     `ReadDir`; reading a file: `ReadFile`;
##   * `echo` is output to stdout (`Write`), a line read from stdin input
##     (`Read`).
##
## A read's payload carries what the script observed. The kinds round-trip
## exactly, so the reader reports what the tracer recorded. No mocks: the
## real compiler runs the script against a scratch directory.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/io_event_stream

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_nimscript_io_kinds"

const testScript = """
static: discard fileExists("io.nims")
mkDir("d1")
writeFile("d1/f.txt", "x")
discard readFile("d1/f.txt")
discard fileExists("d1/f.txt")
discard dirExists("nope")
discard listFiles("d1")
discard listDirs("d1")
cpFile("d1/f.txt", "d1/g.txt")
mvFile("d1/g.txt", "d1/h.txt")
rmFile("d1/h.txt")
cpDir("d1", "d2")
mvDir("d2", "d3")
rmDir("d3")
cd("d1")
cd("..")
putEnv("TVM_TRACE_IO_KINDS", "1")
discard getEnv("TVM_TRACE_IO_KINDS")
discard existsEnv("TVM_TRACE_IO_KINDS")
delEnv("TVM_TRACE_IO_KINDS")
discard findExe("sh")
exec("true")
discard readLineFromStdin()
echo "done"
"""

const expected = [
  ("createDir: d1", "CreateDir"),
  ("writeFile: d1/f.txt", "WriteFile"),
  ("readFile: d1/f.txt", "ReadFile"),
  ("fileExists: d1/f.txt -> true", "Stat"),
  ("dirExists: nope -> false", "Stat"),
  ("listFiles: d1 -> [d1/f.txt]", "ReadDir"),
  ("listDirs: d1 -> []", "ReadDir"),
  ("copyFile: d1/f.txt -> d1/g.txt", "WriteFile"),
  ("moveFile: d1/g.txt -> d1/h.txt", "Rename"),
  ("removeFile: d1/h.txt", "RemoveFile"),
  ("copyDir: d1 -> d2", "CreateDir"),
  ("moveDir: d2 -> d3", "Rename"),
  ("removeDir: d3", "RemoveDir"),
  ("setCurrentDir: d1", "ChangeDir"),
  ("setCurrentDir: ..", "ChangeDir"),
  ("putEnv: TVM_TRACE_IO_KINDS=1", "WriteEnv"),
  ("getEnv: TVM_TRACE_IO_KINDS -> 1", "ReadEnv"),
  ("existsEnv: TVM_TRACE_IO_KINDS -> true", "ReadEnv"),
  ("delEnv: TVM_TRACE_IO_KINDS", "WriteEnv"),
  ("findExe: sh -> *", "Stat"),
  ("exec: true", "Exec"),
  ("typed at stdin", "Read"),
  ("done\n", "Write"),
]

const stdlibScript = """
import std/os
writeFile("w.txt", "abc")
discard readFile("w.txt")
discard os.fileExists("w.txt")
discard os.dirExists("w.txt")
"""

const stdlibExpected = [
  ("writeFile: w.txt", "WriteFile"),
  ("readFile: w.txt", "ReadFile"),
  ("fileExists: w.txt -> true", "Stat"),
  ("dirExists: w.txt -> false", "Stat"),
]

proc recordedEvents(script, name: string): seq[(string, string)] =
  ## The I/O events `nim e --trace` records for `script`, as (payload, kind).
  let nim = getCurrentCompilerExe()
  let traceFile = buildDir / (name & ".ct")
  writeFile(buildDir / (name & ".nims"), script)
  let (output, exitCode) = execCmdEx(nim & " e --trace:" & traceFile & " " &
    name & ".nims", workingDir = buildDir)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  var r = openNewTrace(traceFile).get()
  for i in 0'u64 ..< r.ioEventCount().get():
    let ev = r.ioEvent(i).get()
    result.add((cast[string](ev.data), eventLogKindName(ev.kind)))

proc main() =
  let nim = getCurrentCompilerExe()
  removeDir(buildDir)
  createDir(buildDir)
  let scriptFile = buildDir / "io.nims"
  let traceFile = buildDir / "io.ct"
  writeFile(scriptFile, testScript)

  let (output, exitCode) = execCmdEx(nim & " e --trace:" & traceFile &
                                     " io.nims", workingDir = buildDir,
                                     input = "typed at stdin\n")
  doAssert exitCode == 0, "nim e --trace failed: " & output

  var r = openNewTrace(traceFile).get()
  var got: seq[(string, string)]
  for i in 0'u64 ..< r.ioEventCount().get():
    let ev = r.ioEvent(i).get()
    got.add((cast[string](ev.data), eventLogKindName(ev.kind)))

  doAssert got.len == expected.len,
    "expected " & $expected.len & " I/O events, got " & $got.len & ": " & $got
  for i, (text, kind) in expected:
    # A trailing `*` stands for a result that depends on the machine (a
    # where `sh` is found).
    doAssert (if text.endsWith("*"): got[i][0].startsWith(text[0 ..< ^1]) and
                got[i][0].len > text.len - 1
              else: got[i][0] == text),
      "event " & $i & " text: expected " & text.escape & ", got " &
      got[i][0].escape
    doAssert got[i][1] == kind,
      "event " & $i & " (" & text.escape & "): expected kind " & kind &
      ", got " & got[i][1]

  # The same operations reached through `std/os` and
  # `std/syncio` rather than the NimScript API.
  let viaStdlib = recordedEvents(stdlibScript, "stdlib")
  doAssert viaStdlib == @stdlibExpected,
    "through std/os and std/envvars: expected " & $stdlibExpected &
    ", got " & $viaStdlib

  echo "PASS: tvm_trace_nimscript_io_kinds"
  removeDir(buildDir)

main()
