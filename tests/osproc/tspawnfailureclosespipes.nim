discard """
  matrix: "; -d:useFork"
  output: ""
"""

# A `startProcess` that fails must not leave open any descriptor it created.
# On POSIX it creates the child's three pipes (six descriptors) before it
# spawns, and the fork path creates an error pipe too. When the spawn fails,
# for example because the command does not exist, those descriptors must be
# closed before the error reaches the caller: a long-running process that
# retries a failing start would otherwise run out of descriptors.
#
# The default leg drives the posix_spawn path, `-d:useFork` the fork/exec
# path. (`-d:useClone` is left out: that path crashes in `dealloc(stack)`
# right after the clone, independently of this test.)
#
# No mocks: every case makes a real `startProcess` call and compares the
# parent's open descriptors before and after it.

import std/[os, osproc, strutils]

when defined(windows):
  # CreateProcess failures are covered by the Windows implementation's own
  # handle bookkeeping; this test is about the POSIX descriptor table.
  discard
else:
  import std/posix

  const missing = "/nonexistent/tspawnfailureclosespipes-cmd"

  proc openDescriptors(): seq[cint] =
    ## Every descriptor open in this process, in ascending order.
    var lim: RLimit
    doAssert getrlimit(RLIMIT_NOFILE, lim) == 0
    let top = min(lim.rlim_cur.int, 65536)
    for fd in 0 ..< top:
      if fcntl(fd.cint, F_GETFD) >= 0:
        result.add fd.cint

  proc expectFailureLeavesNothing(what: string; command: string;
                                  workingDir = ""; args: seq[string] = @[];
                                  options: set[ProcessOption] = {}) =
    let before = openDescriptors()
    for attempt in 1 .. 3:
      var raised = false
      try:
        let p = startProcess(command, workingDir = workingDir, args = args,
                             options = options)
        # Not expected; close it so a missing failure is reported as that
        # rather than as a leak.
        discard p.waitForExit()
        p.close()
      except OSError:
        raised = true
      doAssert raised, what & ": startProcess did not fail"
      let after = openDescriptors()
      doAssert after == before, what & " (attempt " & $attempt &
        "): descriptors open before " & $before & ", after " & $after

  proc withFreeDescriptors(free: int; body: proc ()) =
    ## Runs `body` with RLIMIT_NOFILE lowered so that exactly `free`
    ## descriptor numbers are available, then restores the limit.
    var saved: RLimit
    doAssert getrlimit(RLIMIT_NOFILE, saved) == 0
    let open = openDescriptors()
    var limit = 0
    var left = free
    while left > 0:
      if limit.cint notin open: dec left
      inc limit
    var lowered = saved
    lowered.rlim_cur = limit
    doAssert setrlimit(RLIMIT_NOFILE, lowered) == 0
    try:
      body()
    finally:
      doAssert setrlimit(RLIMIT_NOFILE, saved) == 0

  proc checkAllShapes() =
    expectFailureLeavesNothing("missing command", missing)
    expectFailureLeavesNothing("missing command, stderr to stdout", missing,
                               options = {poStdErrToStdOut})
    expectFailureLeavesNothing("missing command, daemon", missing,
                               options = {poDaemon})
    expectFailureLeavesNothing("missing command on PATH",
                               "tspawnfailureclosespipes-no-such-cmd",
                               options = {poUsePath})
    expectFailureLeavesNothing("missing working directory", "/bin/sh",
                               workingDir = missing, args = @["-c", "true"])
    expectFailureLeavesNothing("missing command, parent streams", missing,
                               options = {poParentStreams})

  checkAllShapes()

  # Six free descriptors: the three child pipes fit and the fork path's
  # error pipe does not, so that path fails after creating them.
  withFreeDescriptors(6) do ():
    expectFailureLeavesNothing("no room for the error pipe", missing)
  # Three free descriptors: the second child pipe cannot be created.
  withFreeDescriptors(3) do ():
    expectFailureLeavesNothing("no room for the child pipes", missing)

  # The failures above must not have left `startProcess` unusable.
  let output = execProcess("/bin/sh", args = ["-c", "echo ok"],
                           options = {})
  doAssert output.strip == "ok", output
