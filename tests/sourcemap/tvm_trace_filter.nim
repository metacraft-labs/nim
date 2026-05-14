discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## TF-M4: end-to-end test for the cross-language trace-filter wiring.
##
## Exercises four properties of the integration between
## `codetracer_trace_writer/path_filter` and the Nim VM tracer:
##
##   1. Built-in default filter — running `nim e --trace:<f>` on a tiny
##      user script produces a trace whose `paths` table contains ONLY the
##      user file. The Nim stdlib (lib/system/*, lib/std/*, lib/pure/*, ...)
##      is skipped without any user-supplied filter file or env var.
##   2. CLI override — `--trace-filter:<file>` is honored. A filter that
##      restricts tracing to a specific filename produces the expected
##      trimmed `paths`.
##   3. `--no-auto-filter` does not break tracing.
##   4. `CODETRACER_TRACE_FILTER` env var composes after auto-discovery
##      and before CLI flags; passing a filter that overrides the builtin
##      to `default_exec = "skip"` and selectively re-enables the user
##      file should produce a single-path trace identical in shape to
##      case (1).
##
## See: `codetracer-specs/Recording-Backends/Trace-Filters.milestones.md` § TF-M4
## and `codetracer-trace-format-spec/Trace-Filters.md` §§ 5–6.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_filter"

const userScript = """
proc userProc(x: int): int =
  result = x * 2

let y = userProc(21)
echo y
"""

const cliFilterToml = """
[meta]
name = "tvm-trace-filter-test"
version = 1

[scope]
default_exec = "skip"

[[scope.rules]]
selector = "file:glob:**/user_program.nims"
exec = "trace"
reason = "Only trace the user test program."
"""

proc readPaths(traceFile: string): seq[string] =
  ## Open `traceFile` and dump its registered paths.
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  for i in 0 ..< int(rdr.pathCount):
    let p = rdr.path(uint64(i))
    if p.isOk:
      result.add(p.get)

proc stepCountOf(traceFile: string): uint64 =
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  let sc = rdr.stepCount
  doAssert sc.isOk, "stepCount failed: " & sc.error
  return sc.get

proc runNim(nim, scriptFile, traceFile: string;
            extraArgs: seq[string] = @[];
            env: seq[(string, string)] = @[]): string =
  ## Run `nim e --trace:<traceFile> <extraArgs> <scriptFile>` and return
  ## stdout+stderr. `env` is set in the child process if non-empty.
  var cmd = nim & " e --trace:" & traceFile
  for a in extraArgs:
    cmd.add(" ")
    cmd.add(a)
  cmd.add(" ")
  cmd.add(scriptFile)
  if env.len == 0:
    let (output, exitCode) = execCmdEx(cmd)
    doAssert exitCode == 0, "nim e --trace failed: " & output
    return output
  # Compose with explicit env. execCmdEx doesn't accept env; use a shell
  # invocation that sets each var.
  var prefixed = ""
  for (k, v) in env:
    prefixed.add(k & "=" & quoteShell(v) & " ")
  let fullCmd = prefixed & cmd
  let (output, exitCode) = execCmdEx(fullCmd)
  doAssert exitCode == 0,
    "nim e --trace (with env) failed:\n  cmd: " & fullCmd & "\n  out: " & output
  return output

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "user_program.nims"
  writeFile(scriptFile, userScript)

  # ----- Case 1: builtin default filter only -----------------------------
  block:
    let traceFile = buildDir / "case1_builtin.ct"
    let output = runNim(nim, scriptFile, traceFile)
    doAssert "42" in output,
      "expected '42' from userProc(21), got output: " & output
    let paths = readPaths(traceFile)
    doAssert paths.len == 1,
      "case1: expected exactly 1 path (the user script), got " &
      $paths.len & ": " & paths.join(", ")
    doAssert paths[0].endsWith("user_program.nims"),
      "case1: expected the user script path, got: " & paths[0]
    let sc = stepCountOf(traceFile)
    doAssert sc >= 1,
      "case1: expected at least 1 step from user code, got " & $sc
    echo "PASS case 1: builtin filter — paths=", paths.len, " steps=", sc

  # ----- Case 2: explicit --trace-filter restricts further ---------------
  block:
    let filterFile = buildDir / "cli_filter.toml"
    writeFile(filterFile, cliFilterToml)
    let traceFile = buildDir / "case2_cli.ct"
    discard runNim(nim, scriptFile, traceFile,
                   @["--trace-filter:" & filterFile])
    let paths = readPaths(traceFile)
    doAssert paths.len == 1,
      "case2: expected exactly 1 path, got " & $paths.len &
      ": " & paths.join(", ")
    doAssert paths[0].endsWith("user_program.nims"),
      "case2: expected user_program.nims, got: " & paths[0]
    echo "PASS case 2: --trace-filter — paths=", paths.len

  # ----- Case 3: --no-auto-filter still allows tracing user code ---------
  block:
    let traceFile = buildDir / "case3_no_auto.ct"
    discard runNim(nim, scriptFile, traceFile, @["--no-auto-filter"])
    let paths = readPaths(traceFile)
    doAssert paths.len == 1,
      "case3: expected exactly 1 path, got " & $paths.len &
      ": " & paths.join(", ")
    doAssert paths[0].endsWith("user_program.nims"),
      "case3: expected user_program.nims, got: " & paths[0]
    echo "PASS case 3: --no-auto-filter — paths=", paths.len

  # ----- Case 4: CODETRACER_TRACE_FILTER env var composes correctly ------
  block:
    let envFilterFile = buildDir / "env_filter.toml"
    writeFile(envFilterFile, cliFilterToml)
    let traceFile = buildDir / "case4_env.ct"
    discard runNim(nim, scriptFile, traceFile,
                   env = @[("CODETRACER_TRACE_FILTER", envFilterFile)])
    let paths = readPaths(traceFile)
    doAssert paths.len == 1,
      "case4: expected exactly 1 path, got " & $paths.len &
      ": " & paths.join(", ")
    doAssert paths[0].endsWith("user_program.nims"),
      "case4: expected user_program.nims, got: " & paths[0]
    echo "PASS case 4: CODETRACER_TRACE_FILTER — paths=", paths.len

  removeDir(buildDir)
  echo "PASS: tvm_trace_filter (TF-M4)"

main()
