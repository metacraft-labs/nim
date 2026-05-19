#[!]#
# Tests `highlightRange` when a proc declaration is missing its
# `=` body separator: `proc foo() int discard` (the parser
# expects `=` after the return type and before the body).
#
# Exploratory: locks in current behaviour for the `foo` proc and
# any symbols defined either side of the malformed declaration.

proc valid_before(): int = 0

proc broken() int discard

var counter_after = 1

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.int	int	$file	9	21	""	100
highlightRange	skProc	thighlight_range_missing_eq.valid_before	proc (): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skResult	thighlight_range_missing_eq.valid_before.result	int	$file	9	0	""	100
highlightRange	skProc	thighlight_range_missing_eq.valid_before	proc (): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skProc	thighlight_range_missing_eq.broken	proc ()	$file	11	5	""	100
highlightRange	skProc	thighlight_range_missing_eq.broken	proc ()	$file	11	5	""	100
highlightRange	skType	system.int	int	$file	11	14	""	100
highlightRange	skVar	thighlight_range_missing_eq.counter_after	int	$file	13	4	""	100
highlightRange	skVar	thighlight_range_missing_eq.counter_after	int	$file	13	4	""	100
"""
