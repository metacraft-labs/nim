discard """
  cmd: "nim e $file"
  targets: "e"
"""

## CTFS-M-CallKeyOrder: call_keys must be allocated at call ENTRY, so
## a child call always has a larger call_key than its enclosing parent.
##
## Pre-fix the writer assigned call_keys at registerReturn (the natural
## moment when the buffered CallRecord lands in the call stream), which
## meant the innermost frame — the first to return — got call_key 0 and
## the outermost frame got the highest key. Debugger UIs that walk a
## trace forward (step-into, reverse-step, breakpoint navigation) all
## assume call_key matches entry order; an entry-order mismatch breaks
## parent/child rendering and any UI that looks up a parent by smaller
## key.
##
## The snapshot pinned next to this file captures the post-fix order:
## the outermost `outer` call_entry appears with `call_key: 0`, and the
## nested `inner` call_entry inside it appears with `call_key: 1`. The
## matching call_exit events carry the same keys.

proc inner() = discard         # line 21

proc outer() =                  # line 23
  inner()                       # line 24

outer()                         # line 26
