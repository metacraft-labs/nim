discard """
  joinable: false
"""

# `koch runCI` boots the compiler with `-d:nimStrictMode` ("Boot Nim ORC",
# and "Testing booting in refc" with `--mm:refc`). Under that define
# `config/config.nims` turns the `ConvFromXtoItselfNotNeeded` hint into an
# error, so a single redundant conversion anywhere in the compiler sources,
# such as `name.string` on a value that already is a `string`, fails the
# boot before any test runs.
#
# Nothing else in the regular test run compiles the compiler in strict mode,
# and `Packages CI`, which runs `koch runCI`, is never triggered by a push to
# the fork's branch, so such a conversion can sit unnoticed for years (two of
# them did, both in the macro-sourcemap code). This test closes that gap
# cheaply: it semantically checks `compiler/nim.nim` the way the boot
# compiles it, for each memory manager the boot uses and for each OS the CI
# matrix boots on, since `when defined(...)` branches hide code from a check
# made for another target. No mocks: it runs the compiler under test on the
# real compiler sources.
#
# The strict-mode hint-as-error is also passed explicitly, so the test keeps
# its meaning when the compiler under test was built elsewhere and reads a
# global config that lacks the `nimStrictMode` block.

import std/[os, osproc, strutils]

when defined(nimPreviewSlimSystem):
  import std/assertions

const repoRoot = currentSourcePath().parentDir.parentDir.parentDir

let nim = getCurrentCompilerExe()
let compilerMain = repoRoot / "compiler" / "nim.nim"
doAssert fileExists(compilerMain), compilerMain

var failures: seq[string]
for os in ["linux", "macosx", "windows"]:
  for mm in ["orc", "refc"]:
    # The same switches `koch boot` passes to the compile of `compiler/nim.nim`
    # (`--skipUserCfg --skipParentCfg -d:nimKochBootstrap ... -d:release
    # -d:nimStrictMode --lib:lib --noNimblePath`), with `check` in place of
    # `c --compileOnly` and the target selected by `--os` / `--mm`.
    let args = @["check", "--skipUserCfg", "--skipParentCfg",
                 "-d:nimKochBootstrap", "-d:release", "-d:nimStrictMode",
                 "--hintAsError:ConvFromXtoItselfNotNeeded",
                 "--os:" & os, "--mm:" & mm,
                 "--lib:" & (repoRoot / "lib"), "--noNimblePath",
                 compilerMain]
    let (output, code) = execCmdEx(quoteShellCommand(nim & args),
                                   workingDir = repoRoot)
    # Report every hint-turned-error, not only the first one: `check` keeps
    # going after an error, while the boot stops at the first.
    var errors: seq[string]
    for line in output.splitLines:
      if "Error:" in line: errors.add line
    if code != 0 or errors.len > 0:
      failures.add "--os:" & os & " --mm:" & mm & " (exit " & $code & ")\n  " &
        (if errors.len > 0: errors.join("\n  ") else: output)

doAssert failures.len == 0,
  "compiler/nim.nim does not compile under -d:nimStrictMode:\n" &
    failures.join("\n")
