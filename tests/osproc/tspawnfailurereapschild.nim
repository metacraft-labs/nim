discard """
  matrix: "; -d:useFork; -d:useClone"
  output: ""
"""

# A `startProcess` that fails must not leave a child behind. On the fork path
# the child is created before it is known whether it can run the command:
# when its `dup2`, `setpgid`, `chdir` or `exec` fails, it reports the error
# through the error pipe and exits. The caller gets an `OSError` and no
# `Process`, so it has no pid to wait for; unless `startProcess` reaps the
# child itself, every failed start leaves a zombie until the parent exits,
# and a long-running process that retries a failing start fills the process
# table.
#
# The default leg drives the posix_spawn path (glibc reaps a child whose exec
# failed before `posix_spawn` returns), `-d:useFork` the fork/exec path, and
# `-d:useClone` the same path with the child created by `clone`.
#
# No mocks: every case makes a real `startProcess` call and then asks the
# kernel, with `waitpid(-1, …)`, whether this process has any child left.

import std/[osproc, strutils]

when defined(windows):
  # CreateProcess creates no process when it fails; this test is about the
  # POSIX fork path.
  discard
else:
  import std/posix

  const missing = "/nonexistent/tspawnfailurereapschild-cmd"

  proc leftoverChildren(): int =
    ## Reaps every child of this process and returns how many there were.
    ## By the time a failed `startProcess` returns, its child has reported
    ## the error and is exiting, but it may not have finished: it is a zombie
    ## or about to become one. So the wait blocks, and returns once this
    ## process has no child at all (`ECHILD`). Every child the tests start on
    ## purpose is waited for before this is called, so whatever it reaps was
    ## left behind.
    while true:
      var status: cint
      let pid = waitpid(-1, status, 0)
      if pid > 0:
        inc result
      else:
        let err = errno
        if err == EINTR: continue
        doAssert err == ECHILD, "waitpid: " & $strerror(err)
        return

  proc expectFailureLeavesNoChild(what: string; command: string;
                                  workingDir = ""; args: seq[string] = @[];
                                  options: set[ProcessOption] = {}) =
    doAssert leftoverChildren() == 0, what & ": children before the test"
    for attempt in 1 .. 3:
      var raised = false
      try:
        let p = startProcess(command, workingDir = workingDir, args = args,
                             options = options)
        # Not expected; wait for it so a missing failure is reported as that
        # rather than as a leftover child.
        discard p.waitForExit()
        p.close()
      except OSError:
        raised = true
      doAssert raised, what & ": startProcess did not fail"
      let left = leftoverChildren()
      doAssert left == 0, what & " (attempt " & $attempt & "): " & $left &
        " child process(es) left behind by a failed startProcess"

  # Each shape fails at a different step in the child: `exec` for a missing
  # command (with or without the stream redirections), `setpgid` before it
  # for `poDaemon`, the `PATH` lookup for `poUsePath`, and `chdir` for a
  # missing working directory.
  expectFailureLeavesNoChild("missing command", missing)
  expectFailureLeavesNoChild("missing command, stderr to stdout", missing,
                             options = {poStdErrToStdOut})
  expectFailureLeavesNoChild("missing command, daemon", missing,
                             options = {poDaemon})
  expectFailureLeavesNoChild("missing command on PATH",
                             "tspawnfailurereapschild-no-such-cmd",
                             options = {poUsePath})
  expectFailureLeavesNoChild("missing working directory", "/bin/sh",
                             workingDir = missing, args = @["-c", "true"])
  expectFailureLeavesNoChild("missing command, parent streams", missing,
                             options = {poParentStreams})

  # The failures above must not have left `startProcess` unusable, and a
  # successful start must still hand the child to the caller: it is the
  # caller's to wait for, not reaped by `startProcess`.
  let p = startProcess("/bin/sh", args = ["-c", "exit 7"], options = {})
  doAssert p.waitForExit() == 7
  p.close()
  doAssert leftoverChildren() == 0
  let output = execProcess("/bin/sh", args = ["-c", "echo ok"],
                           options = {})
  doAssert output.strip == "ok", output
