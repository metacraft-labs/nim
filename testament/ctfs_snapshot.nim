#
#
#            Nim Testament — CTFS Snapshot Harness
#        (c) Copyright 2026 Metacraft Labs
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## CTFS-M1: snapshot diffing for tests running under target `e` (targetVM).
##
## See CodeTracer specs § "CTFS / VM Tracing Coverage" → "CTFS-M1: testament
## evalTrace harness + targetVM" for the design.
##
## Behavior controlled by `TSpec.evalTrace`:
##   - empty (default) — diff against `<testfile>.evaltrace.json` (sibling).
##   - `"skip"`        — opt out (return ok without comparing).
##   - any other value — explicit golden-path override.
##
## Bootstrap-and-fail: if the golden file does not exist, write the generated
## JSON to the expected path and return a failure so CI catches new snapshots
## before they enter the repo. The parent assistant audits each first-run
## snapshot from first principles before commit (per spec).
##
## ---------------------------------------------------------------------------
## Materializer integration (CTFS-M1 correction)
## ---------------------------------------------------------------------------
## Per the spec ("Dependency on `codetracer-trace-format-nim`"), testament
## imports the materializer library directly — `codetracer_ct_print_lib`'s
## `buildFullDocument(reader, FullOpts(stripPaths: true))` is the same code
## path the `ct-print` CLI uses for `--full --strip-paths`. The compiler
## already imports the same trace-format library (for vm_trace emission), so
## testament inherits the same dependency surface as the compiler — no
## additional cost beyond what `koch boot` already pulls in.
##
## Sibling-repo path resolution lives in `testament/testament.nim.cfg`
## (`--path:"$nim/dist/codetracer-trace-format-nim/src"`), mirroring the
## compiler's `config/nim.cfg` setup.

import std/[json, os, strutils]
import codetracer_trace_writer/new_trace_reader
import codetracer_ct_print_lib

type
  SnapshotOutcome* = enum
    snapPass        ## golden existed and matched
    snapSkipped     ## evalTrace == "skip"
    snapBootstrap   ## golden did not exist — wrote it, must fail
    snapMismatch    ## golden existed but differed
    snapError       ## materializer / IO error

  SnapshotResult* = object
    outcome*: SnapshotOutcome
    goldenPath*: string
    detail*: string   ## human-readable diff / error / message

proc materializeTrace*(ctFile: string):
    tuple[ok: bool, json: JsonNode, detail: string] =
  ## Open the `.ct` trace at `ctFile` via the seek-based reader and produce
  ## the same JSON document that `ct-print --full --strip-paths` emits.
  if not fileExists(ctFile):
    return (false, newJNull(), "trace file not found: " & ctFile)
  let openRes = openNewTrace(ctFile)
  if openRes.isErr:
    return (false, newJNull(),
      "failed to open trace " & ctFile & ": " & openRes.error)
  var reader = openRes.get()
  try:
    let doc = buildFullDocument(reader, FullOpts(stripPaths: true))
    return (true, doc, "")
  except CatchableError as e:
    return (false, newJNull(),
      "materializer raised " & $e.name & ": " & e.msg)

proc resolveGoldenPath*(testFile, evalTraceField: string): string =
  ## Compute the on-disk path for the golden snapshot given the test source
  ## file and the parsed `evalTrace` field. Caller must filter out the "skip"
  ## case before calling this.
  if evalTraceField.len == 0:
    result = testFile & ".evaltrace.json"
  elif isAbsolute(evalTraceField):
    result = evalTraceField
  else:
    # Resolve relative paths against the test source directory so authors can
    # write `evalTrace: "snapshots/foo.json"` and have it land next to the
    # test rather than relative to cwd.
    result = testFile.parentDir / evalTraceField

proc renderJsonStable*(j: JsonNode): string =
  ## Pretty-print with deterministic key order. `std/json` preserves insertion
  ## order; `buildFullDocument` is already deterministic by spec. We use a
  ## 2-space indent so diffs are readable.
  pretty(j, 2) & "\n"

proc lineDiff*(expected, actual: string): string =
  ## Produce a compact line-by-line diff suitable for a failure message.
  ## We avoid pulling in a real diff library — for small JSON snapshots a
  ## first-difference report with surrounding context is sufficient.
  let exp = expected.splitLines
  let act = actual.splitLines
  var firstDiff = -1
  for i in 0 ..< min(exp.len, act.len):
    if exp[i] != act[i]:
      firstDiff = i
      break
  if firstDiff < 0:
    if exp.len != act.len:
      firstDiff = min(exp.len, act.len)
    else:
      return ""  # actually identical
  var report = "[CTFS] snapshot mismatch (first divergence at line " &
    $(firstDiff + 1) & "):\n"
  let ctxStart = max(0, firstDiff - 2)
  let ctxEnd = min(max(exp.len, act.len), firstDiff + 4)
  for i in ctxStart ..< ctxEnd:
    let e = if i < exp.len: exp[i] else: "<missing>"
    let a = if i < act.len: act[i] else: "<missing>"
    if e == a:
      report.add "  " & $(i + 1) & ":  " & e & "\n"
    else:
      report.add "- " & $(i + 1) & ":  " & e & "\n"
      report.add "+ " & $(i + 1) & ":  " & a & "\n"
  report

proc runSnapshotCheck*(testFile, evalTraceField, ctFile: string): SnapshotResult =
  ## End-to-end CTFS-M1 snapshot pipeline. `ctFile` is the .ct trace produced
  ## by `nim e --trace:<ctFile>` for the test.
  if evalTraceField == "skip":
    return SnapshotResult(outcome: snapSkipped)

  let goldenPath = resolveGoldenPath(testFile, evalTraceField)

  let mat = materializeTrace(ctFile)
  if not mat.ok:
    return SnapshotResult(outcome: snapError, goldenPath: goldenPath,
      detail: "[CTFS] materializer failed: " & mat.detail)

  let generated = renderJsonStable(mat.json)

  if not fileExists(goldenPath):
    try:
      writeFile(goldenPath, generated)
    except IOError as e:
      return SnapshotResult(outcome: snapError, goldenPath: goldenPath,
        detail: "[CTFS] failed to write bootstrap snapshot " &
                goldenPath & ": " & e.msg)
    return SnapshotResult(outcome: snapBootstrap, goldenPath: goldenPath,
      detail: "[CTFS] snapshot bootstrap — wrote " & goldenPath &
              "; review and commit")

  let existing = try: readFile(goldenPath)
                 except IOError as e:
                   return SnapshotResult(outcome: snapError,
                     goldenPath: goldenPath,
                     detail: "[CTFS] failed to read golden " &
                             goldenPath & ": " & e.msg)
  if existing == generated:
    return SnapshotResult(outcome: snapPass, goldenPath: goldenPath)
  return SnapshotResult(outcome: snapMismatch, goldenPath: goldenPath,
    detail: lineDiff(existing, generated))
