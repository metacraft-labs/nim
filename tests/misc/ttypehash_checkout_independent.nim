discard """
  targets: "c"
  joinable: false
"""

## A type's hash must not depend on where the project is checked out.
##
## `sighashes.hashTypeSym` feeds every RTTI hash: the `display` tables of
## `TNimTypeV2` and the token each `of` check compares against. It used to
## hash the defining file's absolute path (`customPath` only abbreviates the
## home directory), so the same commit built in two checkouts produced two
## different binaries -- measured on a 4.5 MB static program: ~500 bytes of
## `.text` operands and `.rodata` tables differed, nothing else. It now hashes
## the canonical module path (`--filenames:canonical`).
##
## Part 1 compiles one fixture package at two paths of different depth and
## requires the generated display tables to be identical. The compiler built
## before the change fails it (the display constants differ beyond the root
## entry). Part 2 is the guard against a hash that stopped distinguishing
## anything: two types of the same name in two same-named modules of one
## project must still be told apart by `of` at run time.
##
## No mocks: real compiler invocations on real files.

import std/[assertions, os, osproc, strutils, tempfiles]

const
  nimble = "version = \"0.1.0\"\nauthor = \"nim\"\ndescription = \"fixture\"\nlicense = \"MIT\"\n"
  main = """
type
  Base* = ref object of RootObj
  Derived* = ref object of Base
proc isDerived*(x: Base): bool = x of Derived
let b: Base = Derived()
echo isDerived(b)
"""

proc displayTables(dir: string): seq[string] =
  ## Every `NU32 ...[n] = {...}` initializer of the main module's C file,
  ## with the C identifier dropped (it is a per-module counter).
  let (output, code) = execCmdEx(quoteShell(getCurrentCompilerExe()) &
    " c --hints:off --compileOnly --nimcache:" & quoteShell(dir / "nc") & " " &
    quoteShell(dir / "main.nim"))
  doAssert code == 0, output
  let c = readFile(dir / "nc" / "@mmain.nim.c")
  for line in c.splitLines():
    let i = line.find("NU32 TM__")
    let j = line.find("] = {")
    if i >= 0 and j > i:
      result.add(line[j .. ^1])
  doAssert result.len > 0, "no display table in the generated C"

block checkoutPathIndependence:
  let root = createTempDir("ttypehash_", "")
  let a = root / "one" / "fixturepkg"
  let b = root / "two" / "deeper" / "still" / "fixturepkg"
  for d in [a, b]:
    createDir(d)
    writeFile(d / "fixturepkg.nimble", nimble)
    writeFile(d / "main.nim", main)
  let ta = displayTables(a)
  let tb = displayTables(b)
  doAssert ta == tb, "type hashes depend on the checkout path:\n" &
    ta.join("\n") & "\n--- vs ---\n" & tb.join("\n")
  removeDir(root)

block sameNamedTypesStayDistinct:
  let root = createTempDir("ttypehash_names_", "")
  createDir(root / "a")
  createDir(root / "b")
  writeFile(root / "fixturepkg.nimble", nimble)
  writeFile(root / "a" / "m.nim", "type T* = ref object of RootObj\n")
  writeFile(root / "b" / "m.nim", "type T* = ref object of RootObj\n")
  writeFile(root / "main.nim", "import a/m as ma\nimport b/m as mb\n" &
    "let x: RootRef = ma.T()\necho x of mb.T, \" \", x of ma.T\n")
  let (output, code) = execCmdEx(quoteShell(getCurrentCompilerExe()) &
    " r --hints:off --nimcache:" & quoteShell(root / "nc") & " " &
    quoteShell(root / "main.nim"))
  doAssert code == 0, output
  doAssert output.strip().endsWith("false true"), output
  removeDir(root)
