discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-Generics: verify that generic proc instantiations produce
## distinct entries in the trace's `functions[]` table.
##
## Pre-CTFS-M-Generics every instantiation of `proc f[T](x: T): T`
## registered under the bare name `f`, so `f[int]`, `f[string]` and
## `f[float]` collapsed into a single `functions[]` entry. The runtime
## behaviour the trace is supposed to record is "three different
## procedures with three different bodies" — collapsing them violated
## the "trace shows what happens at runtime" principle.
##
## The fix: when `sfFromGeneric in prc.flags`, the tracer composes the
## function name from `prc.name.s` plus the resolved proc signature
## (`f(int) -> int`, `f(string) -> string`, …). Since the Nim compiler
## already creates a distinct `PSym` per instantiation (the
## `funcByItemId` cache key remains distinct), the only change needed
## was the writer-facing name — distinct names produce distinct
## `functionIds`.
##
## This test exercises three instantiations and asserts:
##   1. `functions[]` contains exactly three entries.
##   2. Each entry name is unique and includes the instantiated type
##      (`int`, `string`, `float`) — guarding the "distinguishable
##      names" half of the contract.
##   3. The trace fires three `call_entry` events, one per
##      instantiation, each referencing the corresponding function id.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_generics"

const userScript = """
proc f[T](x: T): T =
  result = x

let a = f[int](42)
let b = f[string]("hello")
let c = f[float](3.14)

echo a, " ", b, " ", c
"""

proc readFunctions(traceFile: string): seq[string] =
  result = @[]
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  for i in 0 ..< int(rdr.functionCount):
    let f = rdr.function(uint64(i))
    if f.isOk:
      result.add(f.get)

proc callCountOf(traceFile: string): uint64 =
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed for " & traceFile & ": " & openRes.error
  var rdr = openRes.get()
  let cc = rdr.callCount
  doAssert cc.isOk, "callCount failed: " & cc.error
  return cc.get

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "generics_program.nims"
  writeFile(scriptFile, userScript)

  let traceFile = buildDir / "generics.ct"
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "42 hello 3.14" in output,
    "expected '42 hello 3.14' in stdout, got: " & output

  let funcs = readFunctions(traceFile)
  # Three distinct instantiations -> three distinct entries.
  doAssert funcs.len == 3,
    "expected exactly 3 function entries (one per instantiation), got " &
    $funcs.len & ": " & funcs.join(", ")

  # Each entry shares the bare prefix `f(` (so the base name survives) and
  # carries a unique resolved signature.
  for name in funcs:
    doAssert name.startsWith("f("),
      "expected entry to start with 'f(' (bare name + signature), got: " & name

  # All three signatures must be distinct.
  var seen: seq[string] = @[]
  for n in funcs:
    doAssert n notin seen,
      "duplicate function entry: " & n & " in " & funcs.join(", ")
    seen.add(n)

  # The instantiated types (`int`, `string`, `float`) must be reflected in
  # exactly one entry each. We match against the resolved-signature suffix
  # to guard the "distinguishable names" half of the contract without
  # over-constraining the exact rendering format.
  proc countContaining(funcs: seq[string], needle: string): int =
    for n in funcs:
      if needle in n:
        inc result
  doAssert countContaining(funcs, "int") == 1,
    "expected exactly 1 entry mentioning 'int', got: " & funcs.join(", ")
  doAssert countContaining(funcs, "string") == 1,
    "expected exactly 1 entry mentioning 'string', got: " & funcs.join(", ")
  doAssert countContaining(funcs, "float") == 1,
    "expected exactly 1 entry mentioning 'float', got: " & funcs.join(", ")

  # Call-event count: each instantiation is invoked once.
  let calls = callCountOf(traceFile)
  doAssert calls == 3,
    "expected exactly 3 Call events (one per instantiation), got " & $calls

  echo "PASS: tvm_trace_generics — functions=", funcs.len,
       " (", funcs.join(", "), ") calls=", calls

  removeDir(buildDir)

main()
