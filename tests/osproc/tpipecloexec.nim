discard """
  matrix: "; -d:useFork; -d:useClone"
  output: ""
"""

# `startProcess` connects the child's fd 0, 1 and 2 to pipes. Those three must
# be the child's ONLY descriptors on the pipes: a further copy is inherited by
# everything the child starts, and a grandchild that outlives the child then
# keeps the parent's read end from ever seeing end-of-file, so the parent
# cannot tell that its child has exited.
#
# The default leg drives the posix_spawn path, `-d:useFork` the fork/exec
# path, and `-d:useClone` the same path with the child created by `clone`.
#
# No mocks: every case spawns real processes. The child that reports its
# descriptors is this test program itself, started in "report" mode.

import std/[os, osproc, streams, strutils, times]

when defined(windows):
  # CreateProcess hands the child only the handles named in STARTUPINFO plus
  # the ones marked inheritable; that model is covered elsewhere.
  discard
else:
  import std/posix

  const sh = when defined(android): "/system/bin/sh" else: "/bin/sh"

  proc fifoId(fd: cint): string =
    ## Identifies the pipe behind `fd`, or "" when `fd` is not an open pipe.
    var st: Stat
    if fstat(fd, st) != 0 or not S_ISFIFO(st.st_mode):
      return ""
    $st.st_dev & ":" & $st.st_ino

  proc reportDescriptors() =
    ## Report mode: echo stdin, then name every descriptor above 2 that refers
    ## to the same pipe as one of fd 0, 1 or 2.
    let input = stdin.readAll()
    var std: seq[string] = @[]
    for fd in 0.cint .. 2.cint:
      let id = fifoId(fd)
      if id.len > 0: std.add id
    var leaks: seq[string] = @[]
    for fd in 3.cint ..< 1024.cint:
      if fcntl(fd, F_GETFD) < 0: continue
      let id = fifoId(fd)
      if id.len > 0 and id in std:
        leaks.add $fd
    stdout.write "in=" & input & "\n" & "std=" & $std.len & "\n" &
                 "leaks=" & leaks.join(",") & "\n"
    stdout.flushFile()

  proc checkChild(options: set[ProcessOption]; workingDir = "") =
    let p = startProcess(getAppFilename(), workingDir = workingDir,
                         args = ["report"], options = options)
    p.inputStream.write "ping"
    p.inputStream.close()
    let output = p.outputStream.readAll()
    doAssert p.waitForExit() == 0, output
    p.close()
    let ctx = $options & " workingDir=" & workingDir & ":\n" & output
    doAssert "in=ping\n" in output, ctx
    doAssert "std=3\n" in output, ctx
    doAssert "leaks=\n" in output, ctx

  proc checkAllShapes() =
    checkChild({})
    checkChild({poStdErrToStdOut})
    checkChild({poStdErrToStdOut, poDaemon})
    # A `workingDir` takes the fork path where posix_spawn cannot chdir.
    checkChild({}, workingDir = getTempDir())

  proc checkGrandchildDoesNotHoldOutput() =
    # The scenario the leak breaks: the child starts a background process with
    # its own standard streams redirected away from the pipes, and exits. The
    # parent must see end-of-file now, not when the background process exits.
    let start = epochTime()
    let p = startProcess(sh, args = ["-c",
      "sleep 30 </dev/null >/dev/null 2>&1 & echo started"], options = {})
    let output = p.outputStream.readAll()
    let elapsed = epochTime() - start
    doAssert p.waitForExit() == 0
    p.close()
    doAssert output == "started\n", output
    doAssert elapsed < 20.0,
      "end-of-file on the child's stdout took " & $elapsed & " s"

  proc closedStandardStreams() =
    ## With fd 0, 1 and 2 closed in the parent, as in a daemon, `pipe` hands
    ## out those numbers. The child must still get working standard streams
    ## and no further copies. Reports through the exit code alone.
    for fd in 0.cint .. 2.cint: discard close(fd)
    try:
      checkAllShapes()
    except CatchableError, AssertionDefect:
      quit 1
    quit 0

  if paramCount() >= 1 and paramStr(1) == "report":
    reportDescriptors()
  elif paramCount() >= 1 and paramStr(1) == "closed-std":
    closedStandardStreams()
  else:
    checkAllShapes()
    checkGrandchildDoesNotHoldOutput()
    let p = startProcess(getAppFilename(), args = ["closed-std"],
                         options = {poParentStreams})
    doAssert p.waitForExit() == 0,
      "children of a parent with its standard streams closed"
    p.close()
