discard """
  cmd: "nim e $file"
  targets: "e"
"""

import mscriptcompiletime

macro foo =
  doAssert bar == 2
foo()
