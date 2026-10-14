discard """
  matrix: "--skipParentCfg --filenames:legacyRelProj"
  output: '''
logged: echo aa bb
logged: echo ab
logged: echo ab
logged: echo ab
logged: echo ab
logged: echo ab
'''
"""

# A term-rewriting template whose argument contains declarations. After a
# rewrite the compiler folds constants over the whole rewritten statement.
# `mapIt` expands to `type OutType = typeof(..., typeOfIter)`, and with
# `openSym` disabled (the default) the `typeOfIter` symbol a template leaves
# in that type section has no type; folding it crashed the compiler with
# SIGSEGV. The folding must skip type sections, `typeof` expressions, the
# declared type of a `var`/`let` (also in tuple unpacking), the type of a
# `cast` or object construction, and the other declarations that the
# transformation pass skips.
#
# `--skipParentCfg` keeps tests/config.nims from enabling `openSym`, which
# wraps the symbol and hides the crash.

import std/[sequtils, strutils]

type Box[T] = object
  x: T

proc run(cmd: string): string = cmd
proc runLogged(cmd: string): string = "logged: " & cmd

template logRun{run(c)}(c: string): string = runLogged(c)

template joined(s: untyped): untyped =
  block:
    type Elem = typeof(items(s), typeOfIter)
    const prefix = "echo "
    var e: Elem = prefix
    for a in s: e.add a
    e

template declaredType(s: untyped): untyped =
  block:
    let start: typeof(items(s), typeOfIter) = "echo "
    var e = start
    for a in s: e.add a
    e

template tupleType(s: untyped): untyped =
  block:
    var (e, unused): (typeof(items(s), typeOfIter), int) = ("echo ", 0)
    for a in s: e.add a
    e

template castType(s: untyped): untyped =
  block:
    var e = cast[typeof(items(s), typeOfIter)]("echo ")
    for a in s: e.add a
    e

template objConstrType(s: untyped): untyped =
  block:
    var e = Box[typeof(items(s), typeOfIter)](x: "echo ").x
    for a in s: e.add a
    e

proc main() =
  let args = @["a", "b"]
  echo run("echo " & args.mapIt(it & it).join(" "))
  echo run(joined(args))
  echo run(declaredType(args))
  echo run(tupleType(args))
  echo run(castType(args))
  echo run(objConstrType(args))

main()
