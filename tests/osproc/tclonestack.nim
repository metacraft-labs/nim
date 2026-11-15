discard """
  matrix: "; -d:useFork; -d:useClone; -d:useClone -d:useMalloc; -d:useClone -d:nimPreviewProcConversion"
  output: ""
"""

# The fork path of `startProcess` gives the child it creates with `clone`
# (`-d:useClone` on Linux) a stack it allocates itself, and must free that
# stack with the pointer `alloc` returned for it. `clone` is handed the TOP
# of the allocation, because the stack grows down; freeing that top pointer
# instead of the base hands the allocator an address it never returned:
#
# * with Nim's allocator, the 64 KiB stack is never freed, so every spawn
#   leaks it, and the allocator reads a "chunk header" out of the child's
#   stack frames;
# * with `-d:useMalloc`, `free` receives an address `malloc` never returned
#   and the process crashes on its first spawn.
#
# The `-d:useClone` leg catches the first by checking that spawning does not
# grow the heap, the `-d:useClone -d:useMalloc` leg the second by spawning at
# all. The `-d:useClone -d:nimPreviewProcConversion` leg checks that the
# clone path compiles where a proc does not convert to `pointer` implicitly.
# The default (posix_spawn) and `-d:useFork` legs allocate no stack and
# hold the same checks as a baseline.
#
# No mocks: every spawn starts a real process.

import std/osproc

when defined(posix):
  const sh = when defined(android): "/system/bin/sh" else: "/bin/sh"

  proc spawnAndReap() =
    let p = startProcess(sh, args = ["-c", "exit 7"], options = {})
    doAssert p.waitForExit() == 7
    p.close()

  # The first spawn may allocate what later ones reuse, so measure after it.
  spawnAndReap()

  when not defined(useMalloc):
    const spawns = 32
    let before = getOccupiedMem()
    for _ in 1 .. spawns:
      spawnAndReap()
    let grown = getOccupiedMem() - before
    # A leaked child stack is 64 KiB per spawn, 2 MiB over the loop. Allow
    # far less than one stack in total, for the allocator's own bookkeeping.
    doAssert grown < 16 * 1024,
      "spawning " & $spawns & " processes grew the heap by " & $grown &
      " bytes"
  else:
    for _ in 1 .. 4:
      spawnAndReap()
