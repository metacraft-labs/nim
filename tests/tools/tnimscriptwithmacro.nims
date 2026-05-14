discard """
cmd: "nim e $file"
targets: "e"
output: '''
foobar
nothing
hallo
'''
"""

# this test ensures that the mode is resetted correctly to repr

import macros

macro foobar(): void =
  result = newCall(bindSym"echo", newLit("nothing"))

echo "foobar"

let x = 123

foobar()

exec "echo hallo"
