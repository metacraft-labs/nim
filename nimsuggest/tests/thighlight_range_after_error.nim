#[!]#
# Tests `highlightRange` for symbols defined AFTER a syntax error.
# Tests Nim sem's error-recovery ability: after the parser bails on
# the malformed line, does it pick up parsing again at the next
# top-level statement so symbols defined LATER in the file are
# still bound?
#
# Exploratory: documents whether `after_proc` and `after_var`
# below the malformed `broken` statement get highlight rows.

proc before_proc(): int = 0

# A truly malformed line that cannot be parsed:
proc broken_proc() int discard

proc after_proc(): string = "after"

var after_var = 42

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.int	int	$file	11	20	""	100
highlightRange	skProc	thighlight_range_after_error.before_proc	proc (): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	11	5	""	100
highlightRange	skResult	thighlight_range_after_error.before_proc.result	int	$file	11	0	""	100
highlightRange	skProc	thighlight_range_after_error.before_proc	proc (): int{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	11	5	""	100
highlightRange	skProc	thighlight_range_after_error.broken_proc	proc ()	$file	14	5	""	100
highlightRange	skProc	thighlight_range_after_error.broken_proc	proc ()	$file	14	5	""	100
highlightRange	skType	system.int	int	$file	14	19	""	100
highlightRange	skType	system.string	string	$file	16	19	""	100
highlightRange	skProc	thighlight_range_after_error.after_proc	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	16	5	""	100
highlightRange	skResult	thighlight_range_after_error.after_proc.result	string	$file	16	0	""	100
highlightRange	skProc	thighlight_range_after_error.after_proc	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	16	5	""	100
highlightRange	skVar	thighlight_range_after_error.after_var	int	$file	18	4	""	100
highlightRange	skVar	thighlight_range_after_error.after_var	int	$file	18	4	""	100
"""
