discard """
  targets: "c"
  joinable: false
"""

## What a type's hash may and may not depend on.
##
## `sighashes.hashTypeSym` feeds every RTTI hash: the `display` tables of
## `TNimTypeV2` and the token each `of` check compares against. It hashes the
## absolute path of the type's defining file, as upstream Nim does, so two
## types that differ only by the file defining them never share a hash. That
## makes the hashes depend on where a project is checked out; a build that
## must not (a reproducible release artefact) passes
## `--typeHashPathMap:OLD=NEW`, which rewrites a leading OLD the way a C
## compiler's `-ffile-prefix-map` does.
##
## 1. Two copies of one package -- same nimble name, same in-package path,
##    same module and type name, in different directories -- define two
##    distinct types, by default and under a map of their common parent.
##    (A rendering by canonical module path once gave them one hash: `of`
##    answered `true` for the wrong type, and with different fields the
##    two types became one C struct and the C compile failed.)
## 2. With different fields they compile, and run, as two types.
## 3. One fixture at two paths gives identical display tables under the
##    map of each path to one name, and different ones without it -- the
##    latter shows the check looks at what the map changes.
##
## No mocks: real compiler invocations on real files.

import std/[assertions, os, osproc, strutils, tempfiles]

const
  dupNimble = "version = \"0.1.0\"\nauthor = \"nim\"\ndescription = \"dup\"\nlicense = \"MIT\"\n"
  main = """
type
  Base* = ref object of RootObj
  Derived* = ref object of Base
proc isDerived*(x: Base): bool = x of Derived
let b: Base = Derived()
echo isDerived(b)
"""

proc nimc(args: string): tuple[output: string; exitCode: int] =
  execCmdEx(quoteShell(getCurrentCompilerExe()) & " --hints:off " & args)

proc twoCopies(root, fieldA, fieldB: string) =
  for (copy, field) in [("a", fieldA), ("b", fieldB)]:
    createDir(root / "vendor" / copy / "src")
    writeFile(root / "vendor" / copy / "dup.nimble", dupNimble)
    writeFile(root / "vendor" / copy / "src" / "m.nim",
              "type T* = ref object of RootObj\n  " & field & "\n")

proc runMain(root, mainText, extra: string): string =
  writeFile(root / "main.nim", mainText)
  let (output, code) = nimc("r " & extra & " --nimcache:" &
    quoteShell(root / "nc" & $extra.len) & " " & quoteShell(root / "main.nim"))
  doAssert code == 0, output
  output.strip()

block twoCopiesOfOnePackageStayDistinct:
  let root = createTempDir("ttypehash_dup_", "")
  twoCopies(root, "x*: int", "x*: int")
  let m = "import vendor/a/src/m as ma\nimport vendor/b/src/m as mb\n" &
    "let x: RootRef = ma.T(x: 42)\necho x of mb.T, \" \", x of ma.T\n"
  doAssert runMain(root, m, "").endsWith("false true")
  doAssert runMain(root, m, "--typeHashPathMap:" & root & "=/fixture")
    .endsWith("false true")
  removeDir(root)

block twoCopiesWithDifferentFieldsCompile:
  let root = createTempDir("ttypehash_dupfields_", "")
  twoCopies(root, "x*: int", "y*: string")
  let m = "import vendor/a/src/m as ma\nimport vendor/b/src/m as mb\n" &
    "let x: RootRef = ma.T(x: 42)\nlet y: RootRef = mb.T(y: \"s\")\n" &
    "echo x of mb.T, \" \", y of ma.T, \" \", ma.T(x).x, \" \", mb.T(y).y\n"
  doAssert runMain(root, m, "").endsWith("false false 42 s")
  removeDir(root)

proc displayTables(dir, extra: string): seq[string] =
  ## Every `NU32 ...[n] = {...}` initializer of the main module's C file,
  ## the C identifier dropped (it is a per-module counter).
  removeDir(dir / "nc")
  let (output, code) = nimc("c --compileOnly " & extra & " --nimcache:" &
    quoteShell(dir / "nc") & " " & quoteShell(dir / "main.nim"))
  doAssert code == 0, output
  for line in readFile(dir / "nc" / "@mmain.nim.c").splitLines():
    let i = line.find("NU32 TM__")
    let j = line.find("] = {")
    if i >= 0 and j > i:
      result.add(line[j .. ^1])
  doAssert result.len > 0, "no display table in the generated C"

block checkoutPathIndependenceUnderTheMap:
  let root = createTempDir("ttypehash_", "")
  let a = root / "one" / "fixturepkg"
  let b = root / "two" / "deeper" / "still" / "fixturepkg"
  for d in [a, b]:
    createDir(d)
    writeFile(d / "fixturepkg.nimble", dupNimble)
    writeFile(d / "main.nim", main)
  doAssert displayTables(a, "--typeHashPathMap:" & a & "=/fixture") ==
           displayTables(b, "--typeHashPathMap:" & b & "=/fixture")
  doAssert displayTables(a, "") != displayTables(b, ""),
    "without the map the hashes must still follow the path"
  removeDir(root)
