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

import std/[tables, syncio, os, strutils]
import msgs, options, lineinfos
import ast
import results
export results
import codetracer_trace_writer/multi_stream_writer
import codetracer_trace_writer/value_stream
import codetracer_trace_writer/cbor
import codetracer_trace_writer/path_filter
import codetracer_trace_types
import vm_value_serializer
import vmdef

const builtinNimVmFilterToml* = """
[meta]
name = "builtin-nim-vm-default"
version = 1
description = "Default Nim VM tracer filter - skip stdlib"

[scope]
default_exec = "trace"

[[scope.rules]]
selector = "file:glob:**/lib/system.nim"
exec = "skip"
reason = "Skip the main system module"

[[scope.rules]]
selector = "file:glob:**/lib/system/**"
exec = "skip"
reason = "Skip Nim stdlib system/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/std/**"
exec = "skip"
reason = "Skip Nim stdlib std/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/pure/**"
exec = "skip"
reason = "Skip Nim stdlib pure/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/core/**"
exec = "skip"
reason = "Skip Nim stdlib core/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/impure/**"
exec = "skip"
reason = "Skip Nim stdlib impure/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/posix/**"
exec = "skip"
reason = "Skip Nim stdlib posix/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/windows/**"
exec = "skip"
reason = "Skip Nim stdlib windows/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/wrappers/**"
exec = "skip"
reason = "Skip Nim stdlib wrappers/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/deprecated/**"
exec = "skip"
reason = "Skip Nim stdlib deprecated/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/experimental/**"
exec = "skip"
reason = "Skip Nim stdlib experimental/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/genode/**"
exec = "skip"
reason = "Skip Nim stdlib genode/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/js/**"
exec = "skip"
reason = "Skip Nim stdlib js/ subtree"

[[scope.rules]]
selector = "file:glob:**/lib/arch/**"
exec = "skip"
reason = "Skip Nim stdlib arch/ subtree"
"""
  ## TF-M4 builtin default trace-filter (TOML).
  ##
  ## Skips the entire Nim stdlib so that the resulting trace only contains
  ## events from user code. Subsequent filter sources (auto-discovered file,
  ## env var, --trace-filter flags) override these decisions per spec § 5.

type
  ## TF-M4 sentinel for the FileIndex-keyed classification cache.
  ##
  ## We cache the classification decision in a dense seq indexed by
  ## `FileIndex.int32`. Entries take one of three states:
  ##   * `pcUnclassified` — never seen, run the classifier on first access.
  ##   * `pcSkip`         — classifier decided to skip this path.
  ##   * `pcTrace`        — classifier decided to trace; `pathId` is the
  ##                        writer-registered id.
  PathCacheKind* = enum
    pcUnclassified
    pcSkip
    pcTrace

  PathCacheEntry* = object
    kind*: PathCacheKind
    pathId*: uint64

  VmTracer* = object
    writer*: MultiStreamTraceWriter
    outputPath*: string                 ## destination .ct path
    lastLine*: uint32
    lastFileIndex*: int32
    lastPathId*: uint64                 ## last pathId actually emitted
    lastEmittedLine*: uint64            ## last line actually emitted
    haveLastEmitted*: bool              ## true after the first registerStep
    pathCache*: seq[PathCacheEntry]     ## TF-M4: dense FileIndex-keyed cache
    functions*: Table[string, uint64]   ## name → functionId
    typeNames*: Table[string, uint64]   ## type name → typeId
    nextVariableIndex*: uint64          ## counter for synthetic r<N> varnames
    pendingValues*: seq[VariableValue]  ## values buffered between steps
    depth*: int
    config*: ConfigRef
    filter*: Classifier                 ## TF-M4: cross-language trace filter

proc ensurePath(tracer: var VmTracer, fileIndex: int32,
                skip: var bool): uint64 =
  ## TF-M4: classify-once-per-FileIndex, cached in a dense seq.
  ##
  ## Sets `skip = true` if the classifier decided to skip this path or if
  ## the index is invalid; in that case the returned pathId is meaningless.
  ## Otherwise returns the registered pathId (which may legitimately be 0
  ## since the interning table is 0-indexed). Per spec § 6 the hot path is
  ## a single array deref after the first access — no hashes or repeated
  ## classification.
  skip = false
  if fileIndex < 0:
    skip = true
    return 0
  let idx = int(fileIndex)
  if idx < tracer.pathCache.len:
    let entry = tracer.pathCache[idx]
    case entry.kind
    of pcSkip:
      skip = true
      return 0
    of pcTrace:
      return entry.pathId
    of pcUnclassified: discard  # fall through to classify
  else:
    tracer.pathCache.setLen(idx + 1)

  let fullPath = toFullPath(tracer.config, FileIndex(fileIndex))
  let decision = classify(tracer.filter, fullPath)
  if decision.exec == eaSkip:
    tracer.pathCache[idx] = PathCacheEntry(kind: pcSkip, pathId: 0)
    skip = true
    return 0

  let res = tracer.writer.registerPath(fullPath)
  if res.isErr:
    # Path registration failed; cache as skip to avoid retrying and continue.
    tracer.pathCache[idx] = PathCacheEntry(kind: pcSkip, pathId: 0)
    skip = true
    return 0

  let pathId = res.get()
  tracer.pathCache[idx] = PathCacheEntry(kind: pcTrace, pathId: pathId)
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

proc findAutoFilter*(scriptPath: string): string =
  ## TF-M4: walk upward from `scriptPath`'s directory looking for a
  ## `.codetracer/trace-filter.toml`. Returns the absolute path on the first
  ## hit, or "" if none is found.
  if scriptPath.len == 0:
    return ""
  var dir = ""
  try:
    let abs =
      if isAbsolute(scriptPath): scriptPath
      else: absolutePath(scriptPath)
    dir = parentDir(abs)
  except OSError:
    return ""
  except ValueError:
    return ""
  while dir.len > 0:
    let candidate = dir / ".codetracer" / "trace-filter.toml"
    if fileExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  return ""

proc parseEnvFilterPaths*(envValue: string): seq[string] =
  ## TF-M4: parse `CODETRACER_TRACE_FILTER` — `::`-separated path list.
  ## Empty entries are skipped.
  result = @[]
  if envValue.len == 0:
    return
  var i = 0
  while i < envValue.len:
    let nextSep = envValue.find("::", i)
    if nextSep < 0:
      let part = envValue[i ..< envValue.len].strip()
      if part.len > 0:
        result.add(part)
      break
    let part = envValue[i ..< nextSep].strip()
    if part.len > 0:
      result.add(part)
    i = nextSep + 2

proc loadComposedClassifier*(
    config: ConfigRef, scriptPath: string): Result[Classifier, string] =
  ## TF-M4: build the per-tracer Classifier from the four-layer composition
  ## defined in `Trace-Filters.md` § 5:
  ##   1. builtin default      (always)
  ##   2. auto-discovered file (`.codetracer/trace-filter.toml`, unless
  ##                            `--no-auto-filter` was passed)
  ##   3. env var               (`CODETRACER_TRACE_FILTER`, `::`-separated)
  ##   4. CLI flags             (`--trace-filter:<path>`, repeatable)
  ## Later sources override earlier ones rule-by-rule per the library's
  ## last-match-wins semantics.

  # Layer 1: builtin default. Parsing failure is a programmer bug — surface
  # it loudly rather than silently shipping an unfiltered trace.
  let builtinRes = compileFiltersInline(builtinNimVmFilterToml, "<builtin>")
  if builtinRes.isErr:
    return err("BUG: builtin trace filter failed to parse: " & builtinRes.error)
  var classifier = builtinRes.get()

  # Layer 2: auto-discovery, unless suppressed.
  if config != nil and not config.noAutoFilter:
    let autoPath = findAutoFilter(scriptPath)
    if autoPath.len > 0:
      let r = compileFilters(@[autoPath])
      if r.isErr:
        return err(r.error)
      let extra = r.get()
      for rule in extra.rules:
        classifier.rules.add(rule)
      classifier.sources.add(autoPath)
      for w in extra.warnings:
        classifier.warnings.add(w)
      classifier.defaultExec = extra.defaultExec

  # Layer 3: env var.
  let envPaths = parseEnvFilterPaths(getEnv("CODETRACER_TRACE_FILTER"))
  if envPaths.len > 0:
    let r = compileFilters(envPaths)
    if r.isErr:
      return err(r.error)
    let extra = r.get()
    for rule in extra.rules:
      classifier.rules.add(rule)
    for s in extra.sources:
      classifier.sources.add(s)
    for w in extra.warnings:
      classifier.warnings.add(w)
    classifier.defaultExec = extra.defaultExec

  # Layer 4: CLI flag(s).
  if config != nil and config.traceFilterPaths.len > 0:
    let r = compileFilters(config.traceFilterPaths)
    if r.isErr:
      return err(r.error)
    let extra = r.get()
    for rule in extra.rules:
      classifier.rules.add(rule)
    for s in extra.sources:
      classifier.sources.add(s)
    for w in extra.warnings:
      classifier.warnings.add(w)
    classifier.defaultExec = extra.defaultExec

  ok(classifier)

proc initVmTracer*(outputPath: string, scriptPath: string,
                   config: ConfigRef): Result[ptr VmTracer, string] =
  ## Create a new VmTracer. Returns a heap-allocated pointer suitable
  ## for storing in TCtx.vmTracer.
  let writerRes = initMultiStreamWriter(outputPath, scriptPath)
  if writerRes.isErr:
    return err("failed to create trace writer: " & writerRes.error)

  let filterRes = loadComposedClassifier(config, scriptPath)
  if filterRes.isErr:
    # Don't leak the half-built writer.
    var w = writerRes.get()
    w.closeCtfs()
    return err("failed to compile trace filters: " & filterRes.error)

  var tracer = cast[ptr VmTracer](alloc0(sizeof(VmTracer)))
  tracer[] = VmTracer(
    writer: writerRes.get(),
    outputPath: outputPath,
    lastLine: 0,
    lastFileIndex: -1,
    lastPathId: 0,
    lastEmittedLine: 0,
    haveLastEmitted: false,
    pathCache: @[],
    functions: initTable[string, uint64](),
    typeNames: initTable[string, uint64](),
    nextVariableIndex: 0,
    pendingValues: @[],
    depth: 0,
    config: config,
    filter: filterRes.get(),
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

  var skip = false
  let pathId = tracer.ensurePath(fileIdx, skip)
  # TF-M4: if the classifier said skip (or registration failed), drop any
  # pending values along with the step so we don't accumulate phantom
  # assignments anchored to no real source line.
  if skip:
    tracer.pendingValues.setLen(0)
    return
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
