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
## Runner protocol
## ===============
##
## A compiled test binary can also be driven from the outside, one test per
## process, by a runner that does the scheduling itself. Four flags make that
## possible:
##
## ===================== =======================================================
## flag                  effect
## ===================== =======================================================
## `--list`              print one `suite::test` name per line
## `--list-json`         print the same set as a JSON catalog, with the
##                       per-test metadata described below
## `--run "suite::test"` run exactly that one test; exit code 0 for a pass,
##                       1 for a failure, 2 for a skip
## `--catalog FILE`      write a `name` to `bodyHash` map to FILE, or to
##                       stdout when FILE is `-`
## ===================== =======================================================
##
## When the `NIMTEST_RESULT_FILE` environment variable names a file, `--run`
## writes the status, duration, checkpoints and exception of the test to it.
##
## What lands on standard output
## -----------------------------
##
## In the three modes whose document goes to standard output — `--list`,
## `--list-json` and `--catalog -` — the document is the ONLY thing there. The
## program's own output, whether from a `suite` body, from a C library writing
## to `stdout` directly, or from a child process that inherits the descriptor,
## is redirected to standard error for the duration of the run.
##
## This is not tidiness. A `suite` body executes when the suite is declared,
## which is long before the document is written, so without the redirection an
## `echo` in one would be interleaved with the document on the same descriptor.
## For `--list` that is unrecoverable rather than merely untidy: a write with no
## trailing newline does not add a spurious line, it prefixes itself to a real
## test name, and no consumer can tell the result from a genuine name.
##
## Nothing is discarded — the author's output still appears on standard error —
## and nothing is added to standard output. A consumer that merges the two
## streams itself (`prog --list >file 2>&1`) opts back into the ambiguity.
##
## `--catalog FILE` and `--run` are untouched, since neither writes a document
## to standard output; under `--run`, standard output belongs to the test.
##
## Tests entry
## -----------
##
## A test binary also answers the `tests` entry of
## `nim-entrypoints <https://github.com/metacraft-labs/nim-entrypoints>`_,
## through which a build tool lists and runs the tests of any program, whatever
## framework they are written in. The run-time selector is recognised only as
## the FIRST argument, `--entrypoint=<name>` or `--entrypoint <name>`. Every
## argument after it belongs to the entry: none is read as one of the flags
## above or as a positional filter.
##
## ======================================= =====================================
## arguments                               effect
## ======================================= =====================================
## `--entrypoint=list`                     print the entry list, one JSON
##                                         document (schema `entrypoints/1`)
##                                         naming `main` and `tests`, whose
##                                         `entries` are the test names
## `--entrypoint=tests --list`             print every test name, one per line
## `--entrypoint=tests --list-test-cases`  print nothing: no test of this module
##                                         can be built alone
## `--entrypoint=tests --run-exact=NAME`   run exactly the tests named `NAME`;
##                                         repeatable
## `--entrypoint=tests --run=PATTERN`      run the tests the filter `PATTERN`
##                                         matches, as a positional filter does
##                                         without the selector; repeatable
## `--entrypoint=tests`                    run every test
## `--entrypoint=main`                     run every test
## ======================================= =====================================
##
## A test's name under the entry is `suite::test`, or the bare test name
## outside a suite (the `--list` flag above writes `::test` there). No test runs
## while a listing is printed, and the listing is the only thing on standard
## output, as above. A name holding a line break cannot be listed: it is named
## on standard error and the exit code is 70, before any name is printed.
##
## `--run-exact` compares a name as written and never as a pattern, so a name
## containing `*` selects that test alone. A name that `--list` does not print,
## `--run-exact` together with `--run`, a `--run` that matches no test and an
## entry other than `list`, `main` and `tests` each name the problem on
## standard error and exit with 64. Otherwise the exit code is that of an
## ordinary run: 1 when a test that ran failed, else 0. A skipped test does not
## fail the run; when `NIMTEST_RESULT_FILE` is set and `--run-exact` names one
## test, the result of that test is written to it exactly as under `--run`,
## `"SKIP"` included.
##
## The listing and the refusals are produced when the program exits, once
## every test has registered itself, so a program that declares no test answers
## nothing. The exit code of a refusal cannot be set from an exit proc, so a
## refusal ends the process at once: exit procs registered before the first
## `suite` or `test`, and output buffered in files other than standard output
## and standard error, are not run or written. A process that ends from inside
## a test (`abortOnError`, or a `quit` in the test) keeps the exit code the
## test chose and is not refused. Standard output is claimed by the first `suite` or `test` rather
## than at module initialization, because only there is it known who answers
## the entry: output the program writes at module level before its first
## `suite` or `test` still reaches standard output.
##
## Two other components can answer the entry for the same tests, and then this
## module stands down: it prints nothing, refuses nothing, leaves the exit code
## alone and leaves standard output where it is. Which applies is decided where
## each `suite` and `test` expands, from what that module can see:
##
## * a program built with nim-entrypoints (`entryArgs` and `parseSelector` are
##   visible), whose `tests:` block lists the tests and guards them. Under
##   `--run-exact` this module still runs only the named tests, and under
##   `--run` only the matching ones;
## * reprobuild's `ct_test_unittest_parallel` (`queueProtocolExitHook` and
##   `entryRunWanted` are visible), which wraps this module and selects the
##   tests itself. This module then reads the arguments as it does without
##   the selector, which is what that wrapper was written against.
##
## Backends
## --------
##
## The protocol needs the argument vector, so it exists only on backends that
## have one. On the JavaScript backend `unittest` cannot read command line
## arguments at all: every flag above is ignored there and a test binary always
## behaves as if it had been run with none. A runner must not drive a
## JavaScript-compiled test binary through these flags.
##
## Catalog fields
## --------------
##
## Every row of `--list-json` carries:
##
## ================= ==========================================================
## field             value
## ================= ==========================================================
## `name`            `suite::test`, or `::test` outside a suite
## `suite`           the suite name; empty outside a suite
## `test`            the test name
## `file`            the declaring file, relative to the project directory
## `line`            1-based line of the `test` call
## `column`          0-based column of the `test` call
## `kind`            always `"in-process"`; see below
## `bodyHash`        `macros.symBodyHash` of the test body, taken transitively
##                   over everything the body calls
## `group`           the `group` option, else the enclosing `testGroup`, else
##                   `"@global"`
## `threadsRequired` the `threadsRequired` option, else `1`
## `xfail`           the `xfail` reason, or `null` when it is empty
## `tags`            the `tags` option, else `[]`
## `deterministic`   the `deterministic` option, else `true`
## ================= ==========================================================
##
## The last five are declared by the test author — see `test` — and mean
## nothing to `unittest` itself, which runs every test sequentially in one
## process and so has neither a scheduler to inform nor a previous run to
## compare against. It transports them for the runner that does.
##
## `kind` is the one field with no per-test source. `unittest` registers
## in-process bodies and nothing else, so `"in-process"` is not a placeholder
## standing in for something this module declines to compute: it is the whole
## truth about every row it can emit. It is in the payload because a catalog
## merged from several producers needs the discriminator.
##
## Conforming producers
## --------------------
##
## `unittest` is not the only program that can answer these flags — a project
## may put its own harness behind them — so what a consumer may assume needs
## stating. A producer conforms if:
##
## * `name`, `suite`, `test`, `file`, `line` and `column` are on every row. A
##   consumer may rely on all six.
## * `bodyHash` is present only when the producer can genuinely compute one,
##   and is OMITTED otherwise. It must never be filled with a placeholder: a
##   consumer compares hashes to decide what to re-run, an absent hash reads as
##   "no information" and re-runs, and any placeholder reads as a real digest
##   and would collide with every other row carrying it.
## * `kind`, `group`, `threadsRequired`, `xfail`, `tags` and `deterministic`
##   are optional. A consumer reads an absent field as the default above, and
##   must not read that default as a declaration: "the producer never mentions
##   this field" and "the author declared the default" are the same state, and
##   nothing may depend on telling them apart.
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
    group: string
    threadsRequired: int
    xfail: string
    tags: seq[string]
    deterministic: bool

  ProtocolMode = enum
    pmDefault,
    pmList,
    pmListJson,
    pmRun,
    pmCatalog,
    pmError

  EntryMode = enum
    ## What the run-time selector asked for; see "Tests entry" in the module
    ## documentation. Kept apart from `ProtocolMode` rather than added to it:
    ## `parseProtocolArgs` is reached from every test body through `fail`, so
    ## anything it reads is part of every `bodyHash`, and the selector has to
    ## be answered without changing those hashes.
    emNone,          ## no selector: the program behaves as it always did
    emDescribe,      ## `--entrypoint=list`
    emList,          ## `--entrypoint=tests --list`
    emListTestCases, ## `--entrypoint=tests --list-test-cases`
    emRun,           ## `--entrypoint=tests`, with or without a selection,
                     ## and `--entrypoint=main`
    emUnknown,       ## `--entrypoint=<an entry this program does not have>`
    emUsage          ## `--entrypoint=tests` with arguments it refuses

  EntryOwner = enum
    ## Who answers the selector for the `suite` or `test` being expanded.
    eoUnittest,    ## this module: it prints, refuses and sets the exit code
    eoEntrypoints, ## nim-entrypoints, whose `tests:` block holds the test
    eoWrapper      ## a wrapper of this module that answers the entry itself

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
  entryInitialized {.threadvar.}: bool
  entryExitProcAdded {.threadvar.}: bool
  entryMode {.threadvar.}: EntryMode
  entryName {.threadvar.}: string
    ## The entry the selector named, for `emUnknown`'s message.
  entryUsageError {.threadvar.}: string
    ## Why `emUsage` refuses the entry's arguments.
  entryExact {.threadvar.}: seq[string]
    ## The `--run-exact=<name>` names.
  entryPatterns {.threadvar.}: seq[string]
    ## The `--run=<pattern>` patterns.
  entryPatternMatched {.threadvar.}: bool
  entryNames {.threadvar.}: seq[string]
    ## Every test this module answers the entry for, as the entry names it.
  entryWritesResult {.threadvar.}: bool
    ## `NIMTEST_RESULT_FILE` is written for the test that is running.

  runningTestStatus {.threadvar.}: ptr TestStatus
    ## The status variable of the test currently executing on this thread, or
    ## `nil` when no test is running here.
    ##
    ## `fail` normally reaches the enclosing test's status through the
    ## `testStatusIMPL` symbol that `test` injects, which only resolves inside
    ## the test body itself. A `check` in a helper `proc` — the ordinary way to
    ## share assertions between cases — compiles outside that scope, so the
    ## lookup fails and the failure had nowhere to go but the process exit
    ## code. That is not a channel the per-case protocol can use: `test`
    ## rewrites the exit code from the test's own status when it finishes, so
    ## the failure was overwritten and the case reported `PASS` on both
    ## channels at once. This pointer is the scope-independent route to the
    ## same variable.
    ##
    ## Thread-local on purpose: it addresses a stack variable owned by the
    ## thread running the test, so a helper on ANOTHER thread must not reach
    ## it. There it stays `nil` and `fail` keeps the exit-code behaviour it has
    ## always had.

const
  outputLevelDefault = PRINT_ALL
  nimUnittestOutputLevel {.strdefine.} = $outputLevelDefault
  nimUnittestColor {.strdefine.} = "auto" ## auto|on|off
  nimUnittestAbortOnError {.booldefine.} = false
  nimTestResultFileEnv = "NIMTEST_RESULT_FILE"

  protocolDefaultGroup = "@global"
    ## `group` reported for a test that joins no group. Named rather than
    ## spelled inline so the emitter, the `test` macro and the documentation
    ## cannot drift apart.
  protocolDefaultThreadsRequired = 1
    ## `threadsRequired` reported for a test that declares no weight.
  protocolDefaultDeterministic = true
    ## `deterministic` reported for a test that declares nothing: a test is
    ## assumed to depend only on the code it exercises until its author says
    ## otherwise. The default has to be the safe direction for a consumer that
    ## skips unchanged tests, and `true` is that direction only because the
    ## consumer re-runs on a changed `bodyHash`; a test that reads the clock or
    ## the network has to say `deterministic = false` to be re-run regardless.
  protocolNoTags: array[0, string] = []
    ## The empty `tags` list, as an `array` so passing it costs no allocation
    ## on the path every test takes whether or not the protocol is in use.

template deprecateEnvVarHere() =
  # xxx issue a runtime warning to deprecate this envvar.
  discard

abortOnError = nimUnittestAbortOnError
when declared(stdout):
  if existsEnv("NIMTEST_ABORT_ON_ERROR"):
    deprecateEnvVarHere()
    abortOnError = true

# ---------------------------------------------------------------------------
# Keeping the protocol document off the same channel as the program's own output
# ---------------------------------------------------------------------------
#
# `--list`, `--list-json` and `--catalog -` put a machine-readable document on
# standard output, but they also RUN the module: a `suite` body executes when
# the suite is declared, long before the document is written, and anything it
# prints lands on the very same descriptor. A single `echo` in a suite body is
# therefore enough to make the document unparseable, and a `write(stdout, ...)`
# with no newline is worse than unparseable — it splices itself onto the front
# of a real payload line:
#
#     $ prog --list
#     debugging... suite::first case          # a case name, silently mangled
#
# No consumer can undo that, because nothing in the byte stream distinguishes
# the noise from the name. The only component that knows a document-bearing
# mode is active BEFORE user code runs, and that owns the descriptor, is this
# module. So it takes the descriptor: at module initialization — which precedes
# the body of every module that imports this one — the real standard output is
# saved aside and the process's own file descriptor 1 is pointed at standard
# error for the rest of the run. See `protocolClaimsStdout`.
#
# Consequences, all deliberate:
#
# * The document is written to the saved descriptor and is the ONLY thing on it,
#   byte for byte identical to what a noise-free run produced before.
# * The author's `echo` is not discarded — it is still printed, on standard
#   error, where a human debugging a test can still read it.
# * The redirection is done at the descriptor level rather than by reassigning
#   `stdout`, so it also covers C code writing to `stdout` directly and child
#   processes that inherit descriptor 1. That is the same hazard in its general
#   form: a helper process's chatter can no longer reach a consumer's parser.
# * `--catalog FILE` and `--run` are left alone; neither puts a document on
#   standard output, and `--run` is expected to show the test's own output.
#
# A stream a consumer merges by hand (`prog --list >f 2>&1`) is outside what
# this can fix, and always was.

when declared(stdout):
  when defined(windows):
    proc protocolDupFd(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
    proc protocolDup2Fd(oldFd, newFd: cint): cint {.
      importc: "_dup2", header: "<io.h>".}
    proc protocolCloseFd(fd: cint): cint {.importc: "_close", header: "<io.h>".}
  else:
    proc protocolDupFd(fd: cint): cint {.importc: "dup", header: "<unistd.h>".}
    proc protocolDup2Fd(oldFd, newFd: cint): cint {.
      importc: "dup2", header: "<unistd.h>".}
    proc protocolCloseFd(fd: cint): cint {.
      importc: "close", header: "<unistd.h>".}

  var protocolStdout: File
    ## The program's real standard output, held aside for the document while
    ## descriptor 1 is pointed at standard error.
  var protocolStdoutRedirected = false
    ## Deliberately NOT a `threadvar`: the redirection is a property of the
    ## process, done once by the thread that initializes this module, and every
    ## other thread has to see it.

  proc protocolRedirectStdout() =
    ## Point descriptor 1 at standard error and keep the original for the
    ## document. A failure at any step leaves the process exactly as it was and
    ## the protocol falls back to writing on the shared descriptor, which is no
    ## worse than the behaviour this replaces.
    if protocolStdoutRedirected:
      return
    let outFd = cint(getFileHandle(stdout))
    let errFd = cint(getFileHandle(stderr))
    flushFile(stdout)
    let saved = protocolDupFd(outFd)
    if saved < 0:
      return
    if saved == errFd:
      # `dup` returns the lowest free descriptor, so getting standard error's
      # number back means standard error was closed. Redirecting into it would
      # then point the program's output at the descriptor now holding the
      # document — the very confusion being fixed, with the two streams
      # separately buffered on top. There is nowhere to move the output to, so
      # nothing moves.
      discard protocolCloseFd(saved)
      return
    var restored: File
    if not open(restored, FileHandle(saved), fmWrite):
      discard protocolCloseFd(saved)
      return
    if protocolDup2Fd(errFd, outFd) < 0:
      close(restored)
      return
    protocolStdout = restored
    protocolStdoutRedirected = true

  proc protocolEcho(line: string) =
    ## `echo`, except that once the redirection is in place it addresses the
    ## saved descriptor. Same bytes, same order, same per-line flush.
    if protocolStdoutRedirected:
      protocolStdout.write(line)
      protocolStdout.write("\n")
      flushFile(protocolStdout)
    else:
      echo line

  proc protocolFlushStdout() =
    if protocolStdoutRedirected:
      flushFile(protocolStdout)

else:
  # A backend without `stdout` has no protocol either: the argument vector is
  # unreachable there, so no mode but `pmDefault` can ever be selected. See the
  # `Backends` section of this module's documentation.
  proc protocolRedirectStdout() = discard
  proc protocolEcho(line: string) = echo line
  proc protocolFlushStdout() = discard

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
  # `kind` is the one field here with no per-test source. `unittest` registers
  # in-process bodies and nothing else — it has no `registerExternalTest`, no
  # `.test` file discovery and no fuzz corpus — so "in-process" is not a
  # placeholder standing in for a value this module could compute; it is the
  # complete truth about every test this producer can emit. It stays in the
  # payload because a catalog merged from several producers needs the
  # discriminator, and because `summary.byKind` is keyed on it.
  result.add(",\"kind\":\"in-process\",\"group\":")
  result.add(jsonString(test.group))
  result.add(",\"threadsRequired\":")
  result.add($test.threadsRequired)
  result.add(",\"xfail\":")
  # An empty reason is `null`, not `""`: `xfail = when defined(windows): "..."
  # else: ""` is the documented way to mark a test expected to fail on one
  # platform, and on the other platforms it must be indistinguishable from a
  # test that never mentioned `xfail` at all.
  if test.xfail.len == 0:
    result.add("null")
  else:
    result.add(jsonString(test.xfail))
  result.add(",\"tags\":[")
  for i, tag in test.tags:
    if i > 0:
      result.add(",")
    result.add(jsonString(tag))
  result.add("],\"bodyHash\":")
  result.add(jsonString(test.bodyHash))
  result.add(",\"deterministic\":")
  result.add(if test.deterministic: "true" else: "false")
  result.add("}")

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
  # `--run`, or the tests entry's `--run-exact` of a single name: the two ways
  # of running exactly one test, so the one result has an owner.
  if protocolResultFile.len == 0 or
      (protocolMode != pmRun and not entryWritesResult):
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
    protocolEcho buildListJson()
  of pmCatalog:
    let catalog = buildCatalogJson()
    if protocolCatalogPath == "-":
      protocolEcho catalog
    elif protocolCatalogPath.len > 0:
      when declared(writeFile):
        writeFile(protocolCatalogPath, catalog)
    else:
      protocolEcho "unittest: --catalog requires a file path"
      when declared(setProgramResult):
        setProgramResult 1
  of pmRun:
    if not protocolRanSelected:
      writeMissingProtocolResult()
      when declared(setProgramResult):
        setProgramResult 1
  of pmError:
    if protocolParseError.len > 0:
      protocolEcho protocolParseError
    when declared(setProgramResult):
      setProgramResult 1
  else:
    discard
  protocolFlushStdout()

proc entrySelector(): tuple[name: string; taken: int] =
  ## The entry the run-time selector names: the FIRST argument
  ## `--entrypoint=<name>` (one argument taken) or `--entrypoint <name>` (two).
  ## `taken` is 0 when the program was not given a selector. Only the first
  ## argument is a selector, as in nim-entrypoints, so a test filter or a
  ## program option further on is never read as one.
  when declared(paramCount):
    if paramCount() >= 1:
      let first = paramStr(1)
      if first.startsWith("--entrypoint="):
        return (first.substr("--entrypoint=".len), 1)
      if first == "--entrypoint":
        if paramCount() >= 2:
          return (paramStr(2), 2)
        return ("", 1)

proc protocolClaimsStdout(): bool =
  ## Whether the command line selects a mode whose document is written to
  ## standard output, decided WITHOUT touching any protocol state.
  ##
  ## This is the question `protocolRedirectStdout` has to answer at module
  ## initialization, before the importing module's body — and therefore before
  ## any `suite` body — has run. `parseProtocolArgs` cannot answer it there,
  ## for two reasons that both come down to it running too early:
  ##
  ## * `disableParamFiltering` is a runtime call the user makes from their own
  ##   module body, so a parse that ran before that body would decide the
  ##   meaning of the positional arguments before being told.
  ## * `macros.symBodyHash` reaches `parseProtocolArgs` from every test body
  ##   that uses `check`, by way of `fail` -> `ensureInitialized`. Editing it at
  ##   all would change the `bodyHash` this module reports for every such test
  ##   in every program — a full re-run for every consumer that uses the hash to
  ##   skip unchanged tests, in exchange for nothing they asked for.
  ##
  ## So the two stay separate, and this one is deliberately the smaller: it
  ## reads the argument vector and returns a `bool`. It mirrors the flag
  ## spellings and the last-flag-wins precedence of `parseProtocolArgs` below,
  ## and a new document-bearing flag has to be added in both places. Missing it
  ## here costs the new flag the protection and nothing else.
  ##
  ## Under the run-time selector the arguments belong to the entry, and the
  ## descriptor is claimed later, by the first `suite` or `test` that answers
  ## the entry (`enterEntry`): only there is it known whether this module or
  ## nim-entrypoints prints the document.
  when declared(paramCount):
    if entrySelector().taken > 0:
      return false
    var i = 1
    while i <= paramCount():
      let arg = paramStr(i)
      if arg == "--list" or arg == "--list-json":
        result = true
      elif arg == "--run":
        # A trailing `--run` is a usage error, which prints a diagnostic rather
        # than a document; either way standard output is not claimed.
        result = false
        inc i
      elif arg.startsWith("--run="):
        result = false
      elif arg == "--catalog":
        if i == paramCount():
          result = false
        else:
          inc i
          result = paramStr(i) == "-"
      elif arg.startsWith("--catalog="):
        result = arg.substr("--catalog=".len) == "-"
      inc i

proc initProtocolStdout() =
  ## Claim standard output for the document before the importing module's body
  ## runs. This is the earliest moment this module gets control, and it precedes
  ## every `suite` declaration in every module that imports it.
  ##
  ## It does not precede the initialization of a module imported BEFORE
  ## `unittest`; such a module's own start-up output still reaches standard
  ## output. That window is far smaller than a suite body and closing it
  ## entirely would need help from the compiler.
  when nimvm:
    # A module used at compile time initializes inside the VM, which has no
    # argument vector and no file descriptors.
    discard
  else:
    if protocolClaimsStdout():
      protocolRedirectStdout()

initProtocolStdout()

proc parseProtocolArgs() {.gcsafe.} =
  # Whether the flags parsed here put their document on standard output is
  # decided a second time, and earlier, by `protocolClaimsStdout` above; see
  # there for why the two are not shared. Adding a document-bearing flag here
  # means adding it there too.
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
                          line, column: int; bodyHash: string;
                          group: string; threadsRequired: int;
                          xfail: string; tags: openArray[string];
                          deterministic: bool) =
  ## `tags` is an `openArray` rather than a `seq` because this proc is called
  ## once per test in EVERY mode, including a plain `nim c -r`, where the
  ## metadata is discarded. The `seq` is materialized only in the two modes
  ## that go on to serialize it.
  let name = protocolFullName(suiteName, testName)
  case protocolMode
  of pmList:
    protocolEcho name
  of pmListJson, pmCatalog:
    protocolTests.add TestMetadata(
      suiteName: suiteName,
      testName: testName,
      file: file,
      line: line,
      column: column,
      bodyHash: bodyHash,
      group: group,
      threadsRequired: threadsRequired,
      xfail: xfail,
      tags: @tags,
      deterministic: deterministic
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

# ---------------------------------------------------------------------------
# The tests entry
# ---------------------------------------------------------------------------
#
# Everything below answers nim-entrypoints' run-time selector; see "Tests
# entry" in the module documentation. None of it is reached from a test body:
# it is called from the `suite` and `test` expansions only, so it leaves every
# `bodyHash` as it was, and without a selector it does nothing but look at the
# first argument once.

const
  entryUsageExitCode = 64
    ## nim-entrypoints' `usageExitCode` (EX_USAGE).
  entryUnlistableExitCode = 70
    ## nim-entrypoints' `unlistableNameExitCode` (EX_SOFTWARE).
  entryProgramName = querySetting(SingleValueSetting.projectName)
    ## The `program` of the entry list, as nim-entrypoints spells it.

proc entryTestName(suiteName, testName: string): string =
  ## A test's name under the entry: `suite::test`, or the bare test name
  ## outside a suite, as nim-entrypoints names a `tests:` block's tests (the
  ## `--list` protocol above writes `::test` there).
  if suiteName.len == 0: testName else: suiteName & "::" & testName

proc isOneLine(name: string): bool =
  '\n' notin name and '\r' notin name

proc parseEntryArgs() {.gcsafe.} =
  ## Read the selector and the entry's arguments, once. Under the selector the
  ## arguments are the entry's alone: `parseProtocolArgs` is marked as done so
  ## that neither the protocol flags nor the positional filters are read from
  ## them. Without that, `--entrypoint=tests --run-exact=x` was two filters
  ## that no test matches, so nothing ran and the run passed.
  if entryInitialized:
    return
  entryInitialized = true
  when declared(paramCount):
    let selector = entrySelector()
    if selector.taken == 0:
      return
    # Also undoes a parse that already happened, which only a `check` at
    # module level, ahead of the first `suite` or `test`, can have caused.
    protocolInitialized = true
    protocolMode = pmDefault
    testsFilters.clear()
    protocolResultFile = ""
    case selector.name
    of "list":
      entryMode = emDescribe
    of "main":
      entryMode = emRun
    of "tests":
      var listing, testCasesOnly = false
      var i = selector.taken + 1
      while i <= paramCount():
        let arg = paramStr(i)
        if arg == "--list":
          listing = true
        elif arg == "--list-test-cases":
          listing = true
          testCasesOnly = true
        elif arg.startsWith("--run-exact="):
          entryExact.add arg.substr("--run-exact=".len)
        elif arg.startsWith("--run="):
          entryPatterns.add arg.substr("--run=".len)
        elif arg == "--run":
          if i == paramCount():
            entryUsageError = "--run requires a pattern"
          else:
            inc i
            entryPatterns.add paramStr(i)
        # Any other argument is ignored: it is neither a protocol flag nor a
        # filter here.
        inc i
      # A listing wins over a run, as in nim-entrypoints.
      if listing:
        entryMode = if testCasesOnly: emListTestCases else: emList
      elif entryUsageError.len > 0:
        entryMode = emUsage
      elif entryExact.len > 0 and entryPatterns.len > 0:
        entryMode = emUsage
        entryUsageError = "--run-exact cannot be combined with --run: " &
          "--run-exact selects listed names exactly, --run matches patterns"
      else:
        entryMode = emRun
    else:
      entryName = selector.name
      entryMode = emUnknown
    if entryMode != emRun and formatters.len == 0:
      # No test runs in these modes; the base formatter reports nothing, so a
      # suite does not announce itself either.
      formatters = @[OutputFormatter()]
    when declared(existsEnv):
      if entryMode == emRun and entryExact.len == 1:
        protocolResultFile = getEnv(nimTestResultFileEnv)

proc protocolEntryOwner(entrypointsVisible, wrapperVisible: bool): EntryOwner =
  ## Decided where a `suite` or `test` expands, from what the user's module
  ## can see there: nim-entrypoints' `entryArgs` and `parseSelector` mean
  ## nim-entrypoints owns the selector (the test sits in its `tests:` block);
  ## reprobuild's `ct_test_unittest_parallel` (its `queueProtocolExitHook`
  ## and `entryRunWanted`) wraps this module and answers the entry itself.
  if entrypointsVisible: eoEntrypoints
  elif wrapperVisible: eoWrapper
  else: eoUnittest

when declared(stderr):
  when defined(windows):
    proc entryExitNow(code: cint) {.importc: "_exit", header: "<stdlib.h>",
      noreturn.}
  else:
    proc entryExitNow(code: cint) {.importc: "_exit", header: "<unistd.h>",
      noreturn.}

  proc entryRefuse(code: int; message: string) =
    ## Name the problem on standard error and end the process with `code`.
    ## Called from the exit hook, which runs from the C runtime's `atexit`
    ## once the program result has already been taken, so neither
    ## `setProgramResult` nor `quit` can give the exit code there. The process
    ## ends at once instead, as nim-entrypoints' `exitImmediately` does, and
    ## exit procs queued behind this one do not run.
    stderr.writeLine("unittest: " & message)
    flushFile(stderr)
    flushFile(stdout)
    protocolFlushStdout()
    entryExitNow(cint(code))
else:
  # No argument vector, so no selector and nothing to refuse.
  proc entryRefuse(code: int; message: string) = discard

proc buildEntryList(): string =
  ## nim-entrypoints' entry list (schema `entrypoints/1`). Both entries are
  ## chosen at run time; neither has a `-d:entrypoint=<name>` build.
  result = "{\"schema\":\"entrypoints/1\",\"program\":"
  result.add jsonString(entryProgramName)
  result.add ",\"default\":\"main\",\"entries\":[" &
    "{\"name\":\"main\",\"doc\":\"run every test\",\"select\":[\"runtime\"]}," &
    "{\"name\":\"tests\",\"doc\":\"run the program's tests\"," &
    "\"select\":[\"runtime\"],\"args\":" &
    jsonString("[--list] [--list-test-cases] [--run=<pattern>]... " &
      "[--run-exact=<name>]...") &
    ",\"entries\":["
  for i, name in entryNames:
    if i > 0:
      result.add ","
    result.add jsonString(name)
  result.add "]}]}"

proc finishEntry() =
  ## The exit hook of a program whose entry this module answers: the
  ## documents, which need every test registered, and the refusals.
  case entryMode
  of emNone, emListTestCases:
    discard
  of emDescribe:
    protocolEcho buildEntryList()
  of emList:
    # Every name is checked before any is printed, so a tool never reads a
    # partial list as the whole.
    for name in entryNames:
      if not name.isOneLine:
        entryRefuse(entryUnlistableExitCode, "the test name " & name.escape &
          " cannot be listed: it holds a line break, and " &
          "--entrypoint=tests --list prints one name per line; rename the test")
        return
    for name in entryNames:
      protocolEcho name
  of emUnknown:
    entryRefuse(entryUsageExitCode,
      (if entryName.len == 0: "--entrypoint needs an entry name"
       else: "unknown entry '" & entryName & "'") &
      "; the entries are: main, tests")
  of emUsage:
    entryRefuse(entryUsageExitCode, entryUsageError)
  of emRun:
    if runningTestStatus != nil:
      # The process is ending from inside a test body: `abortOnError`, or a
      # `quit` in the test. The tests after it never registered, so a name
      # cannot be called unknown, and the exit code the test chose stands.
      discard
    elif entryExact.len > 0:
      for name in entryExact:
        if not name.isOneLine or name notin entryNames:
          entryRefuse(entryUsageExitCode, "--run-exact: no test is named " &
            "exactly " & name.escape & " (the name is compared as written, " &
            "not as a pattern, and must be one that --entrypoint=tests " &
            "--list prints); the tests are: " & entryNames.join(", "))
          return
    elif entryPatterns.len > 0 and not entryPatternMatched:
      entryRefuse(entryUsageExitCode, "--run: no test matches " &
        entryPatterns.join(", ") & "; the tests are: " & entryNames.join(", "))
  protocolFlushStdout()

proc enterEntry(owner: EntryOwner) =
  ## Called by every `suite` and `test` expansion, ahead of anything else.
  ## Without a selector, or when another component answers it, it does nothing
  ## else; in particular it registers no exit proc (see
  ## `ensureProtocolExitProc` for why that matters on the JS backend).
  if owner == eoWrapper:
    # The wrapper reads the command line itself and was written against this
    # module as it behaves without the entry, so the arguments are left to
    # `parseProtocolArgs` exactly as they were before the entry existed.
    return
  parseEntryArgs()
  if entryMode == emNone or owner != eoUnittest:
    return
  if entryMode in {emDescribe, emList, emListTestCases}:
    # The document is about to be the only thing on standard output; see
    # "Keeping the protocol document off the same channel" above. Claimed
    # here rather than at module initialization, because only an expansion
    # site knows that this module, and not nim-entrypoints, prints it.
    protocolRedirectStdout()
  if not entryExitProcAdded:
    entryExitProcAdded = true
    addExitProc(finishEntry)

proc registerEntryTest(suiteName, testName: string; owner: EntryOwner) =
  if entryMode != emNone and owner == eoUnittest:
    entryNames.add entryTestName(suiteName, testName)

proc shouldRunTest(suiteName, testName: string; owner: EntryOwner): bool =
  ## `shouldRunProtocolTest`, or under the selector the entry's selection.
  if entryMode == emNone:
    return shouldRunProtocolTest(suiteName, testName)
  if entryMode != emRun:
    return false
  let name = entryTestName(suiteName, testName)
  if entryExact.len > 0:
    result = name.isOneLine and name in entryExact
  elif entryPatterns.len > 0:
    for pattern in entryPatterns:
      if matchFilter(suiteName, testName, pattern):
        result = true
    if result:
      entryPatternMatched = true
  else:
    result = true
  entryWritesResult = result and owner == eoUnittest and entryExact.len == 1

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
  bind formatters, ensureInitialized, ensureProtocolExitProc, suiteEnded,
    enterEntry, protocolEntryOwner

  block:
    template setup(setupBody: untyped) {.dirty, used.} =
      var testSetupIMPLFlag {.used.} = true
      template testSetupIMPL: untyped {.dirty.} = setupBody

    template teardown(teardownBody: untyped) {.dirty, used.} =
      var testTeardownIMPLFlag {.used.} = true
      template testTeardownIMPL: untyped {.dirty.} = teardownBody

    let testSuiteName {.used.} = name

    # Who answers the tests entry is decided here, where the user's module is
    # in scope: this template is dirty, so `declared` sees its imports.
    enterEntry(protocolEntryOwner(
      declared(entryArgs) and declared(parseSelector),
      declared(queueProtocolExitHook) and declared(entryRunWanted)))
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

template testGroup*(name: string; body: untyped) {.dirty.} =
  ## Declare that every test in `body` belongs to the group `name`.
  ##
  ##   ```nim
  ##   suite "database":
  ##     testGroup "db-access":
  ##       test "insert record":
  ##         check db.insert(record)
  ##
  ##       test "delete record":
  ##         check db.delete(id)
  ##   ```
  ##
  ## A group is the unit a scheduler serializes: tests that share a port, a
  ## database or a working directory name the same group, and a runner that
  ## reads `--list-json` can then keep them off each other. `unittest` itself
  ## runs tests sequentially and so has nothing to schedule — it reports the
  ## membership and nothing more. See `test`'s `group` option to name a group
  ## for a single test, which takes precedence over an enclosing `testGroup`.
  ##
  ## The declaration is block-level because group membership is a property of a
  ## SET of tests: the interesting case is a whole suite sharing one resource,
  ## and repeating `group = "db-access"` on each test invites the typo that
  ## silently splits the set in two.
  block:
    let testGroupName {.used.} = name
    body

template testImpl(name: untyped; xfail: string; tags: openArray[string];
                  group: string; threadsRequired: int; deterministic: bool;
                  body: untyped) {.dirty.} =
  ## The body of `test`, with the declared metadata already separated out by
  ## that macro. Kept a `{.dirty.}` template rather than folded into the macro
  ## so the expansion stays readable and, more importantly, so
  ## `instantiationInfo(-1, true)` below still names the user's `test` call
  ## site: `getAst` on a template preserves the instantiation stack, and the
  ## emitted `line`/`column` are byte-identical to what the plain template
  ## reported before this macro existed.
  bind shouldRun, checkpoints, formatters, ensureInitialized, testEnded,
    exceptionTypeName, setProgramResult, protocolBodyHash, registerProtocolTest,
    resetProtocolTestState, ensureProtocolExitProc, shouldRunTest,
    protocolMode, pmRun, protocolDefaultGroup, runningTestStatus, enterEntry,
    protocolEntryOwner, registerEntryTest

  block:
    # `getAst` leaves `entryArgs` and its peers unbound, so like `suite`'s
    # check this one resolves in the module that wrote the `test`.
    let testEntryOwnerIMPL {.used.} = protocolEntryOwner(
      declared(entryArgs) and declared(parseSelector),
      declared(queueProtocolExitHook) and declared(entryRunWanted))
    enterEntry(testEntryOwnerIMPL)
    ensureInitialized()
    ensureProtocolExitProc()

    let currentSuiteNameIMPL {.used.} =
      when declared(testSuiteName): testSuiteName else: ""
    let currentGroupIMPL {.used.} =
      # A per-test `group` wins over an enclosing `testGroup`; with neither,
      # the test is in the default group. The empty string is the "said
      # nothing" marker rather than a legal group name, so a test cannot land
      # in a nameless group by accident.
      if group.len > 0: group
      else:
        when declared(testGroupName): testGroupName
        else: protocolDefaultGroup
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
      testBodyHashIMPLValue,
      currentGroupIMPL,
      threadsRequired,
      xfail,
      tags,
      deterministic
    )
    registerEntryTest(currentSuiteNameIMPL, name, testEntryOwnerIMPL)

    if shouldRunTest(currentSuiteNameIMPL, name, testEntryOwnerIMPL):
      checkpoints = @[]
      resetProtocolTestState()
      var testStatusIMPL {.inject.} = TestStatus.OK
      # Publish the status variable for the duration of the body so a `fail`
      # compiled outside this scope — every `check` in a helper `proc` — can
      # still reach it. Saved and restored rather than nilled: the value is
      # whatever was published when this test started, so a test reached from
      # inside another test's body cannot strand the outer one.
      # Keep declaration and assignment separate. The hot-code-reloading
      # transform lifts initialized locals behind a guard; on the JS backend
      # that guard can absorb the following try and leave its finally orphaned.
      var enclosingTestStatusIMPL: ptr TestStatus
      enclosingTestStatusIMPL = runningTestStatus
      runningTestStatus = addr testStatusIMPL

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
        # Unpublish before anything else in the teardown path: a `fail` from a
        # formatter or from `testEnded` belongs to no test.
        runningTestStatus = enclosingTestStatusIMPL
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

macro test*(args: varargs[untyped]): untyped =
  ## Define a single test case identified by `name`, optionally declaring what
  ## a runner needs to know about it.
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
  ##
  ## Declared properties
  ## -------------------
  ##
  ## Between the name and the body, a test may declare any of five properties.
  ## Each is optional and each reaches the outside world through the
  ## `--list-json` catalog described in this module's documentation; `unittest`
  ## itself does not act on any of them, because it runs tests sequentially in
  ## one process and so has neither a scheduler to inform nor a previous run to
  ## compare against.
  ##
  ## ================== ============================== ==========================
  ## option             meaning                        default
  ## ================== ============================== ==========================
  ## `xfail`            reason the test is expected    `""`, reported as `null`
  ##                    to fail
  ## `tags`             free-form labels a runner can  `[]`
  ##                    filter on
  ## `group`            name of a set of tests that    the enclosing
  ##                    must not run concurrently      `testGroup`, else
  ##                                                   `"@global"`
  ## `threadsRequired`  concurrency slots the test     `1`
  ##                    consumes
  ## `deterministic`    whether the outcome depends    `true`
  ##                    only on the code under test
  ## ================== ============================== ==========================
  ##
  ##   ```nim
  ##   test "known overflow", xfail = "bug #1234":
  ##     check largeComputation() == expected
  ##
  ##   test "fetches the index", tags = ["slow", "network"],
  ##       deterministic = false:
  ##     check fetch("http://example.com").code == 200
  ##
  ##   test "saturates the machine", threadsRequired = countProcessors():
  ##     check heavyComputation() == expected
  ##   ```
  ##
  ## An `xfail` reason is a string rather than a `bool` so the annotation
  ## carries WHY, and so a platform-conditional annotation has somewhere to go:
  ##
  ##   ```nim
  ##   test "win32 path handling",
  ##       xfail = (when defined(windows): "not implemented" else: ""):
  ##     check crossPlatformFeature()
  ##   ```
  ##
  ## An empty reason means the same thing as saying nothing at all.
  ##
  ## `test` is a macro rather than a template only because Nim binds a trailing
  ## block to the next unfilled parameter in order: with the options declared as
  ## defaulted parameters, `test "x": body` binds the body to the first option
  ## and `test "x", xfail = "y": body` does not compile at all. Everything the
  ## macro does is separate the options from the name and the body; the code it
  ## produces is the `testImpl` template above, which is what `test` always was.
  if args.len < 2:
    error("'test' takes a name and a body", args)

  let
    name = args[0]
    body = args[^1]
  var
    xfail = newLit("")
    tags = bindSym"protocolNoTags"
    group = newLit("")
    threadsRequired = newLit(protocolDefaultThreadsRequired)
    deterministic = newLit(protocolDefaultDeterministic)
    seen: seq[string] = @[]

  proc claim(seen: var seq[string]; option: NimNode; canonical: string) =
    ## Record that `canonical` has been given, rejecting a second mention.
    ## Keyed on the canonical spelling rather than on what the author typed,
    ## because `eqIdent` is style-insensitive: `xfail` and `xFail` select the
    ## same option and so must collide as one.
    if canonical in seen:
      error("duplicate 'test' option: " & canonical, option[0])
    seen.add canonical

  for i in 1 ..< args.len - 1:
    let option = args[i]
    if option.kind != nnkExprEqExpr:
      error("a 'test' option is written 'name = value'; expected one of " &
        "xfail, tags, group, threadsRequired, deterministic", option)
    if option[0].eqIdent("xfail"):
      claim(seen, option, "xfail"); xfail = option[1]
    elif option[0].eqIdent("tags"):
      claim(seen, option, "tags"); tags = option[1]
    elif option[0].eqIdent("group"):
      claim(seen, option, "group"); group = option[1]
    elif option[0].eqIdent("threadsRequired"):
      claim(seen, option, "threadsRequired"); threadsRequired = option[1]
    elif option[0].eqIdent("deterministic"):
      claim(seen, option, "deterministic"); deterministic = option[1]
    else:
      error("unknown 'test' option: " & repr(option[0]) & "; expected one of " &
        "xfail, tags, group, threadsRequired, deterministic", option[0])

  result = getAst(testImpl(name, xfail, tags, group, threadsRequired,
                           deterministic, body))

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
    # No `testStatusIMPL` in scope: this `fail` is compiled outside a test
    # body, which is where every `check` in a helper `proc` ends up. If a test
    # is running on this thread, that is still the test that failed, and
    # `runningTestStatus` reaches its status without needing the symbol.
    #
    # The `setProgramResult` fallback is kept for the case it was actually
    # written for — a `fail` with no test running on this thread at all — and
    # is unchanged there.
    if runningTestStatus != nil:
      runningTestStatus[] = TestStatus.FAILED
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
