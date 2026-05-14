#[!]#
# Tests the v3 `highlightRange` verb (range-query analogue of `highlight`).
#
# See C source maps V3, milestone M4 in Nim-Compiler-Patches.md
# (§ "1b. C Source Maps V3"). `ideHighlightRange` emits one suggest
# row per sem-resolved (sym, info) pair whose position falls inside
# the supplied [start, end] range. The start position uses the
# standard line/col arguments; the end position is parsed from the
# `tag` trailer as `<endLine>:<endCol>`.
#
# The 10 sibling *_highlight.nim tests exercise the point-query
# verb; this is the first nimsuggest-level test for the range-query
# verb. Until this file was added, the only regression coverage for
# `ideHighlightRange` was the property-test framework in
# tests/sourcemap/sourcemap_coverage_helpers.nim.

proc greet(): string = "hi"

var counter = 0

let limit = 10

template twice(body: untyped): untyped =
  body
  body

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.string	string	$file	17	14	""	100
highlightRange	skProc	thighlight_range.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	17	5	""	100
highlightRange	skResult	thighlight_range.greet.result	string	$file	17	0	""	100
highlightRange	skProc	thighlight_range.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	17	5	""	100
highlightRange	skVar	thighlight_range.counter	int	$file	19	4	""	100
highlightRange	skVar	thighlight_range.counter	int	$file	19	4	""	100
highlightRange	skLet	thighlight_range.limit	int	$file	21	4	""	100
highlightRange	skLet	thighlight_range.limit	int	$file	21	4	""	100
highlightRange	skTemplate	thighlight_range.twice	template (body: untyped): untyped	$file	23	9	""	100
highlightRange	skTemplate	thighlight_range.twice	template (body: untyped): untyped	$file	23	9	""	100
highlightRange	skType	system.untyped	untyped	$file	23	21	""	100
highlightRange	skParam	thighlight_range.twice.body	untyped	$file	23	15	""	100
highlightRange	skType	system.untyped	untyped	$file	23	31	""	100
"""
