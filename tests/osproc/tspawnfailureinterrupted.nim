discard """
  matrix: "; -d:useFork; -d:useClone"
  output: ""
"""

# A `startProcess` whose child cannot run the command must raise `OSError`,
# even when a signal interrupts the parent while it waits to learn the
# outcome. On the fork path the parent blocks in `read` on the error pipe
# until the child either execs (end-of-file) or reports its errno and exits.
# A signal whose handler was installed without `SA_RESTART` makes that `read`
# return -1 with `EINTR`. If that is taken as "no error", the caller gets a
# `Process` for a child that is about to exit 1 instead of the `OSError` that
# names the cause.
#
# A repeating interval timer delivers SIGALRM, with a handler installed
# without `SA_RESTART`, every 20 microseconds while the test starts a missing
# command many times. Without the retry on `EINTR`, some of those starts
# return a `Process`. The default leg drives posix_spawn, which does not
# report an interrupted wait as success, and `-d:useClone` uses CLONE_VFORK,
# which holds the parent until the child has exec'd or exited; both must hold
# too.
#
# No mocks: real signals, real `startProcess` calls.

import std/osproc

when defined(windows):
  # No POSIX signals or fork path on Windows.
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

  const missing = "/nonexistent/tspawnfailureinterrupted-cmd"
  const attempts = 2000

  var act: Sigaction
  act.sa_handler = onAlarm
  discard sigemptyset(act.sa_mask)
  act.sa_flags = 0 # no SA_RESTART: interrupted calls fail with EINTR
  doAssert sigaction(SIGALRM, act, nil) == 0

  # Starts that wrongly returned a `Process`. Their pipes are closed at once,
  # so that many of them cannot exhaust the file descriptor limit, but they
  # are reaped only after the timer is stopped: `waitForExit` does not retry
  # an interrupted `waitpid` on every platform, so reaping them under the
  # signal storm could raise.
  var startedAnyway: seq[Process]
  # An `OSError` for any other reason than the missing command, such as an
  # interrupted call that is not retried, is a failure too: it would hide
  # the defect this test is about behind the right exception type.
  var otherErrors: seq[string]
  setTimer(20)
  try:
    for i in 1 .. attempts:
      try:
        let p = startProcess(missing, options = {})
        p.close()
        startedAnyway.add p
      except OSError as e:
        if e.errorCode != ENOENT:
          otherErrors.add $e.errorCode & ": " & e.msg
  finally:
    setTimer(0)

  for p in startedAnyway:
    discard p.waitForExit()

  doAssert interruptions > 0, "the timer never fired"
  doAssert startedAnyway.len == 0, $startedAnyway.len & " of " & $attempts &
    " starts of a missing command returned a Process instead of raising " &
    "(" & $interruptions & " SIGALRM interruptions)"
  doAssert otherErrors.len == 0, $otherErrors.len & " starts raised an " &
    "OSError other than ENOENT; first: " & otherErrors[0]
