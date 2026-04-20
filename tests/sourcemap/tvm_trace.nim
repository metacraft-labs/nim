discard """
  action: "run"
  targets: "c"
"""

## Test that `nim e --trace` produces a valid .ct trace file.

import std/[os, osproc, compilesettings, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace"

const testScript = """
proc add(a, b: int): int =
  result = a + b

let x = add(3, 4)
echo x
"""

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let scriptFile = buildDir / "test_script.nims"
  let traceFile = buildDir / "test_trace.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert fileExists(traceFile), "trace file not created"
  doAssert getFileSize(traceFile) > 0, "trace file is empty"

  # Verify CTFS magic bytes
  let data = readFile(traceFile)
  doAssert data.len >= 5
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and data[2] == '\x72' and
           data[3] == '\xAC' and data[4] == '\xE2', "not a valid CTFS file"

  removeDir(buildDir)
  echo "PASS: tvm_trace"

main()
