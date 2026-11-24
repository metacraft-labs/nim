type
  Mode* = enum
    mDev
  Resolver* =
    proc (artifact: int): seq[int]
  Config* = object
    sessionId*: string
