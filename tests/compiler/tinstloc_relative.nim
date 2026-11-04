# The compiler records where in its own source each message and VM stack
# trace was raised (`msgs.instLoc`, `vm.stackTrace`). Those locations are
# compiled into the compiler binary, so an absolute path there is the path
# of the tree the compiler was built in: a compiler built under
# /tmp/a15-r4/.../nim-fork/tree carried 47 such strings, and an installed copy
# of it named the build machine. They are recorded relative to the Nim
# source root instead, which still says which module and line raised it.

import std/os
import compiler/msgs

template reportHere(): InstantiationInfo = instLoc()

proc where(): InstantiationInfo = reportHere()

let loc = where()
doAssert not loc.filename.isAbsolute, loc.filename
doAssert loc.filename == "tests" / "compiler" / "tinstloc_relative.nim",
  loc.filename
doAssert loc.line == 14, $loc.line
