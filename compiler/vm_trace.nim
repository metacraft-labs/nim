#
#
#           The Nim Compiler
#        (c) Copyright 2024 Metacraft Labs
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## VM execution tracing for CodeTracer.
##
## This module handles all tracing operations, isolated from the main VM code.
## It writes .ct trace files using the CodeTracer trace format (CTFS).
##
## CTFS-M1 update: vm_trace is now compiled unconditionally into `bin/nim`.
## Per-run emission is gated solely by the runtime flag `--trace:<path>`
## (i.e. `optTraceVM in conf.globalOptions and conf.traceOutputPath.len > 0`);
## when the flag is absent, the call sites in vm.nim see `c.vmTracer == nil`
## and short-circuit, so the dormant cost is one nil-check per relevant op.
##
## CTFS-M-Fix update: ported from the legacy v3 single-stream `TraceWriter`
## to the v4 `MultiStreamTraceWriter`. The v4 model attaches variable values
## to the step that *follows* them in the emission sequence — a register write
## is observable at the next source line. Concretely:
##   * `traceAssignment` builds a `VariableValue` and appends it to
##     `pendingValues`.
##   * `traceStep` flushes `pendingValues` into the next `registerStep` call
##     and then clears the buffer.
##   * `traceCall` and `traceReturn` flush any leftover `pendingValues` via a
##     synthetic step at the *last known* (path, line) before recording the
##     call/return, so no values are silently dropped.
##   * `closeVmTracer` flushes any final leftover `pendingValues` via a
##     synthetic step at the last known (path, line), then finalises the
##     CTFS container and serialises it to disk. The v4 CTFS container is
##     in-memory only — `close` writes the meta.dat / interning tables /
##     stream files into the container, and `toBytes` produces the on-disk
##     blob that the materializer / `ct-print` consume.
##
## Variable identification: the VM does not surface variable names at the
## per-instruction tracing sites (`traceAssignment(reg)` only sees the
## register, not its bound symbol). We therefore emit each value under a
## synthetic varname `r<N>` (one per assignment) so it round-trips through
## the interning table. Mapping these back to source-level variables is a
## later milestone; here we only need the materializer to surface
## non-empty `events` / `paths` / `functions` arrays.

import std/[tables, syncio]
import msgs, options, lineinfos
import ast
import results
export results
import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/value_stream
import codetracer_trace_writer/cbor
import codetracer_trace_types
import vm_value_serializer
import vmdef

type
  VmTracer* = object
    writer*: MultiStreamTraceWriter
    outputPath*: string                 ## destination .ct path
    lastLine*: uint32
    lastFileIndex*: int32
    lastPathId*: uint64                 ## last pathId actually emitted
    lastEmittedLine*: uint64            ## last line actually emitted
    haveLastEmitted*: bool              ## true after the first registerStep
    paths*: Table[int32, uint64]        ## fileIndex → registered pathId
    functions*: Table[string, uint64]   ## name → functionId
    typeNames*: Table[string, uint64]   ## type name → typeId
    nextVariableIndex*: uint64          ## counter for synthetic r<N> varnames
    pendingValues*: seq[VariableValue]  ## values buffered between steps
    depth*: int
    config*: ConfigRef

proc ensurePath(tracer: var VmTracer, fileIndex: int32): uint64 =
  ## Register a file path if not already registered, return its pathId.
  if fileIndex in tracer.paths:
    return tracer.paths[fileIndex]

  let fullPath = toFullPath(tracer.config, FileIndex(fileIndex))
  let res = tracer.writer.registerPath(fullPath)
  if res.isErr:
    # Path registration failed; cache 0 to avoid retrying and continue.
    tracer.paths[fileIndex] = 0
    return 0

  let pathId = res.get()
  tracer.paths[fileIndex] = pathId
  return pathId

proc ensureFunction(tracer: var VmTracer, name: string): uint64 =
  ## Register a function name if not already registered, return its functionId.
  if name in tracer.functions:
    return tracer.functions[name]

  let res = tracer.writer.registerFunction(name)
  if res.isErr:
    tracer.functions[name] = 0
    return 0

  let funcId = res.get()
  tracer.functions[name] = funcId
  return funcId

proc ensureTypeName(tracer: var VmTracer, name: string): uint64 =
  ## Register a type name in the interning table, returning its typeId.
  if name.len == 0:
    return 0
  if name in tracer.typeNames:
    return tracer.typeNames[name]
  let res = tracer.writer.registerType(name)
  if res.isErr:
    tracer.typeNames[name] = 0
    return 0
  let tid = res.get()
  tracer.typeNames[name] = tid
  return tid

proc encodeValue(v: ValueRecord): seq[byte] =
  ## CBOR-encode a ValueRecord for storage in the value stream.
  ## Initialise CborEncoder by hand (rather than via its `init` template)
  ## because the compiler is built with `--experimental:strictDefs` and
  ## `--warningAsError:Uninit`, which trips on `init`'s partial-result
  ## construction.
  var enc = CborEncoder(buf: newSeqOfCap[byte](256))
  enc.encodeCborValueRecord(v)
  enc.getBytes()

proc typeNameForReg(reg: TFullReg, typ: PType): string =
  ## Pick a reasonable type name for interning. Prefers the explicit `typ`,
  ## falls back to the register kind, finally an empty string.
  if typ != nil:
    case typ.kind
    of tyBool: return "bool"
    of tyChar: return "char"
    of tyString: return "string"
    of tyCstring: return "cstring"
    of tyInt..tyInt64: return "int"
    of tyUInt..tyUInt64: return "uint"
    of tyFloat..tyFloat128: return "float"
    of tyEnum: return "enum"
    else: discard
  case reg.kind
  of rkInt: return "int"
  of rkFloat: return "float"
  of rkNode: return "node"
  of rkNone: return "none"
  of rkRegisterAddr, rkNodeAddr: return "address"

proc flushPendingValuesAsStep(tracer: var VmTracer) =
  ## If there are buffered values without a following step, emit a synthetic
  ## step at the last known (path, line) so the values are recoverable. This
  ## is used by traceCall / traceReturn / closeVmTracer to avoid dropping
  ## values when no further `traceStep` will arrive before the transition.
  if tracer.pendingValues.len == 0:
    return
  if not tracer.haveLastEmitted:
    # No step has ever been emitted; we have no (path,line) to attach values
    # to. Drop them — the trace has no observable state to anchor them on.
    tracer.pendingValues.setLen(0)
    return
  let res = tracer.writer.registerStep(tracer.lastPathId,
                                       tracer.lastEmittedLine,
                                       tracer.pendingValues)
  if res.isErr:
    discard
  tracer.pendingValues.setLen(0)

proc initVmTracer*(outputPath: string, scriptPath: string,
                   config: ConfigRef): Result[ptr VmTracer, string] =
  ## Create a new VmTracer. Returns a heap-allocated pointer suitable
  ## for storing in TCtx.vmTracer.
  let writerRes = initMultiStreamWriter(outputPath, scriptPath)
  if writerRes.isErr:
    return err("failed to create trace writer: " & writerRes.error)

  var tracer = cast[ptr VmTracer](alloc0(sizeof(VmTracer)))
  tracer[] = VmTracer(
    writer: writerRes.get(),
    outputPath: outputPath,
    lastLine: 0,
    lastFileIndex: -1,
    lastPathId: 0,
    lastEmittedLine: 0,
    haveLastEmitted: false,
    paths: initTable[int32, uint64](),
    functions: initTable[string, uint64](),
    typeNames: initTable[string, uint64](),
    nextVariableIndex: 0,
    pendingValues: @[],
    depth: 0,
    config: config,
  )
  ok(tracer)

proc traceStep*(tracer: var VmTracer, info: TLineInfo) =
  ## Emit a Step event if the source line changed since last step.
  ## This avoids flooding on instructions that map to the same line.
  ## Any pending values accumulated since the last step are attached.
  let fileIdx = int32(info.fileIndex)
  let line = info.line

  # Skip unknown/invalid line info
  if fileIdx < 0 or line == 0:
    return

  # Only emit on line/file change
  if line == tracer.lastLine and fileIdx == tracer.lastFileIndex:
    return

  tracer.lastLine = line
  tracer.lastFileIndex = fileIdx

  let pathId = tracer.ensurePath(fileIdx)
  let res = tracer.writer.registerStep(pathId, uint64(line),
                                       tracer.pendingValues)
  if res.isErr:
    discard
  tracer.pendingValues.setLen(0)
  tracer.lastPathId = pathId
  tracer.lastEmittedLine = uint64(line)
  tracer.haveLastEmitted = true

proc traceCall*(tracer: var VmTracer, name: string, info: TLineInfo) =
  ## Emit a Call event.
  flushPendingValuesAsStep(tracer)
  let funcId = tracer.ensureFunction(name)
  let res = tracer.writer.registerCall(funcId, [])
  if res.isErr:
    discard
  tracer.depth += 1

proc traceReturn*(tracer: var VmTracer) =
  ## Emit a Return event.
  flushPendingValuesAsStep(tracer)
  if tracer.depth > 0:
    tracer.depth -= 1
  # Use the default void-return marker (empty seq → VoidReturnMarker).
  let res = tracer.writer.registerReturn(@[])
  if res.isErr:
    discard

proc traceAssignment*(tracer: var VmTracer, reg: TFullReg,
                      typ: PType = nil) =
  ## Buffer a Value event for a register-writing opcode.
  ## Serializes the register value and queues it; it is flushed as part of
  ## the next `traceStep` (or via `flushPendingValuesAsStep` on transition).
  let value = serializeVmValue(reg, typ)
  let typeName = typeNameForReg(reg, typ)
  let typeId = tracer.ensureTypeName(typeName)

  # Synthetic varname per assignment so each value has a recoverable id.
  let varIndex = tracer.nextVariableIndex
  tracer.nextVariableIndex += 1
  let varRes = tracer.writer.registerVarname("r" & $varIndex)
  let varnameId =
    if varRes.isErr: 0'u64
    else: varRes.get()

  tracer.pendingValues.add(VariableValue(
    varnameId: varnameId,
    typeId: typeId,
    data: encodeValue(value),
  ))

proc syncVmTracer*(tracer: ptr VmTracer) =
  ## Flush trace data to disk for concurrent readers.
  ##
  ## CTFS-M-Fix: the v4 MultiStreamTraceWriter builds the CTFS container in
  ## memory and only serialises on close, so there is no meaningful
  ## incremental flush available. This is intentionally a no-op; concurrent
  ## reader support for v4 is a later milestone.
  if tracer == nil:
    return

proc closeVmTracer*(tracer: ptr VmTracer): Result[void, string] =
  ## Close the trace writer and free the VmTracer.
  if tracer == nil:
    return ok()

  # Flush any leftover pending values via a synthetic step at the last
  # emitted (path, line) so we don't silently drop final assignments.
  flushPendingValuesAsStep(tracer[])

  # Finalise the in-memory CTFS container (writes interning tables, stream
  # files and meta.dat into the container).
  let closeRes = tracer.writer.close()
  if closeRes.isErr:
    let path = tracer.outputPath
    let msg = closeRes.error
    tracer.writer.closeCtfs()
    dealloc(tracer)
    return err("failed to close trace writer for " & path & ": " & msg)

  # Serialise the container and write it to disk. v4 is in-memory only,
  # unlike the v3 streaming writer, so this is the point where the .ct
  # file actually appears.
  let bytes = tracer.writer.toBytes()
  let path = tracer.outputPath
  try:
    writeFile(path, cast[string](bytes))
  except IOError as e:
    tracer.writer.closeCtfs()
    dealloc(tracer)
    return err("failed to write trace to " & path & ": " & e.msg)
  except OSError as e:
    tracer.writer.closeCtfs()
    dealloc(tracer)
    return err("failed to write trace to " & path & ": " & e.msg)

  tracer.writer.closeCtfs()
  dealloc(tracer)
  return ok()
