discard """
  action: "run"
  targets: "c"
"""

## Test that `nim secret --trace` (the REPL) produces a valid .ct trace file.
## Commands are piped via stdin; EOF (closing the input stream) triggers REPL exit.

import std/[os, osproc, streams, compilesettings, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_repl"

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let traceFile = buildDir / "repl_trace.ct"

  # Remove any leftover trace file from a previous run
  if fileExists(traceFile):
    removeFile(traceFile)

  # Start the REPL with --trace, piping commands via stdin
  let p = startProcess(nim,
    args = @["secret", "--trace:" & traceFile],
    options = {poUsePath, poStdErrToStdOut})

  let inp = p.inputStream
  inp.write("let x = 1 + 2\n")
  inp.write("echo x\n")
  inp.close()  # EOF triggers REPL exit

  let exitCode = p.waitForExit()
  p.close()

  doAssert exitCode == 0, "nim secret --trace failed with exit code " & $exitCode

  # The trace file must exist and be non-empty
  doAssert fileExists(traceFile), "trace file not created: " & traceFile
  doAssert getFileSize(traceFile) > 0, "trace file is empty"

  # Verify CTFS magic bytes: C0 DE 72 AC E2
  let data = readFile(traceFile)
  doAssert data.len >= 5, "trace file too small: " & $data.len & " bytes"
  doAssert data[0] == '\xC0' and data[1] == '\xDE' and data[2] == '\x72' and
           data[3] == '\xAC' and data[4] == '\xE2',
           "not a valid CTFS file (bad magic bytes)"

  removeDir(buildDir)
  echo "PASS: tvm_trace_repl"

main()
