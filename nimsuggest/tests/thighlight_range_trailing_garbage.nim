#[!]#
# Tests `highlightRange` when the file ends with trailing
# unparseable garbage at the end of the line stream.
#
# Exploratory: documents that an EOF-position error does NOT
# prevent earlier well-formed declarations from contributing
# highlight rows.

proc greet(): string = "hi"

var counter = 0

@@@ unparseable trailing tokens @@@

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.string	string	$file	9	14	""	100
highlightRange	skProc	thighlight_range_trailing_garbage.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skResult	thighlight_range_trailing_garbage.greet.result	string	$file	9	0	""	100
highlightRange	skProc	thighlight_range_trailing_garbage.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	9	5	""	100
highlightRange	skVar	thighlight_range_trailing_garbage.counter	int	$file	11	4	""	100
highlightRange	skVar	thighlight_range_trailing_garbage.counter	int	$file	11	4	""	100
highlightRange	skUnknown	thighlight_range_trailing_garbage.`@@@`	Error Type	$file	13	0	""	100
highlightRange	skUnknown	thighlight_range_trailing_garbage.unparseable	Error Type	$file	13	4	""	100
highlightRange	skUnknown	thighlight_range_trailing_garbage.trailing	Error Type	$file	13	16	""	100
highlightRange	skUnknown	thighlight_range_trailing_garbage.`@@@`	Error Type	$file	13	32	""	100
highlightRange	skUnknown	thighlight_range_trailing_garbage.tokens	Error Type	$file	13	25	""	100
"""
