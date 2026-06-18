## Smallest possible program to exercise the codetracer-nim compile-time
## tracer. Run with `ct run hello.nim` (or record/replay separately) and
## step through the assignments to see local values appear in the GUI.

proc greet(name: string): string =
  let prefix = "Hello, "
  let suffix = "!"
  result = prefix & name & suffix

let who = "codetracer"
let msg = greet(who)
echo msg
