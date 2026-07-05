discard """
  targets: "c"
  joinable: false
"""

import std/[assertions, envvars, os, osproc, strutils, syncio, unittest]

const resultEnv = "NIMTEST_RESULT_FILE"

proc selfCommand(args: openArray[string]): string =
  result = quoteShell(getAppFilename())
  for arg in args:
    result.add " "
    result.add quoteShell(arg)

proc runSelf(args: varargs[string]): tuple[output: string, exitCode: int] =
  execCmdEx(selfCommand(args))

proc withResultFile(name: string; args: varargs[string]):
    tuple[output: string, exitCode: int, resultJson: string] =
  let path = getTempDir() / ("tunittest_protocol_" & name & "_" &
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
  let listed = runSelf("--list")
  doAssert listed.exitCode == 0, listed.output
  doAssert listed.output == """
::top level
protocol suite::selected
protocol suite::skipped
protocol suite::failing
protocol suite::not selected
other suite::selected
""", listed.output

  let listJson = runSelf("--list-json")
  doAssert listJson.exitCode == 0, listJson.output
  expectContains listJson.output, """"name":"protocol suite::selected""""
  expectContains listJson.output, """"bodyHash":""""
  expectContains listJson.output, """"summary":{"total":6"""
  expectNotContains listJson.output, "selected body"

  let catalogPath = getTempDir() / ("tunittest_protocol_catalog_" &
    $getCurrentProcessId() & ".json")
  let catalogFile = runSelf("--catalog", catalogPath)
  doAssert catalogFile.exitCode == 0, catalogFile.output
  doAssert fileExists(catalogPath), catalogFile.output
  let catalogJson = readFile(catalogPath)
  removeFile(catalogPath)
  expectContains catalogJson, """"version":1"""
  expectContains catalogJson, """"protocol suite::selected":""""

  let catalogStdout = runSelf("--catalog", "-")
  doAssert catalogStdout.exitCode == 0, catalogStdout.output
  expectContains catalogStdout.output, """"protocol suite::selected":""""

  let selected = withResultFile("pass", "--run", "protocol suite::selected")
  doAssert selected.exitCode == 0, selected.output & selected.resultJson
  doAssert selected.output == "selected body\n", selected.output
  expectContains selected.resultJson, """"status":"PASS""""
  expectContains selected.resultJson, """"checkpoints":[]"""
  expectContains selected.resultJson, """"exception":null"""

  let skipped = withResultFile("skip", "--run", "protocol suite::skipped")
  doAssert skipped.exitCode == 2, skipped.output & skipped.resultJson
  doAssert skipped.output == "", skipped.output
  expectContains skipped.resultJson, """"status":"SKIP""""
  expectContains skipped.resultJson, """"skipReason":"not available""""

  let failing = withResultFile("fail", "--run", "protocol suite::failing")
  doAssert failing.exitCode == 1, failing.output & failing.resultJson
  expectContains failing.resultJson, """"status":"FAIL""""
  expectContains failing.resultJson, "Check failed"
  expectContains failing.resultJson, "1 == 2"

  let missing = withResultFile("missing", "--run", "protocol suite::missing")
  doAssert missing.exitCode == 1, missing.output & missing.resultJson
  expectContains missing.resultJson, """"status":"FAIL""""
  expectContains missing.resultJson, "test not found: protocol suite::missing"

  let positional = runSelf("protocol suite::selected")
  doAssert positional.exitCode == 0, positional.output
  expectContains positional.output, "[Suite] protocol suite"
  expectContains positional.output, "selected body"
  expectNotContains positional.output, "not selected body"

  quit 0

test "top level":
  echo "top level body"

suite "protocol suite":
  test "selected":
    echo "selected body"
    check true

  test "skipped":
    skip("not available")

  test "failing":
    check 1 == 2

  test "not selected":
    echo "not selected body"
    check false

suite "other suite":
  test "selected":
    echo "wrong selected body"
    check false
