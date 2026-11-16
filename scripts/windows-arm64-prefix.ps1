# Build and qualify one native Windows ARM64 Nim prefix from a Linux seed.
#
# Driven by .github/workflows/windows-arm64-prefix.yml; see its header for the
# contract (reprobuild-pm Distribution-And-Packaging.md §7.1, W2). Every image
# this script runs after the llvm-mingw download is an ARM64 image built here
# or by llvm-mingw; nothing runs under x64 emulation.
#
# Evidence (logs, receipt, the ZIP) goes to -Evidence.
param(
    [Parameter(Mandatory = $true)][string]$Label,
    [Parameter(Mandatory = $true)][string]$Repo,
    [Parameter(Mandatory = $true)][string]$Commit,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SeedArchive,
    [Parameter(Mandatory = $true)][string]$LlvmMingwRelease,
    [Parameter(Mandatory = $true)][string]$LlvmMingwSha256,
    [Parameter(Mandatory = $true)][string]$WorkRoot,
    [Parameter(Mandatory = $true)][string]$Evidence,
    [Parameter(Mandatory = $true)][string]$FactoryRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Native exit codes are checked explicitly below, with the command named.
$PSNativeCommandUseErrorActionPreference = $false

$Arm64 = 0xAA64
$receipt = [ordered]@{
    label = $Label; repo = $Repo; commit = $Commit; version = $Version
    factoryRevision = $FactoryRevision; llvmMingwRelease = $LlvmMingwRelease
    llvmMingwSha256 = $LlvmMingwSha256; runner = $env:RUNNER_NAME
    steps = [ordered]@{}
}

function Get-PeMachine([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).ProviderPath)
    if ($bytes.Length -lt 0x40 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) { throw "Not a PE image: $Path" }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ([BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550) { throw "Not a PE image: $Path" }
    return [int][BitConverter]::ToUInt16($bytes, $pe + 4)
}

function Assert-Arm64([string]$Path) {
    $machine = Get-PeMachine $Path
    if ($machine -ne $Arm64) { throw ("{0} is machine 0x{1:X4}, not ARM64 0xAA64" -f $Path, $machine) }
}

function Invoke-Step {
    ## Run $Image with $Arguments in $Directory, tee the output into the
    ## evidence directory, record the duration, and throw naming the step on a
    ## nonzero exit. Returns the combined output.
    param([string]$Name, [string]$Image, [string[]]$Arguments, [string]$Directory)
    $log = Join-Path $Evidence "$Label-$Name.log"
    # Tee-Object creates no file for a command that prints nothing.
    Set-Content -LiteralPath $log -Value $null
    $started = Get-Date
    Push-Location $Directory
    try {
        & $Image @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log | Out-Host
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $seconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    $receipt.steps[$Name] = [ordered]@{ exit = $code; seconds = $seconds }
    Write-Host ("== {0}: exit {1} in {2}s" -f $Name, $code, $seconds)
    if ($code -ne 0) { throw "$Name failed with exit code $code (log: $log)" }
    return (Get-Content -LiteralPath $log -Raw)
}

New-Item -ItemType Directory -Force -Path $WorkRoot, $Evidence | Out-Null
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$originalPath = $env:PATH

# ── 1. The C compiler: llvm-mingw, aarch64-hosted, UCRT (W1) ─────────────────
$llvmZip = Join-Path $WorkRoot "llvm-mingw-$LlvmMingwRelease-ucrt-aarch64.zip"
Invoke-WebRequest -Uri "https://github.com/mstorsjo/llvm-mingw/releases/download/$LlvmMingwRelease/llvm-mingw-$LlvmMingwRelease-ucrt-aarch64.zip" -OutFile $llvmZip
$actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $llvmZip).Hash.ToLowerInvariant()
if ($actualSha -ne $LlvmMingwSha256.ToLowerInvariant()) { throw "llvm-mingw sha256 $actualSha does not match the pin" }
& $tar -xf $llvmZip -C $WorkRoot
if ($LASTEXITCODE -ne 0) { throw 'extracting llvm-mingw failed' }
$llvmBin = Join-Path $WorkRoot "llvm-mingw-$LlvmMingwRelease-ucrt-aarch64\bin"
Assert-Arm64 (Join-Path $llvmBin 'clang.exe')
$env:PATH = "$llvmBin;$originalPath"
$receipt.cc = (& (Join-Path $llvmBin 'gcc.exe') --version | Select-Object -First 1)

# ── 2. The source, at the exact commit the seed was generated from ───────────
$src = Join-Path $WorkRoot 'src'
$seedRoot = Join-Path $WorkRoot 'seed-unpacked'
New-Item -ItemType Directory -Force -Path $seedRoot | Out-Null
& $tar -xzf $SeedArchive -C $seedRoot
if ($LASTEXITCODE -ne 0) { throw 'extracting the seed failed' }
$seed = Join-Path $seedRoot 'seed'
$seedSource = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $seed 'SEED_SOURCE')) {
    $k, $v = $line -split '=', 2
    $seedSource[$k] = $v
}
foreach ($pair in @(@('repo', $Repo), @('commit', $Commit), @('version', $Version))) {
    if ($seedSource[$pair[0]] -ne $pair[1]) { throw "seed $($pair[0]) '$($seedSource[$pair[0]])' is not '$($pair[1])'" }
}
$receipt.seedSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $SeedArchive).Hash.ToLowerInvariant()
git init -q $src
git -C $src fetch -q --depth 1 $Repo $Commit
git -C $src checkout -q FETCH_HEAD
if ((git -C $src rev-parse HEAD).Trim() -ne $Commit) { throw 'source checkout is not the seed commit' }
git clone -q https://github.com/nim-lang/checksums.git (Join-Path $src 'dist/checksums')
git -C (Join-Path $src 'dist/checksums') checkout -q $seedSource['checksums']
if ($LASTEXITCODE -ne 0) { throw 'checksums checkout failed' }

# The release tree carries icons\*_icon.o as x64 COFF objects, which
# compiler/nim.nim and koch.nim link on Windows+gcc. Rebuild them for ARM64
# (an upstream Nim gap: the objects are architecture-specific but committed).
foreach ($icon in @('nim', 'koch')) {
    $null = Invoke-Step "windres-$icon" 'aarch64-w64-mingw32-windres' @('-i', "icons/$icon.rc", '-O', 'coff', '-o', "icons/${icon}_icon.o") $src
}
Copy-Item -LiteralPath (Join-Path $src 'icons/nim_icon.o') -Destination (Join-Path $seed 'nim_icon.o')

# ── 3. Compile the seed natively ────────────────────────────────────────────
# genScript wrote the generating host's source root into every -I; point
# them at this host's checkout of the same commit.
$seedRootPath = (Get-Content -LiteralPath (Join-Path $seed 'SOURCE_ROOT') -Raw).Trim()
$script = Join-Path $seed 'compile_nim.bat'
$text = [IO.File]::ReadAllText($script)
$rewritten = $text
foreach ($sep in @('\', '/')) {
    $rewritten = $rewritten.Replace("-I$seedRootPath$sep", "-I$src\")
}
if ($rewritten -eq $text) { throw "the seed script names no -I$seedRootPath include root" }
[IO.File]::WriteAllText($script, $rewritten)
$null = Invoke-Step 'seed-compile' 'cmd.exe' @('/d', '/c', 'compile_nim.bat') $seed
Assert-Arm64 (Join-Path $seed 'nim.exe')
New-Item -ItemType Directory -Force -Path (Join-Path $src 'bin') | Out-Null
Copy-Item -LiteralPath (Join-Path $seed 'nim.exe') -Destination (Join-Path $src 'bin/nim.exe')

# ── 4. koch boot to a byte-identical fixpoint ───────────────────────────────
# --no-insert-timestamp: the PE link timestamp alone makes two otherwise
# identical iterations differ, and koch is silent about inequality on Windows.
$nim = Join-Path $src 'bin/nim.exe'
$null = Invoke-Step 'build-koch' $nim @('c', '-d:release', '--hints:off', '--out:koch.exe', 'koch.nim') $src
Assert-Arm64 (Join-Path $src 'koch.exe')
$boot = Invoke-Step 'koch-boot' (Join-Path $src 'koch.exe') @('boot', '-d:release', '--cc:gcc', '--hints:off', '--passL:-Wl,--no-insert-timestamp') $src
if ($boot -notmatch 'executables are equal: SUCCESS!') {
    throw 'koch boot did not reach a byte-identical fixpoint (no "executables are equal: SUCCESS!")'
}
Assert-Arm64 $nim
$versionText = Invoke-Step 'nim-version' $nim @('--version') $src
if ($versionText -notmatch "Nim Compiler Version $([regex]::Escape($Version)) \[Windows: arm64\]") {
    throw "bin/nim.exe does not report Nim $Version for Windows arm64"
}
if ($versionText -notmatch "git hash: $Commit") { throw 'bin/nim.exe does not name the source commit' }

# ── 5. The distribution: koch zip's tree, zipped here ───────────────────────
# koch zip builds the tools and assembles build/nim-<version>; its last step
# shells out to 7z, which this host need not have and whose absence niminst
# only reports. The tree is zipped with .NET instead, UTF-8 names.
$null = Invoke-Step 'koch-zip' (Join-Path $src 'koch.exe') @('zip', '-d:release', '--cc:gcc', '--passL:-Wl,--no-insert-timestamp') $src
$tree = Join-Path $src "build/nim-$Version"
foreach ($relative in @('bin/nim.exe', 'bin/nimble.exe', 'bin/nimsuggest.exe', 'bin/vccexe.exe', 'lib/system.nim', 'config/nim.cfg', 'compiler/nim.nim')) {
    if (-not (Test-Path -LiteralPath (Join-Path $tree $relative) -PathType Leaf)) { throw "the distribution lacks $relative" }
}
foreach ($image in Get-ChildItem -LiteralPath $tree -Recurse -File -Include '*.exe', '*.dll') { Assert-Arm64 $image.FullName }
$zipName = "$Label-$($Commit.Substring(0, 12))-windows-arm64.zip"
$zip = Join-Path $Evidence $zipName
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($tree, $zip, [IO.Compression.CompressionLevel]::Optimal, $true, [Text.Encoding]::UTF8)

# ── 6. Qualify the packaged prefix, from a fresh extraction ─────────────────
$prefixRoot = Join-Path $WorkRoot 'qualify'
[IO.Compression.ZipFile]::ExtractToDirectory($zip, $prefixRoot)
$prefix = Join-Path $prefixRoot "nim-$Version"
$pnim = Join-Path $prefix 'bin/nim.exe'
Assert-Arm64 $pnim
$scratch = Join-Path $WorkRoot 'smoke'
New-Item -ItemType Directory -Force -Path $scratch | Out-Null
[IO.File]::WriteAllText((Join-Path $scratch 'prefix_smoke.nim'), @'
import std/[json, osproc, sequtils, strutils, typedthreads]
let data = parseJson("{\"values\":[2,3,5]}")
doAssert data["values"].getElems.mapIt(it.getInt).foldl(a + b) == 10
proc worker(p: ptr int) {.thread.} = p[] = 42
var v = 0
var t: Thread[ptr int]
createThread(t, worker, addr v); joinThread(t)
doAssert v == 42
try: raise newException(ValueError, "x")
except ValueError: discard
doAssert "child-ok" in execProcess("cmd.exe", args = ["/c", "echo child-ok"], options = {poUsePath})
doAssert hostCPU == "arm64" and hostOS == "windows"
echo "arm64-prefix-stdlib-ok"
'@)
$smoke = Join-Path $scratch 'prefix_smoke.exe'
$null = Invoke-Step 'smoke-compile' $pnim @('c', '-d:release', '--cc:gcc', '--hints:off', '--nimcache:cache-smoke', "--out:$smoke", 'prefix_smoke.nim') $scratch
Assert-Arm64 $smoke
$run = Invoke-Step 'smoke-run' $smoke @() $scratch
if ($run -notmatch 'arm64-prefix-stdlib-ok') { throw 'the stdlib smoke did not report success' }
# The fork's compiler-argument-file controls, where the source has them (the
# 2.2.10 maintenance source does; upstream 2.2.8 does not).
$argsTest = Join-Path $src 'tests/misc/tcompilerargsfile.nim'
if (Test-Path -LiteralPath $argsTest -PathType Leaf) {
    $argsLog = Invoke-Step 'compiler-args-file-controls' $pnim @('r', '--hints:off', '--cc:gcc', "--nimcache:$(Join-Path $scratch 'cache-argsfile')", "--out:$(Join-Path $scratch 'tcompilerargsfile.exe')", $argsTest) $scratch
    if ($argsLog -notmatch 'compiler argument file controls passed') { throw 'compiler argument file controls did not report success' }
    $receipt.compilerArgsFileControls = 'passed'
} else {
    $receipt.compilerArgsFileControls = 'not in this source'
}

$receipt.zip = $zipName
$receipt.zipSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
$receipt.nimVersion = ($versionText -split "`n" | Select-Object -First 1).Trim()
$receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Evidence "receipt-$Label.json") -Encoding utf8
Write-Host "Qualified $zipName sha256 $($receipt.zipSha256)"
