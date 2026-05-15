discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-OOP: verify that method dispatch surfaces the concrete
## (dispatch-resolved) procedure as a distinct entry in the trace's
## `functions[]` table.
##
## Pre-CTFS-M-OOP all overloads of `method sound(...)` registered under
## the bare name `sound`, so calls dispatched to `Dog.sound` and
## `Cat.sound` collapsed into a single function entry — a debugger
## reading the trace couldn't tell which concrete method actually ran
## for which object. That violates the "trace shows what happens at
## runtime" principle: each method body is genuinely different code.
##
## The fix in `functionNameForTrace`: when `prc.kind == skMethod`,
## suffix the bare name with the first parameter's type rendered via
## `typeToString` (`sound[Dog]`, `sound[Cat]`, `sound[Animal]`). The
## first parameter is the dispatch type — sem enforces `hasObjParam`,
## so it's always present. Generic instantiations remain handled by
## the `sfFromGeneric` branch, which renders the full resolved
## signature.
##
## Two supporting changes make this trace observable under `nim e`,
## which previously rejected method calls outright:
##
##   * `compiler/vmgen.nim` no longer fails calls to `skMethod` syms.
##     `transformCall` rewrites the call to invoke the dispatcher
##     (an `skMethod` with `sfDispatcher`), and the dispatcher body's
##     inner if/elif calls reach `nkCall(skMethod, …)` again — these
##     are passed through `genCall` so the VM enters the concrete
##     method body.
##   * `compiler/transf.nim::transformBody` lazily invokes
##     `generateIfMethodDispatchers` the first time a dispatcher's
##     body is requested with an empty body. `cgen` / `jsgen` run that
##     pass at end-of-module; for VM eval there is no end-of-module
##     hook, so we synthesise the body on demand.
##   * `compiler/cgmeth.nim::genIfDispatcher` skips the `chckNilDisp`
##     prelude when the compiler proc is absent (NimScript builds
##     exclude `system/chcks.nim` via the `notJSnotNims` gate); the
##     dispatcher's if/elif chain still produces correct dispatch.
##
## This test exercises three concrete methods (`Animal`, `Dog`, `Cat`)
## and asserts:
##   1. `functions[]` contains an entry for each dispatch-resolved
##      method: `sound[Dog]`, `sound[Cat]`. The dispatcher itself
##      (`sound[Animal]`) appears as the entry registered when the
##      dispatcher proc is first entered.
##   2. The trace fires four `call_entry` events — one dispatcher call
##      plus one concrete-method call per pet, two pets total. The
##      exact count is pinned because the if/elif dispatcher always
##      consults the chain before tail-calling the concrete method.
##   3. The bare name `sound` (no bracketed dispatch type) MUST NOT
##      appear — that would mean a non-suffixed entry leaked through
##      and Dog/Cat dispatches collapsed under one ID.

import std/[os, osproc, assertions, strutils, sets]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_oop"

const userScript = """
type
  Animal = ref object of RootObj
  Dog = ref object of Animal
  Cat = ref object of Animal

method sound(a: Animal): string {.base.} = "?"
method sound(d: Dog): string = "woof"
method sound(c: Cat): string = "meow"

let pets: seq[Animal] = @[Animal(Dog()), Animal(Cat())]
for pet in pets:
  echo pet.sound()
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
  let scriptFile = buildDir / "oop_program.nims"
  writeFile(scriptFile, userScript)

  let traceFile = buildDir / "oop.ct"
  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "woof" in output and "meow" in output,
    "expected 'woof' and 'meow' in stdout, got: " & output

  let funcs = readFunctions(traceFile)

  # All `sound`-related entries should be distinguishable by their
  # bracketed dispatch type.
  var soundEntries: seq[string] = @[]
  for n in funcs:
    if n.startsWith("sound"):
      soundEntries.add(n)

  # We expect at least one entry per concrete method (Dog, Cat) plus
  # the dispatcher (Animal). The exact count depends on whether the
  # base method body is ever reached — `Dog` and `Cat` both override
  # so the base body never runs, but the dispatcher itself is entered
  # twice (once per pet) and registered as `sound[Animal]`.
  doAssert "sound[Dog]" in soundEntries,
    "expected 'sound[Dog]' in functions[], got: " & soundEntries.join(", ")
  doAssert "sound[Cat]" in soundEntries,
    "expected 'sound[Cat]' in functions[], got: " & soundEntries.join(", ")

  # All `sound`-related entries must be distinct (no collisions under
  # the bare name `sound`).
  var seen = initHashSet[string]()
  for e in soundEntries:
    doAssert e notin seen,
      "duplicate sound entry: " & e & " in " & soundEntries.join(", ")
    seen.incl(e)

  # Sanity: the bare name `sound` (no brackets) must NOT appear — that
  # would mean the old code-path leaked a non-suffixed entry through.
  doAssert "sound" notin seen,
    "expected no bare 'sound' entry; functions[] = " & soundEntries.join(", ")

  # Every sound entry must follow the `name[Type]` shape.
  for e in soundEntries:
    doAssert e.startsWith("sound[") and e.endsWith("]"),
      "expected entry to be in 'sound[<Type>]' shape, got: " & e

  # Call event count: two pets, each going through dispatcher + a
  # concrete-method call -> 4 Call events total.
  let calls = callCountOf(traceFile)
  doAssert calls == 4,
    "expected exactly 4 Call events (2 dispatcher + 2 concrete), got " & $calls

  echo "PASS: tvm_trace_oop — sound entries=", soundEntries.len,
       " (", soundEntries.join(", "), ") calls=", calls

  removeDir(buildDir)

main()
