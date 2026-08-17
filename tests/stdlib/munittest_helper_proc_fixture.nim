## Assertion helpers for `tunittest_failure_in_helper_proc`, deliberately kept
## in a SEPARATE module.
##
## A helper that shares assertions between test cases is normally written once
## and imported, so the module boundary is the realistic shape — and it is the
## harder one: `fail` has to reach the running test through a symbol bound in
## `unittest`'s own scope, not through anything the calling module supplies.

import std/unittest

proc expectEqualAcrossModules*(a, b: int) =
  check a == b
