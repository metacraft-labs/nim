## Fixture for `tunittest_entrypoint`: a test program that answers the tests
## entry through `std/unittest` alone. It is compiled and driven by that test
## rather than run by testament, because it carries a failing test on purpose.
##
## Every test body prints a marker, so a run shows exactly which bodies ran.
## The suite body writes to standard output on its own account, with and
## without a trailing newline, which is the noise a listing must not contain.

import std/unittest

when defined(entrypointFixtureAbort):
  # A failing test ends the process from inside its body.
  abortOnError = true

test "outside":
  echo "marker: outside"
  check true

suite "math":
  echo "suite body noise"
  write(stdout, "partial noise -> ")

  test "add":
    echo "marker: math::add"
    check 1 + 1 == 2

  test "mul":
    echo "marker: math::mul"
    check 2 * 3 == 7

  test "skipped":
    echo "marker: math::skipped"
    skip("not here")

  test "star*":
    echo "marker: math::star*"
    check true

  test "starry":
    echo "marker: math::starry"
    check true

when defined(entrypointFixtureLineBreak):
  suite "names":
    test "line\nbreak":
      echo "marker: names::line break"
