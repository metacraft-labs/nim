#
#
#           The Nim Compiler
#        (c) Copyright 2026 Nim contributors
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Compiler argument files (`nim --compilerArgsFile:<path>`).
##
## Operating systems bound the length of a process command line. Windows'
## `CreateProcessW` refuses a command line longer than 32,767 UTF-16 code
## units including its terminating NUL (`ERROR_FILENAME_EXCED_RANGE`, 206;
## https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-createprocessw).
## Build tools that pass many search paths can exceed it. This module defines
## a lossless transport for the *logical* compiler argument vector: the caller
## writes the vector to a file and passes exactly one physical option naming it.
##
## The file is UTF-8 JSON (RFC 8259, https://www.rfc-editor.org/rfc/rfc8259)
## without a byte order mark, with exactly these two fields:
##
## ```json
## {"version":1,"argv":["c","--path:relative imports","project.nim"]}
## ```
##
## `argv` is the vector the caller would otherwise have passed, excluding
## argv0, in order and including empty strings. The parser here is a
## deliberately strict, self-contained JSON reader for exactly that schema:
## `std/json` accepts comments, silently keeps the last of duplicate keys and
## does not validate UTF-8, and each of those would let a malformed file mean
## something other than what its producer wrote. Nothing is shell-parsed,
## substituted, normalized or expanded.
##
## The file is read and validated once per invocation. The frontend keeps the
## resulting vector in `ConfigRef` and feeds it to both command-line passes and
## to the NimScript argument APIs, so modifying or removing the file while
## configuration runs cannot change what the second pass sees.

import std/unicode

when defined(nimPreviewSlimSystem):
  import std/syncio

const
  ArgsFileSwitch* = "compilerArgsFile"
    ## The physical option's spelling. Matched style-insensitively, like every
    ## other compiler switch.
  ArgsFileVersion* = 1

type
  ArgsFileError* = object of CatchableError
    ## A malformed, unreadable or unsupported argument file. `msg` says why.

proc fail(msg: string) {.noreturn.} =
  raise newException(ArgsFileError, msg)

proc validateUtf8(data: string) =
  ## Rejects anything that is not well-formed UTF-8 (RFC 3629 §4): overlong
  ## forms, encoded surrogates, code points above U+10FFFF and truncated
  ## sequences. `std/unicode.validateUtf8` accepts some of those, so the check
  ## is spelled out here.
  var i = 0
  while i < data.len:
    let b0 = data[i].uint8
    if b0 < 0x80:
      inc i
      continue
    var need: int
    var lo = 0x80'u8
    var hi = 0xBF'u8
    case b0
    of 0xC2'u8..0xDF'u8: need = 1
    of 0xE0'u8: need = 2; lo = 0xA0
    of 0xE1'u8..0xEC'u8, 0xEE'u8..0xEF'u8: need = 2
    of 0xED'u8: need = 2; hi = 0x9F   # excludes encoded surrogates
    of 0xF0'u8: need = 3; lo = 0x90
    of 0xF1'u8..0xF3'u8: need = 3
    of 0xF4'u8: need = 3; hi = 0x8F   # excludes > U+10FFFF
    else: fail("invalid UTF-8 at byte offset " & $i)
    if i + need >= data.len:
      fail("truncated UTF-8 sequence at byte offset " & $i)
    let b1 = data[i + 1].uint8
    if b1 < lo or b1 > hi:
      fail("invalid UTF-8 at byte offset " & $i)
    for k in 2..need:
      let b = data[i + k].uint8
      if b < 0x80 or b > 0xBF:
        fail("invalid UTF-8 at byte offset " & $i)
    inc i, need + 1

type
  Reader = object
    data: string
    pos: int

proc atEnd(r: Reader): bool {.inline.} = r.pos >= r.data.len

proc skipWs(r: var Reader) =
  # RFC 8259 §2: insignificant whitespace is exactly these four bytes.
  while not r.atEnd and r.data[r.pos] in {' ', '\t', '\n', '\r'}:
    inc r.pos

proc expect(r: var Reader; c: char; what: string) =
  r.skipWs
  if r.atEnd or r.data[r.pos] != c:
    fail("malformed JSON: expected " & what & " at byte offset " & $r.pos)
  inc r.pos

proc hex4(r: var Reader): int =
  if r.pos + 4 > r.data.len:
    fail("malformed JSON: truncated \\u escape at byte offset " & $r.pos)
  result = 0
  for k in 0..3:
    let c = r.data[r.pos + k]
    let v = case c
      of '0'..'9': ord(c) - ord('0')
      of 'a'..'f': ord(c) - ord('a') + 10
      of 'A'..'F': ord(c) - ord('A') + 10
      else: fail("malformed JSON: invalid \\u escape at byte offset " & $r.pos)
    result = result * 16 + v
  inc r.pos, 4

proc parseString(r: var Reader): string =
  ## RFC 8259 §7 string. Escaped surrogates must form a pair; a decoded NUL
  ## is refused because no operating system can deliver it in an argument.
  r.skipWs
  if r.atEnd or r.data[r.pos] != '"':
    fail("malformed JSON: expected a string at byte offset " & $r.pos)
  inc r.pos
  result = ""
  while true:
    if r.atEnd:
      fail("malformed JSON: unterminated string")
    let c = r.data[r.pos]
    case c
    of '"':
      inc r.pos
      return
    of '\\':
      inc r.pos
      if r.atEnd: fail("malformed JSON: unterminated escape")
      let e = r.data[r.pos]
      inc r.pos
      case e
      of '"': result.add '"'
      of '\\': result.add '\\'
      of '/': result.add '/'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of 'u':
        let at = r.pos - 2
        var cp = r.hex4
        if cp in 0xDC00..0xDFFF:
          fail("unpaired Unicode surrogate escape at byte offset " & $at)
        if cp in 0xD800..0xDBFF:
          if r.pos + 6 > r.data.len or r.data[r.pos] != '\\' or
              r.data[r.pos + 1] != 'u':
            fail("unpaired Unicode surrogate escape at byte offset " & $at)
          inc r.pos, 2
          let low = r.hex4
          if low notin 0xDC00..0xDFFF:
            fail("unpaired Unicode surrogate escape at byte offset " & $at)
          cp = 0x10000 + ((cp - 0xD800) shl 10) + (low - 0xDC00)
        if cp == 0:
          fail("argument contains a NUL character (escape at byte offset " &
               $at & ")")
        result.add Rune(cp).toUTF8
      else:
        fail("malformed JSON: invalid escape at byte offset " & $(r.pos - 2))
    of '\0'..'\x1F':
      # Unescaped control characters, including a raw NUL, are not JSON.
      fail("malformed JSON: unescaped control character at byte offset " &
           $r.pos)
    else:
      result.add c
      inc r.pos

proc parseVersion(r: var Reader): int =
  ## Accepts a JSON number token and requires it to be the integer 1. A
  ## fraction or exponent (`1.0`, `1e0`) is not an integer.
  r.skipWs
  let start = r.pos
  if not r.atEnd and r.data[r.pos] == '-': inc r.pos
  if r.atEnd or r.data[r.pos] notin {'0'..'9'}:
    fail("\"version\" must be the integer " & $ArgsFileVersion)
  if r.data[r.pos] == '0':
    inc r.pos
  else:
    while not r.atEnd and r.data[r.pos] in {'0'..'9'}: inc r.pos
  if not r.atEnd and r.data[r.pos] in {'.', 'e', 'E'}:
    fail("\"version\" must be the integer " & $ArgsFileVersion)
  let token = r.data[start ..< r.pos]
  if not r.atEnd and r.data[r.pos] notin {' ', '\t', '\n', '\r', ',', '}'}:
    fail("malformed JSON: invalid number at byte offset " & $start)
  if token != $ArgsFileVersion:
    fail("unsupported argument file version " & token & "; this compiler " &
         "supports version " & $ArgsFileVersion)
  result = ArgsFileVersion

proc parseArgv(r: var Reader): seq[string] =
  result = @[]
  r.expect('[', "'[' starting \"argv\"")
  r.skipWs
  if not r.atEnd and r.data[r.pos] == ']':
    inc r.pos
    return
  while true:
    r.skipWs
    if r.atEnd or r.data[r.pos] != '"':
      fail("\"argv\" entry " & $result.len & " is not a string")
    result.add r.parseString
    r.skipWs
    if r.atEnd: fail("malformed JSON: unterminated \"argv\" array")
    case r.data[r.pos]
    of ',': inc r.pos
    of ']':
      inc r.pos
      return
    else: fail("malformed JSON: expected ',' or ']' at byte offset " & $r.pos)

proc parseCompilerArgs*(content: string): seq[string] =
  ## Validates `content` as a version-1 argument file and returns its logical
  ## argument vector. Raises `ArgsFileError` on any deviation from the format.
  result = @[]
  if content.len >= 3 and content[0] == '\xEF' and content[1] == '\xBB' and
      content[2] == '\xBF':
    fail("argument file starts with a UTF-8 byte order mark")
  validateUtf8(content)
  var r = Reader(data: content, pos: 0)
  var seenVersion = false
  var seenArgv = false
  r.expect('{', "'{' starting the top-level object")
  r.skipWs
  if not r.atEnd and r.data[r.pos] == '}':
    inc r.pos
  else:
    while true:
      let key = r.parseString
      r.expect(':', "':' after a field name")
      case key
      of "version":
        if seenVersion: fail("duplicate field \"version\"")
        seenVersion = true
        discard r.parseVersion
      of "argv":
        if seenArgv: fail("duplicate field \"argv\"")
        seenArgv = true
        result = r.parseArgv
      else:
        fail("unknown field \"" & key & "\"")
      r.skipWs
      if r.atEnd: fail("malformed JSON: unterminated top-level object")
      case r.data[r.pos]
      of ',': inc r.pos
      of '}':
        inc r.pos
        break
      else: fail("malformed JSON: expected ',' or '}' at byte offset " & $r.pos)
  r.skipWs
  if not r.atEnd:
    fail("malformed JSON: unexpected content after the top-level object " &
         "at byte offset " & $r.pos)
  if not seenVersion: fail("missing field \"version\"")
  if not seenArgv: fail("missing field \"argv\"")

proc readCompilerArgsFile*(path: string): seq[string] =
  ## Reads and validates the argument file at `path`. A relative `path` is
  ## resolved against the current directory, which is the caller's: the
  ## frontend reads the file before anything can change it. The file is
  ## closed and never deleted; it belongs to the caller.
  result = @[]
  if path.len == 0:
    fail("--" & ArgsFileSwitch & " requires a file path")
  var content = ""
  try:
    content = readFile(path)
  except IOError, OSError:
    fail("cannot read argument file '" & path & "': " & getCurrentExceptionMsg())
  try:
    result = parseCompilerArgs(content)
  except ArgsFileError:
    fail("invalid argument file '" & path & "': " & getCurrentExceptionMsg())
