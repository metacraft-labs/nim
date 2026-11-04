discard """
  joinable: false
  timeout: 1200
"""

## Real-compiler controls for `nim --compilerArgsFile:<path>`
## (see `compiler/argsfile.nim`).
##
## Every positive case is a differential control: the compiler that built
## this test is run twice on the same fixture tree, once with the logical
## argument vector as its OS argv and once with that vector in an argument
## file, and the two runs must agree on exit code, combined output (config
## script observations, diagnostics, program output) and the recorded
## `config.commandLine`. Cases cover both command-line passes, user/parent/
## project-specific configuration, `config.nims` imports, relative paths,
## search-path order with duplicates, exclusions and aliases, defines with
## quotes/backslashes/`$`/`%`/`@`/BMP and supplementary Unicode, target-program
## arguments (including empty ones), an empty logical vector and an argument
## file that configuration removes or replaces between the passes.
##
## Every malformed-input class the format refuses has a negative case, each
## checked to fail before configuration runs.
##
## On Windows one more control builds a logical vector longer than the
## 32,767 UTF-16 code unit `CreateProcessW` limit, shows that the direct
## invocation fails with ERROR_FILENAME_EXCED_RANGE (206) and that the same
## vector through an argument file compiles and runs.
##
## Nothing is mocked: the compiler, file system and C toolchain are real.

import std/[os, osproc, streams, strutils, json, sequtils]


const nim = getCurrentCompilerExe()

let root = getTempDir() / ("tcompilerargsfile-" & $getCurrentProcessId())
let proj = root / "proj"
let argsDir = root / "args files"
let exeSuffix = when defined(windows): ".exe" else: ""

type RunResult = object
  exitCode: int
  output: string

proc progress(what: string) =
  # Progress goes to stderr unbuffered, so a qualification log streaming this
  # test shows which compiler run is in flight.
  stderr.writeLine "[tcompilerargsfile] ", what
  stderr.flushFile()

proc run(args: seq[string]; cwd = proj): RunResult =
  progress("run " & (if args.len > 0: args[0] else: "<no args>") & " (" &
    $args.len & " args) in " & cwd)
  var p = startProcess(nim, workingDir = cwd, args = args,
                       options = {poStdErrToStdOut})
  defer: p.close()
  # Drain to EOF. `Stream.readAll` stops at the first short read, and a
  # Windows pipe read returns whatever is available, so it truncated the
  # compiler's output and then deadlocked once the compiler filled the pipe.
  var buffer = newString(4096)
  while true:
    let n = p.outputStream.readData(addr buffer[0], buffer.len)
    if n <= 0: break
    result.output.add buffer[0 ..< n]
  result.exitCode = p.waitForExit()

proc writeArgsFile(name: string; argv: seq[string]): string =
  ## Writes a version-1 argument file and returns its path relative to `proj`
  ## (the caller's current directory), so the transport's own path is
  ## resolved against the caller CWD.
  let node = %*{"version": 1, "argv": argv}
  writeFile(argsDir / name, $node)
  result = ".." / "args files" / name

proc clean() =
  removeDir(proj / "cache")
  removeDir(proj / "build")

proc builtProgramOutput(): string =
  ## Output of the program a `c` run built, which reports what the compiler
  ## recorded (`config.commandLine` among it) through `std/compilesettings`.
  let exe = proj / "build" / "main" & exeSuffix
  if fileExists(exe): execProcess(exe, args = [], options = {poStdErrToStdOut})
  else: ""

var failures = 0
proc check(cond: bool; what: string) =
  if not cond:
    inc failures
    echo "FAILED: ", what

proc differential(name: string; argv: seq[string]; expect: seq[string] = @[];
                  status = 0; physicalName = "compilerArgsFile:") =
  ## Runs `argv` directly and through an argument file and requires the two
  ## to agree. `expect` are substrings both outputs must contain.
  clean()
  let direct = run(argv)
  let directProgram = builtProgramOutput()
  clean()
  let file = writeArgsFile(name & ".json", argv)
  let viaFile = run(@["--" & physicalName & file])
  let fileProgram = builtProgramOutput()
  check direct.exitCode == status,
    name & ": direct exit " & $direct.exitCode & "\n" & direct.output
  check viaFile.exitCode == direct.exitCode,
    name & ": exit codes differ " & $direct.exitCode & " vs " & $viaFile.exitCode
  check viaFile.output == direct.output,
    name & ": outputs differ\n--- direct\n" & direct.output &
    "\n--- file\n" & viaFile.output
  check fileProgram == directProgram,
    name & ": built programs differ\n" & directProgram & "\n" & fileProgram
  check "compilerArgsFile:" & file notin viaFile.output,
    name & ": the physical transport option leaked into an observation"
  for e in expect:
    check e in direct.output & directProgram,
      name & ": missing '" & e & "'\n" & direct.output & directProgram

proc negative(name, content, diagnostic: string) =
  ## A malformed argument file must be refused with a clear diagnostic before
  ## any configuration file is evaluated.
  writeFile(argsDir / name, content)
  let r = run(@["--compilerArgsFile:" & (".." / "args files" / name)])
  check r.exitCode != 0, name & ": accepted\n" & r.output
  check diagnostic in r.output,
    name & ": expected '" & diagnostic & "' in\n" & r.output
  check "CFG " notin r.output, name & ": configuration ran\n" & r.output

# --------------------------------------------------------------------------
# Fixture tree.
# --------------------------------------------------------------------------

removeDir(root)
createDir(argsDir)
createDir(proj / "relative imports")
createDir(proj / "excluded")
createDir(proj / "ünï 😀")
createDir(root / "configset")

# Parent-directory configuration.
writeFile(root / "nim.cfg", "define:fromParentCfg\n")
# Project configuration with an early import relative to the script.
writeFile(proj / "cfghelper.nim", "proc cfgMarker*(): string = \"cfg-import-ok\"\n")
writeFile(proj / "config.nims", """
import std/strutils
import cfghelper
echo "CFG ", cfgMarker()
echo "CFG paramCount=", paramCount()
for i in 1 .. paramCount():
  echo "CFG param ", i, "=", paramStr(i).escape
echo "CFG exe=", paramStr(0).escape
if existsEnv("TARGSFILE_MUTATE"):
  let target = getEnv("TARGSFILE_MUTATE")
  if getEnv("TARGSFILE_MUTATE_MODE") == "remove":
    rmFile(target)
  else:
    writeFile(target, "{\"version\":1,\"argv\":[\"c\",\"-d:replaced\",\"main.nim\"]}")
""")
# Project-specific configuration, both kinds.
writeFile(proj / "main.nims", "echo \"CFG project nims\"\nswitch(\"define\", \"fromProjectNims\")\n")
writeFile(proj / "main.nim.cfg", "define:fromProjectCfg\n")
writeFile(proj / "relative imports" / "libmod.nim", "const marker* = \"libmod-relative\"\n")
writeFile(proj / "excluded" / "libmod.nim", "const marker* = \"libmod-EXCLUDED\"\n")
writeFile(proj / "excluded" / "onlyexcluded.nim", "const x* = 1\n")
writeFile(proj / "ünï 😀" / "unimod.nim", "const uniMarker* = \"unimod-ok\"\n")
writeFile(proj / "main.nim", """
import std/[os, strutils, compilesettings]
echo "PROGRAM commandLine=", querySetting(SingleValueSetting.commandLine).escape
import libmod, unimod
const sval {.strdefine.} = ""
const lastFlag {.strdefine.} = ""
echo "PROGRAM ", marker, " ", uniMarker
echo "PROGRAM sval=", sval.escape
echo "PROGRAM lastFlag=", lastFlag
echo "PROGRAM parentCfg=", defined(fromParentCfg), " projectCfg=", defined(fromProjectCfg),
  " projectNims=", defined(fromProjectNims), " cmd=", defined(fromCmd),
  " replaced=", defined(replaced)
echo "PROGRAM argc=", paramCount()
for i in 1 .. paramCount():
  echo "PROGRAM arg ", i, "=", paramStr(i).escape
""")
writeFile(proj / "broken.nim", "import onlyexcluded\necho x\n")
writeFile(proj / "script.nims", """
import std/strutils
echo "SCRIPT argc=", paramCount()
for i in 1 .. paramCount():
  echo "SCRIPT arg ", i, "=", paramStr(i).escape
""")
writeFile(root / "configset" / "config.nims", "switch(\"compilerArgsFile\", \"x.json\")\n")
writeFile(root / "configset" / "main.nim", "echo 1\n")

let sval = "quote\" back\\slash $HOME %PATH% @file é 😀 sp ace"
let common = @[
  "--skipUserCfg", "--hints:off", "--colors:off",
  "--nimcache:cache", "--out:" & "build" / "main" & exeSuffix,
  "--path:excluded", "--path:relative imports", "-p:relative imports",
  "--path:relative imports", "--excludePath:excluded", "--path:ünï 😀",
  "-d:sval=" & sval, "--define:fromCmd"]
let targetArgs = @["", "with space", "$HOME", "%PATH%", "@resp",
                   "--compilerArgsFile:literal.json", "quote\"d",
                   "back\\slash", "é😀", ""]

# --------------------------------------------------------------------------
# Differential controls.
# --------------------------------------------------------------------------

block compileAndRun:
  progress("case compileAndRun")
  var expect = @["CFG cfg-import-ok", "CFG project nims",
    "CFG paramCount=" & $(common.len + 2 + targetArgs.len),
    "PROGRAM libmod-relative unimod-ok",
    "PROGRAM sval=" & sval.escape,
    "PROGRAM parentCfg=true projectCfg=true projectNims=true cmd=true replaced=false",
    "PROGRAM argc=" & $targetArgs.len]
  for i, a in targetArgs:
    expect.add "PROGRAM arg " & $(i + 1) & "=" & a.escape
  let argv = @["r"] & common & @["main.nim"] & targetArgs
  for i, a in argv:
    expect.add "CFG param " & $(i + 1) & "=" & a.escape
  differential("run", argv, expect)
  # The physical option is matched style-insensitively, with either separator.
  differential("style", argv, expect, physicalName = "compiler_args_file=")

block compileOnly:
  progress("case compileOnly")
  differential("compile", @["c"] & common & @["main.nim"],
    @["CFG cfg-import-ok", "PROGRAM commandLine=\" c --skipUserCfg",
      "PROGRAM sval=" & sval.escape])

block emptyVector:
  progress("case emptyVector")
  # An empty logical vector takes the ordinary no-arguments usage path; it
  # must not reparse the physical option.
  differential("empty", @[], @["nim command [options] [projectfile] [arguments]"])

block diagnostics:
  progress("case diagnostics")
  # A module reachable only through an excluded path stays unresolved, and the
  # diagnostic is identical.
  differential("broken", @["c"] & common & @["broken.nim"],
               @["onlyexcluded"], status = 1)

block nimscriptMain:
  progress("case nimscriptMain")
  differential("script", @["--hints:off", "script.nims", "a", "b c", ""],
               @["SCRIPT argc=5", "SCRIPT arg 4=\"b c\"", "SCRIPT arg 5=\"\""])

block secondPassIsRetained:
  progress("case secondPassIsRetained")
  # Configuration replaces, then removes, the argument file between the
  # passes. The second pass must still see the vector read before pass 1.
  let argv = @["r"] & common & @["main.nim", "x"]
  for mode in ["replace", "remove"]:
    clean()
    let dummy = root / ("dummy-" & mode)
    writeFile(dummy, "")
    putEnv("TARGSFILE_MUTATE_MODE", mode)
    putEnv("TARGSFILE_MUTATE", dummy)
    let direct = run(argv)
    clean()
    let rel = writeArgsFile("mutate-" & mode & ".json", argv)
    putEnv("TARGSFILE_MUTATE", argsDir / ("mutate-" & mode & ".json"))
    let viaFile = run(@["--compilerArgsFile:" & rel])
    delEnv("TARGSFILE_MUTATE")
    delEnv("TARGSFILE_MUTATE_MODE")
    check direct.exitCode == 0 and viaFile.exitCode == 0,
      mode & ": failed\n" & direct.output & "\n" & viaFile.output
    check viaFile.output == direct.output,
      mode & ": outputs differ\n" & direct.output & "\n--- file\n" & viaFile.output
    check "replaced=false" in viaFile.output, mode & ": second pass reread the file"
    if mode == "remove":
      check not fileExists(argsDir / "mutate-remove.json"), "remove: config did not run"
    else:
      check "-d:replaced" in readFile(argsDir / "mutate-replace.json"),
        "replace: config did not run"

block absolutePath:
  progress("case absolutePath")
  clean()
  discard writeArgsFile("absolute.json", @["c"] & common & @["main.nim"])
  let r = run(@["--compilerArgsFile:" & (argsDir / "absolute.json")])
  check r.exitCode == 0, "absolute path: " & r.output
  check fileExists(proj / "build" / "main" & exeSuffix), "absolute path: no output"

block longVector:
  progress("case longVector")
  # Many search roots and defines, as a build tool's provider compile carries.
  var argv = @["r", "--skipUserCfg", "--hints:off", "--colors:off",
               "--nimcache:cache", "--out:" & "build" / "main" & exeSuffix]
  var units = 0
  var i = 0
  while units < 40_000:
    let dir = root / "roots" / ("sdk-root-" & align($i, 4, '0') & "-" & repeat('r', 80))
    argv.add "--path:" & dir
    argv.add "--excludePath:" & dir
    argv.add "-d:pad" & $i & "=" & repeat('x', 40)
    units = argv.foldl(a + b.len + 3, 0)
    inc i
  argv.add @["--path:relative imports", "--path:ünï 😀", "-d:lastFlag=long-vector-ok", "main.nim"]
  clean()
  when defined(windows):
    var code = 0
    try:
      discard run(argv)
    except OSError as e:
      code = e.errorCode
    check code == 206, "long vector: direct invocation did not fail with 206 (got " & $code & ")"
    let rel = writeArgsFile("long.json", argv)
    let r = run(@["--compilerArgsFile:" & rel])
    check r.exitCode == 0, "long vector: file-backed failed\n" & r.output
    check "PROGRAM lastFlag=long-vector-ok" in r.output, "long vector: last flag lost\n" & r.output
  else:
    differential("long", argv, @["PROGRAM lastFlag=long-vector-ok"])

# --------------------------------------------------------------------------
# Refusals.
# --------------------------------------------------------------------------

block refusals:
  progress("case refusals")
  let ok = "\"argv\":[\"c\",\"main.nim\"]"
  negative("bom.json", "\xEF\xBB\xBF{\"version\":1," & ok & "}", "byte order mark")
  negative("utf8.json", "{\"version\":1,\"argv\":[\"\xFF\"]}", "invalid UTF-8")
  negative("overlong.json", "{\"version\":1,\"argv\":[\"\xC0\xAF\"]}", "invalid UTF-8")
  negative("surrogate-utf8.json", "{\"version\":1,\"argv\":[\"\xED\xA0\x80\"]}", "invalid UTF-8")
  negative("truncated-utf8.json", "{\"version\":1,\"argv\":[\"\xE2\x82", "UTF-8")
  negative("high-surrogate.json", "{\"version\":1,\"argv\":[\"\\ud800\"]}", "unpaired Unicode surrogate")
  negative("low-surrogate.json", "{\"version\":1,\"argv\":[\"\\udc00\"]}", "unpaired Unicode surrogate")
  negative("bad-pair.json", "{\"version\":1,\"argv\":[\"\\ud800\\u0041\"]}", "unpaired Unicode surrogate")
  negative("nul-escape.json", "{\"version\":1,\"argv\":[\"a\\u0000b\"]}", "NUL")
  negative("nul-raw.json", "{\"version\":1,\"argv\":[\"a\0b\"]}", "control character")
  negative("control.json", "{\"version\":1,\"argv\":[\"a\nb\"]}", "control character")
  negative("truncated.json", "{\"version\":1,\"argv\":[\"c\"", "malformed JSON")
  negative("trailing-comma.json", "{\"version\":1,\"argv\":[\"c\",]}", "not a string")
  negative("trailing-content.json", "{\"version\":1," & ok & "} x", "unexpected content")
  negative("comment.json", "{\"version\":1, // c\n" & ok & "}", "malformed JSON")
  negative("single-quote.json", "{'version':1," & ok & "}", "malformed JSON")
  negative("top-array.json", "[\"c\",\"main.nim\"]", "malformed JSON")
  negative("empty-file.json", "", "malformed JSON")
  negative("bad-escape.json", "{\"version\":1,\"argv\":[\"\\x41\"]}", "invalid escape")
  negative("unknown.json", "{\"version\":1," & ok & ",\"cwd\":\".\"}", "unknown field \"cwd\"")
  negative("dup-argv.json", "{\"version\":1," & ok & "," & ok & "}", "duplicate field \"argv\"")
  negative("dup-version.json", "{\"version\":1,\"version\":1," & ok & "}", "duplicate field \"version\"")
  negative("no-version.json", "{" & ok & "}", "missing field \"version\"")
  negative("no-argv.json", "{\"version\":1}", "missing field \"argv\"")
  negative("version-2.json", "{\"version\":2," & ok & "}", "unsupported argument file version 2")
  negative("version-string.json", "{\"version\":\"1\"," & ok & "}", "must be the integer 1")
  negative("version-float.json", "{\"version\":1.0," & ok & "}", "must be the integer 1")
  negative("version-exp.json", "{\"version\":1e0," & ok & "}", "must be the integer 1")
  negative("argv-object.json", "{\"version\":1,\"argv\":{}}", "malformed JSON")
  negative("entry-number.json", "{\"version\":1,\"argv\":[\"c\",1]}", "entry 1 is not a string")
  negative("entry-null.json", "{\"version\":1,\"argv\":[null]}", "entry 0 is not a string")
  negative("entry-array.json", "{\"version\":1,\"argv\":[[\"c\"]]}", "entry 0 is not a string")

  # Unreadable: a missing file and a directory.
  block:
    let r = run(@["--compilerArgsFile:" & (".." / "args files" / "absent.json")])
    check r.exitCode != 0 and "cannot read argument file" in r.output, "absent: " & r.output
    let d = run(@["--compilerArgsFile:" & (".." / "args files")])
    check d.exitCode != 0 and "argument file" in d.output, "directory: " & d.output
    let e = run(@["--compilerArgsFile:"])
    check e.exitCode != 0 and "requires a file path" in e.output, "empty path: " & e.output

  # The transport is only the sole physical argument: never combined with
  # other physical options, nested (no recursive expansion) or configured.
  block:
    let inner = writeArgsFile("inner.json", @["r", "--hints:off", "main.nim"])
    for argv in [@["--compilerArgsFile:" & inner, "c", "main.nim"],
                 @["c", "--compilerArgsFile:" & inner, "main.nim"]]:
      let r = run(argv)
      check r.exitCode != 0 and "must be the only compiler argument" in r.output,
        "combined: " & r.output
      check "PROGRAM" notin r.output, "combined: compiled anyway"
    let outer = writeArgsFile("outer.json", @["--compilerArgsFile:" & inner])
    let r = run(@["--compilerArgsFile:" & outer])
    check r.exitCode != 0 and "must be the only compiler argument" in r.output,
      "nested: " & r.output
    check "PROGRAM" notin r.output, "nested: the inner file was expanded"
    let c = run(@["c", "--skipUserCfg", "--hints:off", "main.nim"], cwd = root / "configset")
    check c.exitCode != 0 and "must be the only compiler argument" in c.output,
      "configured: " & c.output

removeDir(root)
doAssert failures == 0, $failures & " compiler argument file control(s) failed"
echo "compiler argument file controls passed"
