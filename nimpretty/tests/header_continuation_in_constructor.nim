const chronosOutputVTable = OutputStreamVTable(
  writeSync: proc (s: OutputStream, src: pointer, srcLen: Natural)
                  {.iocall.} =
      s.closeFut = close ChronosOutputStream(s).transport
  ,
  flushSync: proc (s: OutputStream) {.iocall.} =
    discard
)
