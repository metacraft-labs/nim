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

# ---------------------------------------------------------------------------
# TF-M7: SHA-256 (minimal, RFC 6234)
# ---------------------------------------------------------------------------
#
# The Nim stdlib only ships SHA-1; we need SHA-256 to populate the
# trace-filter provenance digests recorded in meta.dat per spec § 7.
# Pulling in `nimcrypto` (or any third-party crate) is overkill for one
# digest call per recording session, and the compiler's bootstrap
# already avoids non-stdlib deps for the boot-image hash budget.  ~60
# lines of self-contained code suffice.

const Sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32,
]

proc rotr32(x: uint32, n: int): uint32 {.inline.} =
  (x shr uint32(n)) or (x shl uint32(32 - n))

proc sha256Sum(data: openArray[byte]): array[32, byte] =
  ## Compute the SHA-256 digest of `data`.  Returns the 32 raw digest
  ## bytes (no hex encoding); the meta.dat writer wants raw bytes per
  ## spec § 7.
  result = default(array[32, byte])
  var h: array[8, uint32] = [
    0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
    0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32,
  ]
  # Build the padded message.  Padding is: append 0x80, then enough
  # zero bytes for the result to be ≡ 56 (mod 64), then a big-endian
  # 64-bit bit-length.
  let msgBits = uint64(data.len) * 8'u64
  var msg = newSeqOfCap[byte](data.len + 64)
  for b in data:
    msg.add(b)
  msg.add(0x80'u8)
  while (msg.len mod 64) != 56:
    msg.add(0'u8)
  for i in countdown(7, 0):
    msg.add(byte((msgBits shr uint64(i * 8)) and 0xFF'u64))

  var w: array[64, uint32] = default(array[64, uint32])
  var blockIdx = 0
  while blockIdx < msg.len:
    for t in 0 ..< 16:
      let off = blockIdx + t * 4
      w[t] = (uint32(msg[off]) shl 24) or (uint32(msg[off + 1]) shl 16) or
             (uint32(msg[off + 2]) shl 8) or uint32(msg[off + 3])
    for t in 16 ..< 64:
      let s0 = rotr32(w[t - 15], 7) xor rotr32(w[t - 15], 18) xor (w[t - 15] shr 3'u32)
      let s1 = rotr32(w[t - 2], 17) xor rotr32(w[t - 2], 19) xor (w[t - 2] shr 10'u32)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    var a = h[0]; var b = h[1]; var c = h[2]; var d = h[3]
    var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
    for t in 0 ..< 64:
      let sig1 = rotr32(e, 6) xor rotr32(e, 11) xor rotr32(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let temp1 = hh + sig1 + ch + Sha256K[t] + w[t]
      let sig0 = rotr32(a, 2) xor rotr32(a, 13) xor rotr32(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let temp2 = sig0 + maj
      hh = g; g = f; f = e; e = d + temp1
      d = c; c = b; b = a; a = temp1 + temp2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    blockIdx += 64

  for i in 0 ..< 8:
    result[i * 4] = byte((h[i] shr 24) and 0xFF)
    result[i * 4 + 1] = byte((h[i] shr 16) and 0xFF)
    result[i * 4 + 2] = byte((h[i] shr 8) and 0xFF)
    result[i * 4 + 3] = byte(h[i] and 0xFF)

proc sha256OfString(s: string): array[32, byte] =
  ## Convenience: SHA-256 of a string's UTF-8 bytes.  Used for the
  ## inline builtin-default filter (TOML literal in
  ## `builtinNimVmFilterToml`) and for filter file contents we've
  ## already slurped via readFile.
  var buf = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    buf[i] = byte(s[i])
  sha256Sum(buf)

const BuiltinFilterSentinelPath* = "<inline:builtin-default>"
  ## TF-M7 spec § 7 sentinel for the recorder-embedded default filter.
  ## Defined as a constant so the smoke tests (and any downstream
  ## audit tooling) can match against it without recomputing the
  ## string.

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
    nextVariableIndex*: uint64          ## counter for synthetic r<N> varnames
    pendingValues*: seq[VariableValue]  ## values buffered between steps
    depth*: int
    config*: ConfigRef
    filter*: Classifier                 ## TF-M4: cross-language trace filter

proc canonicalizePath(p: string): string =
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
  if p.len == 0:
    return p
  try:
    return expandFilename(p)
  except OSError:
    discard
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
  let canonical = canonicalizePath(rawPath)

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
  let canonical = canonicalizePath(rawPath)
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

proc readFilterFileForProvenance(path: string): Result[string, string] =
  ## Slurp a filter TOML file's content for SHA-256 hashing.  Errors
  ## are surfaced with the same prefix `loadComposedClassifier` uses,
  ## so the recorder-startup diagnostic stays consistent.
  try:
    ok(readFile(path))
  except IOError as e:
    err("failed to read filter file '" & path & "': " & e.msg)
  except OSError as e:
    err("failed to read filter file '" & path & "': " & e.msg)

proc loadComposedClassifier*(
    config: ConfigRef, scriptPath: string,
    provenance: var seq[FilterProvenance]): Result[Classifier, string] =
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
  ## TF-M7: each loaded source is also appended (in composition order)
  ## to `provenance` with its SHA-256 digest, so the tracer can emit
  ## the chain into meta.dat per Trace-Filters.md § 7.

  provenance = @[]

  # Layer 1: builtin default. Parsing failure is a programmer bug — surface
  # it loudly rather than silently shipping an unfiltered trace.
  let builtinRes = compileFiltersInline(builtinNimVmFilterToml, "<builtin>")
  if builtinRes.isErr:
    return err("BUG: builtin trace filter failed to parse: " & builtinRes.error)
  var classifier = builtinRes.get()
  provenance.add(FilterProvenance(
    path: BuiltinFilterSentinelPath,
    sha256: sha256OfString(builtinNimVmFilterToml),
  ))

  # Layer 2: auto-discovery, unless suppressed.
  if config != nil and not config.noAutoFilter:
    let autoPath = findAutoFilter(scriptPath)
    if autoPath.len > 0:
      let contentRes = readFilterFileForProvenance(autoPath)
      if contentRes.isErr:
        return err(contentRes.error)
      let content = contentRes.get()
      let r = compileFiltersInline(content, autoPath)
      if r.isErr:
        return err(r.error)
      let extra = r.get()
      for rule in extra.rules:
        classifier.rules.add(rule)
      classifier.sources.add(autoPath)
      for w in extra.warnings:
        classifier.warnings.add(w)
      classifier.defaultExec = extra.defaultExec
      provenance.add(FilterProvenance(
        path: autoPath,
        sha256: sha256OfString(content),
      ))

  # Layer 3: env var.
  let envPaths = parseEnvFilterPaths(getEnv("CODETRACER_TRACE_FILTER"))
  for envPath in envPaths:
    let contentRes = readFilterFileForProvenance(envPath)
    if contentRes.isErr:
      return err(contentRes.error)
    let content = contentRes.get()
    let r = compileFiltersInline(content, envPath)
    if r.isErr:
      return err(r.error)
    let extra = r.get()
    for rule in extra.rules:
      classifier.rules.add(rule)
    classifier.sources.add(envPath)
    for w in extra.warnings:
      classifier.warnings.add(w)
    classifier.defaultExec = extra.defaultExec
    provenance.add(FilterProvenance(
      path: envPath,
      sha256: sha256OfString(content),
    ))

  # Layer 4: CLI flag(s).
  if config != nil:
    for cliPath in config.traceFilterPaths:
      let contentRes = readFilterFileForProvenance(cliPath)
      if contentRes.isErr:
        return err(contentRes.error)
      let content = contentRes.get()
      let r = compileFiltersInline(content, cliPath)
      if r.isErr:
        return err(r.error)
      let extra = r.get()
      for rule in extra.rules:
        classifier.rules.add(rule)
      classifier.sources.add(cliPath)
      for w in extra.warnings:
        classifier.warnings.add(w)
      classifier.defaultExec = extra.defaultExec
      provenance.add(FilterProvenance(
        path: cliPath,
        sha256: sha256OfString(content),
      ))

  ok(classifier)

proc initVmTracer*(outputPath: string, scriptPath: string,
                   config: ConfigRef): Result[ptr VmTracer, string] =
  ## Create a new VmTracer. Returns a heap-allocated pointer suitable
  ## for storing in TCtx.vmTracer.
  let writerRes = initMultiStreamWriter(outputPath, scriptPath)
  if writerRes.isErr:
    return err("failed to create trace writer: " & writerRes.error)

  var provenance: seq[FilterProvenance] = @[]
  let filterRes = loadComposedClassifier(config, scriptPath, provenance)
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
    funcByItemId: initTable[ItemId, FuncCacheEntry](),
    functions: initTable[string, uint64](),
    typeNames: initTable[string, uint64](),
    nextVariableIndex: 0,
    pendingValues: @[],
    depth: 0,
    config: config,
    filter: filterRes.get(),
  )

  # TF-M7: record the active filter chain provenance (composition
  # order, with SHA-256 of each source) so the meta.dat block reflects
  # exactly which TOML files / inline defaults drove this recording.
  # We always set `recordEvenIfEmpty = true` because the Nim VM tracer
  # is a Tier-1 filter-aware recorder and spec § 7 mandates such
  # recorders SHOULD emit at least the builtin-default entry (which
  # `loadComposedClassifier` always produces).
  tracer.writer.setFilterProvenance(provenance, recordEvenIfEmpty = true)

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
