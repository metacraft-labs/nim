discard """
  action: "run"
  targets: "c"
  matrix: "--gc:orc"
"""

## C Source Map V2 — cleanliness assertion.
##
## The headline V2 promise is that the generated .c file no longer
## contains any preprocessor directives the V1 sourcemap mechanism
## used to leave behind (`#line N FX_K`, `#define FX_<n> "..."`).
## Without those, gcc's DWARF maps assembly to *real* C lines, not
## back-projected Nim lines, which is what makes the C view actually
## steppable in gdb/lldb and what CodeTracer's three-way switching
## needs end-to-end.

import std/[os, strutils, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tc_sourcemap_no_line"

const testProgram = """
proc add(a, b: int): int =
  result = a + b

when isMainModule:
  let x = add(3, 4)
  echo x
"""

proc main() =
  let nim = getCurrentCompilerExe()
  let nimcache = buildDir / "nimcache"
  let srcFile = buildDir / "test_no_line.nim"
  let outFile = buildDir / "test_no_line"

  createDir(buildDir)
  writeFile(srcFile, testProgram)

  let cmd = nim & " c --nimcache:" & nimcache &
    " --sourcemap:on -d:release --hints:off --warnings:off -o:" &
    outFile & " " & srcFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "Compilation failed: " & output

  # Inspect every generated .c file in the nimcache.
  var checkedFiles = 0
  for entry in walkDir(nimcache):
    if not entry.path.endsWith(".c"): continue
    inc checkedFiles
    let body = readFile(entry.path)
    doAssert "#line " notin body,
      "V2 violation: '#line ' directive still present in " &
      entry.path
    doAssert "#define FX_" notin body,
      "V2 violation: '#define FX_' line still present in " &
      entry.path
    # Also ensure no raw markers leaked from the side-channel
    # stripper (would indicate a bug in c_sourcemap.stripMarkersAndCollect).
    doAssert "@CTSM" notin body,
      "V2 violation: raw side-channel marker leaked into " &
      entry.path

  doAssert checkedFiles > 0,
    "No .c files found under nimcache to inspect"

  removeDir(buildDir)
  echo "C sourcemap V2 cleanliness test passed (",
       checkedFiles, " files checked)"

main()
