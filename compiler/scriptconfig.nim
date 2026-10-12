#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implements the new configuration system for Nim. Uses Nim as a scripting
## language.

import
  ast, modules, idents, condsyms,
  options, llstream, vm, vmdef, commands,
  wordrecg, modulegraphs,
  pathutils, pipelines

import vm_trace, msgs, lineinfos
  # CTFS-M1: vm_trace is compiled unconditionally; per-run emission is gated
  # by `optTraceVM in conf.globalOptions and conf.traceOutputPath.len > 0`.

when defined(nimPreviewSlimSystem):
  import std/[syncio, assertions]

import std/[strtabs, os, times, osproc, sequtils]

# we support 'cmpIgnoreStyle' natively for efficiency:
from std/strutils import cmpIgnoreStyle, contains

proc listDirs(a: VmArgs, filter: set[PathComponent]) =
  let dir = getString(a, 0)
  var result: seq[string] = @[]
  for kind, path in walkDir(dir):
    if kind in filter: result.add path
  setResult(a, result)

proc setupVM*(module: PSym; cache: IdentCache; scriptName: string;
              graph: ModuleGraph; idgen: IdGenerator): PEvalContext =
  # For Nimble we need to export 'setupVM'.
  result = newCtx(module, cache, graph, idgen)
  result.mode = emRepl
  registerAdditionalOps(result)
  let conf = graph.config

  # captured vars:
  var errorMsg: string
  var vthisDir = scriptName.splitFile.dir

  # CTFS-M-IO: capture a reference to the EvalContext for the callbacks
  # so they can reach `vmTracer` to emit IO events at the call site. The
  # callbacks already close over `result` via `{.dirty.}` templates, but
  # an explicit alias keeps the trace hook readable and avoids depending
  # on dirty-template name capture for non-template code.
  let ctx = result
  template traceIoOp(a: VmArgs, kindArg: EventLogKind, payload: string) =
    ## Emit an IO event from a NimScript callback. No-op when tracing
    ## is disabled (most common case). The kind is the exact one for the
    ## operation (trace-events.md §"EventLogKind"): creating, removing or
    ## renaming a directory or file is `elkCreateDir` / `elkRemoveDir` /
    ## `elkRemoveFile` / `elkRename`, copying or writing a file is
    ## `elkWriteFile`, changing directory is `elkChangeDir`, running a
    ## command is `elkExec`, setting or removing an environment variable is
    ## `elkWriteEnv`. Reads are recorded too, with what the script observed
    ## in the payload: an environment lookup is `elkReadEnv`, an existence
    ## test or a PATH search `elkStat`, a directory listing `elkReadDir`, a
    ## file read `elkReadFile`, a line from stdin `elkRead`. The event's
    ## source position is the line of the callsite that invoked the
    ## callback (`a.currentLineInfo`, populated by vm.nim's opcIndCall
    ## dispatch).
    if ctx.vmTracer != nil:
      traceIO(cast[ptr VmTracer](ctx.vmTracer)[], kindArg,
              a.currentLineInfo, payload)

  proc listing(entries: seq[string]): string =
    "[" & strutils.join(entries, ", ") & "]"

  proc resultBool(a: VmArgs): bool =
    a.slots[a.ra].intVal != 0

  template traceAfter(name: string, body) {.dirty.} =
    ## Wrap the callback `registerAdditionalOps` installed under `name`
    ## (the `std/os` / `std/syncio` operations a script
    ## reaches by importing them) so that it records an IO event after it
    ## ran. The operation itself is the original callback, unchanged.
    block:
      let original = result.registeredCallback(name)
      if original != nil:
        result.registerCallback name,
          proc (a: VmArgs) =
            original(a)
            body

  template cbconf(name, body) {.dirty.} =
    result.registerCallback "stdlib.system." & astToStr(name),
      proc (a: VmArgs) =
        body

  template cbexc(name, exc, body) {.dirty.} =
    result.registerCallback "stdlib.system." & astToStr(name),
      proc (a: VmArgs) =
        errorMsg = ""
        try:
          body
        except exc:
          errorMsg = getCurrentExceptionMsg()

  template cbos(name, body) {.dirty.} =
    cbexc(name, OSError, body)

  # Idea: Treat link to file as a file, but ignore link to directory to prevent
  # endless recursions out of the box.
  cbos listFilesImpl:
    listDirs(a, {pcFile, pcLinkToFile})
    traceIoOp(a, elkReadDir, "listFiles: " & getString(a, 0) & " -> " &
      listing(a.slots[a.ra].node.sons.mapIt(it.strVal)))
  cbos listDirsImpl:
    listDirs(a, {pcDir})
    traceIoOp(a, elkReadDir, "listDirs: " & getString(a, 0) & " -> " &
      listing(a.slots[a.ra].node.sons.mapIt(it.strVal)))
  cbos removeDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let path = getString(a, 0)
      os.removeDir(path, getBool(a, 1))
      traceIoOp(a, elkRemoveDir, "removeDir: " & path)
  cbos removeFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let path = getString(a, 0)
      os.removeFile path
      traceIoOp(a, elkRemoveFile, "removeFile: " & path)
  cbos createDir:
    let path = getString(a, 0)
    os.createDir path
    traceIoOp(a, elkCreateDir, "createDir: " & path)

  result.registerCallback "stdlib.system.getError",
    proc (a: VmArgs) = setResult(a, errorMsg)

  cbos setCurrentDir:
    let path = getString(a, 0)
    os.setCurrentDir path
    traceIoOp(a, elkChangeDir, "setCurrentDir: " & path)
  cbos getCurrentDir:
    setResult(a, os.getCurrentDir())
  cbos moveFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.moveFile(src, dst)
      traceIoOp(a, elkRename, "moveFile: " & src & " -> " & dst)
  cbos moveDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.moveDir(src, dst)
      traceIoOp(a, elkRename, "moveDir: " & src & " -> " & dst)
  cbos copyFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.copyFile(src, dst)
      traceIoOp(a, elkWriteFile, "copyFile: " & src & " -> " & dst)
  cbos copyDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.copyDir(src, dst)
      traceIoOp(a, elkCreateDir, "copyDir: " & src & " -> " & dst)
  cbos getLastModificationTime:
    let path = getString(a, 0)
    let t = getLastModificationTime(path).toUnix
    setResult(a, t)
    traceIoOp(a, elkStat, "getLastModificationTime: " & path & " -> " & $t)
  cbos findExe:
    let bin = getString(a, 0)
    let found = os.findExe(bin)
    setResult(a, found)
    traceIoOp(a, elkStat, "findExe: " & bin & " -> " & found)

  cbos rawExec:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let cmd = getString(a, 0)
      traceIoOp(a, elkExec, "exec: " & cmd)
      setResult(a, osproc.execCmd cmd)

  cbconf getEnv:
    let key = a.getString 0
    let val = os.getEnv(key, a.getString 1)
    setResult(a, val)
    traceIoOp(a, elkReadEnv, "getEnv: " & key & " -> " & val)
  cbconf existsEnv:
    let key = a.getString 0
    let exists = os.existsEnv(key)
    setResult(a, exists)
    traceIoOp(a, elkReadEnv, "existsEnv: " & key & " -> " & $exists)
  cbconf putEnv:
    let key = a.getString 0
    let val = a.getString 1
    os.putEnv(key, val)
    traceIoOp(a, elkWriteEnv, "putEnv: " & key & "=" & val)
  cbconf delEnv:
    let key = a.getString 0
    os.delEnv(key)
    traceIoOp(a, elkWriteEnv, "delEnv: " & key)
  cbconf dirExists:
    let path = a.getString 0
    let exists = os.dirExists(path)
    setResult(a, exists)
    traceIoOp(a, elkStat, "dirExists: " & path & " -> " & $exists)
  cbconf fileExists:
    let path = a.getString 0
    let exists = os.fileExists(path)
    setResult(a, exists)
    traceIoOp(a, elkStat, "fileExists: " & path & " -> " & $exists)

  cbconf projectName:
    setResult(a, conf.projectName)
  cbconf projectDir:
    setResult(a, conf.projectPath.string)
  cbconf projectPath:
    setResult(a, conf.projectFull.string)
  cbconf thisDir:
    setResult(a, vthisDir)
  cbconf put:
    options.setConfigVar(conf, getString(a, 0), getString(a, 1))
  cbconf get:
    setResult(a, options.getConfigVar(conf, a.getString 0))
  cbconf exists:
    setResult(a, options.existsConfigVar(conf, a.getString 0))
  cbconf nimcacheDir:
    setResult(a, options.getNimcacheDir(conf).string)
  cbconf paramStr:
    setResult(a, os.paramStr(int a.getInt 0))
  cbconf paramCount:
    setResult(a, os.paramCount())
  cbconf cmpIgnoreStyle:
    setResult(a, strutils.cmpIgnoreStyle(a.getString 0, a.getString 1))
  cbconf cmpIgnoreCase:
    setResult(a, strutils.cmpIgnoreCase(a.getString 0, a.getString 1))
  cbconf setCommand:
    conf.setCommandEarly(a.getString 0)
    let arg = a.getString 1
    incl(conf.globalOptions, optWasNimscript)
    if arg.len > 0: setFromProjectName(conf, arg)
  cbconf getCommand:
    setResult(a, conf.command)
  cbconf switch:
    conf.currentConfigDir = vthisDir
    processSwitch(a.getString 0, a.getString 1, passPP, module.info, conf)
  cbconf hintImpl:
    processSpecificNote(a.getString 0, wHint, passPP, module.info,
      a.getString 1, conf)
  cbconf warningImpl:
    processSpecificNote(a.getString 0, wWarning, passPP, module.info,
      a.getString 1, conf)
  cbconf patchFile:
    let key = a.getString(0) & "_" & a.getString(1)
    var val = a.getString(2).addFileExt(NimExt)
    if {'$', '~'} in val:
      val = pathSubs(conf, val, vthisDir)
    elif not isAbsolute(val):
      val = vthisDir / val
    conf.moduleOverrides[key] = val
  cbconf selfExe:
    setResult(a, os.getAppFilename())
  cbconf cppDefine:
    options.cppDefine(conf, a.getString(0))
  cbexc stdinReadLine, EOFError:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      setResult(a, "")
    else:
      let line = stdin.readLine()
      setResult(a, line)
      traceIoOp(a, elkRead, line)
  cbexc stdinReadAll, EOFError:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      setResult(a, "")
    else:
      let text = stdin.readAll()
      setResult(a, text)
      traceIoOp(a, elkRead, text)

  # The same operations reached through `std/os` and `std/syncio` run
  # `registerAdditionalOps`' callbacks; record those too. (`std/envvars`
  # is not reachable from a script: NimScript's own `getEnv` and friends
  # above are the ones it calls.)
  traceAfter "stdlib.syncio.readFile":
    traceIoOp(a, elkReadFile, "readFile: " & getString(a, 0))
  traceAfter "stdlib.syncio.readLines":
    traceIoOp(a, elkReadFile, "readLines: " & getString(a, 0))
  traceAfter "stdlib.syncio.writeFile":
    traceIoOp(a, elkWriteFile, "writeFile: " & getString(a, 0))
  traceAfter "stdlib.oscommon.dirExists":
    traceIoOp(a, elkStat, "dirExists: " & getString(a, 0) & " -> " &
      $resultBool(a))
  traceAfter "stdlib.oscommon.fileExists":
    traceIoOp(a, elkStat, "fileExists: " & getString(a, 0) & " -> " &
      $resultBool(a))
  traceAfter "stdlib.osdirs.createDir":
    traceIoOp(a, elkCreateDir, "createDir: " & getString(a, 0))

proc runNimScript*(cache: IdentCache; scriptName: AbsoluteFile;
                   idgen: IdGenerator;
                   freshDefines=true; conf: ConfigRef, stream: PLLStream) =
  let oldSymbolFiles = conf.symbolFiles
  conf.symbolFiles = disabledSf

  let graph = newModuleGraph(cache, conf)
  connectPipelineCallbacks(graph)
  if freshDefines: initDefines(conf.symbols)

  defineSymbol(conf.symbols, "nimscript")
  defineSymbol(conf.symbols, "nimconfig")

  conf.searchPaths.add(conf.libpath)

  let oldGlobalOptions = conf.globalOptions
  let oldSelectedGC = conf.selectedGC
  unregisterArcOrc(conf)
  conf.globalOptions.excl optOwnedRefs
  conf.selectedGC = gcUnselected
  conf.globalOptions.incl optWithinConfigSystem

  var m = graph.makeModule(scriptName)
  incl(m, sfMainModule)
  var vm = setupVM(m, cache, scriptName.string, graph, idgen)
  graph.vm = vm

  # CTFS-M1: only trace for `nim e` (cmdNimscript), not config file processing.
  # Gating is fully runtime (--trace:<path>); the compiler always carries
  # the emission code.
  if optTraceVM in conf.globalOptions and conf.traceOutputPath.len > 0 and
     conf.cmd == cmdNimscript:
    let tracerRes = initVmTracer(conf.traceOutputPath, scriptName.string, conf)
    if tracerRes.isOk:
      vm.vmTracer = tracerRes.get()
    else:
      rawMessage(conf, warnUser, "failed to initialize VM tracer: " & tracerRes.error)

  graph.setPipeLinePass(EvalPass)
  graph.compilePipelineSystemModule()
  discard graph.processPipelineModule(m, vm.idgen, stream)

  if vm.vmTracer != nil:
    let closeRes = closeVmTracer(cast[ptr VmTracer](vm.vmTracer))
    if closeRes.isErr:
      rawMessage(conf, warnUser, "failed to close VM tracer: " & closeRes.error)
    vm.vmTracer = nil

  # watch out, "newruntime" can be set within NimScript itself and then we need
  # to remember this:
  if conf.selectedGC == gcUnselected:
    conf.selectedGC = oldSelectedGC
  if optOwnedRefs in oldGlobalOptions:
    conf.globalOptions.incl {optTinyRtti, optOwnedRefs, optSeqDestructors}
    defineSymbol(conf.symbols, "nimv2")
  if conf.selectedGC in {gcArc, gcOrc, gcYrc, gcAtomicArc}:
    conf.globalOptions.incl {optTinyRtti, optSeqDestructors}
    defineSymbol(conf.symbols, "nimv2")
    defineSymbol(conf.symbols, "gcdestructors")
    defineSymbol(conf.symbols, "nimSeqsV2")
    case conf.selectedGC
    of gcArc:
      defineSymbol(conf.symbols, "gcarc")
    of gcOrc:
      defineSymbol(conf.symbols, "gcorc")
    of gcYrc:
      defineSymbol(conf.symbols, "gcyrc")
    of gcAtomicArc:
      defineSymbol(conf.symbols, "gcatomicarc")
    else:
      raiseAssert "unreachable"

  # ensure we load 'system.nim' again for the real non-config stuff!
  resetSystemArtifacts(graph)
  # do not remove the defined symbols
  #initDefines()
  undefSymbol(conf.symbols, "nimscript")
  undefSymbol(conf.symbols, "nimconfig")
  conf.globalOptions.excl optWithinConfigSystem
  conf.symbolFiles = oldSymbolFiles
