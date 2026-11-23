discard """
  matrix: "--mm:arc; --mm:orc; --mm:refc"
  output: '''
1
0
1
0
'''
"""

# bug #26247, the form found in the CodeTracer Nim fork: a proc's closure
# environment is shared by a nested proc called on an early-`return` path and
# by an anonymous closure created after that `return`. setupEnvVar handed out
# one cached `:env` node for every use, so injectdestructors' `isLastRead`
# (which finds a use in the CFG by node identity) treated the closure
# construction as the last read and moved `:env` into it
# (`nimMarkCyclic(:env); =wasMoved(:env)`). The later `result = ord(taken)`
# then read `taken` through a nil environment, so every call that did not take
# the early return died with SIGSEGV (`f(3)`, `g(3)`; `f(0)` and `g(0)` passed).

proc f(n: int): int =
  var partial: seq[int]
  proc rep() =
    for p in partial: discard
  if n == 0:
    rep()
    return
  var taken = false
  proc take() =
    taken = true
  let cb = proc() =
    if not taken: take()
  cb()
  result = ord(taken)

echo f(3)
echo f(0)

# The smallest form, from the reprobuild sharded certifying test run that
# crashed on it: the nested proc on the early-return path captures only a
# parameter, and the anonymous closure only a local declared after the return.
proc g(n: int): int =
  proc rep(): int = n
  if n == 0:
    discard rep()
    return
  var taken = false
  let cb = proc() = taken = true
  cb()
  ord(taken)

echo g(3)
echo g(0)
