discard """
  action: "run"
  targets: "c"
"""

## Benchmark: NimScript with/without --trace, target <2x overhead.
##
## Runs a compute-heavy NimScript (fibonacci, sorting) with and without
## --trace using nim_trace, measures wall-clock time, reports overhead
## ratio, and fails if it exceeds 2x.

import std/[os, osproc, times, strutils, assertions, algorithm]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_bench"

const benchScript = """
## Benchmark workload: iterative fibonacci + bubble sort to exercise
## multiple opcode types with substantial iteration count.

proc fib(n: int): int =
  var a = 0
  var b = 1
  for i in 0 ..< n:
    let tmp = a + b
    a = b
    b = tmp
  return a

proc bubbleSort(arr: var seq[int]) =
  let n = arr.len
  for i in 0 ..< n:
    for j in 0 ..< n - i - 1:
      if arr[j] > arr[j + 1]:
        let tmp = arr[j]
        arr[j] = arr[j + 1]
        arr[j + 1] = tmp

proc buildString(n: int): string =
  result = ""
  for i in 0 ..< n:
    result.add($i)
    result.add(" ")

proc main() =
  var total = 0
  for i in 0 ..< 200:
    total += fib(30)

  var data: seq[int] = @[]
  for i in countdown(100, 1):
    data.add(i)
  bubbleSort(data)

  discard buildString(500)
  echo total

main()
"""

proc findNimTrace(): string =
  let nimDir = getCurrentCompilerExe().parentDir
  result = nimDir / "nim_trace"
  if not fileExists(result):
    result = ""

proc measure(nim, scriptFile: string, extraArgs: string = ""): float =
  ## Run the script and return elapsed wall-clock seconds.
  let cmd = nim & " e " & extraArgs & " " & scriptFile
  let start = epochTime()
  let (output, exitCode) = execCmdEx(cmd)
  let elapsed = epochTime() - start
  doAssert exitCode == 0, "benchmark run failed: " & output
  return elapsed

proc main() =
  let nim = findNimTrace()
  if nim == "":
    echo "SKIP: nim_trace binary not found (build with -d:codetracerTracing)"
    quit(0)

  createDir(buildDir)

  let scriptFile = buildDir / "bench_workload.nims"
  let traceFile = buildDir / "bench_trace.ct"
  writeFile(scriptFile, benchScript)

  # Warm-up run (populates filesystem caches, etc.)
  discard measure(nim, scriptFile)

  # Run without tracing (3 iterations, take median)
  var noTraceTimes: seq[float]
  for i in 0 ..< 3:
    noTraceTimes.add(measure(nim, scriptFile))

  # Run with tracing (3 iterations, take median)
  var traceTimes: seq[float]
  for i in 0 ..< 3:
    # Remove old trace file to avoid append
    if fileExists(traceFile):
      removeFile(traceFile)
    traceTimes.add(measure(nim, scriptFile, "--trace:" & traceFile))

  sort(noTraceTimes)
  sort(traceTimes)

  let noTraceTime = noTraceTimes[1]  # median
  let traceTime = traceTimes[1]      # median

  let ratio = if noTraceTime > 0.0:
    traceTime / noTraceTime
  else:
    1.0

  let overhead = (ratio - 1.0) * 100.0

  echo "Without --trace: " & formatFloat(noTraceTime, ffDecimal, 3) & "s"
  echo "With    --trace: " & formatFloat(traceTime, ffDecimal, 3) & "s"
  echo "Ratio:           " & formatFloat(ratio, ffDecimal, 2) & "x"
  echo "Overhead:        " & formatFloat(overhead, ffDecimal, 1) & "%"

  if fileExists(traceFile):
    echo "Trace file size: " & $(getFileSize(traceFile) div 1024) & " KB"

  # Fail if overhead exceeds 2x
  doAssert ratio < 2.0,
    "FAIL: tracing overhead " & formatFloat(ratio, ffDecimal, 2) &
    "x exceeds 2x target (no-trace=" &
    formatFloat(noTraceTime, ffDecimal, 3) & "s, trace=" &
    formatFloat(traceTime, ffDecimal, 3) & "s)"

  removeDir(buildDir)
  echo "PASS: tvm_trace_benchmark - overhead " & formatFloat(ratio, ffDecimal, 2) & "x (< 2.0x)"

main()
