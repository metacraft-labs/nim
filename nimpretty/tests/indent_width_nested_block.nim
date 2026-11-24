type ArrayBuf*[N: static int, T] = object
  when N <= cast[int](uint32.high):
    n*: uint32
  else:
    n*: uint
