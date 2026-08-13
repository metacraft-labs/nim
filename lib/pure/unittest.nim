#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Nim Contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## :Author: Zahary Karadjov
##
## This module implements boilerplate to make unit testing easy.
##
## The test status and name is printed after any output or traceback.
##
## Tests can be nested, however failure of a nested test will not mark the
## parent test as failed. Setup and teardown are inherited. Setup can be
## overridden locally.
##
## Compiled test files as well as `nim c -r <testfile.nim>`
## exit with 0 for success (no failed tests) or 1 for failure.
##
## Testament
## =========
##
## Instead of `unittest`, please consider using
## `the Testament tool <testament.html>`_ which offers process isolation for your tests.
##
## Alternatively using `when isMainModule: doAssert conditionHere` is usually a
## much simpler solution for testing purposes.
##
## Running a single test
## =====================
##
## Specify the test name as a command line argument.
##
##   ```cmd
##   nim c -r test "my test name" "another test"
##   ```
##
## Multiple arguments can be used.
##
## Running a single test suite
## ===========================
##
## Specify the suite name delimited by `"::"`.
##
##   ```cmd
##   nim c -r test "my test name::"
##   ```
##
## Selecting tests by pattern
## ==========================
##
## A single ``"*"`` can be used for globbing.
##
## Delimit the end of a suite name with `"::"`.
##
## Tests matching **any** of the arguments are executed.
##
##   ```cmd
##   nim c -r test fast_suite::mytest1 fast_suite::mytest2
##   nim c -r test "fast_suite::mytest*"
##   nim c -r test "auth*::" "crypto::hashing*"
##   # Run suites starting with 'bug #' and standalone tests starting with '#'
##   nim c -r test 'bug #*::' '::#*'
##   ```
##
## Examples
## ========
##
##   ```nim
##   suite "description for this stuff":
##     echo "suite setup: run once before the tests"
##
##     setup:
##       echo "run before each test"
##
##     teardown:
##       echo "run after each test"
##
##     test "essential truths":
##       # give up and stop if this fails
##       require(true)
##
##     test "slightly less obvious stuff":
##       # print a nasty message and move on, skipping
##       # the remainder of this block
##       check(1 != 1)
##       check("asd"[2] == 'd')
##
##     test "out of bounds error is thrown on bad access":
##       let v = @[1, 2, 3]  # you can do initialization here
##       expect(IndexDefect):
##         discard v[4]
##
##     echo "suite teardown: run once after the tests"
##   ```
##
## Limitations/Bugs
## ================
## Since `check` will rewrite some expressions for supporting checkpoints
## (namely assigns expressions to variables), some type conversions are not supported.
## For example `check 4.0 == 2 + 2` won't work. But `doAssert 4.0 == 2 + 2` works.
## Make sure both sides of the operator (such as `==`, `>=` and so on) have the same type.
##

import std/private/since
import std/exitprocs

when defined(nimPreviewSlimSystem):
  import std/[assertions, syncio]

import std/[macros, strutils, streams, times, sets, sequtils]
import std/compilesettings

when declared(stdout):
  import std/os

const useTerminal = not defined(js)

when useTerminal:
  import std/terminal

type
  TestStatus* = enum ## The status of a test when it is done.
    OK,
    FAILED,
    SKIPPED

  OutputLevel* = enum ## The output verbosity of the tests.
    PRINT_ALL,        ## Print as much as possible.
    PRINT_FAILURES,   ## Print only the failed tests.
    PRINT_NONE        ## Print nothing.

  TestResult* = object
    suiteName*: string
      ## Name of the test suite that contains this test case.
      ## Can be ``nil`` if the test case is not in a suite.
    testName*: string
      ## Name of the test case
    status*: TestStatus

  TestMetadata = object
    suiteName: string
    testName: string
    file: string
    line: int
    column: int
    bodyHash: string

  ProtocolMode = enum
    pmDefault,
    pmList,
    pmListJson,
    pmRun,
    pmCatalog,
    pmError

  OutputFormatter* = ref object of RootObj

  ConsoleOutputFormatter* = ref object of OutputFormatter
    colorOutput: bool
      ## Have test results printed in color.
      ## Default is `auto` depending on `isatty(stdout)`, or override it with
      ## `-d:nimUnittestColor:auto|on|off`.
      ##
      ## Deprecated: Setting the environment variable `NIMTEST_COLOR` to `always`
      ## or `never` changes the default for the non-js target to true or false respectively.
      ## Deprecated: the environment variable `NIMTEST_NO_COLOR`, when set, changes the
      ## default to true, if `NIMTEST_COLOR` is undefined.
    outputLevel: OutputLevel
      ## Set the verbosity of test results.
      ## Default is `PRINT_ALL`, or override with:
      ## `-d:nimUnittestOutputLevel:PRINT_ALL|PRINT_FAILURES|PRINT_NONE`.
      ##
      ## Deprecated: the `NIMTEST_OUTPUT_LVL` environment variable is set for the non-js target.
    isInSuite: bool
    isInTest: bool

  JUnitOutputFormatter* = ref object of OutputFormatter
    stream: Stream
    testErrors: seq[string]
    testStartTime: float
    testStackTrace: string

var
  abortOnError* {.threadvar.}: bool ## Set to true in order to quit
                                    ## immediately on fail. Default is false,
                                    ## or override with `-d:nimUnittestAbortOnError:on|off`.
                                    ##
                                    ## Deprecated: can also override depending on whether
                                    ## `NIMTEST_ABORT_ON_ERROR` environment variable is set.

  checkpoints {.threadvar.}: seq[string]
  formatters {.threadvar.}: seq[OutputFormatter]
  testsFilters {.threadvar.}: HashSet[string]
  disabledParamFiltering {.threadvar.}: bool
  protocolInitialized {.threadvar.}: bool
  protocolExitProcAdded {.threadvar.}: bool
  protocolMode {.threadvar.}: ProtocolMode
  protocolTests {.threadvar.}: seq[TestMetadata]
  protocolRunName {.threadvar.}: string
  protocolCatalogPath {.threadvar.}: string
  protocolParseError {.threadvar.}: string
  protocolRanSelected {.threadvar.}: bool
  protocolTestStartTime {.threadvar.}: float
  protocolFailureCheckpoints {.threadvar.}: seq[string]
  protocolException {.threadvar.}: string
  protocolSkipReason {.threadvar.}: string
  protocolResultFile {.threadvar.}: string

const
  outputLevelDefault = PRINT_ALL
  nimUnittestOutputLevel {.strdefine.} = $outputLevelDefault
  nimUnittestColor {.strdefine.} = "auto" ## auto|on|off
  nimUnittestAbortOnError {.booldefine.} = false
  nimTestResultFileEnv = "NIMTEST_RESULT_FILE"

template deprecateEnvVarHere() =
  # xxx issue a runtime warning to deprecate this envvar.
  discard

abortOnError = nimUnittestAbortOnError
when declared(stdout):
  if existsEnv("NIMTEST_ABORT_ON_ERROR"):
    deprecateEnvVarHere()
    abortOnError = true

method suiteStarted*(formatter: OutputFormatter, suiteName: string) {.base, gcsafe.} =
  discard
method testStarted*(formatter: OutputFormatter, testName: string) {.base, gcsafe.} =
  discard
method failureOccurred*(formatter: OutputFormatter, checkpoints: seq[string],
    stackTrace: string) {.base, gcsafe.} =
  ## ``stackTrace`` is provided only if the failure occurred due to an exception.
  ## ``checkpoints`` is never ``nil``.
  discard
method testEnded*(formatter: OutputFormatter, testResult: TestResult) {.base, gcsafe.} =
  discard
method suiteEnded*(formatter: OutputFormatter) {.base, gcsafe.} =
  discard

proc addOutputFormatter*(formatter: OutputFormatter) =
  formatters.add(formatter)

proc delOutputFormatter*(formatter: OutputFormatter) =
  keepIf(formatters, proc (x: OutputFormatter): bool =
    x != formatter)

proc resetOutputFormatters* {.since: (1, 1).} =
  formatters = @[]

proc newConsoleOutputFormatter*(outputLevel: OutputLevel = outputLevelDefault,
                                colorOutput = true): ConsoleOutputFormatter =
  ConsoleOutputFormatter(
    outputLevel: outputLevel,
    colorOutput: colorOutput
  )

proc colorOutput(): bool =
  let color = nimUnittestColor
  case color
  of "auto":
    when declared(stdout): result = isatty(stdout)
    else: result = false
  of "on": result = true
  of "off": result = false
  else: raiseAssert $color

  when declared(stdout):
    if existsEnv("NIMTEST_COLOR"):
      deprecateEnvVarHere()
      let colorEnv = getEnv("NIMTEST_COLOR")
      if colorEnv == "never":
        result = false
      elif colorEnv == "always":
        result = true
    elif existsEnv("NIMTEST_NO_COLOR"):
      deprecateEnvVarHere()
      result = false

proc defaultConsoleFormatter*(): ConsoleOutputFormatter =
  var colorOutput = colorOutput()
  var outputLevel = nimUnittestOutputLevel.parseEnum[:OutputLevel]
  when declared(stdout):
    const a = "NIMTEST_OUTPUT_LVL"
    if existsEnv(a):
      # xxx issue a warning to deprecate this envvar.
      outputLevel = getEnv(a).parseEnum[:OutputLevel]
  result = newConsoleOutputFormatter(outputLevel, colorOutput)

method suiteStarted*(formatter: ConsoleOutputFormatter, suiteName: string) =
  template rawPrint() = echo("\n[Suite] ", suiteName)
  when useTerminal:
    if formatter.colorOutput:
      styledEcho styleBright, fgBlue, "\n[Suite] ", resetStyle, suiteName
    else: rawPrint()
  else: rawPrint()
  formatter.isInSuite = true

method testStarted*(formatter: ConsoleOutputFormatter, testName: string) =
  formatter.isInTest = true

method failureOccurred*(formatter: ConsoleOutputFormatter,
                        checkpoints: seq[string], stackTrace: string) =
  if stackTrace.len > 0:
    echo stackTrace
  let prefix = if formatter.isInSuite: "    " else: ""
  for msg in items(checkpoints):
    echo prefix, msg

method testEnded*(formatter: ConsoleOutputFormatter, testResult: TestResult) =
  formatter.isInTest = false

  if formatter.outputLevel != OutputLevel.PRINT_NONE and
      (formatter.outputLevel == OutputLevel.PRINT_ALL or testResult.status == TestStatus.FAILED):
    let prefix = if testResult.suiteName.len > 0: "  " else: ""
    template rawPrint() = echo(prefix, "[", $testResult.status, "] ",
        testResult.testName)
    when useTerminal:
      if formatter.colorOutput:
        var color = case testResult.status
          of TestStatus.OK: fgGreen
          of TestStatus.FAILED: fgRed
          of TestStatus.SKIPPED: fgYellow
        styledEcho styleBright, color, prefix, "[", $testResult.status, "] ",
            resetStyle, testResult.testName
      else:
        rawPrint()
    else:
      rawPrint()

method suiteEnded*(formatter: ConsoleOutputFormatter) =
  formatter.isInSuite = false

proc xmlEscape(s: string): string =
  result = newStringOfCap(s.len)
  for c in items(s):
    case c:
    of '<': result.add("&lt;")
    of '>': result.add("&gt;")
    of '&': result.add("&amp;")
    of '"': result.add("&quot;")
    of '\'': result.add("&apos;")
    else:
      if ord(c) < 32:
        result.add("&#" & $ord(c) & ';')
      else:
        result.add(c)

proc newJUnitOutputFormatter*(stream: Stream): JUnitOutputFormatter =
  ## Creates a formatter that writes report to the specified stream in
  ## JUnit format.
  ## The ``stream`` is NOT closed automatically when the test are finished,
  ## because the formatter has no way to know when all tests are finished.
  ## You should invoke formatter.close() to finalize the report.
  result = JUnitOutputFormatter(
    stream: stream,
    testErrors: @[],
    testStackTrace: "",
    testStartTime: 0.0
  )
  stream.writeLine("<?xml version=\"1.0\" encoding=\"UTF-8\"?>")
  stream.writeLine("<testsuites>")

proc close*(formatter: JUnitOutputFormatter) =
  ## Completes the report and closes the underlying stream.
  formatter.stream.writeLine("</testsuites>")
  formatter.stream.close()

method suiteStarted*(formatter: JUnitOutputFormatter, suiteName: string) =
  formatter.stream.writeLine("\t<testsuite name=\"$1\">" % xmlEscape(suiteName))

method testStarted*(formatter: JUnitOutputFormatter, testName: string) =
  formatter.testErrors.setLen(0)
  formatter.testStackTrace.setLen(0)
  formatter.testStartTime = epochTime()

method failureOccurred*(formatter: JUnitOutputFormatter,
                        checkpoints: seq[string], stackTrace: string) =
  ## ``stackTrace`` is provided only if the failure occurred due to an exception.
  ## ``checkpoints`` is never ``nil``.
  formatter.testErrors.add(checkpoints)
  if stackTrace.len > 0:
    formatter.testStackTrace = stackTrace

method testEnded*(formatter: JUnitOutputFormatter, testResult: TestResult) =
  let time = epochTime() - formatter.testStartTime
  let timeStr = time.formatFloat(ffDecimal, precision = 8)
  formatter.stream.writeLine("\t\t<testcase name=\"$#\" time=\"$#\">" % [
      xmlEscape(testResult.testName), timeStr])
  case testResult.status
  of TestStatus.OK:
    discard
  of TestStatus.SKIPPED:
    formatter.stream.writeLine("<skipped />")
  of TestStatus.FAILED:
    let failureMsg = if formatter.testStackTrace.len > 0 and
                        formatter.testErrors.len > 0:
                       xmlEscape(formatter.testErrors[^1])
                     elif formatter.testErrors.len > 0:
                       xmlEscape(formatter.testErrors[0])
                     else: "The test failed without outputting an error"

    var errs = ""
    if formatter.testErrors.len > 1:
      var startIdx = if formatter.testStackTrace.len > 0: 0 else: 1
      var endIdx = if formatter.testStackTrace.len > 0:
          formatter.testErrors.len - 2
        else: formatter.testErrors.len - 1

      for errIdx in startIdx..endIdx:
        if errs.len > 0:
          errs.add("\n")
        errs.add(xmlEscape(formatter.testErrors[errIdx]))

    if formatter.testStackTrace.len > 0:
      formatter.stream.writeLine("\t\t\t<error message=\"$#\">$#</error>" % [
          failureMsg, xmlEscape(formatter.testStackTrace)])
      if errs.len > 0:
        formatter.stream.writeLine("\t\t\t<system-err>$#</system-err>" % errs)
    else:
      formatter.stream.writeLine("\t\t\t<failure message=\"$#\">$#</failure>" %
          [failureMsg, errs])

  formatter.stream.writeLine("\t\t</testcase>")

method suiteEnded*(formatter: JUnitOutputFormatter) =
  formatter.stream.writeLine("\t</testsuite>")

proc glob(matcher, filter: string): bool =
  ## Globbing using a single `*`. Empty `filter` matches everything.
  if filter.len == 0:
    return true

  if not filter.contains('*'):
    return matcher == filter

  let beforeAndAfter = filter.split('*', maxsplit = 1)
  if beforeAndAfter.len == 1:
    # "foo*"
    return matcher.startsWith(beforeAndAfter[0])

  if matcher.len < filter.len - 1:
    return false # "12345" should not match "123*345"

  return matcher.startsWith(beforeAndAfter[0]) and matcher.endsWith(
      beforeAndAfter[1])

proc matchFilter(suiteName, testName, filter: string): bool =
  if filter == "":
    return true
  if testName == filter:
    # corner case for tests containing "::" in their name
    return true
  let suiteAndTestFilters = filter.split("::", maxsplit = 1)

  if suiteAndTestFilters.len == 1:
    # no suite specified
    let testFilter = suiteAndTestFilters[0]
    return glob(testName, testFilter)

  return glob(suiteName, suiteAndTestFilters[0]) and
         glob(testName, suiteAndTestFilters[1])

macro protocolBodyHash(bodyProc: typed): string =
  result = newStrLitNode(symBodyHash(bodyProc))

proc protocolFullName(suiteName, testName: string): string =
  if suiteName.len == 0:
    result = "::" & testName
  else:
    result = suiteName & "::" & testName

proc protocolStatus(status: TestStatus): string =
  case status
  of TestStatus.OK: "PASS"
  of TestStatus.FAILED: "FAIL"
  of TestStatus.SKIPPED: "SKIP"

proc jsonEscape(s: string): string =
  result = newStringOfCap(s.len + 2)
  for c in s:
    case c
    of '"': result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else:
      if ord(c) < 32:
        result.add("\\u00")
        result.add(toHex(ord(c), 2))
      else:
        result.add(c)

proc jsonString(s: string): string =
  "\"" & jsonEscape(s) & "\""

proc appendMetadataJson(result: var string, test: TestMetadata) =
  let name = protocolFullName(test.suiteName, test.testName)
  result.add("{\"name\":")
  result.add(jsonString(name))
  result.add(",\"suite\":")
  result.add(jsonString(test.suiteName))
  result.add(",\"test\":")
  result.add(jsonString(test.testName))
  result.add(",\"file\":")
  result.add(jsonString(test.file))
  result.add(",\"line\":")
  result.add($test.line)
  result.add(",\"column\":")
  result.add($test.column)
  result.add(",\"kind\":\"in-process\",\"group\":\"@global\",\"threadsRequired\":1")
  result.add(",\"xfail\":null,\"tags\":[],\"bodyHash\":")
  result.add(jsonString(test.bodyHash))
  result.add(",\"deterministic\":true}")

proc buildListJson(): string =
  var suites = initHashSet[string]()
  result = "{\"tests\":["
  for i, test in protocolTests:
    if i > 0:
      result.add(",")
    appendMetadataJson(result, test)
    if test.suiteName.len > 0:
      suites.incl(test.suiteName)
  result.add("],\"summary\":{\"total\":")
  result.add($protocolTests.len)
  result.add(",\"suites\":")
  result.add($suites.len)
  result.add(",\"byKind\":{\"in-process\":")
  result.add($protocolTests.len)
  result.add("}}}")

proc buildCatalogJson(): string =
  result = "{\"version\":1,\"tests\":{"
  for i, test in protocolTests:
    if i > 0:
      result.add(",")
    result.add(jsonString(protocolFullName(test.suiteName, test.testName)))
    result.add(":")
    result.add(jsonString(test.bodyHash))
  result.add("}}")

proc resetProtocolTestState() =
  protocolTestStartTime = epochTime()
  protocolFailureCheckpoints = @[]
  protocolException = ""
  protocolSkipReason = ""

proc recordProtocolFailure(checkpoints: seq[string], stackTrace: string) {.gcsafe.} =
  protocolFailureCheckpoints.add(checkpoints)
  if stackTrace.len > 0:
    protocolException = stackTrace

proc writeProtocolResult(testResult: TestResult) =
  if protocolMode != pmRun or protocolResultFile.len == 0:
    return

  let durationMs = max(0, int((epochTime() - protocolTestStartTime) * 1000))
  var content = "{\"status\":"
  content.add(jsonString(protocolStatus(testResult.status)))
  if testResult.status == TestStatus.SKIPPED and protocolSkipReason.len > 0:
    content.add(",\"skipReason\":")
    content.add(jsonString(protocolSkipReason))
  content.add(",\"duration_ms\":")
  content.add($durationMs)
  content.add(",\"checkpoints\":[")
  for i, checkpoint in protocolFailureCheckpoints:
    if i > 0:
      content.add(",")
    content.add(jsonString(checkpoint))
  content.add("],\"exception\":")
  if protocolException.len == 0:
    content.add("null")
  else:
    content.add(jsonString(protocolException))
  content.add("}")

  when declared(writeFile):
    writeFile(protocolResultFile, content)

proc writeMissingProtocolResult() =
  if protocolResultFile.len == 0:
    return
  let content = "{\"status\":\"FAIL\",\"duration_ms\":0,\"checkpoints\":[]," &
    "\"exception\":" & jsonString("test not found: " & protocolRunName) & "}"
  when declared(writeFile):
    writeFile(protocolResultFile, content)

proc finishProtocol() =
  case protocolMode
  of pmListJson:
    echo buildListJson()
  of pmCatalog:
    let catalog = buildCatalogJson()
    if protocolCatalogPath == "-":
      echo catalog
    elif protocolCatalogPath.len > 0:
      when declared(writeFile):
        writeFile(protocolCatalogPath, catalog)
    else:
      echo "unittest: --catalog requires a file path"
      when declared(setProgramResult):
        setProgramResult 1
  of pmRun:
    if not protocolRanSelected:
      writeMissingProtocolResult()
      when declared(setProgramResult):
        setProgramResult 1
  of pmError:
    if protocolParseError.len > 0:
      echo protocolParseError
    when declared(setProgramResult):
      setProgramResult 1
  else:
    discard

proc parseProtocolArgs() {.gcsafe.} =
  if protocolInitialized:
    return
  protocolInitialized = true
  protocolMode = pmDefault

  when declared(paramCount):
    var positionalFilters: seq[string] = @[]
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      if arg == "--list":
        protocolMode = pmList
      elif arg == "--list-json":
        protocolMode = pmListJson
      elif arg == "--run":
        if i == paramCount():
          protocolMode = pmError
          protocolParseError = "unittest: --run requires a test name"
        else:
          inc i
          protocolMode = pmRun
          protocolRunName = paramStr(i)
      elif arg.startsWith("--run="):
        protocolMode = pmRun
        protocolRunName = arg.substr("--run=".len)
      elif arg == "--catalog":
        if i == paramCount():
          protocolMode = pmError
          protocolParseError = "unittest: --catalog requires a file path"
        else:
          inc i
          protocolMode = pmCatalog
          protocolCatalogPath = paramStr(i)
      elif arg.startsWith("--catalog="):
        protocolMode = pmCatalog
        protocolCatalogPath = arg.substr("--catalog=".len)
      elif not disabledParamFiltering:
        positionalFilters.add(arg)
      inc i

    if protocolMode == pmRun:
      testsFilters.clear()
      testsFilters.incl(protocolRunName)
      when declared(setProgramResult):
        setProgramResult 1
    elif protocolMode in {pmDefault, pmError}:
      for filter in positionalFilters:
        testsFilters.incl(filter)

    if protocolMode == pmError:
      when declared(setProgramResult):
        setProgramResult 1

  when declared(existsEnv):
    protocolResultFile = getEnv(nimTestResultFileEnv)

proc ensureProtocolExitProc() =
  ## Register the exit hook that emits the `--list-json`/`--catalog` payload
  ## once every test has registered itself.
  ##
  ## A run with NO protocol flag emits nothing at exit, so it must not register
  ## anything either. `addExitProc` is a side effect stock `unittest` never had,
  ## and on the JS backend `std/exitprocs` reaches for `window.onbeforeunload`
  ## unless `-d:nodejs` is set — which throws `ReferenceError: window is not
  ## defined` under a plain `node`, before a single test has run. Gating on the
  ## mode keeps the default path exactly as it was.
  if protocolMode == pmDefault:
    return
  if not protocolExitProcAdded:
    protocolExitProcAdded = true
    addExitProc(finishProtocol)

const protocolProjectDir* = querySetting(SingleValueSetting.projectPath)
  ## Directory of the main module being compiled, resolved once at compile time.
  ## The project is a property of the COMPILATION, so evaluating it here rather
  ## than per test instantiation is both cheaper and more obviously correct —
  ## and it keeps `querySetting` out of the `test` template's expansion site,
  ## where the user's module would have to import `std/compilesettings` itself.

func protocolRelativeFile*(absolute, projectDir: string): string =
  ## Render `absolute` relative to `projectDir` for the protocol's ``file``
  ## field, falling back to `absolute` when it lies outside the project.
  ##
  ## The field has to be BOTH resolvable and reproducible. A bare basename (what
  ## `instantiationInfo(-1, false)` yields) is neither: it discards the
  ## directory, so two same-named test files in different directories are
  ## indistinguishable and neither can be opened. An absolute path (what
  ## `instantiationInfo(-1, true)` yields, with or without `--listFullPaths`)
  ## resolves but embeds the build machine's layout, which defeats diffing two
  ## catalogs produced on different hosts.
  ##
  ## Anchoring on the project directory gives both properties without a new
  ## compiler flag or `-d:` define — deliberately, since this surface is
  ## intended for an upstream proposal and every added knob is a cost there.
  ## The comparison is a plain prefix strip rather than `os.relativePath` so
  ## this stays usable from every backend `unittest` supports; `std/os` is only
  ## imported here `when declared(stdout)`.
  ##
  ## A body OUTSIDE the project — `projectPath` is the main module's directory,
  ## so a test defined in a sibling directory qualifies — falls back to its
  ## basename rather than its absolute path. Emitting the absolute path there
  ## would buy resolvability at the cost of reproducibility, and reproducibility
  ## is the property the catalog workflow cannot do without. The basename is
  ## exactly what such a test reported before, so this is a strict improvement:
  ## paths inside the project gain their directory, and nothing regresses.
  proc basename(path: string): string =
    var start = 0
    for i in countdown(path.high, 0):
      if path[i] == '/' or path[i] == '\\':
        start = i + 1
        break
    if start >= path.len: path else: path[start .. ^1]

  if projectDir.len == 0 or absolute.len <= projectDir.len:
    return basename(absolute)
  if not absolute.startsWith(projectDir):
    return basename(absolute)
  var cut = projectDir.len
  # Tolerate a project dir recorded with or without its trailing separator.
  while cut < absolute.len and (absolute[cut] == '/' or absolute[cut] == '\\'):
    inc cut
  if cut >= absolute.len:
    return basename(absolute)
  absolute[cut .. ^1]

proc registerProtocolTest(suiteName, testName, file: string;
                          line, column: int; bodyHash: string) =
  let name = protocolFullName(suiteName, testName)
  case protocolMode
  of pmList:
    echo name
  of pmListJson, pmCatalog:
    protocolTests.add TestMetadata(
      suiteName: suiteName,
      testName: testName,
      file: file,
      line: line,
      column: column,
      bodyHash: bodyHash
    )
  else:
    discard

proc shouldRun(currentSuiteName, testName: string): bool =
  ## Check if a test should be run by matching suiteName and testName against
  ## test filters.
  if testsFilters.len == 0:
    return true

  for f in testsFilters:
    if matchFilter(currentSuiteName, testName, f):
      return true

  return false

proc shouldRunProtocolTest(currentSuiteName, testName: string): bool =
  case protocolMode
  of pmRun:
    result = protocolFullName(currentSuiteName, testName) == protocolRunName
    if result:
      protocolRanSelected = true
  of pmList, pmListJson, pmCatalog, pmError:
    result = false
  of pmDefault:
    result = shouldRun(currentSuiteName, testName)

proc ensureInitialized() {.gcsafe.} =
  parseProtocolArgs()

  if formatters.len == 0 and
      protocolMode notin {pmList, pmListJson, pmRun, pmCatalog, pmError}:
    formatters = @[OutputFormatter(defaultConsoleFormatter())]

# These two procs are added as workarounds for
# https://github.com/nim-lang/Nim/issues/5549
proc suiteEnded() =
  for formatter in formatters:
    formatter.suiteEnded()

proc testEnded(testResult: TestResult) =
  for formatter in formatters:
    formatter.testEnded(testResult)
  writeProtocolResult(testResult)

template suite*(name, body) {.dirty.} =
  ## Declare a test suite identified by `name` with optional ``setup``
  ## and/or ``teardown`` section.
  ##
  ## A test suite is a series of one or more related tests sharing a
  ## common fixture (``setup``, ``teardown``). The fixture is executed
  ## for EACH test.
  ##
  ##   ```nim
  ##   suite "test suite for addition":
  ##     setup:
  ##       let result = 4
  ##
  ##     test "2 + 2 = 4":
  ##       check(2+2 == result)
  ##
  ##     test "(2 + -2) != 4":
  ##       check(2 + -2 != result)
  ##
  ##     # No teardown needed
  ##   ```
  ##
  ## The suite will run the individual test cases in the order in which
  ## they were listed. With default global settings the above code prints:
  ##
  ##     [Suite] test suite for addition
  ##       [OK] 2 + 2 = 4
  ##       [OK] (2 + -2) != 4
  bind formatters, ensureInitialized, ensureProtocolExitProc, suiteEnded

  block:
    template setup(setupBody: untyped) {.dirty, used.} =
      var testSetupIMPLFlag {.used.} = true
      template testSetupIMPL: untyped {.dirty.} = setupBody

    template teardown(teardownBody: untyped) {.dirty, used.} =
      var testTeardownIMPLFlag {.used.} = true
      template testTeardownIMPL: untyped {.dirty.} = teardownBody

    let testSuiteName {.used.} = name

    ensureInitialized()
    ensureProtocolExitProc()
    try:
      for formatter in formatters:
        formatter.suiteStarted(name)
      body
    finally:
      suiteEnded()

proc exceptionTypeName(e: ref Exception): string {.inline.} =
  if e == nil: "<foreign exception>"
  else: $e.name

when not declared(setProgramResult):
  {.warning: "setProgramResult not available on platform, unittest will not" &
    " give failing exit code on test failure".}
  template setProgramResult(a: int) =
    discard

template test*(name, body) {.dirty.} =
  ## Define a single test case identified by `name`.
  ##
  ##   ```nim
  ##   test "roses are red":
  ##     let roses = "red"
  ##     check(roses == "red")
  ##   ```
  ##
  ## The above code outputs:
  ##
  ##     [OK] roses are red
  bind shouldRun, checkpoints, formatters, ensureInitialized, testEnded,
    exceptionTypeName, setProgramResult, protocolBodyHash, registerProtocolTest,
    resetProtocolTestState, ensureProtocolExitProc, shouldRunProtocolTest,
    protocolMode, pmRun

  ensureInitialized()
  ensureProtocolExitProc()

  block:
    let currentSuiteNameIMPL {.used.} =
      when declared(testSuiteName): testSuiteName else: ""
    # `fullPaths = true` so the directory survives; `protocolRelativeFile` then
    # anchors it on the project directory so the emitted path is reproducible
    # across hosts. See `protocolRelativeFile` for why neither the bare
    # basename nor the raw absolute path is usable on its own.
    let testLocationIMPL {.used.} = instantiationInfo(-1, true)
    proc testBodyIMPL(testStatusIMPL: ptr TestStatus) =
      when declared(testSetupIMPLFlag): testSetupIMPL()
      when declared(testTeardownIMPLFlag):
        defer: testTeardownIMPL()
      body

    let testBodyHashIMPLValue {.used.} = protocolBodyHash(testBodyIMPL)
    registerProtocolTest(
      currentSuiteNameIMPL,
      name,
      protocolRelativeFile(testLocationIMPL.filename, protocolProjectDir),
      testLocationIMPL.line,
      testLocationIMPL.column,
      testBodyHashIMPLValue
    )

    if shouldRunProtocolTest(currentSuiteNameIMPL, name):
      checkpoints = @[]
      resetProtocolTestState()
      var testStatusIMPL {.inject.} = TestStatus.OK

      for formatter in formatters:
        formatter.testStarted(name)

      try:
        testBodyIMPL(addr testStatusIMPL)

      except Exception:
        let e = getCurrentException()
        let eTypeDesc = "[" & exceptionTypeName(e) & "]"
        checkpoint("Unhandled exception: " & getCurrentExceptionMsg() & " " & eTypeDesc)
        var stackTrace {.inject.} = e.getStackTrace()
        fail()

      except:
        checkpoint("Unhandled exception: " & getCurrentExceptionMsg() & " [<foreign exception>]")
        fail()

      finally:
        if testStatusIMPL == TestStatus.FAILED:
          setProgramResult 1
        elif protocolMode == pmRun and testStatusIMPL == TestStatus.SKIPPED:
          setProgramResult 2
        elif protocolMode == pmRun:
          setProgramResult 0
        let testResult = TestResult(
          suiteName: currentSuiteNameIMPL,
          testName: name,
          status: testStatusIMPL
        )
        testEnded(testResult)
        checkpoints = @[]

proc checkpoint*(msg: string) =
  ## Set a checkpoint identified by `msg`. Upon test failure all
  ## checkpoints encountered so far are printed out. Example:
  ##
  ##   ```nim
  ##   checkpoint("Checkpoint A")
  ##   check((42, "the Answer to life and everything") == (1, "a"))
  ##   checkpoint("Checkpoint B")
  ##   ```
  ##
  ## outputs "Checkpoint A" once it fails.
  checkpoints.add(msg)
  # TODO: add support for something like SCOPED_TRACE from Google Test

template fail* =
  ## Print out the checkpoints encountered so far and quit if ``abortOnError``
  ## is true. Otherwise, erase the checkpoints and indicate the test has
  ## failed (change exit code and test status). This template is useful
  ## for debugging, but is otherwise mostly used internally. Example:
  ##
  ##   ```nim
  ##   checkpoint("Checkpoint A")
  ##   complicatedProcInThread()
  ##   fail()
  ##   ```
  ##
  ## outputs "Checkpoint A" before quitting.
  bind ensureInitialized, setProgramResult, recordProtocolFailure
  when declared(testStatusIMPL):
    when typeof(testStatusIMPL) is ptr TestStatus:
      testStatusIMPL[] = TestStatus.FAILED
    else:
      testStatusIMPL = TestStatus.FAILED
  else:
    setProgramResult 1

  ensureInitialized()

    # var stackTrace: string = nil
  when declared(stackTrace):
    recordProtocolFailure(checkpoints, stackTrace)
  else:
    recordProtocolFailure(checkpoints, "")

  for formatter in formatters:
    when declared(stackTrace):
      formatter.failureOccurred(checkpoints, stackTrace)
    else:
      formatter.failureOccurred(checkpoints, "")

  if abortOnError: quit(1)

  checkpoints = @[]

template skip*(reason = "") =
  ## Mark the test as skipped. Should be used directly
  ## in case when it is not possible to perform test
  ## for reasons depending on outer environment,
  ## or certain application logic conditions or configurations.
  ## The test code is still executed.
  ##   ```nim
  ##   if not isGLContextCreated():
  ##     skip()
  ##   ```
  bind checkpoints, protocolSkipReason

  when typeof(testStatusIMPL) is ptr TestStatus:
    testStatusIMPL[] = TestStatus.SKIPPED
  else:
    testStatusIMPL = TestStatus.SKIPPED
  protocolSkipReason = reason
  checkpoints = @[]

macro check*(conditions: untyped): untyped =
  ## Verify if a statement or a list of statements is true.
  ## A helpful error message and set checkpoints are printed out on
  ## failure (if ``outputLevel`` is not ``PRINT_NONE``).
  runnableExamples:
    import std/strutils

    check("AKB48".toLowerAscii() == "akb48")

    let teams = {'A', 'K', 'B', '4', '8'}

    check:
      "AKB48".toLowerAscii() == "akb48"
      'C' notin teams

  let checked = callsite()[1]

  template print(name: untyped, value: typed) =
    when compiles(string($value)):
      checkpoint(name & " was " & $value)

  proc inspectArgs(exp: NimNode): tuple[assigns, check, printOuts: NimNode] =
    result = (newNimNode(nnkStmtList), copyNimTree(exp), newNimNode(nnkStmtList))

    var counter = 0

    if exp[0].kind in {nnkIdent, nnkOpenSymChoice, nnkClosedSymChoice, nnkSym} and
        $exp[0] in ["not", "in", "notin", "==", "<=",
                    ">=", "<", ">", "!=", "is", "isnot"]:

      for i in 1 ..< exp.len:
        if exp[i].kind notin nnkLiterals:
          inc counter
          let argStr = exp[i].toStrLit
          let paramAst = exp[i]
          if exp[i].kind == nnkIdent:
            result.printOuts.add getAst(print(argStr, paramAst))
          if exp[i].kind in nnkCallKinds + {nnkDotExpr, nnkBracketExpr, nnkPar} and
                  (exp[i].typeKind notin {ntyTypeDesc} or $exp[0] notin ["is", "isnot"]):
            let callVar = newIdentNode(":c" & $counter)
            # Construct AST directly instead of using getAst to preserve line info
            let asgnNode = newNimNode(nnkVarSection, exp[i])
            let identDef = newNimNode(nnkIdentDefs, exp[i])
            identDef.add callVar
            identDef.add newEmptyNode()
            identDef.add paramAst
            asgnNode.add identDef
            result.assigns.add asgnNode
            result.check[i] = callVar
            result.check[^1].setLineInfo exp.lineInfoObj
            result.printOuts.add getAst(print(argStr, callVar))
          if exp[i].kind == nnkExprEqExpr:
            # ExprEqExpr
            #   Ident "v"
            #   IntLit 2
            result.check[i] = exp[i][1]
          if exp[i].typeKind notin {ntyTypeDesc}:
            let arg = newIdentNode(":p" & $counter)
            # Construct AST directly instead of using getAst to preserve line info
            let asgnNode = newNimNode(nnkVarSection, exp[i])
            let identDef = newNimNode(nnkIdentDefs, exp[i])
            identDef.add arg
            identDef.add newEmptyNode()
            identDef.add paramAst
            asgnNode.add identDef
            result.assigns.add asgnNode
            result.printOuts.add getAst(print(argStr, arg))
            result.printOuts[^1].setLineInfo exp.lineInfoObj
            if exp[i].kind != nnkExprEqExpr:
              result.check[i] = arg
            else:
              result.check[i][1] = arg

  case checked.kind
  of nnkCallKinds:

    let (assigns, check, printOuts) = inspectArgs(checked)
    # `ipCanonical`, not the default absolute rendering: this literal is
    # planted in the caller's AST, and `sighashes.hashBodyTree` hashes string
    # literals verbatim, so an absolute path here makes `macros.symBodyHash`
    # (and therefore the runner protocol's `bodyHash`) depend on where the
    # package is checked out. Canonical rather than project-relative because
    # `projectPath` is the main module's directory: a test file compiled as its
    # own main module would render as a bare basename, so two same-named test
    # files in different directories would become indistinguishable.
    let lineinfo = newStrLitNode(checked.lineInfo(ipCanonical))
    let callLit = checked.toStrLit

    # Wrap assigns in a line pragma block to preserve stack trace location.
    # Bare `{.line.}` rather than `{.line: (file, line, col).}`: the argument
    # form plants the filename in the body AST as an ordinary string literal,
    # and `sighashes.hashBodyTree` hashes string literals verbatim, so every
    # test containing a `check` would hash differently in a different checkout.
    # The bare form takes the instantiation site from the compiler's own
    # context instead, so the stack trace this pragma exists to fix is
    # unchanged and nothing is written into the tree.
    let pragmaBlock = newNimNode(nnkPragmaBlock)
    let pragma = newNimNode(nnkPragma)
    pragma.add newIdentNode("line")
    pragmaBlock.add pragma
    pragmaBlock.add assigns

    result = quote do:
      block:
        `pragmaBlock`
        if `check`:
          discard
        else:
          checkpoint(`lineinfo` & ": Check failed: " & `callLit`)
          `printOuts`
          fail()

  of nnkStmtList:
    result = newNimNode(nnkStmtList)
    for node in checked:
      if node.kind != nnkCommentStmt:
        result.add(newCall(newIdentNode("check"), node))

  else:
    let lineinfo = newStrLitNode(checked.lineInfo(ipCanonical))
    let callLit = checked.toStrLit

    result = quote do:
      if `checked`:
        discard
      else:
        checkpoint(`lineinfo` & ": Check failed: " & `callLit`)
        fail()

template require*(conditions: untyped) =
  ## Same as `check` except any failed test causes the program to quit
  ## immediately. Any teardown statements are not executed and the failed
  ## test output is not generated.
  let savedAbortOnError = abortOnError
  block:
    abortOnError = true
    check conditions
  abortOnError = savedAbortOnError

macro expect*(exceptions: varargs[typed], body: untyped): untyped =
  ## Test if `body` raises an exception found in the passed `exceptions`.
  ## The test passes if the raised exception is part of the acceptable
  ## exceptions. Otherwise, it fails.
  runnableExamples:
    import std/[math, random, strutils]
    proc defectiveRobot() =
      randomize()
      case rand(1..4)
      of 1: raise newException(OSError, "CANNOT COMPUTE!")
      of 2: discard parseInt("Hello World!")
      of 3: raise newException(IOError, "I can't do that Dave.")
      else: assert 2 + 2 == 5

    expect IOError, OSError, ValueError, AssertionDefect:
      defectiveRobot()

  template expectException(errorTypes, lineInfoLit, body): NimNode {.dirty.} =
    try:
      body
      checkpoint(lineInfoLit & ": Expect Failed, no exception was thrown.")
      fail()
    except errorTypes:
      discard

  template expectBody(errorTypes, lineInfoLit, body): NimNode {.dirty.} =
    try:
      body
      checkpoint(lineInfoLit & ": Expect Failed, no exception was thrown.")
      fail()
    except errorTypes:
      discard
    except Exception:
      let err = getCurrentException()
      checkpoint(lineInfoLit & ": Expect Failed, " & $err.name & " was thrown.")
      fail()
  var errorTypes = newNimNode(nnkBracket)
  var hasException = false
  for exp in exceptions:
    if exp.strVal == "Exception":
      hasException = true
    errorTypes.add(exp)

  if hasException:
    result = getAst(expectException(errorTypes,
                                    errorTypes.lineInfo(ipCanonical), body))
  else:
    result = getAst(expectBody(errorTypes,
                               errorTypes.lineInfo(ipCanonical), body))

proc disableParamFiltering* =
  ## disables filtering tests with the command line params
  disabledParamFiltering = true
