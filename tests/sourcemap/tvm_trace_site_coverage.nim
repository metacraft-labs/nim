discard """
  action: "run"
  targets: "c"
  matrix: "-p:$lib/../dist/codetracer-trace-format-nim/src -p:$lib/../dist/nim-results -p:$lib/../dist/nim-stew"
"""

## CTFS-M-TraceSites: end-to-end test for traceAssignment coverage of the
## register-writing opcodes that CTFS-M-Varnames left unhooked.
##
## Pre-CTFS-M-TraceSites, only `opcAsgnInt`, `opcAsgnFloat`,
## `opcAsgnComplex`, `opcFastAsgnComplex`, `opcLdObj`, `opcWrObj` fired
## `traceAssignment`. That excluded:
##
##   * module-scope (global) writes via `opcWrDeref` — `let x = 42` at
##     top level produced ZERO value records because the runtime
##     destination is a temp `rkNodeAddr`, not the user-binding slot.
##   * literal/initializer loads (`opcLdImmInt`, `opcLdConst`,
##     `opcLdNull`, `opcLdNullReg`).
##   * arithmetic-into-binding (`opcAddInt`, `opcAddImmInt`, `opcSubInt`,
##     `opcSubImmInt`, `opcMulInt`, `opcDivInt`, `opcModInt`,
##     `opcAddFloat`, `opcSubFloat`, `opcMulFloat`, `opcDivFloat`).
##
## After CTFS-M-TraceSites, all of the above fire `traceAssignment` at
## the post-write point; the resolver's nil-sym short-circuit keeps
## compiler temporaries out of the value stream so the trace stays
## bounded.
##
## This test exercises three user-binding write paths:
##
##   1. Top-level (module-scope) binding via `opcWrDeref`:
##      `let topInt = 42`. Pre-CTFS-M-TraceSites this produced no value
##      record at all; this test asserts the record exists with value 42.
##   2. Proc-local binding via arithmetic-into-binding:
##      `var counter = 0; counter = counter + 5` exercises
##      `opcAddImmInt` writing back to `counter`'s slot.
##   3. Proc-local binding via return-value assignment:
##      `let local = compute(7)` exercises the global write (`r =
##      demo(7)` pattern) at module scope.

import std/[os, osproc, assertions, strutils]
import results

{.passL: "-lzstd".}

import codetracer_trace_writer/new_trace_reader

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_site_coverage"

const testScript = """
# Top-level user bindings — exercises module-scope opcWrDeref writes.
let topInt = 42
var topVar = 0
topVar = topVar + 1

# Proc-local — exercises proc-scope writes through the existing trace sites.
proc compute(x: int): int =
  result = x * 2
let local = compute(7)

# Arithmetic-into-binding — exercises opcAddImmInt / opcMulInt writing
# directly back into the binding's slot.
var counter = 0
counter = counter + 5
counter = counter * 3

echo topInt, " ", topVar, " ", local, " ", counter
"""

proc readIntFromCbor(data: openArray[byte]): int64 =
  ## Decode `{"kind":"Int","i":<int>,"type_id":<id>}` CBOR into an int64.
  ## CBOR map header 0xA3, key "kind"=string(4)="Int", key "i"=value,
  ## key "type_id"=int. We scan for the "i" key (a single-byte text "i"
  ## of length 1: 0x61 0x69, i.e. major-type 3 short string).
  ## Returns int64.high on parse failure (sentinel).
  if data.len < 4:
    return int64.high
  var pos = 0
  # Expect 0xA3 (map with 3 entries) at pos 0.
  if data[pos] != 0xA3'u8:
    return int64.high
  pos += 1
  # Walk the map looking for the text-string key "i" (length 1).
  while pos < data.len - 1:
    if data[pos] == 0x61'u8 and pos + 1 < data.len and data[pos + 1] == 0x69'u8:
      pos += 2
      if pos >= data.len:
        return int64.high
      let first = data[pos]
      if first < 0x18'u8:
        # Direct unsigned int 0..23.
        return int64(first)
      elif first == 0x18'u8 and pos + 1 < data.len:
        return int64(data[pos + 1])
      elif first == 0x19'u8 and pos + 2 < data.len:
        return int64(uint16(data[pos + 1]) shl 8 or uint16(data[pos + 2]))
      elif first == 0x1A'u8 and pos + 4 < data.len:
        return int64(uint32(data[pos + 1]) shl 24 or
                     uint32(data[pos + 2]) shl 16 or
                     uint32(data[pos + 3]) shl 8 or
                     uint32(data[pos + 4]))
      else:
        return int64.high
    pos += 1
  return int64.high

proc main() =
  let nim = getCurrentCompilerExe()
  doAssert fileExists(nim), "compiler binary not found at: " & nim

  createDir(buildDir)
  let scriptFile = buildDir / "test_site_coverage.nims"
  let traceFile = buildDir / "test_site_coverage.ct"
  writeFile(scriptFile, testScript)

  let cmd = nim & " e --trace:" & traceFile & " " & scriptFile
  let (output, exitCode) = execCmdEx(cmd)
  doAssert exitCode == 0, "nim e --trace failed: " & output
  doAssert "42 1 14 15" in output,
    "expected echo output '42 1 14 15', got: " & output

  doAssert fileExists(traceFile), "trace file not created"
  let openRes = openNewTrace(traceFile)
  doAssert openRes.isOk,
    "openNewTrace failed: " & openRes.error
  var rdr = openRes.get()

  # Walk all value records across all steps, key by binding name.
  let scRes = rdr.stepCount
  doAssert scRes.isOk, "stepCount read failed: " & scRes.error

  var topIntValues: seq[int64] = @[]
  var topVarValues: seq[int64] = @[]
  var localValues: seq[int64] = @[]
  var counterValues: seq[int64] = @[]

  for n in 0'u64 ..< scRes.get():
    let valsRes = rdr.values(n)
    if valsRes.isErr:
      continue
    for vv in valsRes.get():
      let vn = rdr.varname(vv.varnameId)
      if vn.isErr:
        continue
      let name = vn.get()
      let intVal = readIntFromCbor(vv.data)
      if intVal == int64.high:
        continue
      case name
      of "topInt": topIntValues.add(intVal)
      of "topVar": topVarValues.add(intVal)
      of "local": localValues.add(intVal)
      of "counter": counterValues.add(intVal)
      else: discard

  # (1) topInt = 42 — module-scope opcWrDeref write.
  doAssert 42 in topIntValues,
    "expected topInt=42 in trace, got values: " & $topIntValues

  # (2) topVar — module-scope global. The opcWrDeref path emits the
  # post-write value 1 (initialised to 0, then `topVar = topVar + 1`
  # computes the sum in a temp and writes it back via opcWrDeref).
  doAssert 1 in topVarValues,
    "expected topVar=1 in trace, got values: " & $topVarValues

  # (3) local = 14 — module-scope global written by opcWrDeref after
  # compute(7) returns 14.
  doAssert 14 in localValues,
    "expected local=14 in trace, got values: " & $localValues

  # (4) counter goes 0 -> 5 -> 15 via opcAddImmInt, opcMulInt; the
  # initial null-init via opcLdNullReg is also traced.
  doAssert 5 in counterValues,
    "expected counter=5 in trace (arithmetic-into-binding via " &
    "opcAddImmInt/opcWrDeref), got values: " & $counterValues
  doAssert 15 in counterValues,
    "expected counter=15 in trace (arithmetic-into-binding via " &
    "opcMulInt/opcWrDeref), got values: " & $counterValues

  removeDir(buildDir)
  echo "PASS: tvm_trace_site_coverage — topInt=", topIntValues,
       " topVar=", topVarValues,
       " local=", localValues,
       " counter=", counterValues

main()
