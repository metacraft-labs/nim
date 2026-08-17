discard """
  targets: "c"
  joinable: false
"""

## A failing `check` in a helper `proc` must fail the test that called it.
##
## `fail` reaches the enclosing test through `testStatusIMPL`, the symbol
## `test` injects into the test body. A `check` written in a helper `proc` —
## the ordinary way to share assertions between cases — is compiled outside
## that body, so the symbol does not resolve and `fail` used to fall back to
## setting the process exit code.
##
## That fallback cannot carry a failure out of a test, for a reason that only
## shows up on the per-case protocol path: `test` writes the exit code from the
## test's own status when the case finishes, so the fallback's `1` was
## overwritten by the `0` of a status that no one had marked failed. The case
## then reported `PASS` on BOTH channels — result document and exit code — so
## there was not even a disagreement for a runner to notice. A whole-binary run
## kept the exit code but still printed `[OK]` for the case, which is why this
## could survive in a suite that looked green case by case and red overall.
##
## So both channels are asserted here, on both the per-case path and the
## whole-binary path, and the last case pins the fallback that is still correct:
## a `fail` with no test running on this thread has nothing to mark, and setting
## the exit code is all it can do.

import std/[assertions, envvars, os, osproc, strutils, syncio, unittest]
import munittest_helper_proc_fixture

const resultEnv = "NIMTEST_RESULT_FILE"

proc expectEqualSameModule(a, b: int) =
  check a == b

proc selfCommand(args: openArray[string]): string =
  result = quoteShell(getAppFilename())
  for arg in args:
    result.add " "
    result.add quoteShell(arg)

proc runSelf(args: varargs[string]): tuple[output: string, exitCode: int] =
  execCmdEx(selfCommand(args))

proc withResultFile(name: string; args: varargs[string]):
    tuple[output: string, exitCode: int, resultJson: string] =
  let path = getTempDir() / ("tunittest_helper_proc_" & name & "_" &
    $getCurrentProcessId() & ".json")
  let hadPrevious = existsEnv(resultEnv)
  let previous = getEnv(resultEnv)
  putEnv(resultEnv, path)
  try:
    let run = execCmdEx(selfCommand(args))
    let content = if fileExists(path): readFile(path) else: ""
    result = (run.output, run.exitCode, content)
  finally:
    if fileExists(path):
      removeFile(path)
    if hadPrevious:
      putEnv(resultEnv, previous)
    else:
      delEnv(resultEnv)

proc expectContains(haystack, needle: string) =
  doAssert haystack.contains(needle), haystack & "\nmissing: " & needle

proc expectNotContains(haystack, needle: string) =
  doAssert not haystack.contains(needle), haystack & "\nunexpected: " & needle

if commandLineParams().len == 0:
  # ---- the per-case protocol path ---------------------------------------
  #
  # This is the path the failure used to disappear on entirely: the document
  # is what a runner reports, and it said PASS.
  let sameModule = withResultFile("same-module",
    "--run", "helper proc::failing check in a helper proc in this module")
  doAssert sameModule.exitCode == 1, sameModule.output & sameModule.resultJson
  expectContains sameModule.resultJson, """"status":"FAIL""""
  expectContains sameModule.resultJson, "Check failed"
  expectContains sameModule.resultJson, "a == b"

  let otherModule = withResultFile("other-module",
    "--run", "helper proc::failing check in a helper proc in another module")
  doAssert otherModule.exitCode == 1,
    otherModule.output & otherModule.resultJson
  expectContains otherModule.resultJson, """"status":"FAIL""""
  expectContains otherModule.resultJson, "Check failed"

  # A helper that does not fail must not acquire a failure from the mechanism
  # that carries one.
  let passing = withResultFile("passing",
    "--run", "helper proc::passing check in a helper proc")
  doAssert passing.exitCode == 0, passing.output & passing.resultJson
  expectContains passing.resultJson, """"status":"PASS""""
  expectContains passing.resultJson, """"checkpoints":[]"""

  # ---- the whole-binary path --------------------------------------------
  #
  # The exit code was already 1 here, so it does not discriminate. What was
  # wrong is the per-case verdict a developer reads: the checkpoint was
  # printed and the case was then marked as having passed. Only the `[FAILED]`
  # marker is asserted, because `tests/config.nims` compiles this suite with
  # `nimUnittestOutputLevel:PRINT_FAILURES`, under which a passing case prints
  # nothing at all — the passing case is covered by its document above.
  let wholeBinary = runSelf("helper proc::*")
  doAssert wholeBinary.exitCode == 1, wholeBinary.output
  expectContains wholeBinary.output,
    "[FAILED] failing check in a helper proc in this module"
  expectContains wholeBinary.output,
    "[FAILED] failing check in a helper proc in another module"
  expectNotContains wholeBinary.output,
    "[OK] failing check in a helper proc"

  # ---- the fallback that is still correct --------------------------------
  #
  # `outside-any-test` matches no test, so nothing runs and the trailing call
  # at the bottom of this file reaches `fail` with no test running on this
  # thread. There is no status to mark, and the exit code is the only channel
  # left.
  let outside = runSelf("outside-any-test")
  doAssert outside.exitCode == 1, outside.output
  expectContains outside.output, "outside any test"

  quit 0

suite "helper proc":
  test "failing check in a helper proc in this module":
    expectEqualSameModule(1, 2)

  test "failing check in a helper proc in another module":
    expectEqualAcrossModules(3, 4)

  test "passing check in a helper proc":
    expectEqualSameModule(5, 5)

if commandLineParams() == @["outside-any-test"]:
  echo "outside any test"
  expectEqualSameModule(6, 7)
