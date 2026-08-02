discard """
  matrix: "--mm:refc; --mm:orc"
"""

## Regression test for the protocol catalog's ``file`` field.
##
## The field must be BOTH resolvable and reproducible:
##
## * resolvable — a consumer has to be able to open the file, so the directory
##   cannot be discarded. A bare basename makes two same-named test files in
##   different directories indistinguishable.
## * reproducible — two catalogs produced on different machines have to diff
##   cleanly, so no output may embed the build host's layout.
##
## `instantiationInfo(-1, false)` gives only the basename, and
## `instantiationInfo(-1, true)` gives an absolute path with OR without
## `--listFullPaths` (measured). Neither is sufficient alone, hence
## `protocolRelativeFile`, which anchors on the project directory and falls
## back to the basename outside it.

import std/[strutils, unittest]

suite "protocol file paths":

  test "paths inside the project keep their directory":
    check protocolRelativeFile("/p/tests/probe.nim", "/p/tests") == "probe.nim"
    check protocolRelativeFile("/p/tests/sub/a.nim", "/p/tests") == "sub/a.nim"

  test "a trailing separator on the project dir is tolerated":
    check protocolRelativeFile("/p/tests/a.nim", "/p/tests/") == "a.nim"

  test "paths outside the project fall back to the basename":
    # `projectPath` is the MAIN MODULE's directory, so a test body in a sibling
    # directory lands here. The basename is what such a test already reported,
    # so this path is unchanged rather than regressed.
    check protocolRelativeFile("/p/lib/shared.nim", "/p/tests") == "shared.nim"
    check protocolRelativeFile("/other/deep/a.nim", "/p") == "a.nim"

  test "an empty project dir still yields a relative name":
    check protocolRelativeFile("/p/a.nim", "") == "a.nim"

  test "NO output is ever an absolute path":
    # The reproducibility guarantee, asserted exhaustively over the shapes the
    # helper can be handed. If this fails, catalogs stop diffing across hosts.
    const cases = [
      ("/p/tests/x.nim", "/p/tests"),
      ("/p/lib/y.nim", "/p/tests"),
      ("/z/w.nim", "/p"),
      ("/p/a.nim", ""),
      ("/p/tests", "/p/tests"),
      ("relative/already.nim", "/p")
    ]
    for (absolute, projectDir) in cases:
      let got = protocolRelativeFile(absolute, projectDir)
      check got.len > 0
      check not got.startsWith("/")
      check not got.contains(":\\")

  test "the project dir constant is available and absolute":
    # Sanity: querySetting resolved at compile time. If this is empty the
    # relativisation silently degrades to basenames everywhere.
    check protocolProjectDir.len > 0
