#[!]#
# Tests `highlightRange` against an unbalanced bracket literal.
# The parser raises an error scanning the `[1, 2, 3` array literal
# because the closing `]` never arrives before EOF.
#
# Exploratory: documents which earlier symbols survive sem and
# whether the partially-typed `nums` let still emits a row.

proc head(xs: seq[int]): int = xs[0]

var seen = 0

let nums = [1, 2, 3

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.seq	seq	$file	9	14	"Generic type to construct sequences."	100
highlightRange	skType	system.int	int	$file	9	18	""	100
highlightRange	skParam	thighlight_range_unbalanced_bracket.head.xs	seq[int]	$file	9	10	""	100
highlightRange	skType	system.int	int	$file	9	25	""	100
highlightRange	skProc	thighlight_range_unbalanced_bracket.head	proc (xs: seq[int]): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skParam	thighlight_range_unbalanced_bracket.head.xs	seq[int]	$file	9	31	""	100
highlightRange	skResult	thighlight_range_unbalanced_bracket.head.result	int	$file	9	0	""	100
highlightRange	skProc	thighlight_range_unbalanced_bracket.head	proc (xs: seq[int]): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skVar	thighlight_range_unbalanced_bracket.seen	int	$file	11	4	""	100
highlightRange	skVar	thighlight_range_unbalanced_bracket.seen	int	$file	11	4	""	100
highlightRange	skLet	thighlight_range_unbalanced_bracket.nums	array[0..2, int]	$file	13	4	""	100
highlightRange	skLet	thighlight_range_unbalanced_bracket.nums	array[0..2, int]	$file	13	4	""	100
"""
