func allFieldNames(T: typedesc): auto #[{.compileTime.}]# =
  result = 1

let x = 1 #[ note ]# + 2
