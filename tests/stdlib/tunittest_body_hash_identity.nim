discard """
  targets: "c"
  joinable: false
"""

## A body hash must identify a test's BODY. Two things that are not the body
## are easy to let leak into it, and neither is covered by the other two
## `tunittest_body_hash_*` files:
##
## 1. **The labels.** A test's name, and its suite's name, are what the runner
##    protocol reports *alongside* the hash. If they also reached the hash, a
##    catalog diff could not tell a rename from an edit: every renamed case
##    would look like a changed case and be re-run. `testImpl` keeps the body
##    in a nested `testBodyIMPL` proc and passes `name` only to
##    `registerProtocolTest` and to the formatters, both outside that proc, so
##    the separation exists — but nothing asserted it, and the `test` template
##    became `macro test*(args: varargs[untyped])` with an option-parsing layer
##    in between, which is exactly the kind of restructure that can pull a
##    literal into the body without anyone noticing.
##
## 2. **Where the toolchain is installed.** `sighashes.symBodyDigest` recurses
##    through every routine a body calls, so `std/unittest`'s own internals are
##    part of every test's hash, and any absolute path a stdlib routine plants
##    in its own body would travel with them. `tunittest_body_hash_paths.nim`
##    varies the *package's* checkout directory but compiles every fixture with
##    the same `--lib`, so the stdlib prefix has never been varied by a checked
##    -in test. A CI worker and a developer's machine differ in both.
##
## Both halves need a negative control, because both are trivially satisfiable
## by a hash that has stopped looking at anything: part one by a hash that
## ignores the body, part two by a hash that ignores the standard library. So
## each half also asserts the *opposite* case — a changed body still rehashes,
## and a body that genuinely reaches a path inside the standard library still
## tracks it.
##
## No mocks: real compiler invocations, real copies of the standard library on
## disk, and the hashes are read out of the runner protocol the consumer
## actually uses.

import std/[assertions, json, os, osproc, sets, strutils, syncio, tables,
            tempfiles]

const
  nimbleSource = """
version = "0.1.0"
author = "nim"
description = "body hash identity fixture"
license = "MIT"
"""

# ---------------------------------------------------------------------------
# Part 1 — the labels are not the body.
# ---------------------------------------------------------------------------

const
  ## Every variant keeps the target test's body at the same line and column:
  ## `check` plants its own location into the body as a string literal, so a
  ## variant that shifted the body would legitimately rehash and the comparison
  ## would prove nothing. Only the quoted names, or the checked expression,
  ## differ between these.
  labelBase = """
import std/unittest

suite "identity":
  test "target":
    var probe = 1
    check probe == 1
  test "control":
    var other = 2
    check other == 2
"""
  labelRenamedTest = labelBase.replace("test \"target\"", "test \"renamed\"")
  labelRenamedSuite = labelBase.replace("suite \"identity\"",
                                        "suite \"renamed\"")
  labelChangedBody = labelBase.replace("check probe == 1", "check probe == 2")

# ---------------------------------------------------------------------------
# Part 2 — the standard library's install prefix is not the body.
# ---------------------------------------------------------------------------

const
  ## `mstdlibprobe` is written INTO each copy of the standard library, so
  ## `currentSourcePath()` inside it yields that copy's absolute path. It is
  ## the negative control for part two: a body that really does reach a path
  ## under the stdlib prefix must still track it, otherwise the equality
  ## assertions could be satisfied by a hash that had stopped descending into
  ## the standard library at all.
  stdlibProbeSource = """
proc stdlibProbePath*(): string =
  currentSourcePath()
"""
  prefixFixture = """
import std/unittest
import mstdlibprobe

suite "prefix":
  test "plain":
    var probe = 1
    check probe == 1
  test "expect":
    expect ValueError:
      raise newException(ValueError, "boom")
  test "reaches into the stdlib prefix":
    check stdlibProbePath().len > 0
"""
  prefixIndependentTests = ["prefix::plain", "prefix::expect"]
  prefixDependentTest = "prefix::reaches into the stdlib prefix"

# ---------------------------------------------------------------------------
# Shared helpers.
# ---------------------------------------------------------------------------

proc compileFixture(nim, libDir, src, exe, nimcache: string) =
  ## `--lib` is explicit because that is the variable under test in part two,
  ## and because the compiler under test is not necessarily installed next to
  ## the `lib` these sources belong to.
  let command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(nimcache) &
    " -o:" & quoteShell(exe) & " " & quoteShell(src)
  let compiled = execCmdEx(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  doAssert fileExists(exe), "compiler did not produce " & exe

proc bodyHashes(binary: string): Table[string, string] =
  let listed = execCmdEx(quoteShell(binary) & " --list-json")
  doAssert listed.exitCode == 0, listed.output
  for item in parseJson(listed.output)["tests"]:
    result[item["name"].getStr] = item["bodyHash"].getStr

proc partOne(nim, libDir, sandbox: string) =
  ## All four variants are compiled from the SAME file path, so the location
  ## literal `check` plants is identical in every one of them and the only
  ## thing that varies is what this part means to vary.
  let root = sandbox / "labels"
  createDir(root / "tests")
  writeFile(root / "mypkg.nimble", nimbleSource)
  let src = root / "tests" / "t.nim"

  var hashes: Table[string, Table[string, string]]
  for variant, source in {
      "base": labelBase,
      "renamedTest": labelRenamedTest,
      "renamedSuite": labelRenamedSuite,
      "changedBody": labelChangedBody}.toTable:
    writeFile(src, source)
    let exe = root / addFileExt(variant, ExeExt)
    compileFixture(nim, libDir, src, exe, root / ("nimcache_" & variant))
    hashes[variant] = bodyHashes(exe)

  # PRECONDITION: the renames really did rename something, so the equalities
  # below are between differently-labelled tests rather than between two
  # spellings of the same label.
  doAssert hashes["base"].hasKey("identity::target")
  doAssert hashes["renamedTest"].hasKey("identity::renamed"),
    "the test-rename variant did not produce a renamed test: " &
    $hashes["renamedTest"]
  doAssert not hashes["renamedTest"].hasKey("identity::target")
  doAssert hashes["renamedSuite"].hasKey("renamed::target"),
    "the suite-rename variant did not produce a renamed suite: " &
    $hashes["renamedSuite"]
  doAssert not hashes["renamedSuite"].hasKey("identity::target")

  # 1. A TEST'S NAME IS NOT ITS BODY. Renaming a case must leave its hash
  #    alone, or a catalog diff reports every rename as an edit.
  doAssert hashes["base"]["identity::target"] ==
           hashes["renamedTest"]["identity::renamed"],
    "renaming a test changed its bodyHash, so a rename is indistinguishable " &
    "from an edit: " & hashes["base"]["identity::target"] & " vs " &
    hashes["renamedTest"]["identity::renamed"]

  # 2. NEITHER IS ITS SUITE'S NAME.
  doAssert hashes["base"]["identity::target"] ==
           hashes["renamedSuite"]["renamed::target"],
    "renaming the enclosing suite changed a test's bodyHash: " &
    hashes["base"]["identity::target"] & " vs " &
    hashes["renamedSuite"]["renamed::target"]

  # 3. NEGATIVE CONTROL: the hash still moves when the body moves. Without
  #    this, assertions 1 and 2 would be satisfied by a constant.
  doAssert hashes["base"]["identity::target"] !=
           hashes["changedBody"]["identity::target"],
    "changing the checked expression did not change the bodyHash"

  # 4. NEGATIVE CONTROL: two differently-bodied tests in the same binary do
  #    not collide, so `bodyHash` is discriminating in this fixture at all.
  doAssert hashes["base"]["identity::target"] !=
           hashes["base"]["identity::control"],
    "two distinct test bodies share a bodyHash: " & $hashes["base"]

proc installStdlib(source, dest: string) =
  ## A real copy, not a symlink: the property under test is what the compiler
  ## writes into the tree for a file at a given absolute path, and a symlink
  ## would leave that path shared between the two "installations".
  copyDir(source, dest)
  writeFile(dest / "pure" / "mstdlibprobe.nim", stdlibProbeSource)

proc partTwo(nim, libDir, sandbox: string) =
  # Two stdlib prefixes whose paths differ in length as well as in content, so
  # a hash that depended on the prefix could not coincide by luck.
  let prefixA = sandbox / "sdk"
  let prefixB = sandbox / "a-considerably-longer-toolchain-prefix"
  doAssert prefixA.len != prefixB.len
  createDir(prefixA)
  createDir(prefixB)
  installStdlib(libDir, prefixA / "lib")
  installStdlib(libDir, prefixB / "lib")

  # One package, one source path, compiled twice. The package does not move,
  # so the only absolute path that differs between the two builds is the
  # standard library's.
  let root = sandbox / "prefixpkg"
  createDir(root / "tests")
  writeFile(root / "mypkg.nimble", nimbleSource)
  let src = root / "tests" / "t.nim"
  writeFile(src, prefixFixture)

  var hashes: Table[string, Table[string, string]]
  for variant, prefix in {"a": prefixA, "b": prefixB}.toTable:
    let exe = root / addFileExt("prefix_" & variant, ExeExt)
    compileFixture(nim, libDir = prefix / "lib", src = src, exe = exe,
                   nimcache = root / ("nimcache_" & variant))
    hashes[variant] = bodyHashes(exe)

  for name in prefixIndependentTests:
    doAssert hashes["a"].hasKey(name), "fixture did not register " & name
    doAssert hashes["a"][name].len > 0, "empty bodyHash for " & name

  # 1. THE INSTALL PREFIX IS NOT THE BODY. Same source, same checkout, two
  #    standard libraries at different absolute paths.
  for name in prefixIndependentTests:
    doAssert hashes["a"][name] == hashes["b"][name],
      "bodyHash of " & name & " depends on where the standard library is " &
      "installed: " & hashes["a"][name] & " vs " & hashes["b"][name]

  # 2. NEGATIVE CONTROL, and the one that makes assertion 1 mean something: a
  #    body that genuinely reaches a path under the prefix — here through a
  #    module living inside the standard library itself — must still track it.
  #    If this ever became an equality too, the hash would have stopped
  #    descending into the standard library and assertion 1 would be vacuous.
  doAssert hashes["a"][prefixDependentTest] != hashes["b"][prefixDependentTest],
    "a test body that transitively reaches `currentSourcePath()` inside the " &
    "standard library hashes the same under two different prefixes; the " &
    "digest is no longer descending into stdlib callees, so the equalities " &
    "above prove nothing"

  # 3. NEGATIVE CONTROL: not a constant.
  var distinctHashes: HashSet[string]
  for name, hash in hashes["a"]:
    distinctHashes.incl hash
  doAssert distinctHashes.len == hashes["a"].len,
    "distinct test bodies collided: " & $hashes["a"]

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  let libDir = currentSourcePath().parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir
  let sandbox = createTempDir("tunittest_body_hash_identity_", "")
  try:
    partOne(nim, libDir, sandbox)
    partTwo(nim, libDir, sandbox)
  finally:
    removeDir(sandbox)

main()
