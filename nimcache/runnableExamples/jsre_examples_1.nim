#[
autogenerated by docgen
loc: /home/runner/work/nim/nim/lib/js/jsre.nim(56, 3)
rdoccmd: 
]#
import std/assertions
import "/home/runner/work/nim/nim/lib/js/jsre.nim"
{.line: ("/home/runner/work/nim/nim/lib/js/jsre.nim", 56, 3).}:
  let jsregex: RegExp = newRegExp(r"bc$", r"i")
  assert jsregex in r"abc"
  assert jsregex notin r"abcd"
  assert "xabc".contains jsregex

