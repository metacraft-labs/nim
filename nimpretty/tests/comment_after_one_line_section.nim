let scratch = getTempDir() / "repro-teardown-" & $getCurrentProcessId()
# Removed when this process exits, whichever cases it ran, not by a final
# "teardown" case.

const FirstCommentLine = lineHere() + 1
## First line of the description.
## Second line.
