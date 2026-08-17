discard """
  targets: "c"
  joinable: false
"""

## `system.InstantiationPath` decides how `instantiationInfo` renders a
## location, and the choice is load-bearing precisely because the rendering is
## folded into the caller's AST as a string literal, where
## `sighashes.hashBodyTree` hashes it verbatim. Every mode is therefore also a
## decision about what `macros.symBodyHash` — and so the unittest runner
## protocol's `bodyHash` — depends on.
##
## Two requirements apply at once, and this file exists because each of the
## three modes fails exactly one of them, so a test that checked only one
## requirement would accept the wrong mode:
##
## | mode          | same source, two checkouts | two same-named files, one checkout |
## |---------------+----------------------------+------------------------------------|
## | `ipAbsolute`  | different  (NOT reproducible) | different                       |
## | `ipBasename`  | same                       | same  (NOT resolvable)             |
## | `ipCanonical` | same                       | different                          |
##
## The top row is what a body hash did before the location rendering was made
## a choice: it tracked the checkout, which is the cross-host catalog-diffing
## blocker. The middle row is the obvious repair, and it is the trap — it is
## perfectly reproducible, so it passes any stability-only test, while making
## two same-named test files in different directories indistinguishable. This
## is the same ambiguity that got project-relative paths removed from
## `macros.lineInfoObj` in nim-lang/Nim#7429.
##
## Running the whole table, rather than asserting only the mode that is used,
## is what makes this a mutation test rather than a snapshot: it fails if the
## modes are ever collapsed into each other, and it states in the file what
## each mode costs.
##
## No mocks: three real compilations of the same source at three real paths,
## and the rendering is read back out of the built binary rather than
## predicted.

import std/[assertions, os, osproc, strutils, syncio, tables, tempfiles]

const
  fixtureSource = """
import std/macros

# Templates, because `instantiationInfo(-1, ...)` names the instantiation site
# of the enclosing template — which is how `assertions.assert` and
# `unittest.check` reach it, and therefore the shape whose behaviour matters.
template plantAbsolute(): string = instantiationInfo(-1, ipAbsolute).filename
template plantBasename(): string = instantiationInfo(-1, ipBasename).filename
template plantCanonical(): string = instantiationInfo(-1, ipCanonical).filename

# The legacy two-state overload, whose ordinals `InstantiationPath` was chosen
# to agree with. `false` must still mean `ipBasename` and `true` `ipAbsolute`.
template plantLegacyFalse(): string = instantiationInfo(-1, false).filename
template plantLegacyTrue(): string = instantiationInfo(-1, true).filename

proc withAbsolute(): string = plantAbsolute()
proc withBasename(): string = plantBasename()
proc withCanonical(): string = plantCanonical()
proc withLegacyFalse(): string = plantLegacyFalse()
proc withLegacyTrue(): string = plantLegacyTrue()

macro hashOf(s: typed): string = newStrLitNode(symBodyHash(s))

echo "hash.absolute=", hashOf(withAbsolute)
echo "hash.basename=", hashOf(withBasename)
echo "hash.canonical=", hashOf(withCanonical)
echo "rendered.absolute=", withAbsolute()
echo "rendered.basename=", withBasename()
echo "rendered.canonical=", withCanonical()
echo "rendered.legacyFalse=", withLegacyFalse()
echo "rendered.legacyTrue=", withLegacyTrue()
"""
  nimbleSource = """
version = "0.1.0"
author = "nim"
description = "instantiation path fixture"
license = "MIT"
"""

proc writePackage(root: string) =
  ## Two files with the SAME basename in sibling directories, and a `.nimble`
  ## at the root. The `.nimble` is what `canonicalImportAux` anchors on: it
  ## marks the package root, which is the whole point, because `conf.projectPath`
  ## is the main module's own directory and each of these is compiled as its
  ## own main module.
  createDir(root)
  writeFile(root / "mypkg.nimble", nimbleSource)
  for leaf in ["a", "b"]:
    createDir(root / "tests" / leaf)
    writeFile(root / "tests" / leaf / "p.nim", fixtureSource)

proc readValues(nim, libDir, root, leaf: string): Table[string, string] =
  let dir = root / "tests" / leaf
  let exe = dir / addFileExt("p", ExeExt)
  let command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(root / ("nimcache_" & leaf)) &
    " -o:" & quoteShell(exe) & " " & quoteShell(dir / "p.nim")
  let compiled = execCmdEx(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  let run = execCmdEx(quoteShell(exe))
  doAssert run.exitCode == 0, run.output
  for line in run.output.splitLines:
    let parts = line.split('=', maxsplit = 1)
    if parts.len == 2:
      result[parts[0]] = parts[1]
  doAssert result.len == 8, "fixture printed " & $result.len &
    " values, expected 8:\n" & run.output

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  let libDir = currentSourcePath().parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir

  let sandbox = createTempDir("tbody_hash_instantiation_path_", "")
  try:
    # Two checkouts of one package, with root names that differ in length as
    # well as content so that no equality below can hold by coincidence.
    let shortRoot = sandbox / "co"
    let longRoot = sandbox / "a-considerably-longer-worktree-name"
    doAssert shortRoot.len != longRoot.len
    writePackage(shortRoot)
    writePackage(longRoot)

    let shortA = readValues(nim, libDir, shortRoot, "a")
    let shortB = readValues(nim, libDir, shortRoot, "b")
    let longA = readValues(nim, libDir, longRoot, "a")

    # -- What each mode renders. ---------------------------------------------
    doAssert shortA["rendered.basename"] == "p.nim",
      "ipBasename no longer renders a bare file name: " &
      shortA["rendered.basename"]
    doAssert shortA["rendered.absolute"] == shortRoot / "tests" / "a" / "p.nim",
      "ipAbsolute no longer renders the full path: " &
      shortA["rendered.absolute"]
    doAssert shortA["rendered.canonical"] in
             ["tests/a/p.nim", "tests\\a\\p.nim"],
      "ipCanonical no longer renders the package-anchored path; it rendered " &
      shortA["rendered.canonical"] & ", so either the `.nimble` anchor stopped " &
      "being found or the rendering fell back to `projectPath`"

    # -- The legacy `fullPaths: bool` overload still means what it meant. -----
    #    `InstantiationPath`'s ordinals were chosen for this; a reordering of
    #    the enum would silently change the meaning of every existing call
    #    site, including `unittest`'s own `instantiationInfo(-1, true)`.
    doAssert shortA["rendered.legacyFalse"] == shortA["rendered.basename"],
      "instantiationInfo(-1, false) no longer agrees with ipBasename"
    doAssert shortA["rendered.legacyTrue"] == shortA["rendered.absolute"],
      "instantiationInfo(-1, true) no longer agrees with ipAbsolute"

    # -- Requirement 1: reproducible across checkouts. -----------------------
    doAssert shortA["hash.canonical"] == longA["hash.canonical"],
      "ipCanonical's body hash depends on the checkout path: " &
      shortA["hash.canonical"] & " vs " & longA["hash.canonical"]
    doAssert shortA["hash.basename"] == longA["hash.basename"],
      "ipBasename's body hash depends on the checkout path, which it cannot " &
      "— this fixture is not comparing what it thinks it is"

    # MUTATION ARM: this is the pre-fix behaviour, kept as an assertion rather
    # than as prose. It must keep failing requirement 1, otherwise the two
    # equalities above are being produced by something other than the choice
    # of rendering.
    doAssert shortA["hash.absolute"] != longA["hash.absolute"],
      "ipAbsolute's body hash no longer tracks the checkout path; either the " &
      "mode has stopped meaning what it says, or the two fixtures share a " &
      "path and every result in this file is vacuous"

    # -- Requirement 2: two same-named files stay distinguishable. -----------
    doAssert shortA["hash.canonical"] != shortB["hash.canonical"],
      "ipCanonical gives two same-named files in sibling directories the " &
      "same body hash; the rendering has lost its directory and the hash no " &
      "longer identifies a file"
    doAssert shortA["hash.absolute"] != shortB["hash.absolute"],
      "ipAbsolute stopped distinguishing two directories"

    # MUTATION ARM: the "obvious repair". `ipBasename` is reproducible — it
    # passed requirement 1 above — and is still wrong, for this reason. A
    # future change that made the canonical rendering degrade to a basename
    # would pass every reproducibility assertion in this repository except the
    # one above and its twin in `tunittest_body_hash_paths.nim`.
    doAssert shortA["hash.basename"] == shortB["hash.basename"],
      "ipBasename no longer collides for two same-named files; it may have " &
      "started carrying a directory, in which case this file's account of " &
      "why ipCanonical is needed is out of date"

    # -- The three modes are three different things. -------------------------
    doAssert shortA["hash.absolute"] != shortA["hash.basename"]
    doAssert shortA["hash.absolute"] != shortA["hash.canonical"]
    doAssert shortA["hash.basename"] != shortA["hash.canonical"],
      "ipBasename and ipCanonical produced the same body hash for a file in " &
      "a subdirectory, so the canonical rendering has collapsed to a basename"
  finally:
    removeDir(sandbox)

main()
