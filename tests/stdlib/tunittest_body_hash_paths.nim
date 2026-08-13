discard """
  targets: "c"
  joinable: false
"""

## The protocol's ``bodyHash`` must identify a test body, not a checkout — and
## the location literal it is derived from must still name the file well enough
## to open it.
##
## Both halves are load-bearing, and the second is the one that is easy to lose
## silently. `check`/`require`/`expect`/`doAssert`/`assert` plant their location
## in the expanded body as a string literal, and `sighashes.hashBodyTree` hashes
## string literals verbatim, so an ABSOLUTE path makes the hash track the
## checkout. But the obvious repair — rendering relative to `conf.projectPath` —
## degenerates to a bare basename whenever a file is compiled as its own main
## module, because `projectPath` is the directory of the main module rather than
## the package root (`setFromProjectName`). That is stable across checkouts and
## therefore passes any stability-only test, while quietly making two same-named
## test files in different directories indistinguishable. It is also exactly the
## ambiguity that got project paths removed from `macros.lineInfoObj` in
## nim-lang/Nim#7429.
##
## So the fixture below compiles each test file AS ITS OWN MAIN MODULE, the way
## a per-file test runner does, and requires the rendering to survive that.
##
## No mocks: real compiler invocations against real directories, because the
## property under test is precisely what the compiler writes into the tree.

import std/[assertions, json, os, osproc, sets, strutils, syncio, tables,
            tempfiles]

const
  fixtureSource = """
import std/unittest
import ../../src/mhelper

suite "paths":
  test "check":
    let x = 1
    check x == 1
  test "require":
    let x = 1
    require x == 1
  test "expect":
    expect ValueError:
      raise newException(ValueError, "boom")
  test "doAssert":
    let x = 1
    doAssert x == 1
  test "assert":
    let x = 1
    assert x == 1
  test "transitive helper doAssert":
    check helperWithDoAssert(3) == 6
  test "no assertion macro":
    var x = 1
    x = x + 1
    if x != 2: quit 1
  test "deliberate absolute path":
    # NEGATIVE CONTROL: an explicit request for the absolute path. This one is
    # expected to stay checkout-dependent — the fix must not silently rewrite
    # what a user deliberately asked for.
    if false: echo currentSourcePath()
  test "failing check":
    # Prints the location, so the test below can assert on how it renders.
    let x = 2
    check x == 1
"""
  changedSource = fixtureSource.replace("check x == 1", "check x == 2")
  helperSource = """
proc helperWithDoAssert*(x: int): int =
  doAssert x > 0
  x * 2
"""
  nimbleSource = """
version = "0.1.0"
author = "nim"
description = "body hash path fixture"
license = "MIT"
"""
  reproducibleTests = [
    "paths::check", "paths::require", "paths::expect",
    "paths::doAssert", "paths::assert",
    "paths::transitive helper doAssert", "paths::no assertion macro"
  ]
  locationBearingTests = [
    "paths::check", "paths::require", "paths::expect",
    "paths::doAssert", "paths::assert",
    "paths::transitive helper doAssert"
  ] ## `reproducibleTests` minus `no assertion macro`: a body containing no
    ## assertion macro carries no location literal at all, so two copies of it
    ## in different directories SHOULD hash identically. Including it in the
    ## resolvability check below would assert the opposite of what the design
    ## says.
  absolutePathTest = "paths::deliberate absolute path"
  mutatedTest = "paths::check"

proc writePackage(root, source: string) =
  ## A package with two test files that share a basename, in sibling
  ## directories. The `.nimble` file is what anchors `canonicalImportAux`: it
  ## marks the package root, which is the whole point — `projectPath` would be
  ## `<root>/tests/a` and `<root>/tests/b` respectively.
  createDir(root / "src")
  writeFile(root / "mypkg.nimble", nimbleSource)
  writeFile(root / "src" / "mhelper.nim", helperSource)
  for leaf in ["a", "b"]:
    createDir(root / "tests" / leaf)
    writeFile(root / "tests" / leaf / "t.nim", source)

proc buildTest(nim, libDir, root, leaf: string): string =
  ## Compiles `<root>/tests/<leaf>/t.nim` as its OWN main module.
  ##
  ## `--lib` is passed explicitly: the compiler under test is not necessarily
  ## installed next to the `lib` these sources belong to, and without it the
  ## fixtures would silently be built against a different standard library.
  let dir = root / "tests" / leaf
  result = dir / addFileExt("t", ExeExt)
  let command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(root / ("nimcache_" & leaf)) &
    " -o:" & quoteShell(result) & " " & quoteShell(dir / "t.nim")
  let compiled = execCmdEx(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  doAssert fileExists(result), "compiler did not produce " & result

proc bodyHashes(binary: string): Table[string, string] =
  let listed = execCmdEx(quoteShell(binary) & " --list-json")
  doAssert listed.exitCode == 0, listed.output
  for item in parseJson(listed.output)["tests"]:
    result[item["name"].getStr] = item["bodyHash"].getStr

proc failureOutput(binary: string): string =
  ## The console rendering of the failing `check`, which is where the location
  ## literal becomes visible to a human.
  execCmdEx(quoteShell(binary) & " " & quoteShell("paths::failing check")).output

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  let libDir = currentSourcePath().parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir
  let sandbox = createTempDir("tunittest_body_hash_paths_", "")
  try:
    # Two checkouts of the same package. The names differ in length as well as
    # content, so a hash that depended on the path could not coincide by luck.
    let shortRoot = sandbox / "co"
    let longRoot = sandbox / "a-considerably-longer-worktree-name"
    doAssert shortRoot != longRoot
    writePackage(shortRoot, fixtureSource)
    writePackage(longRoot, fixtureSource)

    let shortA = buildTest(nim, libDir, shortRoot, "a")
    let shortB = buildTest(nim, libDir, shortRoot, "b")
    let longA = buildTest(nim, libDir, longRoot, "a")

    let hashesShortA = bodyHashes(shortA)
    let hashesShortB = bodyHashes(shortB)
    let hashesLongA = bodyHashes(longA)

    # 1. REPRODUCIBILITY: the same file in two checkouts hashes identically.
    for name in reproducibleTests:
      doAssert hashesShortA.hasKey(name), "fixture did not register " & name
      doAssert hashesShortA[name].len > 0, "empty bodyHash for " & name
      doAssert hashesShortA[name] == hashesLongA[name],
        "bodyHash of " & name & " depends on the checkout path: " &
        hashesShortA[name] & " vs " & hashesLongA[name]

    # 2. RESOLVABILITY: `tests/a/t.nim` and `tests/b/t.nim` hold byte-identical
    #    source and are each compiled as their own main module, so a rendering
    #    anchored on `projectPath` calls both of them `t.nim` and they collide.
    #    Anchored on the package root they must stay distinguishable.
    #    THIS is the assertion a stability-only test would have missed.
    doAssert hashesShortA["paths::no assertion macro"] ==
             hashesShortB["paths::no assertion macro"],
      "a body with no location literal should be identical in both " &
      "directories; if it is not, this fixture is not comparing what it thinks"
    for name in locationBearingTests:
      doAssert hashesShortA[name] != hashesShortB[name],
        "two same-named test files in different directories share a bodyHash " &
        "for " & name & " — the location literal has lost its directory, so " &
        "the hash is reproducible but no longer identifies a file"

    # 3. ...and the rendering a human sees keeps the directory too, so the
    #    failure message can still be resolved back to a file.
    let rendered = failureOutput(shortA)
    doAssert rendered.contains("tests/a/t.nim(" ) or
             rendered.contains("tests\\a\\t.nim("),
      "failure message lost the directory, leaving an unresolvable name:\n" &
      rendered
    doAssert not rendered.contains(shortRoot),
      "failure message still embeds the checkout root:\n" & rendered

    # 4. NEGATIVE CONTROL: the hashes are not all one value. Without this, the
    #    equality assertions in (1) would be satisfied by a constant.
    var distinctHashes: HashSet[string]
    for name in reproducibleTests:
      distinctHashes.incl hashesShortA[name]
    doAssert distinctHashes.len == reproducibleTests.len,
      "distinct test bodies collided: " & $distinctHashes

    # 5. NEGATIVE CONTROL: a body that explicitly asks for its absolute path is
    #    left alone, so it still differs between the two checkouts.
    doAssert hashesShortA[absolutePathTest] != hashesLongA[absolutePathTest],
      "currentSourcePath() no longer yields a checkout-dependent bodyHash — " &
      "either the fix over-reached, or this test has stopped measuring " &
      "anything because the two fixtures share a path"

    # 6. NEGATIVE CONTROL: the hash still discriminates a real change.
    let mutatedRoot = sandbox / "mutated"
    writePackage(mutatedRoot, changedSource)
    let hashesMutated = bodyHashes(buildTest(nim, libDir, mutatedRoot, "a"))
    doAssert hashesMutated[mutatedTest] != hashesShortA[mutatedTest],
      "changing the checked expression did not change the bodyHash"
  finally:
    removeDir(sandbox)

main()
