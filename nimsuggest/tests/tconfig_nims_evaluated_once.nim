# nimsuggest must run a project's NimScript config once, like `nim check`.
# nimsuggest used to run it a second time, and the `.nims` next to this file
# holds the shape that killed it then: a top-level `for` after enough
# top-level calls that the re-run found its loop variable's register slot
# stale. Without the lines after the loop the re-run dies compiling it
# (`IndexDefect: index 41 not in 0 .. 40`); with them this fork dies running
# it (a FieldDefect) and stock Nim 2.2.8 gets past it. The script therefore
# ends with an assertion that fails on any second evaluation, crash or not.
# Either way nimsuggest dies before it answers, and `def` returns nothing.
discard """
$nimsuggest --tester $file
>def $1
def;;skProc;;tconfig_nims_evaluated_once.answer;;proc (): int{.noSideEffect, gcsafe, raises: <inferred> [].};;$file;;16;;5;;"";;100
"""

proc answer(): int = 42

discard ans#[!]#wer()
