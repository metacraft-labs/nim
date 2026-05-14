discard """
  action: "run"
  targets: "c"
"""

## Test that `nim e --trace` handles error cases gracefully:
## - Syntax errors in scripts
## - Runtime errors (division by zero)
## - Undefined identifiers
## - Empty scripts
## - Bad imports
##
## Verifies: correct exit codes, no crashes, and any produced trace files
## have valid CTFS magic (not corrupted).

import std/[os, osproc, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_errors"

proc verifyCtfsMagicIfExists(path: string): bool =
  ## If the file exists, verify it has valid CTFS magic. Returns true if
  ## file doesn't exist (acceptable for compile errors) or has valid magic.
  if not fileExists(path):
    return true
  let data = readFile(path)
  if data.len < 5:
    return false
  data[0] == '\xC0' and data[1] == '\xDE' and
    data[2] == '\x72' and data[3] == '\xAC' and
    data[4] == '\xE2'

proc runTraceTest(nim, scriptContent, testName: string): tuple[output: string, exitCode: int, traceExists: bool] =
  let scriptFile = buildDir / (testName & ".nims")
  let traceFile = buildDir / (testName & ".ct")
  writeFile(scriptFile, scriptContent)
  if fileExists(traceFile):
    removeFile(traceFile)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  let traceExists = fileExists(traceFile)
  (output, exitCode, traceExists)

proc main() =
  # CTFS-M1: the VM trace emitter is unconditional in `bin/nim`; no
  # separate `nim_trace` binary exists. Drive `--trace:` via the same
  # compiler used to build this test.
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  createDir(buildDir)

  # ---- Test 1: Script with syntax error ----
  block:
    const script = """
proc broken( =  # invalid syntax
  echo "unreachable"
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "syntax_error")
    doAssert exitCode != 0, "syntax error script should fail, but got exit 0"
    # If a trace file was produced, it must not be corrupted
    let traceFile = buildDir / "syntax_error.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "syntax error produced a corrupted trace file"
    echo "  PASS: syntax error - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 2: Script with runtime error (division by zero) ----
  block:
    const script = """
let x = 1
let y = 0
echo x div y  # division by zero at runtime
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "runtime_div_zero")
    doAssert exitCode != 0, "division by zero should fail, but got exit 0"
    # Runtime errors should still produce a partial trace (the VM ran before crashing)
    let traceFile = buildDir / "runtime_div_zero.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "runtime error produced a corrupted trace file"
    # If trace exists, it should be non-empty (the VM did execute some steps)
    if traceExists:
      doAssert getFileSize(traceFile) > 5,
        "runtime error trace file is too small (should have partial trace)"
    echo "  PASS: runtime div-by-zero - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 3: Script with undefined identifier ----
  block:
    const script = """
echo undefinedVariable
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "undefined_ident")
    doAssert exitCode != 0, "undefined identifier should fail, but got exit 0"
    let traceFile = buildDir / "undefined_ident.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "undefined ident produced a corrupted trace file"
    echo "  PASS: undefined identifier - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 4: Empty script ----
  block:
    const script = ""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "empty_script")
    # Empty script should succeed (nothing to execute is not an error)
    doAssert exitCode == 0, "empty script should succeed, got exit code " & $exitCode &
      "\nOutput: " & output
    # Trace file should exist and be valid (even if minimal)
    let traceFile = buildDir / "empty_script.ct"
    if traceExists:
      doAssert verifyCtfsMagicIfExists(traceFile),
        "empty script produced a corrupted trace file"
      doAssert getFileSize(traceFile) > 0,
        "empty script trace file is zero bytes"
    echo "  PASS: empty script - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 5: Script that imports non-existent module ----
  block:
    const script = """
import nonexistent_module_xyz_12345
echo "should not reach here"
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "bad_import")
    doAssert exitCode != 0, "bad import should fail, but got exit 0"
    let traceFile = buildDir / "bad_import.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "bad import produced a corrupted trace file"
    echo "  PASS: bad import - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 6: Script with type error ----
  block:
    const script = """
let x: int = "this is a string"
echo x
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "type_error")
    doAssert exitCode != 0, "type error should fail, but got exit 0"
    let traceFile = buildDir / "type_error.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "type error produced a corrupted trace file"
    echo "  PASS: type error - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 7: Script that succeeds but has no function calls ----
  block:
    const script = """
echo "hello"
echo "world"
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "simple_echo")
    doAssert exitCode == 0, "simple echo should succeed, got: " & $exitCode &
      "\nOutput: " & output
    let traceFile = buildDir / "simple_echo.ct"
    doAssert traceExists, "simple echo should produce a trace file"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "simple echo produced a corrupted trace file"
    doAssert getFileSize(traceFile) > 16,
      "simple echo trace should be non-trivial"
    echo "  PASS: simple echo - exit code " & $exitCode & ", trace=" & $traceExists

  # ---- Test 8: Script with infinite recursion (stack overflow) ----
  block:
    const script = """
proc infinite(n: int): int =
  infinite(n + 1)

echo infinite(0)
"""
    let (output, exitCode, traceExists) = runTraceTest(nim, script, "stack_overflow")
    doAssert exitCode != 0, "stack overflow should fail, but got exit 0"
    let traceFile = buildDir / "stack_overflow.ct"
    doAssert verifyCtfsMagicIfExists(traceFile),
      "stack overflow produced a corrupted trace file"
    echo "  PASS: stack overflow - exit code " & $exitCode & ", trace=" & $traceExists

  removeDir(buildDir)
  echo "PASS: tvm_trace_errors - all error cases handled gracefully"

main()
