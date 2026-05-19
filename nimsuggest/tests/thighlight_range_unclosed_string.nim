#[!]#
# Tests `highlightRange` against a file with an UNCLOSED STRING LITERAL.
# The lexer raises an error when it walks off the end of the line still
# inside string-literal state.  Sem still runs for the well-formed
# prefix, so any (sym, info) pairs collected before the error point
# should remain in the file-symbols table that `ideHighlightRange`
# iterates.
#
# Locks in the current behaviour: ALL THREE symbols — well-formed
# `greet`, well-formed `counter`, and the `limit` whose initializer
# is malformed — still produce highlight rows. The lexer's
# unclosed-string error does NOT prevent sem from creating the
# `let limit` binding (the AST contains a synthesized error-node
# initializer but the symbol itself is bound to `string` per the
# successfully-parsed initializer prefix).
#
# That makes `ideHighlightRange` robust to mid-file syntax errors:
# the IDE still gets full token-colour data for every symbol that
# even partially survived sem, not just symbols above the error.

proc greet(): string = "hi"

var counter = 0

let limit = "oops

discard """
$nimsuggest --v3 --tester $file
>highlightRange $1 100:0
highlightRange	skType	system.string	string	$file	21	14	""	100
highlightRange	skProc	thighlight_range_unclosed_string.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	21	5	""	100
highlightRange	skResult	thighlight_range_unclosed_string.greet.result	string	$file	21	0	""	100
highlightRange	skProc	thighlight_range_unclosed_string.greet	proc (): string{.noSideEffect, gcsafe, raises: <inferred> [].}	$file	21	5	""	100
highlightRange	skVar	thighlight_range_unclosed_string.counter	int	$file	23	4	""	100
highlightRange	skVar	thighlight_range_unclosed_string.counter	int	$file	23	4	""	100
highlightRange	skLet	thighlight_range_unclosed_string.limit	string	$file	25	4	""	100
highlightRange	skLet	thighlight_range_unclosed_string.limit	string	$file	25	4	""	100
"""
