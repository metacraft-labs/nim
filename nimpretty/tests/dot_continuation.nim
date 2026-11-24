proc f(items: seq[int]) =
  for x in items.
      filterIt(it > 0):
    echo x
  for y in items
      .mapIt(it * 2):
    echo y
