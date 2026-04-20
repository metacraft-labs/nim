## C Source Map Generator for CodeTracer
##
## Parses `#line` directives in generated C files to build bidirectional
## mappings between Nim source lines and C output lines.
##
## The generated JSON file (`ct_sourcemap_<module>`) is consumed by the
## CodeTracer debugger to let users switch between Nim, C, and assembly views.

import std/[os, strutils, tables, json]

type
  Line* = tuple[pathID: int, line: int]

  CSourceMap* = ref object
    cSources*: Table[string, int]
    nimSources*: Table[string, int]
    mappings*: seq[TableRef[int, seq[seq[Line]]]]
    ## For each Nim source (by pathID index), a table mapping Nim line numbers
    ## to groups of consecutive C lines. Each group is a seq[Line] where
    ## Line.pathID indexes into cSources and Line.line is the C line number.

proc newCSourceMap*(): CSourceMap =
  CSourceMap(
    nimSources: initTable[string, int](),
    cSources: initTable[string, int](),
    mappings: @[]
  )

proc genSourceMap*(map: CSourceMap, source: string, cfile: string) =
  ## Parse `#line` directives in the generated C `source` to build
  ## Nim-to-C line mappings. `cfile` is the path to the C file.
  if cfile notin map.cSources:
    map.cSources[cfile] = map.cSources.len

  let lines = source.splitLines()
  var i = 0

  while i < lines.len:
    let lineSource = lines[i]
    # Match: #line <number> "<path>"
    if lineSource.len >= 7 and lineSource.startsWith("#line "):
      let afterLine = 6
      let indexSpace = lineSource.find(' ', afterLine)
      if indexSpace == -1:
        i += 1
        continue
      var nimLine: int
      try:
        nimLine = parseInt(lineSource[afterLine ..< indexSpace])
      except ValueError:
        i += 1
        continue
      if lineSource.len < indexSpace + 3:
        i += 1
        continue
      if lineSource[indexSpace + 1] != '"' or lineSource[^1] != '"':
        i += 1
        continue
      let nimPath = lineSource[indexSpace + 2 .. ^2]

      if nimPath notin map.nimSources:
        map.nimSources[nimPath] = map.nimSources.len
        map.mappings.add(newTable[int, seq[seq[Line]]]())

      let pathIdx = map.nimSources[nimPath]
      var pathMap = map.mappings[pathIdx]
      if nimLine notin pathMap:
        pathMap[nimLine] = @[]
      map.mappings[pathIdx][nimLine].add(@[])

      # Collect subsequent C lines until the next #line directive with a
      # different Nim line number
      var j = i + 1
      while j < lines.len:
        let innerLine = lines[j]
        var isDirective = false
        if innerLine.len >= 7 and innerLine.startsWith("#line "):
          let innerSpace = innerLine.find(' ', 6)
          if innerSpace != -1:
            try:
              let innerNimLine = parseInt(innerLine[6 ..< innerSpace])
              if innerNimLine != nimLine:
                break
              else:
                isDirective = true
            except ValueError:
              discard
        if not isDirective and innerLine.strip.len > 0:
          map.mappings[pathIdx][nimLine][^1].add(
            (pathID: map.cSources[cfile], line: j))
        j += 1
      i = j
    else:
      i += 1

proc `%`(line: Line): JsonNode =
  result = newJArray()
  result.add(%line.pathID)
  result.add(%line.line)

proc serialize*(map: CSourceMap): string =
  var mappingsJson = newJArray()
  for pathMap in map.mappings:
    mappingsJson.add(%pathMap)
  let jsonNode = %*{
    "nimSources": %map.nimSources,
    "cSources": %map.cSources,
    "mappings": mappingsJson
  }
  return pretty(jsonNode)

proc writeSourceMap*(map: CSourceMap, outDir: string, outFileName: string) =
  let path = outDir / "ct_sourcemap_" & outFileName
  writeFile(path, map.serialize())
