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
## CTFS-M-ValueAttribution update: the previous model attached values to
## the NEXT step after the assignment, regardless of where in the source
## the writing opcode lived. That misattributed `let x = 123` (line N) to
## the next user-visible step (e.g. a macro call site at line N+M). The
## fix tracks the writing opcode's `TLineInfo` alongside each buffered
## value (`PendingValue`). `traceStep`, before emitting the requested
## step at the next (path, line), groups buffered pending values by their
## writing-site (path, line) and synthesises one `registerStep` per
## group whose site differs from the new step's site. Values whose
## writing-site equals the new step's site flow through into the new
## step's `vars[]` exactly as before. `traceCall` / `traceReturn` /
## `closeVmTracer` use the same grouping, with the trailing flush
## anchoring values at their actual writing site rather than at the last
## emitted step's stale (path, line).
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

import std/[tables, syncio, os, strutils, sets]
import msgs, options, lineinfos
import ast, renderer
import results
export results
import codetracer_trace_writer/multi_stream_writer
export multi_stream_writer.IOEventKind
import codetracer_trace_writer/value_stream
import codetracer_trace_writer/call_stream
import codetracer_trace_writer/cbor
import codetracer_trace_writer/path_filter
import ../dist/checksums/src/checksums/sha2
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

  PendingValue* = object
    ## CTFS-M-ValueAttribution: a buffered value record together with
    ## the source position of the writing opcode. `value` is the wire
    ## payload that will eventually flow into a `registerStep` call;
    ## `info` is the `TLineInfo` of the instruction that fired
    ## `traceAssignment`. The flush logic groups by (fileIndex, line)
    ## so that values land on the step at their writing site instead
    ## of leaking onto the next user-visible step.
    value*: VariableValue
    info*: TLineInfo

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
    pendingValues*: seq[PendingValue]   ## values buffered between steps
      ## CTFS-M-ValueAttribution: each entry carries the writing
      ## opcode's `TLineInfo` so the flush logic can synthesise an
      ## intermediate step at the writing site when it differs from
      ## the next user-visible step's (path, line).
    depth*: int
    config*: ConfigRef
    filter*: Classifier                 ## TF-M4: cross-language trace filter
    compileTimeDepth*: int
      ## CTFS-M-CompileTimeFilter: number of nested compile-time-evaluation
      ## scopes currently active. The Nim VM is reused for both runtime
      ## script execution (`nim e` script body, mode `emRepl`) and
      ## compile-time evaluation (`static:` blocks, `{.compileTime.}` proc
      ## bodies, macro/template expansion — modes `emStaticStmt`,
      ## `emStaticExpr`, `emConst`, `emOptimize`). The trace is meant to
      ## describe runtime behaviour only, so emission must be suppressed
      ## while this counter is positive. The counter is incremented by
      ## `enterCompileTime` (called from vm.nim immediately before
      ## `rawExecute` for compile-time eval) and decremented by
      ## `leaveCompileTime` immediately after. Using a counter rather than
      ## a bool defends against any future nesting of compile-time scopes
      ## without changing the hook-side check.

proc enterCompileTime*(tracer: var VmTracer) {.inline.} =
  ## CTFS-M-CompileTimeFilter: mark the tracer as currently executing a
  ## compile-time evaluation scope. Called from vm.nim immediately before
  ## any `rawExecute` invocation whose `c.mode` is not `emRepl`
  ## (i.e. evalConstExprAux for static:/const/{.compileTime.} init, and
  ## evalMacroCall for macro bodies). Paired one-for-one with
  ## `leaveCompileTime`.
  inc tracer.compileTimeDepth

proc leaveCompileTime*(tracer: var VmTracer) {.inline.} =
  ## CTFS-M-CompileTimeFilter: pop the compile-time scope. Defends
  ## against caller-side imbalance by clamping at zero rather than
  ## decrementing below it — silent underflow would falsely re-enable
  ## trace emission in a subsequent compile-time scope.
  if tracer.compileTimeDepth > 0:
    dec tracer.compileTimeDepth

proc inCompileTimeContext*(tracer: VmTracer): bool {.inline.} =
  ## CTFS-M-CompileTimeFilter: true when the VM is currently executing
  ## code that runs at compile time. Each trace hook calls this first and
  ## short-circuits when the answer is true, so the trace contains only
  ## the runtime behaviour of the program under trace.
  tracer.compileTimeDepth > 0

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

proc shouldSkipPath(tracer: var VmTracer, fileIndex: int32): bool =
  ## TF-M5-Prep-2 (Blocker 1): non-registering counterpart of
  ## `ensurePath`. Used by `traceAssignment` (and any other emit site
  ## that needs to know "would this path be filtered" without forcing
  ## the writer to allocate a paths[] entry for it).
  ##
  ## Returns `true` if the classifier decided to skip this file, or
  ## the FileIndex is invalid. Returns `false` when the path is
  ## tracedeable — the caller is free to emit. Mutates only the
  ## classification caches (`pathByFileIdx`, `pathByCanonical`); does
  ## not touch the writer's interning table. A subsequent
  ## `ensurePath` for the same FileIndex will register the path then.
  ##
  ## Hot-path budget: one array deref on a cached FileIndex (the same
  ## O(1) primary-cache hit `ensurePath` enjoys). Cold path performs
  ## the same canonicalize + classify as `ensurePath` but stops
  ## before `registerPath`.
  if fileIndex < 0:
    return true
  let idx = int(fileIndex)
  if idx < tracer.pathByFileIdx.len:
    let entry = tracer.pathByFileIdx[idx]
    case entry.kind
    of pcSkip:
      return true
    of pcTrace:
      return false
    of pcUnclassified: discard
  else:
    tracer.pathByFileIdx.setLen(idx + 1)

  # Cold path: classify against the same composed Classifier the rest
  # of the tracer consults. Only mutate the SKIP side of the cache —
  # we deliberately do NOT call writer.registerPath, because doing so
  # would pollute the paths[] interning table with files we never
  # emit a step for.
  let rawPath = toFullPath(tracer.config, FileIndex(fileIndex))
  let canonical = canonicalizePath(tracer, rawPath)

  if canonical in tracer.pathByCanonical:
    let cached = tracer.pathByCanonical[canonical]
    tracer.pathByFileIdx[idx] = cached
    return cached.kind == pcSkip

  let decision = classify(tracer.filter, canonical)
  if decision.exec == eaSkip:
    let entry = PathCacheEntry(kind: pcSkip, pathId: 0)
    tracer.pathByFileIdx[idx] = entry
    tracer.pathByCanonical[canonical] = entry
    return true

  # Decision is `trace`, but we don't register here — the next
  # `ensurePath` call (e.g. from traceStep) will do that, and we
  # leave the primary cache as Unclassified so registration runs
  # exactly once. The classification work we did is still useful via
  # the secondary cache (`pathByCanonical`) — `ensurePath` will hit
  # it on its second probe.
  return false

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

proc displayNameForVarname*(name: string): string =
  ## CTFS-M-GensymDisplay: strip Nim's `\`gensymNN` hygiene suffix from a
  ## varname before it enters the trace's varname interning pool.
  ##
  ## Background: when a template/macro body binds a local (e.g.
  ## ``template log(msg) = let line = msg``), the compiler renames the
  ## binding to ``line\`gensymNN`` to avoid identifier collisions across
  ## expansions. The renamed string lives on `PSym.name.s`. The C / cpp /
  ## js backends never expose this suffix to user-facing artefacts — it's
  ## a compiler-internal mechanism — and the .ct trace should match.
  ##
  ## Why this is safe re: varname identity: `traceAssignment` keys the
  ## per-symbol varname cache by `sym.itemId`, so two distinct gensym'd
  ## symbols stay distinct in `varnameIds` even when they normalize to
  ## the same display string. The writer's interning table dedupes by
  ## string, so two distinct PSyms whose stripped names collide will
  ## share one varnameId in the pool — acceptable because at the source
  ## level they ARE the same name (the local `line` in template `log`),
  ## just reinstantiated per expansion, and trace consumers disambiguate
  ## via the surrounding call context.
  ##
  ## Edge case: a user-written identifier literally named ``foo\`gensym42``
  ## (legal only via `quote do:` shenanigans) would be normalized to
  ## `foo`. Treat this as a documented hygiene-display contract rather
  ## than a bug — internal gensym uniqueness is preserved upstream of the
  ## display string.
  let idx = name.find("`gensym")
  if idx >= 0:
    return name[0 ..< idx]
  return name

proc functionNameForTrace*(prc: PSym, config: ConfigRef = nil): string =
  ## CTFS-M-Generics / CTFS-M-OOP: compose an instantiation-aware
  ## function name.
  ##
  ## For ordinary (non-generic, non-method) procs this returns the bare
  ## source-level name (`prc.name.s`) — identical to the pre-Generics
  ## behaviour, so existing snapshots stay byte-stable.
  ##
  ## For generic *instantiations* (`sfFromGeneric in prc.flags`) we
  ## suffix the bare name with the resolved parameter and return types
  ## in the form `name(param1, param2, ...) -> ret`. Two different
  ## instantiations of the same generic — say `f[int]` and `f[string]`
  ## — therefore produce distinct entries in the trace's `functions[]`
  ## table, matching the "the trace shows what happens at runtime"
  ## principle: at runtime they really are different procedures with
  ## different code and different behaviour.
  ##
  ## We use parameter / return types (not the original generic type
  ## arguments) because:
  ##   * After `seminst.generateInstance` the proc's
  ##     `ast[genericParamsPos]` is reset to `emptyNode` — the resolved
  ##     generic args are no longer reachable from the PSym without the
  ##     `ModuleGraph` instance cache, which the tracer does not have
  ##     access to.
  ##   * The proc's resolved signature (`prc.typ`) fully distinguishes
  ##     all observable instantiations: two `sfFromGeneric` PSyms whose
  ##     signatures coincide describe code paths that behave identically
  ##     at the VM level, so collapsing them into one function entry
  ##     would still be correct from a "what happens at runtime"
  ##     standpoint.
  ##
  ## Edge case: parameterless generics (e.g. `proc g[T](): T`)
  ## instantiate with a return-type-only suffix — `g() -> int`,
  ## `g() -> string`.
  ##
  ## CTFS-M-OOP: for methods (`prc.kind == skMethod`, identified by Nim
  ## with the `method` keyword) we suffix the bare name with the
  ## *dispatch type* — the type of the first parameter — in the form
  ## `name[DispatchType]`. The dispatch type is what makes one concrete
  ## method body distinguishable from another in a vtable lookup: at
  ## runtime, two methods sharing a base name but defined on different
  ## object types (e.g. `method sound(d: Dog)` vs `method sound(c: Cat)`)
  ## execute different code, and the trace should reflect that. The
  ## suffix uses the bracketed form rather than the resolved-signature
  ## form used for generics, both to mirror Nim's at-call-site convention
  ## (`pet.sound`) and to keep method entries visually distinct from
  ## generic-instantiation entries in the trace UI. Dispatcher procs
  ## generated by `cgmeth.createDispatcher` carry `sfDispatcher`
  ## alongside `skMethod`; we surface them as `name[dispatch]` so the
  ## trace shows the indirection layer before each concrete-method
  ## entry. A method that is also a generic instantiation (uncommon but
  ## legal — `method m[T](x: First[T])`) goes through the
  ## `sfFromGeneric` branch first because the resolved signature already
  ## captures the dispatch type as parameter 1.
  ##
  ## CTFS-M-Closures: anonymous closures synthesised from a `proc(...) =`
  ## lambda land in the trace as `:anonymous` (the canonical name
  ## minted by `semexprs.semProcAux` via `idents.idAnon`). Two distinct
  ## lambdas in the same program therefore collapse onto one functionId,
  ## which is unhelpful — the user sees only "some anonymous proc was
  ## called", not which one. We rewrite the bare `:anonymous` to
  ## `<anon>@<file>:<line>`, anchored at the lambda's *definition* site
  ## (`prc.info`). Two lambdas defined on different source lines now get
  ## distinct names, the call-side reader can jump directly to the
  ## defining line, and the angle-bracketed form keeps the entry
  ## visually distinct from named procs in the trace UI.
  if prc == nil:
    return ""
  let base =
    if prc.name == nil: ""
    else: prc.name.s
  if prc.typ == nil:
    return base
  if sfFromGeneric in prc.flags:
    # Walk resolved parameter types via `paramTypes` (skips the return
    # type at index 0). `typeToString` with the default `preferName`
    # produces compact, deterministic output (`int`, `string`,
    # `seq[int]`, …) and is the same renderer Nim's own diagnostics
    # use, so the suffix matches what a user would write at the call
    # site.
    var params = ""
    for i, paramType in prc.typ.paramTypes:
      if i > FirstParamAt: params.add(", ")
      params.add(typeToString(paramType))
    let ret =
      if prc.typ.returnType != nil: typeToString(prc.typ.returnType)
      else: ""
    result = base & "(" & params & ")"
    if ret.len > 0:
      result.add(" -> ")
      result.add(ret)
    return
  if prc.kind == skMethod:
    # Methods carry the dispatch type as their first parameter (Nim
    # forbids `method foo(): T` without an object parameter; sem
    # enforces `hasObjParam`). `firstParamType` returns that type
    # directly; we render it with `typeToString` for compact, stable
    # output (`Dog`, `Cat`, `Animal`). If the dispatcher is invoked
    # before any concrete method (the `sfDispatcher` copy created by
    # `cgmeth.createDispatcher`), the first-param type is the *base*
    # type of the method bucket — the trace shows e.g. `sound[Animal]`
    # for the dispatcher entry and `sound[Dog]` / `sound[Cat]` for the
    # concrete-method entries reached through it.
    let firstParam = prc.typ.firstParamType
    if firstParam != nil:
      result = base & "[" & typeToString(firstParam) & "]"
      return
  # CTFS-M-Closures: rename `:anonymous` lambdas to `<anon>@file:line`
  # using the proc's defining-site `info`. We only rewrite the
  # canonical anonymous marker — named local procs (which can still
  # capture state and become closures) keep their source-level names.
  # When a ConfigRef is available we use the *basename* of the
  # defining file so the entry stays compact and readable in the trace
  # UI (`<anon>@adder.nim:3`); without a config we fall back to just
  # the line number (`<anon>@:3`). Two anonymous procs defined on
  # different source lines get distinct functionIds either way.
  if base == ":anonymous" and prc.info.fileIndex.int32 >= 0:
    let line = prc.info.line
    var loc: string
    if config != nil:
      let full = toFullPath(config, prc.info.fileIndex)
      let (_, name, ext) = splitFile(full)
      loc = name & ext & ":" & $line
    else:
      loc = ":" & $line
    result = "<anon>@" & loc
    return
  result = base

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
  #
  # CTFS-M-Generics: for generic instantiations, `functionNameForTrace`
  # returns a name that incorporates the resolved signature
  # (`f(int) -> int`, `f(string) -> string`, …) so `f[int]` and
  # `f[string]` produce distinct functionIds. Non-generic procs still
  # register under the bare `prc.name.s` — byte-stable for existing
  # snapshots.
  let funcId = tracer.ensureFunction(functionNameForTrace(prc, tracer.config))
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

proc objectTypeName(t: PType): string =
  ## CTFS-M-ExceptionTypeRefinement: extract the user-visible name of a
  ## nominal type (typically an object or distinct), looking through
  ## `tyAlias` / `tyGenericInst` / `tyGenericBody` wrappers so e.g.
  ## `tyRef IndexDefect` resolves to `"IndexDefect"` rather than the
  ## generic instantiation's anonymous wrapper.
  if t == nil:
    return ""
  let resolved = t.skipTypes({tyAlias, tyGenericInst, tyGenericBody})
  if resolved != nil and resolved.sym != nil:
    return resolved.sym.name.s
  if t.sym != nil:
    return t.sym.name.s
  return ""

proc typeNameForReg(reg: TFullReg, typ: PType): string =
  ## Pick a reasonable type name for interning. Prefers the explicit `typ`,
  ## falls back to the register kind, finally an empty string.
  if typ != nil:
    let resolved = typ.skipTypes({tyAlias, tyGenericInst})
    case resolved.kind
    of tyBool: return "bool"
    of tyChar: return "char"
    of tyString: return "string"
    of tyCstring: return "cstring"
    of tyInt..tyInt64: return "int"
    of tyUInt..tyUInt64: return "uint"
    of tyFloat..tyFloat128: return "float"
    of tyEnum: return "enum"
    of tyRef:
      # CTFS-M-ExceptionTypeRefinement: `except T as e:` binds `e` with
      # type `ref T`. Render the underlying object's name so debugger UIs
      # can show `ref IndexDefect` instead of the generic `node` fallback.
      let elem = resolved.elementType
      let inner = objectTypeName(elem)
      if inner.len > 0: return "ref " & inner
      return "ref"
    of tyPtr:
      let elem = resolved.elementType
      let inner = objectTypeName(elem)
      if inner.len > 0: return "ptr " & inner
      return "ptr"
    of tyObject, tyDistinct:
      let name = objectTypeName(resolved)
      if name.len > 0: return name
    else: discard
  case reg.kind
  of rkInt: return "int"
  of rkFloat: return "float"
  of rkNode: return "node"
  of rkNone: return "none"
  of rkRegisterAddr, rkNodeAddr: return "address"

proc emitPendingGroup(tracer: var VmTracer,
                      pathId: uint64, line: uint64,
                      group: openArray[VariableValue]) =
  ## CTFS-M-ValueAttribution helper: emit one `registerStep` carrying
  ## `group`'s values at (pathId, line). Errors are swallowed in the
  ## same shape as the rest of the tracer — a writer error here cannot
  ## be surfaced to the executing VM and dropping the step is the
  ## least-bad recovery. The caller is responsible for updating the
  ## tracer's "last emitted" cursor when the synthetic step
  ## represents the new authoritative source position.
  let res = tracer.writer.registerStep(pathId, line, group)
  if res.isErr:
    discard

proc flushPendingValuesByWritingSite(tracer: var VmTracer) =
  ## CTFS-M-ValueAttribution: emit one synthetic `registerStep` per
  ## distinct writing-site `(fileIndex, line)` carried by the buffered
  ## pending values, in the order they were buffered. After this
  ## proc returns `pendingValues` is empty.
  ##
  ## Used by `traceCall` / `traceReturn` / `closeVmTracer` and as the
  ## "leftover" path in `traceStep` when the new user-visible step's
  ## site doesn't match any of the buffered values' sites. In those
  ## contexts there's no anchoring forthcoming step, so each writing
  ## site must produce its own dedicated step.
  ##
  ## Values whose writing site is invalid (missing line / filtered
  ## path) are dropped silently. This mirrors the behaviour of
  ## `traceStep` which also short-circuits on invalid line info.
  if tracer.pendingValues.len == 0:
    return

  # Group preserving insertion order: walk pendingValues left-to-right,
  # accumulating runs that share (fileIndex, line). For typical short
  # buffers (a handful of writes between two steps), this O(n²)-shaped
  # walk is cheaper than initialising a Table.
  var i = 0
  while i < tracer.pendingValues.len:
    let info = tracer.pendingValues[i].info
    let fileIdx = int32(info.fileIndex)
    let line = info.line
    var j = i + 1
    while j < tracer.pendingValues.len and
          int32(tracer.pendingValues[j].info.fileIndex) == fileIdx and
          tracer.pendingValues[j].info.line == line:
      inc j
    # [i, j) shares the same writing site. Skip groups with no usable
    # source position — the writing opcode has no line info we can
    # attribute the value to.
    if fileIdx >= 0 and line != 0:
      var skip = false
      let pathId = tracer.ensurePath(fileIdx, skip)
      if not skip:
        var group = newSeq[VariableValue](j - i)
        for k in 0 ..< (j - i):
          group[k] = tracer.pendingValues[i + k].value
        emitPendingGroup(tracer, pathId, uint64(line), group)
        # Each synthetic step advances the tracer's emitted cursor so
        # subsequent delta encodings stay correct and a following
        # `traceCall` / `traceReturn` / final flush observes the right
        # "last known" position.
        tracer.lastPathId = pathId
        tracer.lastEmittedLine = uint64(line)
        tracer.haveLastEmitted = true
    i = j
  tracer.pendingValues.setLen(0)

proc flushPendingValuesAsStep(tracer: var VmTracer) {.inline.} =
  ## CTFS-M-ValueAttribution: legacy alias used by traceCall / traceReturn /
  ## traceRaise / closeVmTracer / the filtered branch of traceStep. The
  ## flush now groups by writing site so each value lands on a step at
  ## its source line rather than collapsing onto a single
  ## "last known" position.
  flushPendingValuesByWritingSite(tracer)

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

type
  ComposedClassifier* = object
    ## TF-M5-Prep-2 (Blocker 2): the loaded classifier plus the
    ## provenance chain (path + content sha256) for every source that
    ## contributed rules, in composition order. The provenance feeds
    ## the writer's `setFilterProvenance` so that meta.dat carries the
    ## `FlagHasTraceFilterProvenance` bit and the post-trace JSON
    ## materializer surfaces `metadata.trace_filter.filters[]` per
    ## Trace-Filters.md § 7.
    classifier*: Classifier
    provenance*: seq[FilterProvenance]

proc filterDigest(data: string): array[32, byte] =
  ## Compute SHA-256 of `data` and return the raw 32-byte digest in the
  ## shape the meta.dat writer expects. Uses the bundled
  ## `dist/checksums` module — the same SHA-2 implementation the
  ## compiler already pulls in for ccgtypes/modulegraphs.
  var digest: array[32, byte] = default(array[32, byte])
  let raw = secureHash(Sha_256, data)  # returns array[32, char]
  for i in 0 ..< 32:
    digest[i] = byte(raw[i])
  digest

proc makeProvenance(path: string, content: string): FilterProvenance =
  ## Build one provenance entry: `path` is either a real filter file
  ## path or a sentinel like `<inline:builtin-default>`; `content` is
  ## the literal source bytes whose digest we record.
  FilterProvenance(path: path, sha256: filterDigest(content))

proc loadComposedClassifier*(
    config: ConfigRef, scriptPath: string): Result[ComposedClassifier, string] =
  ## TF-M4: build the per-tracer Classifier from the four-layer composition
  ## defined in `Trace-Filters.md` § 5:
  ##   1. builtin default      (always)
  ##   2. auto-discovered file (`.codetracer/trace-filter.toml`, unless
  ##                            `--no-auto-filter` was passed)
  ##   3. env var               (`CODETRACER_TRACE_FILTER`, `::`-separated)
  ##   4. CLI flags             (`--trace-filter:<path>`, repeatable)
  ## Later sources override earlier ones rule-by-rule per the library's
  ## last-match-wins semantics.
  ##
  ## TF-M5-Prep-2 (Blocker 2): the returned `ComposedClassifier` now
  ## also carries a `provenance: seq[FilterProvenance]` recording each
  ## contributing source (`<inline:builtin-default>` for the embedded
  ## default; absolute file paths for the on-disk sources) together
  ## with the SHA-256 of its source bytes, in the same composition
  ## order the rules were merged. The caller wires this to the writer
  ## via `setFilterProvenance` so meta.dat records the chain (TF-M7).

  var provenance: seq[FilterProvenance] = @[]

  # Layer 1: builtin default. Parsing failure is a programmer bug — surface
  # it loudly rather than silently shipping an unfiltered trace.
  let builtinRes = compileFiltersInline(
    builtinNimVmFilterToml, "<inline:builtin-default>")
  if builtinRes.isErr:
    return err("BUG: builtin trace filter failed to parse: " & builtinRes.error)
  var classifier = builtinRes.get()
  provenance.add(makeProvenance(
    "<inline:builtin-default>", builtinNimVmFilterToml))

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
      # Provenance: hash the on-disk bytes. A read failure here would
      # already have failed compileFilters above, so the readFile is
      # best-effort — if it raises now, fall back to an empty digest
      # rather than abort the whole tracer.
      var content = ""
      try:
        content = readFile(autoPath)
      except IOError, OSError:
        content = ""
      provenance.add(makeProvenance(autoPath, content))

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
    for p in envPaths:
      var content = ""
      try:
        content = readFile(p)
      except IOError, OSError:
        content = ""
      provenance.add(makeProvenance(p, content))

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
    for p in config.traceFilterPaths:
      var content = ""
      try:
        content = readFile(p)
      except IOError, OSError:
        content = ""
      provenance.add(makeProvenance(p, content))

  ok(ComposedClassifier(classifier: classifier, provenance: provenance))

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
  let composed = filterRes.get()

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
    filter: composed.classifier,
    compileTimeDepth: 0,
  )

  # TF-M5-Prep-2 (Blocker 2): hand the composed provenance chain to
  # the writer so meta.dat carries the `FlagHasTraceFilterProvenance`
  # bit and the post-trace materializer surfaces
  # `metadata.trace_filter.filters[]` per Trace-Filters.md § 7. We
  # pass `recordEvenIfEmpty = true` so the bit is also set on the
  # vanishingly rare path where the chain is empty — the spec uses
  # the bit to distinguish "did not record" from "recorded an empty
  # chain", and the Nim VM tracer always at least loads the embedded
  # builtin default, so this branch is mainly defensive.
  tracer.writer.setFilterProvenance(composed.provenance,
                                    recordEvenIfEmpty = true)

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
  ##
  ## CTFS-M-ValueAttribution: any buffered pending values whose
  ## writing site differs from `info`'s (file, line) are flushed first
  ## via dedicated synthetic steps at their writing site. Values whose
  ## writing site equals `info`'s (file, line) are attached as the
  ## `vars[]` of the new step. This makes value records appear at the
  ## source line where the assignment was actually written rather than
  ## leaking onto the next user-visible step.
  # CTFS-M-CompileTimeFilter: drop all step emission while the VM is
  # inside a compile-time evaluation scope (static:, {.compileTime.}
  # proc bodies, macro/template body execution). The trace records
  # runtime behaviour only.
  if inCompileTimeContext(tracer):
    return
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
  # TF-M4: if the classifier said skip (or registration failed), drop the
  # step itself so we don't anchor phantom events on filtered code.
  # CTFS-M-TraceSites: but FLUSH any pending values at their writing
  # sites before dropping — they were produced by traced user code and
  # would otherwise be silently lost at the traced->filtered transition
  # (cf. the symmetric flush in `traceCall` and `traceReturn`).
  if skip:
    flushPendingValuesByWritingSite(tracer)
    return

  # CTFS-M-ValueAttribution: split pendingValues into
  #   * `matching`: values whose writing site equals (fileIdx, line) —
  #     these flow into the new step's vars[] as before.
  #   * everything else: emitted as synthetic intermediate steps at
  #     their respective writing sites first.
  # We walk pendingValues left-to-right and emit a synthetic step
  # whenever we encounter a maximal run of non-matching values that
  # share a writing site. Matching values are accumulated separately
  # and attached to the new step at the end.
  var matching: seq[VariableValue] = @[]
  var i = 0
  while i < tracer.pendingValues.len:
    let pv = tracer.pendingValues[i]
    let pvFileIdx = int32(pv.info.fileIndex)
    let pvLine = pv.info.line
    if pvFileIdx == fileIdx and pvLine == line:
      # Matching value: defer to the new step's vars[].
      matching.add(pv.value)
      inc i
      continue
    # Non-matching run: gather everything that shares this (file, line)
    # then emit one synthetic step for them. Invalid-info values are
    # dropped (no anchoring (path, line) available).
    var j = i + 1
    while j < tracer.pendingValues.len and
          int32(tracer.pendingValues[j].info.fileIndex) == pvFileIdx and
          tracer.pendingValues[j].info.line == pvLine:
      inc j
    if pvFileIdx >= 0 and pvLine != 0:
      var pvSkip = false
      let pvPathId = tracer.ensurePath(pvFileIdx, pvSkip)
      if not pvSkip:
        var group = newSeq[VariableValue](j - i)
        for k in 0 ..< (j - i):
          group[k] = tracer.pendingValues[i + k].value
        emitPendingGroup(tracer, pvPathId, uint64(pvLine), group)
        # Update emitted cursor so the writer's delta encoder stays
        # aligned and subsequent flushes observe the correct "last
        # emitted" position.
        tracer.lastPathId = pvPathId
        tracer.lastEmittedLine = uint64(pvLine)
        tracer.haveLastEmitted = true
    i = j

  let res = tracer.writer.registerStep(pathId, uint64(line), matching)
  if res.isErr:
    discard
  tracer.pendingValues.setLen(0)
  tracer.lastPathId = pathId
  tracer.lastEmittedLine = uint64(line)
  tracer.haveLastEmitted = true

proc traceCall*(tracer: var VmTracer, prc: PSym, info: TLineInfo,
                envNode: PNode = nil) =
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
  ##
  ## CTFS-M-Closures: when `envNode` is non-nil the call is a closure
  ## invocation (`opcIndCall` with an `nkTupleConstr` callee). We
  ## serialize the captured environment as a single `:env` CallArg so
  ## that the trace's `call_entry.args[]` exposes the lexical state the
  ## closure carries — without it the closure body appears to run from
  ## thin air. The env's PNode is the second slot of the closure tuple
  ## (`regs[rb].node[1]`), produced by `transf`'s lambdalifting pass;
  ## it walks through the existing `serializeNode` exactly like any
  ## other aggregate value, so cyclic-ref protection, the depth cap,
  ## and the M-ComplexTypes structural shape all carry over for free.
  ## Non-closure calls keep the legacy empty-args call event so existing
  ## snapshots stay byte-stable.
  if inCompileTimeContext(tracer):
    return
  flushPendingValuesAsStep(tracer)
  var skip = false
  let funcId = tracer.ensureFunctionForSym(prc, skip)
  if skip:
    return
  var args: seq[CallArg] = @[]
  if envNode != nil and envNode.kind != nkNilLit:
    # The env varname is conventionally `:env` (the same name the
    # lambdalifting pass uses for the hidden parameter). We intern it
    # once via the writer's name pool and reuse the id for every
    # closure call thereafter.
    let envVarRes = tracer.writer.registerVarname(":env")
    let envVarId: uint64 =
      if envVarRes.isErr: 0'u64
      else: envVarRes.get()
    var seen = initHashSet[uint64]()
    let envVal = serializeNode(envNode, envNode.typ, 0, seen)
    args.add(CallArg(varnameId: envVarId, value: encodeValue(envVal)))
  let res = tracer.writer.registerCall(funcId, args)
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
  # CTFS-M-CompileTimeFilter: suppress Return events that match a
  # suppressed Call. Same gate as traceCall — same effect on depth.
  if inCompileTimeContext(tracer):
    return
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

proc traceRaise*(tracer: var VmTracer, info: TLineInfo,
                 exceptionTypeName: string, message: string = "") =
  ## CTFS-M3: emit a `sekRaise` event in the execution stream at the raise
  ## site.
  ##
  ## Called from `opcRaise` at runtime, AFTER the dispatch-loop's
  ## `traceStep` has emitted a step for the raise statement's source line.
  ## The sekRaise event itself carries no GLI delta; its source-line
  ## context is inherited from the preceding step (which the materializer
  ## resolves via `stepAbsoluteGlobalLineIndex`). The marker exists so
  ## post-trace tooling can distinguish a control-flow raise transition
  ## from an ordinary line step.
  ##
  ## Any buffered `pendingValues` accumulated since the last step are
  ## flushed onto the preceding traced step before the marker is emitted
  ## — the raise itself is not a value-bearing site, and dropping the
  ## values here would lose state that was produced by traced user code.
  ##
  ## TF-M4 filter gate: if the raise occurs in code whose path was
  ## classified `skip`, we don't have a useful pathId to anchor the
  ## marker to; we still emit the marker (no path is required) but the
  ## preceding `traceStep` call would have early-returned, so no GLI
  ## context is available. Treat this as a tracer-internal short-circuit:
  ## skip the marker too rather than write an event with stale GLI.
  # CTFS-M-CompileTimeFilter: a raise inside compile-time code
  # (e.g. a doAssert in a macro body that fires during expansion) is
  # not a runtime event. The matching traceStep was suppressed, so
  # emitting sekRaise would leave a marker with no anchoring step.
  if inCompileTimeContext(tracer):
    return
  let fileIdx = int32(info.fileIndex)
  if fileIdx < 0 or info.line == 0:
    return
  var skip = false
  discard tracer.ensurePath(fileIdx, skip)
  if skip:
    return

  flushPendingValuesAsStep(tracer)

  let typeId =
    if exceptionTypeName.len > 0: tracer.ensureTypeName(exceptionTypeName)
    else: 0'u64
  let msgBytes = cast[seq[byte]](message)
  let res = tracer.writer.registerRaise(typeId, msgBytes)
  if res.isErr:
    discard

proc traceCatch*(tracer: var VmTracer, info: TLineInfo,
                 exceptionTypeName: string) =
  ## CTFS-M3: emit a `sekCatch` event at the handler-entry site.
  ##
  ## Called from `opcRaise` after the matching handler has been found and
  ## just before `pc` is advanced into the handler body. The `info`
  ## argument is the source position of the matched `except` clause
  ## header (i.e. the line of the `except` keyword) — extracted from the
  ## TLineInfo recorded against the first `opcExcept` of that branch
  ## during codegen.
  ##
  ## Unlike the raise site, the handler-entry line is NOT visited by any
  ## opcode at execution time (`opcExcept` is "never executed", and the
  ## first opcode of the handler body sits on the body's own source line
  ## — line 17 in the canonical try/except/echo example). So we first
  ## emit a normal `traceStep` at the handler's line to update GLI to
  ## the right value, then the sekCatch marker, then control returns to
  ## the dispatch loop which picks up the body's first opcode.
  ##
  ## A stepping debugger walking the execution-order event sequence
  ## therefore sees: …raise(15) → catch(16) → body(17)… , in increasing
  ## source order, with no backwards jumps.
  # CTFS-M-CompileTimeFilter: same rationale as traceRaise — a catch
  # inside compile-time code has no runtime story to tell.
  if inCompileTimeContext(tracer):
    return
  let fileIdx = int32(info.fileIndex)
  if fileIdx < 0 or info.line == 0:
    return

  # Drive the line cursor to the handler-entry line so the sekCatch
  # marker (which carries no GLI itself) materialises at line 16. The
  # underlying `traceStep` honours the same filter / dedup rules as a
  # normal line transition, so an except-handler in filtered code is
  # silently skipped, matching the behaviour at the raise site above.
  traceStep(tracer, info)

  # `traceStep` may have early-returned (filtered path). In that case
  # `lastFileIndex` was still updated above the filter gate, but no
  # `registerStep` ran — the writer has no GLI context for this catch.
  # Re-derive the skip decision and bail without emitting the marker.
  var skip = false
  discard tracer.ensurePath(fileIdx, skip)
  if skip:
    return

  let typeId =
    if exceptionTypeName.len > 0: tracer.ensureTypeName(exceptionTypeName)
    else: 0'u64
  let res = tracer.writer.registerCatch(typeId)
  if res.isErr:
    discard

proc traceAssignment*(tracer: var VmTracer, sym: PSym, reg: TFullReg,
                      info: TLineInfo, typ: PType = nil) =
  ## Buffer a Value event for a register-writing opcode.
  ##
  ## CTFS-M-Varnames: `sym` is the source-level binding that owns the target
  ## register slot, or `nil` when the slot is a compiler temporary. A
  ## `nil` sym short-circuits — no value enters the trace, no synthetic
  ## `r<N>` is minted, and the writer's varname pool stays bounded to
  ## the count of user bindings the program actually defines.
  ##
  ## CTFS-M-ValueAttribution: `info` is the writing opcode's source
  ## position (`c.debug[pc]` at the call site). It's stored alongside
  ## the buffered value so the flush logic can attribute the value to
  ## the source line that produced it rather than to the next
  ## user-visible step.
  ##
  ## Hot path on hit: one Table lookup (`varnameIds`) for repeat
  ## assignments + one CBOR encode + one append to `pendingValues`. The
  ## first assignment to each binding additionally pays a single
  ## `registerVarname` call against the writer's interning table.
  # CTFS-M-CompileTimeFilter: drop assignment emission during
  # compile-time evaluation. Without this, register writes inside
  # `static:` blocks / macro bodies / {.compileTime.} initializers
  # would queue up in `pendingValues` and then leak onto the next
  # runtime step via the deferred flush path in `traceStep`.
  if inCompileTimeContext(tracer):
    return
  if sym == nil:
    return

  # TF-M5-Prep-2 (Blocker 1): filter assignments by the symbol's
  # *defining-file* path, not the currently-executing instruction's
  # path. The VM still EXECUTES bodies of stdlib functions whose
  # call_entry/call_exit was suppressed by `traceCall`'s function-side
  # filter (TF-M4b), and CTFS-M-TraceSites wired `traceAssignment`
  # inside arithmetic opcodes that fire from inside e.g. `system.$`.
  # Without this guard, stdlib-internal symbols (`num`, `tmp`,
  # `i\`gensym1`, package-config bindings) get buffered in
  # `pendingValues` and then flushed onto the next user-visible step,
  # polluting the varname pool with noise.
  if shouldSkipPath(tracer, int32(sym.info.fileIndex)):
    return

  let value = serializeVmValue(reg, typ)
  let typeName = typeNameForReg(reg, typ)
  let typeId = tracer.ensureTypeName(typeName)

  let key = sym.itemId
  var varnameId: uint64 = 0
  tracer.varnameIds.withValue(key, idPtr):
    varnameId = idPtr[]
  do:
    # CTFS-M-GensymDisplay: normalize the displayed varname by stripping
    # Nim's ``\`gensymNN`` hygiene suffix. Per-symbol identity is keyed
    # above by `sym.itemId`, so distinct gensym'd symbols stay distinct
    # in `varnameIds` even when their display strings collide in the
    # writer's interning pool.
    let displayName = displayNameForVarname(sym.name.s)
    let varRes = tracer.writer.registerVarname(displayName)
    varnameId =
      if varRes.isErr: 0'u64
      else: varRes.get()
    tracer.varnameIds[key] = varnameId

  tracer.pendingValues.add(PendingValue(
    value: VariableValue(
      varnameId: varnameId,
      typeId: typeId,
      data: encodeValue(value),
    ),
    info: info,
  ))

proc traceIO*(tracer: var VmTracer, kind: IOEventKind, info: TLineInfo,
              payload: string) =
  ## CTFS-M-IO: emit an IO event into the trace's io_event stream.
  ##
  ## Hooked from:
  ##   * `opcEcho` in vm.nim — `kind = ioStdout`, `payload` = the joined
  ##     argument string with a trailing newline (matching what
  ##     `msgWriteln` actually writes).
  ##   * NimScript callbacks in scriptconfig.nim (`rawExec`, `removeDir`,
  ##     `removeFile`, `createDir`, `setCurrentDir`, `moveFile`,
  ##     `moveDir`, `copyFile`, `copyDir`, `putEnv`, `delEnv`) —
  ##     `kind = ioFileOp`, `payload` = a short human-readable
  ##     description of the operation ("exec: <cmd>", "createDir:
  ##     <path>", ...). `ioFileOp` is the format library's
  ##     general-purpose "filesystem / process" kind; we encode the
  ##     specific operation in the payload prefix since the wire enum
  ##     has only four kinds (ioStdout, ioStderr, ioFileOp, ioError).
  ##
  ## CTFS-M-CompileTimeFilter: skipped while the VM is executing
  ## compile-time code. NimScript callbacks fire only at runtime
  ## (`emRepl`) — `opcEcho` could in principle fire from a macro body
  ## (`static: echo "x"` / `echo` inside a macro), and the trace must
  ## not record those as runtime IO.
  ##
  ## Path filtering: unlike steps / values / call events, IO events are
  ## NOT gated on `shouldSkipPath(info.fileIndex)`. IO is anchored to
  ## the most recently emitted step (`stepCount - 1`), and the step
  ## stream already represents user-traceable code only — frames whose
  ## source is filtered never emit a step. NimScript builtins like
  ## `exec` and `copyFile` reach the recorder via stdlib helpers
  ## (`lib/system/nimscript.nim`), so the callback's
  ## `info.fileIndex` typically points into a filtered subtree even
  ## though the *observable* IO belongs to the surrounding user-source
  ## step. Filtering by `info` here would drop those events and defeat
  ## the milestone's purpose ("the trace shows what happens at
  ## runtime"). The `info` argument is retained for future telemetry
  ## (e.g. column-level attribution within the materializer) but does
  ## not currently gate emission.
  ##
  ## CTFS-M-ValueAttribution: any buffered pending values are flushed
  ## at their own writing sites BEFORE the IO event is recorded. The
  ## writer attaches the new event to `stepCount - 1` (i.e. the most
  ## recently emitted step). Without the flush, values whose
  ## attributed step had not yet been emitted would get displaced onto
  ## the wrong step when the next user-visible step arrived after the
  ## IO write.
  if inCompileTimeContext(tracer):
    return
  discard info  # currently informational only; see "Path filtering" above

  # No step has ever been emitted in this trace yet (`haveLastEmitted`
  # is set by the first successful `registerStep` and never cleared).
  # The writer would otherwise anchor the event to a phantom step 0,
  # which materializes as an orphan in the JSON output. Drop the event
  # rather than poison the snapshot — in practice this branch fires
  # only for IO that occurs before the first user-visible line of the
  # script (i.e. essentially never; the module-prologue setup runs
  # before any echo / exec the user wrote).
  if not tracer.haveLastEmitted:
    return

  flushPendingValuesAsStep(tracer)

  let payloadBytes = cast[seq[byte]](payload)
  let res = tracer.writer.registerIOEvent(kind, payloadBytes)
  if res.isErr:
    discard

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
