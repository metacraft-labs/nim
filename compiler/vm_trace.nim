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
## Variable identification (CTFS-M-Varnames update): the VM trace site
## supplies the owning proc and the target register slot. vmgen.nim
## populates `PCtx.regSymTable[(procId, slot)] -> PSym` for every user
## binding (skLet / skVar / skForVar / skResult / skParam / generic param);
## compiler temporaries (slotTempInt / slotTempFloat / slotTempStr /
## slotTempUnknown / slotTempPerm / slotTempComplex) are deliberately
## absent. `traceAssignment` consults that table:
##
##   * hit  -> emit the value under the symbol's source-level name
##             (`x`, `bar`, `result`, ...). The slot's `r<N>` synthetic
##             label never enters the trace.
##   * miss -> the slot is a temporary; skip the emit entirely. The value
##             never enters the value stream and the synthetic varname
##             never enters the interning pool.
##
## Pre-CTFS-M-Varnames the tracer minted a fresh `r<N>` for every
## assignment, which produced 1.4k-3k synthetic entries in the varname
## pool for trivial programs and made post-hoc audit impossible. The
## table-lookup gate is a single `withValue` (one hash lookup + early
## return on miss), in the same complexity class as TF-M4b's function-side
## filter.

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

  ## TF-M4b sentinel for the function-identity classification cache.
  ##
  ## Same shape and intent as `PathCacheEntry` but keyed by `PSym.itemId`
  ## (the compiler's stable (module, item) symbol identity). Decision is
  ## derived from the function's defining-file path via the same
  ## classifier instance used for paths — no new selector kinds.
  ##
  ## Per spec § 3 a "scope" is any recorder-identifiable unit of code:
  ## a Nim file index AND a function. TF-M4 wired the path-half;
  ## this enum/struct wires the function-half so that call_entry /
  ## call_exit events for stdlib helpers (`addInt`, `addChars`, `$`, ...)
  ## are suppressed in addition to their per-line step events.
  FuncCacheKind* = enum
    fcUnclassified
    fcSkip
    fcTrace

  FuncCacheEntry* = object
    kind*: FuncCacheKind
    functionId*: uint64

  VmTracer* = object
    writer*: MultiStreamTraceWriter
    outputPath*: string                 ## destination .ct path
    lastLine*: uint32
    lastFileIndex*: int32
    lastPathId*: uint64                 ## last pathId actually emitted
    lastEmittedLine*: uint64            ## last line actually emitted
    haveLastEmitted*: bool              ## true after the first registerStep
    pathByFileIdx*: seq[PathCacheEntry] ## TF-M4 primary cache: FileIndex-keyed
    pathByCanonical*: Table[string, PathCacheEntry]
      ## TF-M4a secondary cache: canonical path → entry. Two FileIndexes
      ## that resolve to the same physical file share one entry, so the
      ## `paths[]` interning table contains each canonical path exactly
      ## once.
    pathByBasename*: Table[string, seq[string]]
      ## TF-M4d: lazily-built workdir basename → full path index.
      ## Populated on the first canonicalization that needs the
      ## basename probe (i.e. `expandFilename` failed and the input is a
      ## bare basename). The index is built once per tracer lifetime by
      ## walking `metadata.workdir`.
    basenameIndexBuilt*: bool
      ## TF-M4d: gate so the workdir walk runs at most once.
    funcByItemId*: Table[ItemId, FuncCacheEntry]
      ## TF-M4b function-identity cache. Keyed by `PSym.itemId`
      ## (a (module, item) pair, see compiler/astdef.nim). A `Table`
      ## rather than a dense seq because `PSym.id`'s int form is
      ## `(module shl 24) + item`, which is too sparse for a seq
      ## (stdlib pulls in ~100 modules and the high bits push the id
      ## space into the billions). The per-call hot path is therefore
      ## a single hash lookup — still O(1), still single-read.
    functions*: Table[string, uint64]   ## name → functionId (TF-M4-era fallback)
    typeNames*: Table[string, uint64]   ## type name → typeId
    varnameIds*: Table[ItemId, uint64]
      ## CTFS-M-Varnames: cache of `PSym.itemId -> varnameId` for
      ## user-binding symbols already registered with the writer. Keeps the
      ## hot path to one hash lookup (`regSymTable`) + one cache hit
      ## (`varnameIds`) for repeat assignments to the same variable; only
      ## the first assignment to each binding pays for the writer-side
      ## interning-table registration.
    pendingValues*: seq[VariableValue]  ## values buffered between steps
    depth*: int
    config*: ConfigRef
    filter*: Classifier                 ## TF-M4: cross-language trace filter

proc isBareBasename(p: string): bool {.inline.} =
  ## True when `p` has no path separators — i.e. it's a bare basename
  ## like `tscriptcompiletime.nims` rather than `tests/vm/...nims`.
  for ch in p:
    if ch == DirSep or ch == AltSep:
      return false
  true

proc buildBasenameIndex(tracer: var VmTracer) =
  ## TF-M4d: walk the workdir once and build a basename → seq[fullPath]
  ## index used by `canonicalizePath` to resolve a bare basename to a
  ## real on-disk file. We skip directories that are unlikely to contain
  ## user-relevant Nim source (build caches, VCS metadata, vendored
  ## submodule trees) so the walk cost stays bounded even on
  ## monorepo-scale workdirs.
  ##
  ## The index is only consulted from the OSError fallback in
  ## `canonicalizePath` — the normal `expandFilename` hot path never
  ## touches it.
  tracer.basenameIndexBuilt = true
  let workdir = tracer.writer.metadata.workdir
  if workdir.len == 0 or not dirExists(workdir):
    return
  const skipDirs = [
    "nimcache", ".git", ".hg", ".svn", ".repo", "build", "dist", "bin",
    "node_modules", ".cargo", "target", ".direnv", "result"]
  for entry in walkDirRec(workdir, yieldFilter = {pcFile}, followFilter = {pcDir},
                          relative = false):
    # `walkDirRec` doesn't expose per-directory pruning, so we filter
    # post-hoc: if any path segment matches a known build-artifact dir,
    # skip the entry. This is best-effort — the index is a probe, not a
    # source of truth.
    let rel = entry.relativePath(workdir)
    var skip = false
    for seg in rel.split({DirSep, AltSep}):
      if seg in skipDirs:
        skip = true
        break
    if skip:
      continue
    let ext = entry.splitFile.ext
    # Only index source-like files. The basename probe exists for the
    # compiler's pseudo-path fallback where the basename refers to a
    # Nim source — broadening to all files would blow up the index on
    # binary-heavy workdirs without buying anything.
    if ext != ".nim" and ext != ".nims" and ext != ".cfg":
      continue
    let base = entry.extractFilename
    if base notin tracer.pathByBasename:
      tracer.pathByBasename[base] = @[entry]
    else:
      tracer.pathByBasename[base].add(entry)

proc canonicalizePath(tracer: var VmTracer, p: string): string =
  ## TF-M4a: produce a stable canonical form for path deduplication.
  ##
  ## Two FileIndexes that point at the same physical file (e.g. one
  ## resolved relative to the cwd, another resolved against an absolute
  ## include path) should produce equal strings here. For files that
  ## exist on disk we use `expandFilename` (calls `realpath(3)` /
  ## `GetFullPathName`, which resolves symlinks and case). For
  ## pseudo-paths or files the compiler synthesised that don't actually
  ## exist (the OSError fallback inside the compiler's own
  ## `fileInfoIdx`), we fall back to a syntactic
  ## `absolutePath` + `normalizedPath`. Either way the result is used
  ## consistently as both the classify input and the writer's path
  ## interning key.
  ##
  ## TF-M4d: when `expandFilename` fails and `p` is a bare basename
  ## (e.g. `tscriptcompiletime.nims`), the syntactic fallback resolves
  ## against cwd and yields `<cwd>/<basename>` — which differs from the
  ## workdir-relative form `<cwd>/<subdir>/<basename>` when the file
  ## actually lives in a subdirectory. Both forms then collide as two
  ## distinct `paths[]` entries pointing at the same physical file.
  ## We close the gap with two probes before falling through:
  ##
  ##   1. Scan already-registered canonical paths for a unique
  ##      basename match. Cheap (table walk) and catches the common
  ##      case where the workdir-relative form was registered first.
  ##   2. Walk the workdir tree once (lazy + cached) for a basename
  ##      match. Used when the basename arrives before any of its
  ##      sibling forms.
  ##
  ## Either probe yields a result only if exactly one match is found;
  ## ambiguous matches fall through to the cwd-absolute behaviour to
  ## avoid silently picking the wrong file.
  if p.len == 0:
    return p
  try:
    return expandFilename(p)
  except OSError:
    discard
  # `expandFilename` failed (file not on disk under that name). Before
  # giving up to the cwd-absolute syntactic form, see if `p` is a bare
  # basename we can map to a real file inside the workdir.
  if isBareBasename(p):
    # Probe (1): already-known canonical paths.
    var matches: seq[string] = @[]
    for canon in tracer.pathByCanonical.keys:
      if canon.extractFilename == p:
        matches.add(canon)
    if matches.len == 1:
      return matches[0]
    if matches.len == 0:
      # Probe (2): workdir basename index (lazy build).
      if not tracer.basenameIndexBuilt:
        tracer.buildBasenameIndex()
      if p in tracer.pathByBasename:
        let hits = tracer.pathByBasename[p]
        if hits.len == 1:
          return hits[0]
        # Multiple matches → ambiguous; fall through to the cwd
        # fallback rather than silently picking one.
  try:
    result = absolutePath(p).normalizedPath()
  except OSError, ValueError:
    # Fall back to the input; classify/register will still treat it as
    # a single (uncanonicalized) entry rather than crash.
    result = p

proc ensurePath(tracer: var VmTracer, fileIndex: int32,
                skip: var bool): uint64 =
  ## TF-M4a: two-level path cache.
  ##
  ## Primary cache (`pathByFileIdx`): a dense seq indexed by
  ## `FileIndex.int32`, identical to TF-M4. Per spec § 6 the hot path is
  ## one array deref — no hashes, no repeated classification.
  ##
  ## Secondary cache (`pathByCanonical`): keyed by the canonicalized
  ## absolute+normalized path. On a primary miss we canonicalize and
  ## consult the secondary cache; if the same physical file was already
  ## seen under a different FileIndex, we reuse its entry (decision and
  ## pathId) and propagate it into the primary cache so subsequent hits
  ## for that FileIndex are O(1) and so the writer's `paths[]` table
  ## contains each canonical path exactly once.
  ##
  ## Sets `skip = true` if the classifier decided to skip this path or
  ## if the index is invalid; in that case the returned pathId is
  ## meaningless. Otherwise returns the registered pathId (which may
  ## legitimately be 0 since the interning table is 0-indexed).
  skip = false
  if fileIndex < 0:
    skip = true
    return 0
  let idx = int(fileIndex)
  if idx < tracer.pathByFileIdx.len:
    let entry = tracer.pathByFileIdx[idx]
    case entry.kind
    of pcSkip:
      skip = true
      return 0
    of pcTrace:
      return entry.pathId
    of pcUnclassified: discard  # fall through to classify
  else:
    tracer.pathByFileIdx.setLen(idx + 1)

  # First encounter for this FileIndex: canonicalize and consult the
  # secondary cache before doing any classify/register work.
  let rawPath = toFullPath(tracer.config, FileIndex(fileIndex))
  let canonical = canonicalizePath(tracer, rawPath)

  if canonical in tracer.pathByCanonical:
    let cached = tracer.pathByCanonical[canonical]
    tracer.pathByFileIdx[idx] = cached
    if cached.kind == pcSkip:
      skip = true
      return 0
    return cached.pathId

  # Genuinely new canonical path — classify and (if traced) register it.
  let decision = classify(tracer.filter, canonical)
  if decision.exec == eaSkip:
    let entry = PathCacheEntry(kind: pcSkip, pathId: 0)
    tracer.pathByFileIdx[idx] = entry
    tracer.pathByCanonical[canonical] = entry
    skip = true
    return 0

  let res = tracer.writer.registerPath(canonical)
  if res.isErr:
    # Path registration failed; cache as skip in both tables to avoid
    # retrying.
    let entry = PathCacheEntry(kind: pcSkip, pathId: 0)
    tracer.pathByFileIdx[idx] = entry
    tracer.pathByCanonical[canonical] = entry
    skip = true
    return 0

  let pathId = res.get()
  let entry = PathCacheEntry(kind: pcTrace, pathId: pathId)
  tracer.pathByFileIdx[idx] = entry
  tracer.pathByCanonical[canonical] = entry
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

proc ensureFunctionForSym(tracer: var VmTracer, prc: PSym,
                          skip: var bool): uint64 =
  ## TF-M4b: function-side counterpart of `ensurePath`.
  ##
  ## Classifies the function by its defining-file path (the file where
  ## the function's source resides, i.e. `prc.info.fileIndex`) using the
  ## same `Classifier` instance that `ensurePath` consults. Functions
  ## whose defining file is filtered (e.g. `lib/system/arithmetics.nim`)
  ## get `skip = true`; their call_entry / call_exit events must not be
  ## emitted.
  ##
  ## The classification is cached in `funcByItemId`, keyed by
  ## `PSym.itemId`. Subsequent lookups for the same function symbol are
  ## a single Table read — no canonicalization, no classify call, no
  ## function registration.
  ##
  ## On `skip = true` the returned uint64 is meaningless (callers must
  ## not register a Call/Return event using it).
  skip = false
  if prc == nil:
    # Defensive: a nil prc means we have no symbol to classify. Treat
    # as skip — the caller can't legitimately emit an entry/exit for a
    # nameless function.
    skip = true
    return 0

  let key = prc.itemId
  tracer.funcByItemId.withValue(key, entryPtr):
    case entryPtr[].kind
    of fcSkip:
      skip = true
      return 0
    of fcTrace:
      return entryPtr[].functionId
    of fcUnclassified:
      # Cache shouldn't contain Unclassified entries — they're transient
      # placeholders, never written. Fall through and (re)classify.
      discard

  # First encounter for this PSym: derive the defining-file path,
  # classify against the shared filter, and register the function name
  # only if the decision is `trace`.
  let fileIdx = prc.info.fileIndex
  if int32(fileIdx) < 0:
    # No defining file (synthesised symbol, compiler-internal). Be
    # conservative: skip — symbol's provenance is unknown, can't claim
    # it's user code.
    let entry = FuncCacheEntry(kind: fcSkip, functionId: 0)
    tracer.funcByItemId[key] = entry
    skip = true
    return 0

  let rawPath = toFullPath(tracer.config, fileIdx)
  let canonical = canonicalizePath(tracer, rawPath)
  let decision = classify(tracer.filter, canonical)
  if decision.exec == eaSkip:
    let entry = FuncCacheEntry(kind: fcSkip, functionId: 0)
    tracer.funcByItemId[key] = entry
    skip = true
    return 0

  # Decision is `trace`: register the function name in the writer's
  # interning table. We reuse `ensureFunction(name)` so that overloads
  # sharing a name collapse into one functionId (same as pre-M4b
  # behaviour); the M4b distinction is purely the *filter gate*, not
  # the interning policy.
  let funcId = tracer.ensureFunction(prc.name.s)
  let entry = FuncCacheEntry(kind: fcTrace, functionId: funcId)
  tracer.funcByItemId[key] = entry
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
    pathByFileIdx: @[],
    pathByCanonical: initTable[string, PathCacheEntry](),
    pathByBasename: initTable[string, seq[string]](),
    basenameIndexBuilt: false,
    funcByItemId: initTable[ItemId, FuncCacheEntry](),
    functions: initTable[string, uint64](),
    typeNames: initTable[string, uint64](),
    varnameIds: initTable[ItemId, uint64](),
    pendingValues: @[],
    depth: 0,
    config: config,
    filter: filterRes.get(),
  )

  # TF-M4a: populate `metadata.workdir` so the materializer's
  # `FullOpts(stripPaths: true)` can substitute `<workdir>` into paths
  # rooted in the user's project directory. `initMultiStreamWriter`
  # leaves `workdir` empty, which silently turned `--strip-paths` into
  # a no-op. The current working directory at tracer-init time is the
  # most reliable cross-platform signal for "where the user's code
  # lives" — `nim e --trace:<path>` is conventionally invoked from a
  # project root.
  try:
    tracer.writer.metadata.workdir = getCurrentDir()
  except OSError:
    # Leave workdir empty; the materializer will simply not strip paths
    # rather than crash. This is the same observable behaviour as
    # pre-TF-M4a.
    discard
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

proc traceCall*(tracer: var VmTracer, prc: PSym, info: TLineInfo) =
  ## Emit a Call event.
  ##
  ## TF-M4b: gated on the function-side trace filter. If the callee's
  ## defining-file path is filtered (e.g. it lives in `lib/system/**`),
  ## no Call event is recorded and `tracer.depth` is left unchanged.
  ## The matching `traceReturn` at the return site re-classifies the
  ## same `PSym` (single Table lookup, populated by this call) and
  ## also no-ops, preserving symmetry between entry and exit.
  ##
  ## We still flush any pending values via a synthetic step BEFORE the
  ## filter decision: those values were assigned in code we *did* trace
  ## and would otherwise be silently dropped at the unobservable
  ## entry-to-filtered-frame transition.
  flushPendingValuesAsStep(tracer)
  var skip = false
  let funcId = tracer.ensureFunctionForSym(prc, skip)
  if skip:
    return
  let res = tracer.writer.registerCall(funcId, [])
  if res.isErr:
    discard
  tracer.depth += 1

proc traceReturn*(tracer: var VmTracer, prc: PSym) =
  ## Emit a Return event.
  ##
  ## TF-M4b: symmetric with `traceCall`. We re-classify the returning
  ## function via the same `ensureFunctionForSym` cache; on a filter
  ## skip we emit nothing and leave `tracer.depth` unchanged so it
  ## stays balanced with the suppressed entry.
  flushPendingValuesAsStep(tracer)
  var skip = false
  discard tracer.ensureFunctionForSym(prc, skip)
  if skip:
    return
  if tracer.depth > 0:
    tracer.depth -= 1
  # Use the default void-return marker (empty seq → VoidReturnMarker).
  let res = tracer.writer.registerReturn(@[])
  if res.isErr:
    discard

proc traceAssignment*(tracer: var VmTracer, sym: PSym, reg: TFullReg,
                      typ: PType = nil) =
  ## Buffer a Value event for a register-writing opcode.
  ##
  ## CTFS-M-Varnames: `sym` is the source-level binding that owns the target
  ## register slot, or `nil` when the slot is a compiler temporary. A
  ## `nil` sym short-circuits — no value enters the trace, no synthetic
  ## `r<N>` is minted, and the writer's varname pool stays bounded to
  ## the count of user bindings the program actually defines.
  ##
  ## Hot path on hit: one Table lookup (`varnameIds`) for repeat
  ## assignments + one CBOR encode + one append to `pendingValues`. The
  ## first assignment to each binding additionally pays a single
  ## `registerVarname` call against the writer's interning table.
  if sym == nil:
    return

  let value = serializeVmValue(reg, typ)
  let typeName = typeNameForReg(reg, typ)
  let typeId = tracer.ensureTypeName(typeName)

  let key = sym.itemId
  var varnameId: uint64 = 0
  tracer.varnameIds.withValue(key, idPtr):
    varnameId = idPtr[]
  do:
    let varRes = tracer.writer.registerVarname(sym.name.s)
    varnameId =
      if varRes.isErr: 0'u64
      else: varRes.get()
    tracer.varnameIds[key] = varnameId

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
