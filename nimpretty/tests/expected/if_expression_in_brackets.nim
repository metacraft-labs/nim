proc scan(line: string; quote: char) =
  var e = 0
  while e < line.len and (if quote != '\0': line[e] != quote
    else: line[e] notin Whitespace):
    inc e
  for ext in (when defined(windows): @[".exe", ".cmd", ".bat", ""]
    else: @[""]):
    echo ext
