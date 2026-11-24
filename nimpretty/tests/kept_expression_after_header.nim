proc handRun(cwd: string; withRefs = true):
    tuple[code: int; output: string] =
  let refsFlag =
    if withRefs: " --pushed-refs=" & cwd
    else: ""
  if fileExists(cwd):
    try: result.code = parseInt(readFile(cwd))
    except CatchableError: result.code = 1
