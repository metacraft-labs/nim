discard """
  action: "run"
  targets: "c"
  matrix: "--gc:orc"
"""

## C Source Map V3 — cleanliness assertion.
##
## The headline V2+V3 promise is that the generated .c file no longer
## contains any preprocessor directives the V1 sourcemap mechanism
## used to leave behind (`#line N FX_K`, `#define FX_<n> "..."`),
## nor any side-channel markers from V2's earlier marker-based
## prototype. Without those, gcc's DWARF maps assembly to *real* C
## lines, not back-projected Nim lines — what makes the C view
## actually steppable in gdb/lldb and what CodeTracer's three-way
## switching needs end-to-end. At V3 the mapping data lives entirely
## in the per-`.c` `.map` sidecar (Source Map V3 format).

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
    # Also ensure no raw markers leaked from the (now-retired) V2
    # marker scheme. The .c must be plain C.
    doAssert "@CTSM" notin body,
      "raw V2 side-channel marker leaked into " & entry.path

  doAssert checkedFiles > 0,
    "No .c files found under nimcache to inspect"

  # And confirm the `.map` sidecar exists for at least one .c
  var mapFiles = 0
  for entry in walkDir(nimcache):
    if entry.path.endsWith(".c.map"): inc mapFiles
  doAssert mapFiles > 0,
    "Expected at least one V3 `.map` sidecar in " & nimcache

  removeDir(buildDir)
  echo "C sourcemap V3 cleanliness test passed (",
       checkedFiles, " .c files, ", mapFiles, " .map sidecars)"

main()
