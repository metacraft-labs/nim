discard """
  action: "compile"
"""

## The distribution's global `config/nim.cfg` must not put the libraries
## vendored under `$nim/dist/` for the compiler's own build on the search path
## of every compile.
##
## The fork compiler imports the CodeTracer trace-format library
## (`compiler/vm_trace.nim`, `compiler/vm_value_serializer.nim`), which in turn
## needs nim-stew and nim-results, so a Nim distribution built from this tree
## ships them as `$nim/dist/{codetracer-trace-format-nim,nim-stew,nim-results}`.
## When `config/nim.cfg` listed those directories, every program compiled by
## this `nim` saw them. A project that brings its own copy of one of those
## libraries then had two copies on its path. CodeTracer is one: its
## `libs/nim-stew` and the vendored `dist/nim-stew` both define
## `stew/ptrops.offset`, faststreams loads one copy through `stew/ptrops` and
## the other through `stew/ranges/ptr_arith`, and the call becomes ambiguous
## (codetracer-pm issue
## `2026-10-22-dev-shell-nim-cannot-compile-ct-two-nim-stew-copies-make-ptrops-offset-ambiguous.md`).
##
## The fix keeps those paths in the configs of the programs that import the
## library: `compiler/nim.cfg`, `nimsuggest/nimsuggest.nim.cfg`,
## `drnim/nim.cfg`, `testament/testament.nim.cfg`, and the test directories
## whose programs import compiler modules. This directory adds none of them, so
## the search path seen here is the one an ordinary project gets.
##
## The check reads the effective search path with `std/compilesettings`
## (https://nim-lang.org/docs/compilesettings.html). It does not depend on
## `dist/` being populated: a `path=` entry is added to the search path whether
## or not the directory exists.

import std/[compilesettings, os, strutils]

const
  searchPathList = querySettingSeq(searchPaths)
  libDir = querySetting(libPath)

  # The directories the global config used to add, as path suffixes, so the
  # check holds whichever installation prefix `$nim` resolves to.
  vendoredSuffixes = [
    "dist" / "codetracer-trace-format-nim" / "src",
    "dist" / "nim-stew",
    "dist" / "nim-results",
  ]

proc isVendoredLibPath(path: string): bool =
  let normalized = path.normalizedPath
  for suffix in vendoredSuffixes:
    if normalized.endsWith(DirSep & suffix):
      return true
  false

static:
  # Positive control: the list really is the effective search path, including
  # the entries the global config contributes (`path="$lib/pure"` there).
  doAssert normalizedPath(libDir / "pure") in
      (block:
        var normalized: seq[string]
        for path in searchPathList: normalized.add path.normalizedPath
        normalized),
    "searchPaths does not contain $lib/pure; the global config was not read:\n" &
      searchPathList.join("\n")

  for path in searchPathList:
    doAssert not isVendoredLibPath(path),
      "the global config put a library vendored for the compiler's own " &
        "build on an ordinary compile's search path: " & path
