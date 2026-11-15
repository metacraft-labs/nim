discard """
  matrix: "; -d:useFork; -d:useClone"
  output: ""
"""

# `waitForExit` must return the child's exit code even when a signal
# interrupts the parent while it waits. Without a timeout, it blocks in
# `waitpid`. A signal whose handler was installed without `SA_RESTART` makes
# that call return -1 with `EINTR`, which says nothing about the child. If
# the error is raised, the caller loses the exit code of a child that is
# still running, and has no clean way to wait for it again.
#
# A repeating interval timer delivers SIGALRM, with a handler installed
# without `SA_RESTART`, every millisecond while the parent waits for a child
# that sleeps before it exits with a known code. Without the retry on
# `EINTR`, the wait without a timeout raises "Interrupted system call".
#
# The bounded wait (a timeout) and `execCmdEx` are checked under the same
# storm, but on Linux neither blocks in `waitpid`: the bounded wait polls
# with `WNOHANG` between sleeps, and `execCmdEx` reads the child's output and
# polls its exit code. They guard against regressions there. On the BSDs and
# macOS the bounded wait does block in `waitpid` after kqueue reports the
# exit, and on Haiku after `wait_for_objects_etc` does.
#
# No mocks: real signals, real child processes.

import std/osproc

when defined(windows):
  # No POSIX signals on Windows.
  discard
else:
  import std/posix

  type Itimerval {.importc: "struct itimerval", header: "<sys/time.h>".} = object
    it_interval, it_value: Timeval

  proc setitimer(which: cint; newValue: var Itimerval;
                 oldValue: ptr Itimerval): cint {.
    importc, header: "<sys/time.h>".}

  var itimerReal {.importc: "ITIMER_REAL", header: "<sys/time.h>".}: cint

  var interruptions {.volatile.}: int

  proc onAlarm(sig: cint) {.noconv.} =
    # Only counts; the point is that the parent's blocking calls are
    # interrupted.
    interruptions = interruptions + 1

  proc setTimer(usec: int) =
    var t: Itimerval
    t.it_interval.tv_usec = Suseconds(usec)
    t.it_value.tv_usec = Suseconds(usec)
    doAssert setitimer(itimerReal, t, nil) == 0

  var act: Sigaction
  act.sa_handler = onAlarm
  discard sigemptyset(act.sa_mask)
  act.sa_flags = 0 # no SA_RESTART: interrupted calls fail with EINTR
  doAssert sigaction(SIGALRM, act, nil) == 0

  proc waitsThroughSignals(what: string; timeout: int) =
    let before = interruptions
    let p = startProcess("/bin/sh", args = ["-c", "sleep 0.3; exit 3"],
                         options = {})
    var code = -1
    setTimer(1000)
    try:
      code = p.waitForExit(timeout)
    except OSError as e:
      # Stop the storm first, so that the child can be reaped and the
      # assertion below reports the real cause.
      setTimer(0)
      discard p.waitForExit()
      p.close()
      doAssert false, what & ": waitForExit raised " & e.msg
    finally:
      setTimer(0)
    p.close()
    doAssert interruptions > before, what & ": the timer never fired"
    doAssert code == 3, what & ": exit code " & $code

  waitsThroughSignals("no timeout", -1)
  waitsThroughSignals("timeout", 10_000)

  block execCmdExThroughSignals:
    let before = interruptions
    var res: tuple[output: string, exitCode: int]
    setTimer(1000)
    try:
      res = execCmdEx("sleep 0.3; exit 4")
    finally:
      setTimer(0)
    doAssert interruptions > before, "execCmdEx: the timer never fired"
    doAssert res.exitCode == 4, "execCmdEx: exit code " & $res.exitCode
