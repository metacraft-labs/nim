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

import std/[strtabs, os, times, osproc]

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
  template traceIoOp(a: VmArgs, kindArg: IOEventKind, payload: string) =
    ## Emit an IO event from a NimScript callback. No-op when tracing
    ## is disabled (most common case). The event's source position is
    ## the line of the callsite that invoked the callback
    ## (`a.currentLineInfo`, populated by vm.nim's opcIndCall dispatch).
    if ctx.vmTracer != nil:
      traceIO(cast[ptr VmTracer](ctx.vmTracer)[], kindArg,
              a.currentLineInfo, payload)

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
  cbos listDirsImpl:
    listDirs(a, {pcDir})
  cbos removeDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let path = getString(a, 0)
      os.removeDir(path, getBool(a, 1))
      traceIoOp(a, ioFileOp, "removeDir: " & path)
  cbos removeFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let path = getString(a, 0)
      os.removeFile path
      traceIoOp(a, ioFileOp, "removeFile: " & path)
  cbos createDir:
    let path = getString(a, 0)
    os.createDir path
    traceIoOp(a, ioFileOp, "createDir: " & path)

  result.registerCallback "stdlib.system.getError",
    proc (a: VmArgs) = setResult(a, errorMsg)

  cbos setCurrentDir:
    let path = getString(a, 0)
    os.setCurrentDir path
    traceIoOp(a, ioFileOp, "setCurrentDir: " & path)
  cbos getCurrentDir:
    setResult(a, os.getCurrentDir())
  cbos moveFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.moveFile(src, dst)
      traceIoOp(a, ioFileOp, "moveFile: " & src & " -> " & dst)
  cbos moveDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.moveDir(src, dst)
      traceIoOp(a, ioFileOp, "moveDir: " & src & " -> " & dst)
  cbos copyFile:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.copyFile(src, dst)
      traceIoOp(a, ioFileOp, "copyFile: " & src & " -> " & dst)
  cbos copyDir:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let src = getString(a, 0)
      let dst = getString(a, 1)
      os.copyDir(src, dst)
      traceIoOp(a, ioFileOp, "copyDir: " & src & " -> " & dst)
  cbos getLastModificationTime:
    setResult(a, getLastModificationTime(getString(a, 0)).toUnix)
  cbos findExe:
    setResult(a, os.findExe(getString(a, 0)))

  cbos rawExec:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      discard
    else:
      let cmd = getString(a, 0)
      traceIoOp(a, ioFileOp, "exec: " & cmd)
      setResult(a, osproc.execCmd cmd)

  cbconf getEnv:
    setResult(a, os.getEnv(a.getString 0, a.getString 1))
  cbconf existsEnv:
    setResult(a, os.existsEnv(a.getString 0))
  cbconf putEnv:
    let key = a.getString 0
    let val = a.getString 1
    os.putEnv(key, val)
    traceIoOp(a, ioFileOp, "putEnv: " & key & "=" & val)
  cbconf delEnv:
    let key = a.getString 0
    os.delEnv(key)
    traceIoOp(a, ioFileOp, "delEnv: " & key)
  cbconf dirExists:
    setResult(a, os.dirExists(a.getString 0))
  cbconf fileExists:
    setResult(a, os.fileExists(a.getString 0))

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
      setResult(a, stdin.readLine())
  cbexc stdinReadAll, EOFError:
    if defined(nimsuggest) or graph.config.cmd == cmdCheck:
      setResult(a, "")
    else:
      setResult(a, stdin.readAll())

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
