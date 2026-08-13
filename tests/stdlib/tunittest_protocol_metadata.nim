discard """
  targets: "c"
  joinable: false
"""

## Regression test for the per-test metadata carried by the `--list-json`
## catalog.
##
## Five of the fields the catalog advertises — `group`, `threadsRequired`,
## `xfail`, `tags` and `deterministic` — used to be emitted as fixed literals:
## `"@global"`, `1`, `null`, `[]`, `true`. Nothing a test could say changed any
## of them, so a consumer could carry all five, assert that it had carried
## them, and be asserting on nothing at all.
##
## The property this file pins is therefore not "the fields are present" —
## that was already true and was worthless — but "the fields VARY, and each
## value is the one its test declared". Both halves are needed: variation
## alone would be satisfied by noise, and per-test agreement alone would be
## satisfied by a producer that emits the default for every test that declares
## nothing and has no tests that declare anything.
##
## `kind` is deliberately held to the opposite standard and asserted CONSTANT.
## `unittest` registers in-process bodies and has no other kind of test to
## register — no external command, no file-driven case — so `"in-process"` is
## the complete truth about this producer rather than a placeholder standing
## in for a value it declines to compute. That assertion is the tripwire: a
## change that gives this module a second kind of test has to come here.

import std/[assertions, json, os, osproc, syncio, unittest]

proc runSelf(args: varargs[string]): tuple[output: string, exitCode: int] =
  var command = quoteShell(getAppFilename())
  for arg in args:
    command.add " "
    command.add quoteShell(arg)
  execCmdEx(command)

proc rowFor(rows: seq[JsonNode]; name: string): JsonNode =
  result = nil
  for row in rows:
    if row["name"].getStr == name:
      return row
  doAssert false, "not in the catalog: " & name

proc distinctValues(rows: seq[JsonNode]; field: string): seq[string] =
  ## The rendered JSON of `field` over the whole catalog, deduplicated. Text
  ## rather than typed values so one helper covers a string, an int, a bool,
  ## an array and a null.
  result = @[]
  for row in rows:
    let rendered = $row[field]
    if rendered notin result:
      result.add rendered

if commandLineParams().len == 0:
  let listed = runSelf("--list-json")
  doAssert listed.exitCode == 0, listed.output
  let rows = parseJson(listed.output)["tests"].getElems()

  block declaring_nothing:
    let row = rowFor(rows, "::declares nothing")
    doAssert row["group"].getStr == "@global", $row
    doAssert row["threadsRequired"].getInt == 1, $row
    doAssert row["xfail"].kind == JNull, $row
    doAssert row["tags"].getElems().len == 0, $row
    doAssert row["deterministic"].getBool, $row

  block declaring_each_field:
    doAssert rowFor(rows, "::expected to fail")["xfail"].getStr ==
      "known overflow on 32-bit"
    doAssert rowFor(rows, "::tagged")["tags"] == %*["slow", "network"]
    doAssert rowFor(rows, "::weighted")["threadsRequired"].getInt == 4
    doAssert not rowFor(rows, "::reads the clock")["deterministic"].getBool
    doAssert rowFor(rows, "::grouped by option")["group"].getStr == "db-access"

  block an_empty_xfail_reason_is_no_reason:
    # `xfail = when defined(windows): "..." else: ""` is the documented way to
    # mark a test expected to fail on one platform. On every other platform it
    # has to be indistinguishable from a test that never mentioned `xfail`.
    doAssert rowFor(rows, "::conditionally expected to fail")["xfail"].kind ==
      JNull

  block group_membership:
    doAssert rowFor(rows, "::grouped by block")["group"].getStr == "fs-access"
    # A per-test `group` outranks the enclosing `testGroup`.
    doAssert rowFor(rows, "::block group overridden")["group"].getStr == "net"
    # And the group does not leak past the block that declared it.
    doAssert rowFor(rows, "::after the block")["group"].getStr == "@global"

  block everything_at_once:
    let row = rowFor(rows, "combined::all five")
    doAssert row["group"].getStr == "integration", $row
    doAssert row["threadsRequired"].getInt == 2, $row
    doAssert row["xfail"].getStr == "not implemented yet", $row
    doAssert row["tags"] == %*["slow"], $row
    doAssert not row["deterministic"].getBool, $row

  block the_declared_fields_actually_vary:
    # The assertion the whole file exists for. If any of these five collapses
    # back to a constant, a downstream "we preserve every metadata field"
    # check goes green while testing nothing.
    for field in ["group", "threadsRequired", "xfail", "tags", "deterministic"]:
      let seen = distinctValues(rows, field)
      doAssert seen.len >= 2, field & " never varies: " & $seen

  block kind_is_constant_on_purpose:
    doAssert distinctValues(rows, "kind") == @["\"in-process\""]

  block the_macro_rejects_what_it_cannot_carry:
    # Written as templates because `compiles` takes an expression, and a
    # `test` call with a block body is not one. Each is asserted to be
    # rejected AND a well-formed neighbour is asserted to be accepted, so a
    # macro that rejected everything would not pass this block.
    template accepted = test("x", tags = ["a"], (discard))
    template unknownOption = test("x", bogus = 1, (discard))
    template positionalOption = test("x", "slow", (discard))
    template repeatedOption = test("x", tags = ["a"], tags = ["b"], (discard))
    # `eqIdent` selects the option style-insensitively, so the duplicate check
    # has to be style-insensitive too or the second spelling silently wins.
    template restyledOption = test("x", xfail = "a", xFail = "b", (discard))
    template noBody = test("x")
    doAssert compiles(accepted())
    doAssert not compiles(unknownOption())
    doAssert not compiles(positionalOption())
    doAssert not compiles(repeatedOption())
    doAssert not compiles(restyledOption())
    doAssert not compiles(noBody())

  block metadata_stays_out_of_the_body_hash:
    # The declarations are metadata about a test, not part of it. Were they
    # spliced into the hashed body, annotating a test would look to an
    # incremental runner exactly like editing it.
    doAssert rowFor(rows, "::hash twin, annotated")["bodyHash"] ==
      rowFor(rows, "::hash twin, bare")["bodyHash"]

  quit 0

test "declares nothing":
  discard

test "expected to fail", xfail = "known overflow on 32-bit":
  discard

test "conditionally expected to fail",
    xfail = (when defined(thisIsNeverDefined): "unsupported" else: ""):
  discard

test "tagged", tags = ["slow", "network"]:
  discard

test "weighted", threadsRequired = 4:
  discard

test "reads the clock", deterministic = false:
  discard

test "grouped by option", group = "db-access":
  discard

testGroup "fs-access":
  test "grouped by block":
    discard

  test "block group overridden", group = "net":
    discard

test "after the block":
  discard

# The two below must have byte-identical bodies, so that the only difference
# between them is the annotation. The body deliberately avoids `check`, whose
# expansion plants its own line and column and so hashes differently on every
# line it appears on.
test "hash twin, bare":
  discard "twin"
test "hash twin, annotated", tags = ["twin"], threadsRequired = 3:
  discard "twin"

suite "combined":
  test "all five", group = "integration", threadsRequired = 2,
      xfail = "not implemented yet", tags = ["slow"], deterministic = false:
    discard
