proc readProcessSpec(bytes: openArray[byte]; pos: var int): ProcessSpec =
  let kind = readByteValue(bytes, pos)
  if kind > byte(ord(ckShell)):
    raiseEnvelopeError(eeMalformed, "invalid process kind")
  result.kind = CommandKind(kind)
  result.executable = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  result.args = readStringSeq(bytes, pos)
  let envCount = int(readU32Le(bytes, pos))
  result.env = newSeq[EnvVar](envCount)
  for i in 0 ..< envCount:
    result.env[i].name = readString(bytes, pos)
    result.env[i].value = readString(bytes, pos)
  result.cwd = NormalizedPath(kind: npRelative, value: readString(bytes, pos))
  let stdinPolicy = readByteValue(bytes, pos)
  let stdoutPolicy = readByteValue(bytes, pos)
  let stderrPolicy = readByteValue(bytes, pos)
  if stdinPolicy > byte(ord(spCapture)) or stdoutPolicy > byte(ord(
      spCapture)) or stderrPolicy > byte(ord(spCapture)):
    raiseEnvelopeError(eeMalformed, "invalid stdio policy")
  result.stdinPolicy = StdioPolicy(stdinPolicy)
  result.stdoutPolicy = StdioPolicy(stdoutPolicy)
  result.stderrPolicy = StdioPolicy(stderrPolicy)
