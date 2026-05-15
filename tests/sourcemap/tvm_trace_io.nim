discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-IO: end-to-end test that the Nim VM emits `io_events` for
## echo, exec, and file/directory operations.
##
## Before this milestone the VM tracer recorded zero `io_events` even
## for programs that performed user-visible IO — `echo "x"` produced a
## step at the right source line, but no record of *what* was written
## to stdout. This test:
##
##   1. Writes a small NimScript that performs:
##        echo "hello"          (line 7  — stdout)
##        echo "world"          (line 8  — stdout)
##        exec "echo from-exec" (line 9  — process spawn)
##        mkDir(tmp_dir)        (line 10 — filesystem)
##        rmDir(tmp_dir)        (line 11 — filesystem)
##   2. Runs `nim e --trace:<path>` to record the trace.
##   3. Re-opens the trace via the seek-based reader and asserts:
##        - `ioEventCount() == 5`
##        - the first two events are `ioStdout` with payloads
##          "hello\n" and "world\n"
##        - the third event is `ioFileOp` carrying "exec: echo from-exec"
##        - the fourth/fifth events are `ioFileOp` with "createDir: ..."
##          and "removeDir: ..."

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/io_event_stream

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_io"

proc readPayload(ev: IOEvent): string =
  result = newString(ev.data.len)
  for i in 0 ..< ev.data.len:
    result[i] = char(ev.data[i])

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "tio.nims"
  let traceFile = buildDir / "tio.ct"
  let tmpSubdir = buildDir / "tio_tmp"

  # Build the script — keep line numbers stable so the test reads as a
  # spec.
  let script = """## CTFS-M-IO fixture
import std/os

echo "hello"
echo "world"
exec "echo from-exec"
mkDir("""" & tmpSubdir & """")
rmDir("""" & tmpSubdir & """")
"""
  writeFile(scriptFile, script)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  # `exec` writes via the child shell rather than the VM's stdout
  # interceptor, so the captured `output` may not contain "from-exec";
  # we don't depend on it. The VM-side echo writes must be present:
  doAssert "hello" in output, "expected 'hello' in output, got: " & output
  doAssert "world" in output, "expected 'world' in output, got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()

  let countRes = rdr.ioEventCount()
  doAssert countRes.isOk, "ioEventCount failed: " & countRes.error
  let count = countRes.get()
  doAssert count == 5'u64,
    "expected 5 io_events (2 echo + 1 exec + 1 mkDir + 1 rmDir), got " & $count

  proc readEv(i: uint64): IOEvent =
    let r = rdr.ioEvent(i)
    doAssert r.isOk, "ioEvent[" & $i & "] failed: " & r.error
    r.get()

  let ev0 = readEv(0)
  doAssert ev0.kind == ioStdout,
    "event 0: expected ioStdout, got " & $ev0.kind
  doAssert readPayload(ev0) == "hello\n",
    "event 0: expected 'hello\\n', got " & readPayload(ev0).escape

  let ev1 = readEv(1)
  doAssert ev1.kind == ioStdout,
    "event 1: expected ioStdout, got " & $ev1.kind
  doAssert readPayload(ev1) == "world\n",
    "event 1: expected 'world\\n', got " & readPayload(ev1).escape

  let ev2 = readEv(2)
  doAssert ev2.kind == ioFileOp,
    "event 2: expected ioFileOp (exec), got " & $ev2.kind
  doAssert readPayload(ev2) == "exec: echo from-exec",
    "event 2: expected 'exec: echo from-exec', got " &
    readPayload(ev2).escape

  let ev3 = readEv(3)
  doAssert ev3.kind == ioFileOp,
    "event 3: expected ioFileOp (createDir), got " & $ev3.kind
  doAssert readPayload(ev3).startsWith("createDir: "),
    "event 3: expected payload prefix 'createDir: ', got " &
    readPayload(ev3).escape
  doAssert tmpSubdir in readPayload(ev3),
    "event 3: expected payload to contain '" & tmpSubdir & "', got " &
    readPayload(ev3).escape

  let ev4 = readEv(4)
  doAssert ev4.kind == ioFileOp,
    "event 4: expected ioFileOp (removeDir), got " & $ev4.kind
  doAssert readPayload(ev4).startsWith("removeDir: "),
    "event 4: expected payload prefix 'removeDir: ', got " &
    readPayload(ev4).escape

  echo "PASS: tvm_trace_io (CTFS-M-IO)"
  removeDir(buildDir)

main()
