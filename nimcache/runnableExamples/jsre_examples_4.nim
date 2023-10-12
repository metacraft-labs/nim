#[
autogenerated by docgen
loc: /home/runner/work/nim/nim/lib/js/jsre.nim(78, 1)
rdoccmd: 
]#
import std/assertions
import "/home/runner/work/nim/nim/lib/js/jsre.nim"
{.line: ("/home/runner/work/nim/nim/lib/js/jsre.nim", 78, 1).}:
  let jsregex: RegExp = newRegExp(r"\s+", r"i")
  jsregex.compile(r"\w+", r"i")
  assert "nim javascript".contains jsregex
  assert jsregex.exec(r"nim javascript") == @["nim".cstring]
  assert jsregex.toCstring() == r"/\w+/i"
  jsregex.compile(r"[0-9]", r"i")
  assert "0123456789abcd".contains jsregex
  assert $jsregex == "/[0-9]/i"
  jsregex.compile(r"abc", r"i")
  assert "abcd".startsWith jsregex
  assert "dabc".endsWith jsregex
  jsregex.compile(r"\d", r"i")
  assert "do1ne".split(jsregex) == @["do".cstring, "ne".cstring]
  jsregex.compile(r"[lw]", r"i")
  assert "hello world".replace(jsregex,"X") == "heXlo world"
  jsregex.compile(r"([a-z])\1*", r"g")
  assert "abbcccdddd".replace(jsregex, proc (m: varargs[cstring]): cstring = ($m[0] & $(m.len)).cstring) == "a1b2c3d4"
  let digitsRegex: RegExp = newRegExp(r"\d")
  assert "foo".match(digitsRegex) == @[]

