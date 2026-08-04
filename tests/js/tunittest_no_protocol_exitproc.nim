discard """
  matrix: "-u:nodejs"
  targets: "js"
  joinable: false
"""

## Regression test: a run with NO CodeTracer protocol flag must not register an
## exit proc.
##
## The protocol emits its `--list-json` / `--catalog` payload from an
## `addExitProc` hook, so the hook has to exist in those modes. It must NOT
## exist otherwise: `std/unittest` never called `addExitProc` before, and on the
## JS backend `std/exitprocs` assigns `window.onbeforeunload` unless `-d:nodejs`
## is set. Under a plain `node` that throws `ReferenceError: window is not
## defined` at module scope — before any test runs — so an unconditional
## registration turns every browser-targeted JS test binary into an immediate
## crash when it is smoke-run under node.
##
## `-u:nodejs` in the matrix undoes testament's own `-d:nodejs` (specs.nim
## documents exactly this override), which is what selects the `window` branch
## of `std/exitprocs` while testament still executes the output with node. If
## the registration is ever made unconditional again, this test stops at the
## ReferenceError and reports a nonzero exit code.
##
## There is no output assertion on purpose: `tests/config.nims` sets
## `nimUnittestOutputLevel:PRINT_FAILURES`, so a passing run is silent, and the
## exit code is the whole signal.

import std/unittest

suite "no protocol flags":
  test "the binary reaches its tests at all":
    check 1 + 1 == 2

test "and suite-less tests too":
  check true
