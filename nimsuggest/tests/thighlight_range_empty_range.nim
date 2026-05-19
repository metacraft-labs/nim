#[!]#
# Tests `highlightRange` when invoked with an EMPTY RANGE (start
# == end at a position where no symbol lives).  The handler should
# emit zero highlight rows — not error out, not return all symbols.

proc greet(): string = "hi"

var counter = 0

discard """
$nimsuggest --v3 --tester $file
>highlightRange 5:0 5:0
"""
