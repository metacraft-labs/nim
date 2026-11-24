proc f() =
  for e in sink.waitForDetection("frame-refused", pump = proc() =
    tickFor([hostA], 50)):
    if e.field("refusal") == "revoked" and
        e.field("peer") == $bId:
      sawRevoked = true
