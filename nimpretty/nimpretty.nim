#
#
#           The Nim Compiler
#        (c) Copyright 2017 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Standard tool for pretty printing.

when not defined(nimpretty):
  {.error: "This needs to be compiled with --define:nimPretty".}

import ../compiler / [idents, llstream, ast, msgs, syntaxes, options, pathutils, layouter]

import parseopt, strutils, os, sequtils

import std/tempfiles

const
  Version = "0.2"
  Usage = "nimpretty - Nim Pretty Printer Version " & Version & """

  (c) 2017 Andreas Rumpf
Usage:
  nimpretty [options] nimfiles...
Options:
  --out:file            set the output file (default: overwrite the input file)
  --outDir:dir          set the output dir (default: overwrite the input files)
  --checkEquivalent:file compare the input AST with file; write nothing
  --stdin               read input from stdin and write output to stdout
  --indent:N[=0]        set the number of spaces that is used for indentation
                        --indent:0 means autodetection (default behaviour)
  --maxLineLen:N        set the desired maximum line length (default: 80)
  --version             show the version
  --help                show this help
"""

proc writeHelp() =
  stdout.write(Usage)
  stdout.flushFile()
  quit(0)

proc writeVersion() =
  stdout.write(Version & "\n")
  stdout.flushFile()
  quit(0)

type
  PrettyOptions* = object
    indWidth*: Natural
    maxLineLen*: Positive

proc goodEnough(a, b: PNode): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.kind == b.kind and a.flags == b.flags and a.safeLen == b.safeLen:
    case a.kind
    of nkNone, nkEmpty, nkNilLit: result = true
    of nkIdent: result = a.ident.s == b.ident.s
    of nkSym: result = false # A parsed source must not contain resolved symbols.
    of nkType: result = false # Refuse unsupported semantic nodes conservatively.
    of nkCharLit, nkIntLit..nkInt64Lit, nkUIntLit..nkUInt64Lit:
      result = a.intVal == b.intVal
    of nkFloatLit..nkFloat128Lit:
      result = a.floatVal == b.floatVal
    of nkStrLit, nkRStrLit, nkTripleStrLit:
      result = a.strVal == b.strVal
    else:
      for i in 0 ..< a.len:
        if not goodEnough(a[i], b[i]): return false
      return true
  elif a.kind == nkStmtList and a.len == 1:
    result = goodEnough(a[0], b)
  elif b.kind == nkStmtList and b.len == 1:
    result = goodEnough(a, b[0])
  else:
    result = false

proc finalCheck(content: string; origAst: PNode): bool {.nimcall.} =
  var conf = newConfigRef()
  let oldErrors = conf.errorCounter
  var parser: Parser
  parser.em.indWidth = 2
  let fileIdx = fileInfoIdx(conf, AbsoluteFile "nimpretty_bug.nim")

  openParser(parser, fileIdx, llStreamOpen(content), newIdentCache(), conf)
  let newAst = parseAll(parser)
  closeParser(parser)
  result = conf.errorCounter == oldErrors and goodEnough(newAst, origAst)
  if not result:
    raise newException(ValueError, "formatted output changes parsed meaning")

proc equivalentFiles*(original, candidate: string): bool =
  ## Compare parsed source meaning, including indentation and pragma structure.
  ## Identifier spellings are compared, never cache-local numeric identifiers.
  var conf = newConfigRef()
  let cache = newIdentCache()
  proc parseFile(path: string): PNode =
    var parser: Parser
    openParser(parser, fileInfoIdx(conf, AbsoluteFile absolutePath(path)),
               llStreamOpen(readFile(path)), cache, conf)
    result = parseAll(parser)
    closeParser(parser)
  let a = parseFile(original)
  let b = parseFile(candidate)
  result = conf.errorCounter == 0 and goodEnough(a, b)

proc prettyPrint*(infile, outfile: string; opt: PrettyOptions) =
  var conf = newConfigRef()
  let fileIdx = fileInfoIdx(conf, AbsoluteFile infile)
  let f = splitFile(outfile.expandTilde)
  conf.outFile = RelativeFile f.name & f.ext
  conf.outDir = toAbsoluteDir f.dir
  var parser: Parser
  parser.em.indWidth = opt.indWidth
  if setupParser(parser, fileIdx, newIdentCache(), conf):
    parser.em.maxLineLen = opt.maxLineLen
    let fullAst = parseAll(parser)
    closeParser(parser)
    when defined(nimpretty):
      closeEmitter(parser.em, fullAst, finalCheck)

proc handleStdinInput(opt: PrettyOptions) =
  var content = readAll(stdin)

  var (cfile, path) = createTempFile("nimpretty_", ".nim")

  writeFile(path, content)

  prettyPrint(path, path, opt)

  stdout.write(readAll(cfile))

  close(cfile)
  removeFile(path)

proc main =
  var outfile, outdir, equivalentTo: string

  var infiles = newSeq[string]()
  var outfiles = newSeq[string]()

  var isStdin = false

  var backup = false
    # when `on`, create a backup file of input in case
    # `prettyPrint` could overwrite it (note that the backup may happen even
    # if input is not actually overwritten, when nimpretty is a noop).
    # --backup was un-documented (rely on git instead).
  var opt = PrettyOptions(indWidth: 0, maxLineLen: 80)

  for kind, key, val in getopt():
    case kind
    of cmdArgument:
      if dirExists(key):
        for file in walkDirRec(key, skipSpecial = true):
          if file.endsWith(".nim") or file.endsWith(".nimble"):
            infiles.add(file)
      else:
        infiles.add(key.addFileExt(".nim"))

    of cmdLongOption, cmdShortOption:
      case normalize(key)
      of "help", "h": writeHelp()
      of "version", "v": writeVersion()
      of "backup": backup = parseBool(val)
      of "checkequivalent": equivalentTo = val
      of "output", "o", "out": outfile = val
      of "outDir", "outdir": outdir = val
      of "indent": opt.indWidth = parseInt(val)
      of "maxlinelen": opt.maxLineLen = parseInt(val)
      # "" is equal to '-' as input
      of "stdin", "": isStdin = true
      else: quit "[Error] unknown option: " & key
    of cmdEnd: assert(false) # cannot happen

  if equivalentTo.len > 0:
    if infiles.len != 1 or isStdin or outfile.len > 0 or outdir.len > 0:
      quit "[Error] checkEquivalent requires one input and no output options"
    if not equivalentFiles(equivalentTo, infiles[0]):
      quit "[Error] formatted output changes parsed meaning"
    return

  if isStdin:
    handleStdinInput(opt)
    return

  if infiles.len == 0:
    quit "[Error] no input file."

  if outfile.len != 0 and outdir.len != 0:
    quit "[Error] out and outDir cannot both be specified"

  if outfile.len == 0 and outdir.len == 0:
    outfiles = infiles
  elif outfile.len != 0 and infiles.len > 1:
    # Take the last file to maintain backwards compatibility
    let infile = infiles[^1]
    infiles = @[infile]
    outfiles = @[outfile]
  elif outfile.len != 0:
    outfiles = @[outfile]
  elif outdir.len != 0:
    outfiles = infiles.mapIt($(joinPath(outdir, it)))

  for (infile, outfile) in zip(infiles, outfiles):
    let (dir, _, _) = splitFile(outfile)
    createDir(dir)
    if not fileExists(outfile) or not sameFile(infile, outfile):
      backup = false # no backup needed since won't be over-written
    if backup:
      let infileBackup = infile & ".backup" # works with .nim or .nims
      echo "writing backup " & infile & " > " & infileBackup
      os.copyFile(source = infile, dest = infileBackup)
    prettyPrint(infile, outfile, opt)

when isMainModule:
  main()
