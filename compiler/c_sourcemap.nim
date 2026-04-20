## C Source Map Generator for CodeTracer
##
## Parses `#line` directives in generated C files to build bidirectional
## mappings between Nim source lines and C output lines.
##
## The Nim C codegen emits `#define FX_N "path/to/source.nim"` at the top
## of each C file, followed by `#line L FX_N` directives. This module
## resolves the FX_ references and builds a JSON mapping file.
##
## The generated JSON file (`ct_sourcemap_<module>`) is consumed by the
## CodeTracer debugger to let users switch between Nim, C, and assembly views.

import std/[os, strutils, tables, json]
when defined(nimPreviewSlimSystem):
  import std/syncio

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

proc resolveFilePath(token: string, fxDefs: Table[string, string]): string =
  ## Resolve a file token from a #line directive. Handles both:
  ## - FX_N (macro reference, resolved via fxDefs)
  ## - "path/to/file" (quoted path literal)
  if token.startsWith("FX_"):
    return fxDefs.getOrDefault(token, "")
  elif token.len >= 2 and token[0] == '"' and token[^1] == '"':
    return token[1..^2]
  else:
    return ""

proc genSourceMap*(map: CSourceMap, source: string, cfile: string) =
  ## Parse `#line` directives in the generated C `source` to build
  ## Nim-to-C line mappings. `cfile` is the path to the C file.
  if cfile notin map.cSources:
    map.cSources[cfile] = map.cSources.len

  let lines = source.splitLines()

  # First pass: collect #define FX_N "path" mappings
  var fxDefs = initTable[string, string]()
  for lineSource in lines:
    if lineSource.startsWith("#define FX_"):
      # Format: #define FX_0 "path/to/file.nim"
      let parts = lineSource.split(' ', 2)
      if parts.len == 3 and parts[2].len >= 2 and
         parts[2][0] == '"' and parts[2][^1] == '"':
        fxDefs[parts[1]] = parts[2][1..^2]

  # Second pass: parse #line directives
  var i = 0
  while i < lines.len:
    let lineSource = lines[i]
    if lineSource.startsWith("#line "):
      # Format: #line <number> <file-token>
      # where file-token is FX_N or "path"
      let afterLine = 6
      let indexSpace = lineSource.find(' ', afterLine)
      if indexSpace == -1:
        i += 1
        continue
      var nimLine: int = 0
      try:
        nimLine = parseInt(lineSource[afterLine ..< indexSpace])
      except ValueError:
        i += 1
        continue
      let fileToken = lineSource[indexSpace + 1 .. ^1].strip()
      let nimPath = resolveFilePath(fileToken, fxDefs)
      if nimPath.len == 0:
        i += 1
        continue

      if nimPath notin map.nimSources:
        map.nimSources[nimPath] = map.nimSources.len
        map.mappings.add(newTable[int, seq[seq[Line]]]())

      let pathIdx = map.nimSources[nimPath]
      if nimLine notin map.mappings[pathIdx]:
        map.mappings[pathIdx][nimLine] = @[]
      map.mappings[pathIdx][nimLine].add(@[])

      # Collect subsequent C lines until the next #line directive with a
      # different Nim line number
      var j = i + 1
      while j < lines.len:
        let innerLine = lines[j]
        var isDirective = false
        if innerLine.startsWith("#line "):
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
    elif lineSource.startsWith("#define FX_"):
      i += 1  # Skip define lines
    else:
      i += 1

proc serializeLine(line: Line): JsonNode =
  result = newJArray()
  result.add(%line.pathID)
  result.add(%line.line)

proc serializePathMap(pathMap: TableRef[int, seq[seq[Line]]]): JsonNode =
  result = newJObject()
  for nimLine, groups in pathMap:
    var groupsJson = newJArray()
    for group in groups:
      var groupJson = newJArray()
      for line in group:
        groupJson.add(serializeLine(line))
      groupsJson.add(groupJson)
    result[$nimLine] = groupsJson

proc serialize*(map: CSourceMap): string =
  var mappingsJson = newJArray()
  for pathMap in map.mappings:
    mappingsJson.add(serializePathMap(pathMap))
  let jsonNode = %*{
    "nimSources": %map.nimSources,
    "cSources": %map.cSources,
    "mappings": mappingsJson
  }
  return pretty(jsonNode)

proc writeSourceMap*(map: CSourceMap, outDir: string, outFileName: string) =
  let path = outDir / "ct_sourcemap_" & outFileName
  writeFile(path, map.serialize())
