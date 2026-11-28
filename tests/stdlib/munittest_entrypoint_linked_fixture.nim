## Fixture for `tunittest_entrypoint`: a test program whose tests entry
## belongs to nim-entrypoints, represented by `munittest_entrypoint_standin`
## (see there for why a stand-in). `std/unittest` must then answer nothing
## itself, leave standard output alone, and still run only the named tests
## under `--run-exact`.
##
## The stand-in is imported from a separate module on purpose: that is the
## shape of a real program, and it shows that the check made where `suite` and
## `test` expand sees the importing module's imports, not `std/unittest`'s.

import munittest_entrypoint_standin
import std/unittest

suite "linked":
  echo "linked suite body"

  test "first":
    echo "marker: linked::first"
    check true

  test "second":
    echo "marker: linked::second"
    check true
