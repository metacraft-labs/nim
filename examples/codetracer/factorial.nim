## Recursive factorial — useful for exercising call/return navigation in
## the replay UI. Each recursive frame appears as its own call event, so
## "step into" / "step out" traversal is meaningful.

proc factorial(n: int): int =
  if n <= 1:
    return 1
  return n * factorial(n - 1)

let answer = factorial(6)
echo "6! = ", answer
