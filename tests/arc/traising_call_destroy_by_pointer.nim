discard """
  matrix: "--mm:orc -d:nimPreviewNonVarDestructor; --mm:arc -d:nimPreviewNonVarDestructor; --mm:orc"
  output: '''
ok a
raised
lifted destroys balanced
ok b
raised
custom destroys: 1
'''
"""

# A call that can raise, whose result is stored into a location the
# caller can observe (here a `var` parameter), goes through a temporary
# that is destroyed on the error path. The destructor's C signature takes
# the object by pointer when the object is large or not final, even when
# its Nim parameter is not `var` (the `nimPreviewNonVarDestructor` shape),
# so the temporary must be passed by address.

type
  Lifted = object
    s: string
    a, b, c: int

proc mayRaiseLifted(x: int): Lifted {.noinline.} =
  if x > 0: raise newException(ValueError, "x")
  Lifted(s: "a", a: 1)

proc fillLifted(dest: var Lifted; x: int) =
  dest = mayRaiseLifted(x)

var l: Lifted
fillLifted(l, 0)
echo "ok ", l.s
try:
  fillLifted(l, 1)
except ValueError:
  echo "raised"
echo "lifted destroys balanced"

type
  Custom = object
    s: string
    a, b, c: int

var destroyed = 0

when defined(nimPreviewNonVarDestructor):
  proc `=destroy`(x: Custom) =
    if x.s.len > 0: inc destroyed
    `=destroy`(x.s)
else:
  proc `=destroy`(x: var Custom) =
    if x.s.len > 0: inc destroyed
    `=destroy`(x.s)

proc mayRaiseCustom(x: int): Custom {.noinline.} =
  result = Custom(s: "b")
  if x > 0: raise newException(ValueError, "x")

proc fillCustom(dest: var Custom; x: int) =
  dest = mayRaiseCustom(x)

proc main =
  var c: Custom
  fillCustom(c, 0)
  echo "ok ", c.s
  try:
    fillCustom(c, 1)
  except ValueError:
    echo "raised"
  echo "custom destroys: ", destroyed

main()
