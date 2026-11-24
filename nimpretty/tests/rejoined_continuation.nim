# A line just over the limit whose continuation line has the indentation of
# the split nimpretty inserts: the continuation is rejoined, and the rejoined
# line break must keep its indentation when it is split again.

case x
of StoreCommandLineCommandKind2.closure, StoreCommandLineCommandKind2.export1xxx,
    StoreCommandLineCommandKind2.importAB:
  discard
else: discard

proc p() =
  case x
  of CommandLineStoreCommandKind.closure, CommandLineStoreCommandKind.`export1234`,
      CommandLineStoreCommandKind.`import`:
    discard
  else: discard
