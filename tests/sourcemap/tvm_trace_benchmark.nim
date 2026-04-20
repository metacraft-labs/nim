discard """
  action: "run"
  targets: "c"
  disabled: "true"
"""

## Benchmark: measure overhead of `--trace` on VM execution.
##
## This test is disabled by default (not run in CI) since it measures
## wall-clock time and results vary across machines. Run manually with:
##   nim c -r tests/sourcemap/tvm_trace_benchmark.nim

import std/[os, osproc, compilesettings, times, strutils, assertions]

const
  testsDir = currentSourcePath().parentDir
  buildDir = testsDir / "build_tvm_trace_bench"

const benchScript = """
## Benchmark workload: compute Fibonacci numbers iteratively,
## plus string concatenation to exercise multiple opcode types.

proc fib(n: int): int =
  var a = 0
  var b = 1
  for i in 0 ..< n:
    let tmp = a + b
    a = b
    b = tmp
  return a

proc buildString(n: int): string =
  result = ""
  for i in 0 ..< n:
    result.add($i)
    result.add(" ")

proc main() =
  var total = 0
  for i in 0 ..< 200:
    total += fib(30)
  discard buildString(500)
  echo total

main()
"""

proc measure(nim, scriptFile: string, extraArgs: string = ""): float =
  ## Run the script and return elapsed wall-clock seconds.
  let cmd = nim & " e " & extraArgs & " " & scriptFile
  let start = cpuTime()
  let (output, exitCode) = execCmdEx(cmd)
  let elapsed = cpuTime() - start
  doAssert exitCode == 0, "benchmark run failed: " & output
  return elapsed

proc main() =
  let nim = getCurrentCompilerExe()
  createDir(buildDir)

  let scriptFile = buildDir / "bench_workload.nims"
  let traceFile = buildDir / "bench_trace.ct"
  writeFile(scriptFile, benchScript)

  # Warm up
  discard measure(nim, scriptFile)

  # Run without tracing
  let noTraceTime = measure(nim, scriptFile)

  # Run with tracing
  let traceTime = measure(nim, scriptFile,
                          "--trace:" & traceFile)

  let overhead = if noTraceTime > 0.0:
    (traceTime - noTraceTime) / noTraceTime * 100.0
  else:
    0.0

  echo "Without --trace: " & formatFloat(noTraceTime, ffDecimal, 3) & "s"
  echo "With    --trace: " & formatFloat(traceTime, ffDecimal, 3) & "s"
  echo "Overhead:        " & formatFloat(overhead, ffDecimal, 1) & "%"

  if fileExists(traceFile):
    echo "Trace file size: " & $(getFileSize(traceFile) div 1024) & " KB"

  removeDir(buildDir)
  echo "PASS: tvm_trace_benchmark"

main()
