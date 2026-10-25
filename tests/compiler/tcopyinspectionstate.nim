discard """
  targets: "c"
  cmd: "nim $target -d:nimKochBootstrap $options $file"
"""
# This is an owner metadata/state-machine test, not a runtime hook simulation.
# Direct graph construction is necessary to cover provisional and invalidated
# loader states that ordinary well-formed source cannot request at a VM site.
# Public macro integration and executing lifetime controls live separately in
# tests/macros/tgetcopyoperation*. No fake graph is used by those tests.
import compiler/[ast, modulegraphs, options, idents, lineinfos]
import std/tables

let config = newConfigRef()
let cache = newIdentCache()
let g = newModuleGraph(cache, config)
let ids = idGeneratorForPackage(10)
let typ = newType(tyObject, ids, nil)
proc operation(): PSym =
  result = newSym(skProc, cache.getIdent("=copy"), ids, nil, unknownLineInfo)
  result.ast = newNodeI(nkProcDef, unknownLineInfo, bodyPos + 1)
  for i in 0..bodyPos: result.ast[i] = newNode(nkEmpty)
  result.ast[bodyPos] = newNode(nkStmtList)

proc refused(message: string) =
  var failure: string
  doAssert g.inspectCopyBinding(typ, failure) == nil
  doAssert failure == message, failure

refused("copy operation is not resolved")
let selected = operation()
g.setAttachedOpPartial(0, typ, attachedAsgn, selected)
refused("copy operation is not resolved")
# A real empty completed body remains distinct from a provisional empty body.
g.completeOperationBody(selected)
refused("copy operation is not resolved")
g.copyBindings[typ.itemId] = selected
var failure: string
doAssert g.inspectCopyBinding(typ, failure) == selected
doAssert failure == ""
g.copyGenerationDepth = 1
selected.flagsImpl.incl sfError
refused("copy operation is still being generated")
g.copyGenerationDepth = 0
refused("copy operation is disabled")
selected.flagsImpl.excl sfError

let child = operation()
let childType = newType(tyObject, ids, nil)
g.setAttachedOpPartial(0, childType, attachedAsgn, child)
selected.ast[bodyPos].add newTree(nkCall, newSymNode(child))
refused("copy operation is not resolved")
g.completeOperationBody(child)
doAssert g.inspectCopyBinding(typ, failure) == selected
# Recursive components succeed only with every member complete.
child.ast[bodyPos].add newTree(nkCall, newSymNode(selected))
doAssert g.inspectCopyBinding(typ, failure) == selected
g.operationBodies.del(child.itemId)
refused("copy operation is not resolved")
g.completeOperationBody(child)
let replacement = operation()
g.completeOperationBody(replacement)
g.setAttachedOp(0, childType, attachedAsgn, replacement)
refused("copy operation is not resolved")
g.completeOperationBody(child)
doAssert g.inspectCopyBinding(typ, failure) == selected
config.symbolFiles = readOnlySf
refused("copy operation is not resolved")
config.symbolFiles = disabledSf
config.cmd = cmdNifC
refused("copy operation is not resolved")
config.cmd = cmdCompileToC
g.setAttachedOpPartial(0, typ, attachedAsgn, selected)
refused("copy operation is not resolved")
g.copyBindings[typ.itemId] = selected
refused("copy operation is not resolved")
g.completeOperationBody(selected)
doAssert g.inspectCopyBinding(typ, failure) == selected
g.setAttachedOp(0, typ.itemId, attachedAsgn, replacement)
refused("copy operation is not resolved")
g.copyBindings[typ.itemId] = selected # deliberately stale loaded certificate
refused("copy operation is not resolved")
g.resetForBackend()
refused("copy operation is not resolved")

# Exercise the actual generation transaction API, including nested components
# and error recovery, rather than setting a completed bit by assertion.
g.beginCopyGeneration()
g.setAttachedOpPartial(0, typ, attachedAsgn, selected)
g.completePartialOp(0, typ, attachedAsgn, selected)
g.completeCopyBinding(typ)
g.beginCopyGeneration()
g.endCopyGeneration(true)
doAssert typ.itemId notin g.copyBindings
refused("copy operation is still being generated")
g.endCopyGeneration(true)
doAssert g.inspectCopyBinding(typ, failure) == selected
g.beginCopyGeneration()
g.setAttachedOpPartial(0, typ, attachedAsgn, selected)
g.completePartialOp(0, typ, attachedAsgn, selected)
g.completeCopyBinding(typ)
inc config.errorCounter
g.endCopyGeneration(false)
config.errorCounter = 0
refused("copy operation is not resolved")
doAssert selected.itemId notin g.operationBodies
