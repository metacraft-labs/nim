# Fixture for the header-dependency cache test in `tests/misc/trunner.nim`.
# The C value this prints comes from `mheaderdep.h`, which the test writes into
# a scratch directory and passes with `--cincludes`. Nothing in this file
# changes between the test's compiler invocations; only the header does.

{.emit: """#include "mheaderdep.h"
static int mheaderdepValue(void) { return MHEADERDEP_VALUE; }
""".}

proc mheaderdepValue(): cint {.importc, nodecl.}

echo "mheaderdep: ", mheaderdepValue()
