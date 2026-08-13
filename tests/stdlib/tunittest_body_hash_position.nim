discard """
  targets: "c"
  joinable: false
"""

## A body hash must identify a body, not the body's neighbours.
##
## `sighashes.hashBodyTree` hashes a non-global local by its NAME, and
## `evaltempl` renames a hygienic template local to ``<base>`gensym<N>`` where
## `N` is the enclosing module's template instantiation counter. That counter
## says how many template expansions preceded this one *in the module*, so
## before the fix this test guards, every body that reached a hygienic template
## changed its hash whenever anything above it in the file grew or shrank an
## expansion. `unittest`'s `check`/`require`/`expect` all reach one (via
## `fail`'s `for formatter in formatters`), so inserting a test near the top of
## a file moved the `bodyHash` of every test below it.
##
## The direction was fail-safe — over-invalidation, never a missed re-run — but
## it defeats the incremental test selection the hash exists to enable.
##
## Two halves, and both are load-bearing:
##
## 1. A body's hash must not move when its position in the module moves.
## 2. A body's hash must still move when the body itself changes — including
##    when only the AUTHOR'S OWN local variable names change. Only the
##    compiler-generated part of a local's identity may be normalised.
##
## No mocks: part one asks the compiler under test for real hashes at compile
## time, part two drives real compiler invocations against real files.

import std/[assertions, json, macros, os, osproc, sets, strutils, syncio,
            tables, tempfiles]

# ---------------------------------------------------------------------------
# Part 1 — compile-time, against `macros.symBodyHash` directly.
# ---------------------------------------------------------------------------

template hygienic(value: int): int =
  ## `scratch` is a hygienic local, so each expansion renames it to
  ## ``scratch`gensym<N>`` with the module-wide instantiation counter.
  let scratch = value * 2
  scratch + 1

proc early(): int = hygienic(3)

# Expansions between the two procs, so that `late` is reached with a different
# instantiation counter than `early` was. Distinct arguments so that these are
# not themselves confusable with the procs under test.
proc spacer1(): int = hygienic(11)
proc spacer2(): int = hygienic(12)
proc spacer3(): int = hygienic(13)

proc late(): int = hygienic(3)

proc earlyCaller(): int = early() + 1
proc lateCaller(): int = late() + 1

# Author-written locals. The names here are part of what the author wrote and
# must keep reaching the hash.
proc namedAlpha(): int =
  let alpha = 7
  alpha + 1

proc namedBeta(): int =
  let beta = 7
  beta + 1

proc twoLocalsUseFirst(): int =
  let alpha = 7
  let beta = 7
  alpha

proc twoLocalsUseSecond(): int =
  let alpha = 7
  let beta = 7
  beta

macro bodyHashOf(s: typed): string =
  newStrLitNode(symBodyHash(s))

macro hasHygienicLocal(s: typed): bool =
  ## True when the typed body of `s` still contains a symbol carrying the
  ## ``\`gensym`` hygiene suffix. Without this the equality assertions below
  ## could pass vacuously: if the compiler ever stopped renaming hygienic
  ## locals, there would be nothing left for the fix to normalise and the test
  ## would silently stop measuring anything.
  var found = false
  proc walk(n: NimNode) =
    if n.kind == nnkSym and "`gensym" in n.strVal:
      found = true
    for child in n:
      walk(child)
  walk(s.getImpl)
  newLit(found)

const
  earlyHash = bodyHashOf(early)
  lateHash = bodyHashOf(late)
  earlyCallerHash = bodyHashOf(earlyCaller)
  lateCallerHash = bodyHashOf(lateCaller)
  spacer1Hash = bodyHashOf(spacer1)
  namedAlphaHash = bodyHashOf(namedAlpha)
  namedBetaHash = bodyHashOf(namedBeta)
  useFirstHash = bodyHashOf(twoLocalsUseFirst)
  useSecondHash = bodyHashOf(twoLocalsUseSecond)

proc partOne() =
  # PRECONDITION: the bodies really do carry a hygiene suffix, so the equality
  # assertions below are about the fix and not about an empty set.
  doAssert hasHygienicLocal(early),
    "`early` no longer contains a gensym'ed local; this test has stopped " &
    "exercising the hygienic-template path"
  doAssert hasHygienicLocal(late),
    "`late` no longer contains a gensym'ed local; this test has stopped " &
    "exercising the hygienic-template path"
  doAssert not hasHygienicLocal(namedAlpha),
    "`namedAlpha` was expected to contain only author-written locals"

  doAssert earlyHash.len > 0

  # 1. POSITION INDEPENDENCE: byte-identical bodies, three template expansions
  #    apart in the same module. This also pins the ordinals down as body-local
  #    rather than run-global: a counter shared across the whole compilation
  #    would hand `late` different numbers than `early`.
  doAssert earlyHash == lateHash,
    "two identical bodies hash differently depending on how many template " &
    "expansions precede them in the module: " & earlyHash & " vs " & lateHash

  # 2. ...and the same holds transitively, through a caller that only reaches
  #    the hygienic template via `symBodyDigest`'s recursion into callees.
  doAssert earlyCallerHash == lateCallerHash,
    "position dependence survives one level of call recursion: " &
    earlyCallerHash & " vs " & lateCallerHash

  # 3. NEGATIVE CONTROL: the hash is not a constant.
  doAssert earlyHash != spacer1Hash,
    "bodies with different arguments collided; the hash has stopped " &
    "discriminating"

  # 4. NEGATIVE CONTROL, and the one that constrains the fix most: renaming an
  #    author's own local must still move the hash. A fix that normalised every
  #    local's name — rather than only the compiler-generated suffix — would
  #    pass every assertion above and fail here.
  doAssert namedAlphaHash != namedBetaHash,
    "renaming an author-written local no longer changes the bodyHash; the " &
    "normalisation has reached past the compiler-generated part of the name"

  # 5. NEGATIVE CONTROL: which of two identically-initialised author locals is
  #    referenced must still be visible, so the names are load-bearing and not
  #    merely present.
  doAssert useFirstHash != useSecondHash,
    "referring to a different local of the same type and value no longer " &
    "changes the bodyHash"

# ---------------------------------------------------------------------------
# Part 2 — end to end, through `unittest`'s runner-protocol `bodyHash`.
# ---------------------------------------------------------------------------

const
  prelude = """
import std/unittest

suite "hyg":
"""
  ## Three lines each, so `test "target"` keeps the same line AND column in
  ## every variant. That matters: `check` plants its own location in the body
  ## as a string literal, so a target that moved would legitimately rehash and
  ## the comparison would prove nothing.
  spacerBlock = "\n\n\n"
  oneAboveBlock = """  test "earlier":
    check 1 == 1

"""
  twoAboveBlock = """  test "earlier":
    check 1 == 1
    check 2 == 2
"""
  targetBlock = """  test "target":
    var probe = 1
    check probe == 1
"""
  renamedTargetBlock = """  test "target":
    var reading = 1
    check reading == 1
"""
  changedTargetBlock = """  test "target":
    var probe = 1
    check probe == 2
"""
  nimbleSource = """
version = "0.1.0"
author = "nim"
description = "body hash position fixture"
license = "MIT"
"""

proc variantSource(above, target: string): string =
  result = prelude & above & target

proc lineOfTarget(source: string): int =
  result = 0
  var i = 0
  for line in source.splitLines:
    inc i
    if line.contains("\"target\""):
      return i

proc buildVariant(nim, libDir, root, name, source: string): string =
  ## Compiles the variant AT A FIXED PATH inside `root`. The path is fixed on
  ## purpose: `check`'s location literal is part of the body, so a fixture that
  ## gave each variant its own filename would measure the filename instead.
  let dir = root / "tests"
  createDir(dir)
  let src = dir / "t.nim"
  writeFile(src, source)
  result = root / addFileExt(name, ExeExt)
  let command = quoteShell(nim) & " c --hints:off --verbosity:0" &
    " --lib:" & quoteShell(libDir) &
    " --nimcache:" & quoteShell(root / ("nimcache_" & name)) &
    " -o:" & quoteShell(result) & " " & quoteShell(src)
  let compiled = execCmdEx(command)
  doAssert compiled.exitCode == 0, command & "\n" & compiled.output
  doAssert fileExists(result), "compiler did not produce " & result

proc bodyHashes(binary: string): Table[string, string] =
  let listed = execCmdEx(quoteShell(binary) & " --list-json")
  doAssert listed.exitCode == 0, listed.output
  for item in parseJson(listed.output)["tests"]:
    result[item["name"].getStr] = item["bodyHash"].getStr

proc partTwo() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim
  let libDir = currentSourcePath().parentDir.parentDir.parentDir / "lib"
  doAssert dirExists(libDir), "Nim library directory not found at: " & libDir

  let sandbox = createTempDir("tunittest_body_hash_position_", "")
  try:
    let root = sandbox / "pkg"
    createDir(root)
    writeFile(root / "mypkg.nimble", nimbleSource)

    let variants = {
      "alone": variantSource(spacerBlock, targetBlock),
      "oneAbove": variantSource(oneAboveBlock, targetBlock),
      "twoAbove": variantSource(twoAboveBlock, targetBlock),
      "renamed": variantSource(spacerBlock, renamedTargetBlock),
      "changed": variantSource(spacerBlock, changedTargetBlock)
    }.toTable

    # PRECONDITION: the target sits at the same line in every variant, so a
    # differing hash cannot be blamed on the location literal.
    let targetLine = lineOfTarget(variants["alone"])
    doAssert targetLine > 0
    for name, source in variants:
      doAssert lineOfTarget(source) == targetLine,
        "variant " & name & " moved the target test to line " &
        $lineOfTarget(source) & " instead of " & $targetLine &
        "; the fixture would then be measuring the location literal"

    var hashes: Table[string, Table[string, string]]
    for name, source in variants:
      hashes[name] = bodyHashes(buildVariant(nim, libDir, root, name, source))

    for name in variants.keys:
      doAssert hashes[name].hasKey("hyg::target"),
        "variant " & name & " did not register the target test"

    # 1. POSITION INDEPENDENCE: the number of tests — and therefore of template
    #    expansions — above the target does not reach the target's hash.
    doAssert hashes["alone"]["hyg::target"] == hashes["oneAbove"]["hyg::target"],
      "inserting a test above the target changed its bodyHash: " &
      hashes["alone"]["hyg::target"] & " vs " &
      hashes["oneAbove"]["hyg::target"]
    doAssert hashes["alone"]["hyg::target"] == hashes["twoAbove"]["hyg::target"],
      "adding a check above the target changed its bodyHash: " &
      hashes["alone"]["hyg::target"] & " vs " &
      hashes["twoAbove"]["hyg::target"]

    # 2. NEGATIVE CONTROL: renaming the author's local still rehashes.
    doAssert hashes["alone"]["hyg::target"] != hashes["renamed"]["hyg::target"],
      "renaming the test's own local variable no longer changes its bodyHash"

    # 3. NEGATIVE CONTROL: changing the checked expression still rehashes.
    doAssert hashes["alone"]["hyg::target"] != hashes["changed"]["hyg::target"],
      "changing the checked expression no longer changes the bodyHash"

    # 4. NEGATIVE CONTROL: the hashes in a single variant are not all one
    #    value, so the equalities above cannot be satisfied by a constant.
    var distinctHashes: HashSet[string]
    for name, hash in hashes["twoAbove"]:
      distinctHashes.incl hash
    doAssert distinctHashes.len == hashes["twoAbove"].len,
      "distinct test bodies collided: " & $hashes["twoAbove"]
  finally:
    removeDir(sandbox)

partOne()
partTwo()
