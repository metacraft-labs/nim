discard """
  targets: "c"
  joinable: false
"""

# A protocol document has to survive a program that prints on its own account.
#
# A `suite` body runs when the suite is DECLARED, which is long before the
# document is written, so an ordinary `echo` in one lands on the same descriptor
# the document is about to use. The case that no consumer can recover from is a
# write with no trailing newline: it does not add a spurious line, it splices
# itself onto the front of a real payload line, and nothing in the byte stream
# says where the noise stops and the payload starts.
#
# This file is its own fixture. Run with no arguments it drives copies of itself
# through every protocol mode and checks where each stream went; the suite below
# supplies the noise in each of those copies.

import std/[assertions, envvars, os, osproc, strutils, syncio, unittest]

const
  childEnv = "TUNITTEST_PROTOCOL_STDOUT_CHILD"
    ## Marks a copy spawned by the driver. One of the runs below passes NO
    ## arguments — the plain, protocol-free case — so "was I given arguments?"
    ## cannot be the thing that distinguishes a child, on pain of a fork bomb.
  noiseFullLine = "fixture noise: a whole line"
  noiseDecoy = """{"tests":[{"name":"decoy"}],"summary":{"total":1}}"""
  noisePartialLine = "fixture noise: no trailing newline -> "

proc runSelf(args: varargs[string]):
    tuple[outp: string, errp: string, exitCode: int] =
  ## Run this binary again with `args`, keeping the two streams apart.
  ## `execCmdEx` folds stderr into stdout by default, which is exactly the
  ## confusion under test, so stderr is redirected to a file by the shell.
  let errPath = getTempDir() / ("tunittest_protocol_stdout_" &
    $getCurrentProcessId() & ".err")
  var cmd = quoteShell(getAppFilename())
  for arg in args:
    cmd.add " "
    cmd.add quoteShell(arg)
  cmd.add " 2>"
  cmd.add quoteShell(errPath)
  putEnv(childEnv, "1")
  let run = execCmdEx(cmd, options = {poEvalCommand, poUsePath})
  delEnv(childEnv)
  let errText = if fileExists(errPath): readFile(errPath) else: ""
  if fileExists(errPath):
    removeFile(errPath)
  result = (run.output, errText, run.exitCode)

proc expectContains(haystack, needle: string) =
  doAssert haystack.contains(needle), haystack & "\nmissing: " & needle

proc expectNotContains(haystack, needle: string) =
  doAssert not haystack.contains(needle), haystack & "\nunexpected: " & needle

proc expectNoNoise(stream: string) =
  expectNotContains stream, noiseFullLine
  expectNotContains stream, noisePartialLine
  expectNotContains stream, """{"name":"decoy""""

proc expectAllNoise(stream: string) =
  expectContains stream, noiseFullLine
  expectContains stream, noiseDecoy
  expectContains stream, noisePartialLine

if not existsEnv(childEnv):
  # --list: the mode with no redundancy at all. A mangled name is
  # indistinguishable from a real one, so the whole stream has to be clean.
  let listed = runSelf("--list")
  doAssert listed.exitCode == 0, listed.outp & listed.errp
  doAssert listed.outp == """
noisy suite::first case
noisy suite::second case
""", listed.outp
  expectAllNoise listed.errp

  # --list-json: the document must be the entire stream, not merely somewhere
  # in it. A partial line ahead of it would leave the payload unparseable even
  # though every byte of the document is present.
  let listJson = runSelf("--list-json")
  doAssert listJson.exitCode == 0, listJson.outp & listJson.errp
  doAssert listJson.outp.startsWith("""{"tests":["""), listJson.outp
  doAssert listJson.outp.endsWith("}\n"), listJson.outp
  expectContains listJson.outp, """"name":"noisy suite::first case""""
  expectNoNoise listJson.outp
  expectAllNoise listJson.errp

  # --catalog -
  let catalog = runSelf("--catalog", "-")
  doAssert catalog.exitCode == 0, catalog.outp & catalog.errp
  doAssert catalog.outp.startsWith("""{"version":1,"tests":{"""), catalog.outp
  expectContains catalog.outp, """"noisy suite::first case""""
  expectNoNoise catalog.outp
  expectAllNoise catalog.errp

  # --catalog FILE never puts a document on standard output, so the program's
  # own output is left exactly where it was.
  let catalogPath = getTempDir() / ("tunittest_protocol_stdout_catalog_" &
    $getCurrentProcessId() & ".json")
  let toFile = runSelf("--catalog", catalogPath)
  doAssert toFile.exitCode == 0, toFile.outp & toFile.errp
  expectAllNoise toFile.outp
  doAssert fileExists(catalogPath)
  let catalogText = readFile(catalogPath)
  doAssert catalogText.startsWith("""{"version":1,"tests":{"""), catalogText
  expectNoNoise catalogText
  removeFile(catalogPath)
  doAssert toFile.errp.len == 0, toFile.errp

  # --run reports through NIMTEST_RESULT_FILE and standard output belongs to the
  # test, which is the point of running it. Nothing is moved.
  let ran = runSelf("--run", "noisy suite::first case")
  doAssert ran.exitCode == 0, ran.outp & ran.errp
  expectAllNoise ran.outp
  expectContains ran.outp, "output from the test body"
  doAssert ran.errp.len == 0, ran.errp

  # A run with no protocol flag is untouched in every respect.
  let plain = runSelf()
  doAssert plain.exitCode == 0, plain.outp & plain.errp
  expectAllNoise plain.outp
  expectContains plain.outp, "output from the test body"
  # `tests/config.nims` builds with `nimUnittestOutputLevel:PRINT_FAILURES`, so
  # a passing test prints no `[OK]` line here; the suite header is what proves
  # the console formatter is still installed and still writing where it did.
  expectContains plain.outp, "[Suite] noisy suite"
  doAssert plain.errp.len == 0, plain.errp

suite "noisy suite":
  echo noiseFullLine
  echo noiseDecoy
  write(stdout, noisePartialLine)

  test "first case":
    echo "output from the test body"
    check 1 == 1

  test "second case":
    check 2 == 2
