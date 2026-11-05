discard """
  matrix: "--threads:on"
  output: ""
"""

# `startProcess(workingDir = ...)` must apply the directory in the child only.
# The current directory belongs to the whole process, so changing it in the
# parent around the spawn makes every other thread resolve relative paths
# against the child's directory while the spawn is in flight, and two threads
# spawning at once can leave the process in the wrong directory for good.
#
# No mocks: every case spawns real children through `/bin/sh`.

import std/[os, osproc, streams, strutils, atomics, typedthreads]

when defined(windows):
  # CreateProcess takes the child's directory as an argument.
  discard
else:
  const
    spawnsPerThread = 200
    sh = when defined(android): "/system/bin/sh" else: "/bin/sh"

  let
    home = getCurrentDir()
    scratch = getTempDir() / "tworkingdirthreads_" & $getCurrentProcessId()
    dirA = scratch / "a"
    dirB = scratch / "b"
  createDir(dirA)
  createDir(dirB)

  proc spawnIn(dir: string) =
    let p = startProcess(sh, workingDir = dir, args = ["-c", "exit 0"],
                         options = {})
    doAssert p.waitForExit() == 0
    p.close()

  # Case 1: a thread that never spawns must never see its directory move
  # while another thread spawns with a `workingDir`.
  var stopWatcher: Atomic[bool]
  var watcherMismatches: Atomic[int]

  proc watch(expected: string) {.thread.} =
    while not stopWatcher.load():
      if getCurrentDir() != expected:
        watcherMismatches.atomicInc()

  proc spawner(dir: string) {.thread.} =
    for _ in 0 ..< spawnsPerThread:
      spawnIn(dir)

  block:
    var watcher, worker: Thread[string]
    createThread(watcher, watch, home)
    createThread(worker, spawner, dirA)
    joinThread(worker)
    stopWatcher.store(true)
    joinThread(watcher)
    doAssert watcherMismatches.load() == 0,
      "another thread saw the current directory change " &
      $watcherMismatches.load() & " times while spawning in " & dirA

  # Case 2: two threads spawning concurrently in different directories must
  # leave the process where it started.
  block:
    var t1, t2: Thread[string]
    createThread(t1, spawner, dirA)
    createThread(t2, spawner, dirB)
    joinThread(t1)
    joinThread(t2)
    doAssert getCurrentDir() == home,
      "current directory is " & getCurrentDir() & ", expected " & home

  # Case 3: the child itself still runs in `workingDir`.
  block:
    let (output, code) = execCmdEx("pwd -P", workingDir = dirA)
    doAssert code == 0
    doAssert output.strip() == expandFilename(dirA),
      "child ran in " & output.strip() & ", expected " & dirA

  # Case 4: a relative command resolves against `workingDir`.
  block:
    let script = dirB / "hello.sh"
    writeFile(script, "#!" & sh & "\necho hello-from-b\n")
    setFilePermissions(script, {fpUserRead, fpUserWrite, fpUserExec})
    let p = startProcess("./hello.sh", workingDir = dirB, options = {})
    let output = p.outputStream.readAll()
    doAssert p.waitForExit() == 0
    p.close()
    doAssert output.strip() == "hello-from-b", output

  # Case 5: a missing `workingDir` raises and leaves the caller's directory
  # alone.
  block:
    var raised = false
    try:
      spawnIn(scratch / "missing")
    except OSError:
      raised = true
    doAssert raised, "spawning in a missing directory did not raise"
    doAssert getCurrentDir() == home

  # Case 6: a spawn that fails after the directory is set (a file with the
  # exec bit whose format the kernel rejects, ENOEXEC; posix_spawn does not
  # fall back to the shell) leaves the caller's directory alone.
  block:
    let bogus = dirA / "not-an-executable"
    writeFile(bogus, "\x7fnot an image\n")
    setFilePermissions(bogus, {fpUserRead, fpUserWrite, fpUserExec})
    var raised = false
    try:
      let p = startProcess(bogus, workingDir = dirA, options = {})
      discard p.waitForExit()
      p.close()
    except OSError:
      raised = true
    doAssert raised, "spawning a non-executable did not raise"
    doAssert getCurrentDir() == home,
      "current directory is " & getCurrentDir() & ", expected " & home

  # Case 7: `poDaemon` still puts a child spawned with a `workingDir` in its
  # own process group (field 5 of /proc/<pid>/stat is the process group).
  when defined(linux):
    block:
      let p = startProcess(sh, workingDir = dirA,
        args = ["-c", "echo $$; cut -d' ' -f5 /proc/$$/stat"],
        options = {poDaemon})
      let lines = p.outputStream.readAll().splitLines()
      doAssert p.waitForExit() == 0
      p.close()
      doAssert lines.len >= 2 and lines[0] == lines[1],
        "poDaemon child is not its own process group leader: " & $lines

  removeDir(scratch)
