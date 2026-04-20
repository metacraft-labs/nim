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
## Gated behind `-d:codetracerTracing` — never compiled into the standard
## Nim compiler.

when not defined(codetracerTracing):
  {.error: "vm_trace.nim requires -d:codetracerTracing".}

import std/tables
import msgs, options, lineinfos
import results
export results
import codetracer_trace_writer
import codetracer_trace_types

type
  VmTracer* = object
    writer*: TraceWriter
    lastLine*: uint32
    lastFileIndex*: int32
    paths*: Table[int32, uint64]      ## fileIndex → registered pathId
    functions*: Table[string, uint64] ## name → functionId
    nextPathId*: uint64
    nextFunctionId*: uint64
    depth*: int
    config*: ConfigRef

proc ensurePath(tracer: var VmTracer, fileIndex: int32): uint64 =
  ## Register a file path if not already registered, return its pathId.
  if fileIndex in tracer.paths:
    return tracer.paths[fileIndex]

  let pathId = tracer.nextPathId
  tracer.nextPathId += 1

  let fullPath = toFullPath(tracer.config, FileIndex(fileIndex))
  let res = tracer.writer.writePath(fullPath)
  if res.isErr:
    discard # silently ignore write errors for now

  tracer.paths[fileIndex] = pathId
  return pathId

proc ensureFunction(tracer: var VmTracer, name: string,
                    info: TLineInfo): uint64 =
  ## Register a function if not already registered, return its functionId.
  if name in tracer.functions:
    return tracer.functions[name]

  let funcId = tracer.nextFunctionId
  tracer.nextFunctionId += 1

  let pathId = tracer.ensurePath(int32(info.fileIndex))
  let res = tracer.writer.writeFunction(pathId, int64(info.line), name)
  if res.isErr:
    discard # silently ignore write errors for now

  tracer.functions[name] = funcId
  return funcId

proc initVmTracer*(outputPath: string, scriptPath: string,
                   config: ConfigRef): Result[ptr VmTracer, string] =
  ## Create a new VmTracer. Returns a heap-allocated pointer suitable
  ## for storing in TCtx.vmTracer.
  let writerRes = newTraceWriter(
    path = outputPath,
    program = scriptPath,
    args = @[],
    workdir = "",
  )
  if writerRes.isErr:
    return err("failed to create trace writer: " & writerRes.error)

  var tracer = cast[ptr VmTracer](alloc0(sizeof(VmTracer)))
  tracer[] = VmTracer(
    writer: writerRes.get(),
    lastLine: 0,
    lastFileIndex: -1,
    paths: initTable[int32, uint64](),
    functions: initTable[string, uint64](),
    nextPathId: 0,
    nextFunctionId: 1, # 0 is reserved for TopLevelFunctionId
    depth: 0,
    config: config,
  )
  ok(tracer)

proc traceStep*(tracer: var VmTracer, info: TLineInfo) =
  ## Emit a Step event if the source line changed since last step.
  ## This avoids flooding on instructions that map to the same line.
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
  let res = tracer.writer.writeStep(pathId, int64(line))
  if res.isErr:
    discard

proc traceCall*(tracer: var VmTracer, name: string, info: TLineInfo) =
  ## Emit a Call event.
  let funcId = tracer.ensureFunction(name, info)
  let res = tracer.writer.writeCall(funcId)
  if res.isErr:
    discard
  tracer.depth += 1

proc traceReturn*(tracer: var VmTracer) =
  ## Emit a Return event.
  if tracer.depth > 0:
    tracer.depth -= 1
  let res = tracer.writer.writeReturn()
  if res.isErr:
    discard

proc closeVmTracer*(tracer: ptr VmTracer): Result[void, string] =
  ## Close the trace writer and free the VmTracer.
  if tracer == nil:
    return ok()
  let res = tracer.writer.close()
  dealloc(tracer)
  return res
