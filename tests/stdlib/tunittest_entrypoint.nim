discard """
  targets: "c"
  joinable: false
"""

# `std/unittest` answers nim-entrypoints' tests entry: the run-time selector
# `--entrypoint=<name>` as the first argument, and the entry's own `--list`,
# `--list-test-cases`, `--run-exact` and `--run` after it.
#
# The programs under test are fixtures compiled here, because one of them
# carries a failing test on purpose and this binary has to pass:
#
# * `munittest_entrypoint_fixture` answers the entry through `std/unittest`
#   alone. It is compiled twice, the second time with a test whose name holds
#   a line break and with `abortOnError` set.
# * `munittest_entrypoint_linked_fixture` sees the names nim-entrypoints
#   declares, through a stand-in module (see `munittest_entrypoint_standin`
#   for why a stand-in), so `std/unittest` must stand down.
#
# Standard output and standard error are captured apart throughout: which of
# the two a line reaches is part of what is under test.

import std/[assertions, envvars, json, os, osproc, strutils, syncio, tempfiles]

const resultEnv = "NIMTEST_RESULT_FILE"

type Run = tuple[outp, errp: string, exitCode: int]

var buildDir: string

proc compileFixture(nim, libDir, fixture, name: string;
                    extra: openArray[string] = []): string =
  ## Copy `fixture` (and the stand-in) into the build directory and compile it
  ## there, outside `tests/`, so the program is built as a user would build
  ## it, without this directory's test configuration.
  let here = currentSourcePath().parentDir
  let source = buildDir / fixture
  writeFile(source, readFile(here / fixture))
  writeFile(buildDir / "munittest_entrypoint_standin.nim",
    readFile(here / "munittest_entrypoint_standin.nim"))
  result = buildDir / addFileExt(name, ExeExt)
  var command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(buildDir / (name & "_nimcache")) &
    " -o:" & quoteShell(result)
  for arg in extra:
    command.add " " & quoteShell(arg)
  command.add " " & quoteShell(source)
  let compiled = execCmdEx(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  doAssert fileExists(result), "compiler did not produce " & result

proc run(binary: string; args: varargs[string]): Run =
  ## Run `binary` with `args`, stdout and stderr apart. `execCmdEx` folds the
  ## two together, so stderr goes to a file through the shell.
  let errPath = buildDir / "stderr.txt"
  var cmd = quoteShell(binary)
  for arg in args:
    cmd.add " " & quoteShell(arg)
  cmd.add " 2>" & quoteShell(errPath)
  let ran = execCmdEx(cmd, options = {poEvalCommand, poUsePath})
  let errText = if fileExists(errPath): readFile(errPath) else: ""
  if fileExists(errPath):
    removeFile(errPath)
  result = (ran.output, errText, ran.exitCode)

proc runWithResultFile(binary: string; args: varargs[string]):
    tuple[ran: Run, resultJson: string] =
  let path = buildDir / "result.json"
  putEnv(resultEnv, path)
  try:
    result.ran = run(binary, args)
    result.resultJson = if fileExists(path): readFile(path) else: ""
  finally:
    delEnv(resultEnv)
    if fileExists(path):
      removeFile(path)

proc describe(r: Run): string =
  "exit " & $r.exitCode & "\n--- stdout\n" & r.outp & "\n--- stderr\n" & r.errp

proc expectContains(haystack, needle: string) =
  doAssert haystack.contains(needle), haystack & "\nmissing: " & needle

proc expectNotContains(haystack, needle: string) =
  doAssert not haystack.contains(needle), haystack & "\nunexpected: " & needle

const
  names = ["outside", "math::add", "math::mul", "math::skipped",
           "math::star*", "math::starry"]

proc markersRun(r: Run): seq[string] =
  ## The tests whose bodies ran, from their markers on standard output.
  for line in r.outp.splitLines:
    let at = line.find("marker: ")
    if at >= 0:
      result.add line.substr(at + "marker: ".len)

proc checkPlainProgram(fixture: string) =
  # Without the selector nothing changes: every test runs, positional filters
  # and the `--list` / `--run` protocol answer exactly as before.
  let plain = run(fixture)
  doAssert plain.exitCode == 1, describe(plain)
  doAssert markersRun(plain) == @names, describe(plain)
  expectContains plain.outp, "[Suite] math"

  let listed = run(fixture, "--list")
  doAssert listed.exitCode == 0, describe(listed)
  doAssert listed.outp == "::outside\nmath::add\nmath::mul\nmath::skipped\n" &
    "math::star*\nmath::starry\n", describe(listed)
  expectContains listed.errp, "suite body noise"

  let one = runWithResultFile(fixture, "--run", "math::skipped")
  doAssert one.ran.exitCode == 2, describe(one.ran)
  doAssert markersRun(one.ran) == @["math::skipped"], describe(one.ran)
  expectContains one.resultJson, "\"status\":\"SKIP\""

  let filtered = run(fixture, "math::add")
  doAssert filtered.exitCode == 0, describe(filtered)
  doAssert markersRun(filtered) == @["math::add"], describe(filtered)

proc checkEntryList(fixture: string) =
  let doc = run(fixture, "--entrypoint=list")
  doAssert doc.exitCode == 0, describe(doc)
  doAssert markersRun(doc).len == 0, describe(doc)
  doAssert doc.outp.endsWith("}\n") and doc.outp.count('\n') == 1,
    describe(doc)
  let parsed = parseJson(doc.outp)
  doAssert parsed["schema"].getStr == "entrypoints/1", doc.outp
  doAssert parsed["program"].getStr == "munittest_entrypoint_fixture", doc.outp
  doAssert parsed["default"].getStr == "main", doc.outp
  let entries = parsed["entries"]
  doAssert entries.len == 2, doc.outp
  doAssert entries[0]["name"].getStr == "main", doc.outp
  doAssert entries[1]["name"].getStr == "tests", doc.outp
  for entry in entries:
    doAssert entry["select"] == %["runtime"], doc.outp
  var listedNames: seq[string]
  for name in entries[1]["entries"]:
    listedNames.add name.getStr
  doAssert listedNames == @names, doc.outp
  expectContains doc.errp, "suite body noise"

proc checkTestsList(fixture: string) =
  for selector in [@["--entrypoint=tests"], @["--entrypoint", "tests"]]:
    let listed = run(fixture, selector & @["--list"])
    doAssert listed.exitCode == 0, describe(listed)
    # Exactly the names, and nothing else: the suite body's output, with or
    # without its newline, is on standard error.
    doAssert listed.outp == names.join("\n") & "\n", describe(listed)
    expectContains listed.errp, "suite body noise"
    expectContains listed.errp, "partial noise -> "
    doAssert markersRun((listed.errp, "", 0)).len == 0, describe(listed)

  let cases = run(fixture, "--entrypoint=tests", "--list-test-cases")
  doAssert cases.exitCode == 0, describe(cases)
  doAssert cases.outp == "", describe(cases)
  expectNotContains cases.errp, "marker: "

proc checkRunExact(fixture: string) =
  let add = runWithResultFile(fixture, "--entrypoint=tests",
    "--run-exact=math::add")
  doAssert add.ran.exitCode == 0, describe(add.ran)
  doAssert markersRun(add.ran) == @["math::add"], describe(add.ran)
  expectContains add.resultJson, "\"status\":\"PASS\""

  let mul = runWithResultFile(fixture, "--entrypoint=tests",
    "--run-exact=math::mul")
  doAssert mul.ran.exitCode == 1, describe(mul.ran)
  doAssert markersRun(mul.ran) == @["math::mul"], describe(mul.ran)
  # The console formatter reports as in an ordinary run.
  expectContains mul.ran.outp, "[FAILED] mul"
  expectContains mul.resultJson, "\"status\":\"FAIL\""

  # A skip is not a failure of the run; the result file tells it from a pass.
  let skipped = runWithResultFile(fixture, "--entrypoint=tests",
    "--run-exact=math::skipped")
  doAssert skipped.ran.exitCode == 0, describe(skipped.ran)
  doAssert markersRun(skipped.ran) == @["math::skipped"], describe(skipped.ran)
  expectContains skipped.resultJson, "\"status\":\"SKIP\""
  expectContains skipped.resultJson, "\"skipReason\":\"not here\""

  let outside = run(fixture, "--entrypoint=tests", "--run-exact=outside")
  doAssert outside.exitCode == 0, describe(outside)
  doAssert markersRun(outside) == @["outside"], describe(outside)

  # A name with `*` is a name, not a pattern.
  let star = run(fixture, "--entrypoint=tests", "--run-exact=math::star*")
  doAssert star.exitCode == 0, describe(star)
  doAssert markersRun(star) == @["math::star*"], describe(star)

  let two = runWithResultFile(fixture, "--entrypoint=tests",
    "--run-exact=math::add", "--run-exact=math::skipped")
  doAssert two.ran.exitCode == 0, describe(two.ran)
  doAssert markersRun(two.ran) == @["math::add", "math::skipped"],
    describe(two.ran)
  # Two tests ran, so no single result owns the file.
  doAssert two.resultJson == "", two.resultJson

  let unknown = run(fixture, "--entrypoint=tests", "--run-exact=math::nope")
  doAssert unknown.exitCode == 64, describe(unknown)
  doAssert markersRun(unknown).len == 0, describe(unknown)
  expectContains unknown.errp, "\"math::nope\""

  # Neither protocol nor filter: the old `::` spelling is not an entry name.
  let oldSpelling = run(fixture, "--entrypoint=tests", "--run-exact=::outside")
  doAssert oldSpelling.exitCode == 64, describe(oldSpelling)
  doAssert markersRun(oldSpelling).len == 0, describe(oldSpelling)

  let both = run(fixture, "--entrypoint=tests", "--run-exact=math::add",
    "--run=math::add")
  doAssert both.exitCode == 64, describe(both)
  doAssert markersRun(both).len == 0, describe(both)
  expectContains both.errp, "--run-exact cannot be combined with --run"

proc checkRunAndSelectors(fixture: string) =
  let everything = run(fixture, "--entrypoint=tests")
  doAssert everything.exitCode == 1, describe(everything)
  doAssert markersRun(everything) == @names, describe(everything)

  let main = run(fixture, "--entrypoint=main")
  doAssert main.exitCode == 1, describe(main)
  doAssert markersRun(main) == @names, describe(main)

  # `--run` is the ordinary filter pattern.
  let pattern = run(fixture, "--entrypoint=tests", "--run=math::star*")
  doAssert pattern.exitCode == 0, describe(pattern)
  doAssert markersRun(pattern) == @["math::star*", "math::starry"],
    describe(pattern)

  let noMatch = run(fixture, "--entrypoint=tests", "--run=nothing*")
  doAssert noMatch.exitCode == 64, describe(noMatch)
  doAssert markersRun(noMatch).len == 0, describe(noMatch)

  # The old protocol flags are not read after the selector.
  let oldRun = run(fixture, "--entrypoint=main", "--list")
  doAssert oldRun.exitCode == 1, describe(oldRun)
  doAssert markersRun(oldRun) == @names, describe(oldRun)

  let unknownEntry = run(fixture, "--entrypoint=bogus")
  doAssert unknownEntry.exitCode == 64, describe(unknownEntry)
  doAssert markersRun(unknownEntry).len == 0, describe(unknownEntry)
  expectContains unknownEntry.errp, "unknown entry 'bogus'"

  let noName = run(fixture, "--entrypoint")
  doAssert noName.exitCode == 64, describe(noName)
  doAssert markersRun(noName).len == 0, describe(noName)

proc checkLineBreak(fixture: string) =
  let listed = run(fixture, "--entrypoint=tests", "--list")
  doAssert listed.exitCode == 70, describe(listed)
  doAssert listed.outp == "", describe(listed)
  expectContains listed.errp, "\"names::line\\x0Abreak\""

proc checkAbort(fixture: string) =
  # `abortOnError` ends the process inside `math::mul`, before `math::starry`
  # has registered. That is the test's failure, not an unknown name.
  let aborted = run(fixture, "--entrypoint=tests", "--run-exact=math::mul",
    "--run-exact=math::starry")
  doAssert aborted.exitCode == 1, describe(aborted)
  doAssert markersRun(aborted) == @["math::mul"], describe(aborted)
  expectNotContains aborted.errp, "no test is named"

proc checkLinked(fixture: string) =
  # nim-entrypoints owns the selector here: `std/unittest` prints no list,
  # refuses nothing, and leaves standard output where it was.
  let listed = run(fixture, "--entrypoint=tests", "--list")
  doAssert listed.exitCode == 0, describe(listed)
  expectNotContains listed.outp, "linked::first"
  expectContains listed.outp, "linked suite body"
  doAssert markersRun(listed).len == 0, describe(listed)

  let doc = run(fixture, "--entrypoint=list")
  doAssert doc.exitCode == 0, describe(doc)
  expectNotContains doc.outp, "entrypoints/1"

  let exact = run(fixture, "--entrypoint=tests", "--run-exact=linked::second")
  doAssert exact.exitCode == 0, describe(exact)
  doAssert markersRun(exact) == @["linked::second"], describe(exact)

  let unknown = run(fixture, "--entrypoint=tests", "--run-exact=linked::nope")
  doAssert unknown.exitCode == 0, describe(unknown)
  doAssert markersRun(unknown).len == 0, describe(unknown)

  let everything = run(fixture, "--entrypoint=tests")
  doAssert everything.exitCode == 0, describe(everything)
  doAssert markersRun(everything) == @["linked::first", "linked::second"],
    describe(everything)

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  let libDir = currentSourcePath().parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir
  buildDir = createTempDir("tunittest_entrypoint_", "")
  try:
    let fixture = compileFixture(nim, libDir,
      "munittest_entrypoint_fixture.nim", "munittest_entrypoint_fixture")
    checkPlainProgram(fixture)
    checkEntryList(fixture)
    checkTestsList(fixture)
    checkRunExact(fixture)
    checkRunAndSelectors(fixture)

    let lineBreak = compileFixture(nim, libDir,
      "munittest_entrypoint_fixture.nim", "line_break_fixture",
      ["-d:entrypointFixtureLineBreak", "-d:entrypointFixtureAbort"])
    checkLineBreak(lineBreak)
    checkAbort(lineBreak)

    let linked = compileFixture(nim, libDir,
      "munittest_entrypoint_linked_fixture.nim", "linked_fixture")
    checkLinked(linked)
  finally:
    removeDir(buildDir)

main()
