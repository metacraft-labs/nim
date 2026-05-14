discard """
  cmd: "nim e $file"
  targets: "e"
"""

## CTFS-M3 demonstrator: exception-flow step events in execution order.
##
## After this milestone the trace should record the raise/catch transitions
## as dedicated `sekRaise` / `sekCatch` event-kinds at their respective
## source lines, and in EXECUTION order (try -> raise -> catch -> body)
## rather than the pre-CTFS-M3 source-order bug (try -> raise -> body ->
## catch). See codetracer-specs/Nim-Compiler-Patches.md § CTFS-M3.

try:
  raise newException(IndexDefect, "out of range")  # line 15
except IndexDefect:                                # line 16
  echo "caught"                                    # line 17
