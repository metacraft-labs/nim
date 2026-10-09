discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## A value is recorded under a binding's name only for writes made while
## that binding holds its register.
##
## Registers are numbered per proc, and all top-level code -- including a
## `static:` block compiled before the run -- shares one numbering. The
## script below expands the same template at compile time and at run
## time. Attributing a write by (proc, register) alone names it after
## whichever binding was last given that register anywhere in that code:
## here the inlined `keys` iterator's `t.counter > 0` temporary was
## recorded as `tmpTuple`, the hidden binding of `let (x,y) = q[0]`, at
## the loop's line, before that binding exists.
##
## Asserted: every value of `tmpTuple` is on a step of the line that
## declares it, and so is every value of `key` on its loops' lines.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader
import codetracer_trace_writer/full_document_json

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_slot_reuse_names"

const
  testScript = """
import std/tables

template main() =
  block:
    type
      MyTuple = tuple
        num: int
        strings: seq[string]
        ints: seq[int]

    var foo = MyTuple((
      num: 7,
      strings: @[],
      ints: @[],
    ))

    var bar = MyTuple (
      num: 7,
      strings: @[],
      ints: @[],
    )

    var fooUnnamed = MyTuple((7, @[], @[]))
    var n = 7
    var fooSym = MyTuple((num: n, strings: @[], ints: @[]))

  block:
    var p = newOrderedTable[tuple[a:int], int]()
    var q = newOrderedTable[tuple[x:int], int]()
    for key in p.keys:
      echo key.a
    for key in q.keys:
      echo key.x

  block:
    type
      Item[K,V] = tuple
        key: K
        value: V

    var q = newseq[Item[int,int]](1)
    let (x,y) = q[0]
    echo x, y

  block:
    type T1 = tuple[a, b: int]

    proc p(b: bool): T1 =
      var x: T1 = (10, 20)
      x = if b: (x.b, x.a) else: (-x.b, -x.a)
      x

    doAssert p(false) == (-20, -10)
    doAssert p(true) == (20, 10)

static:
  main()
main()
"""

proc linesOf(needle: string): seq[int] =
  for i, l in pairs(testScript.splitLines):
    if needle in l: result.add i + 1

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)
  let scriptFile = buildDir / "reuse.nim"
  let traceFile = buildDir / "reuse.ct"
  writeFile(scriptFile, testScript)
  let tupleLines = linesOf("let (x,y) = q[0]")
  let keyLines = linesOf("for key in")
  doAssert tupleLines.len == 1 and keyLines.len == 2

  let (output, exitCode) = execCmdEx(nim & " e --trace:" & traceFile &
                                     " " & scriptFile)
  doAssert exitCode == 0, "nim e --trace failed: " & output

  var r = openNewTrace(traceFile).get()
  var tupleValues = 0
  for i in 0'u64 ..< r.stepCount().get():
    for v in r.values(i).get():
      let name = r.varname(v.varnameId).get()
      if name notin ["tmpTuple", "key"]:
        continue
      let pos = r.decodeGlobalPositionIndex(
        r.stepAbsoluteGlobalLineIndex(i).get()).get()
      let allowed = if name == "tmpTuple": tupleLines else: keyLines
      doAssert pos.line.int in allowed,
        "'" & name & "' recorded at line " & $pos.line & " with value " &
        $decodeValueBytesToJson(v.data) & "; it is bound only on line(s) " &
        $allowed
      if name == "tmpTuple": inc tupleValues
  doAssert tupleValues == 1,
    "'tmpTuple' should be recorded once, got " & $tupleValues

  echo "PASS: tvm_trace_slot_reuse_names"
  removeDir(buildDir)

main()
