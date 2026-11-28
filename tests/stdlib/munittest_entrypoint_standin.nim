## A stand-in for the two names of nim-entrypoints that `std/unittest` looks
## for, used by `munittest_entrypoint_linked_fixture`.
##
## Why a stand-in rather than nim-entrypoints itself: the standard library's
## test suite cannot depend on a package outside this repository. What is
## under test here is not nim-entrypoints' behaviour but `std/unittest`'s
## decision, made where `suite` and `test` expand, that another component owns
## the selector; that decision reads only whether these two names are visible
## in the module that wrote the tests. The stand-in therefore declares exactly
## those names, with nim-entrypoints' signatures, and nothing else. The real
## package is exercised against this module outside testament.

proc entryArgs*(): seq[string] =
  ## nim-entrypoints' signature; never called by `std/unittest`.
  @[]

proc parseSelector*(argv: openArray[string]): tuple[name: string, taken: int] =
  ## nim-entrypoints' signature; never called by `std/unittest`.
  ("", 0)
