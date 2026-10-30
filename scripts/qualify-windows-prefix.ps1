# Build a complete maintenance prefix with Nim's own stable koch factory.
# No installed compiler or helper is replaced. All native probes use either
# the declared bootstrap prefix or the complete freshly extracted result.
param([string]$EvidenceRoot = 'build/windows-prefix-qualification')
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'This qualification requires real Windows execution' }
$root = Split-Path -Parent $PSScriptRoot
function Read-Git([string]$Directory, [string[]]$Arguments) {
    $value = & git -C $Directory @Arguments
    if ($LASTEXITCODE -ne 0) { throw 'Cannot read source identity' }
    return ($value -join "`n").Trim()
}
$revision = Read-Git $root @('rev-parse', 'HEAD')
if ($revision -notmatch '^[0-9a-f]{40}$') { throw 'Cannot bind source revision' }
if ($env:GITHUB_ACTIONS -eq 'true' -and $env:GITHUB_SHA -cne $revision) { throw 'Checkout differs from dispatched immutable source' }
if (Read-Git $root @('status', '--porcelain', '--untracked-files=no')) { throw 'Tracked source must be committed and clean' }
$evidence = [IO.Path]::GetFullPath((Join-Path $root $EvidenceRoot))
if (Test-Path -LiteralPath $evidence) { throw 'Qualification output already exists' }
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$receipt = @{ complete = $false; version = '2.2.10'; source = $revision; upstreamCommit = 'bfeb3146d1638b39f69007a4ae5a23e23ae4e5ef'; backportedFix = '92455417a79cd3263975b21a97d6062683f2a195'; tree = (Read-Git $root @('rev-parse', 'HEAD^{tree}')); tools = @{} }
$originalPath = $env:PATH
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('nim-prefix-' + [Guid]::NewGuid().ToString('N'))
$hostImage = [Environment]::ProcessPath
$scratchOwned = $false

function Invoke-Logged([string]$Name, [string]$Image, [string[]]$Arguments, [string]$WorkingDirectory = $root) {
    $start = [Diagnostics.ProcessStartInfo]::new($Image)
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $start
    Write-Host "Starting $Name"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $child.Start()) { throw "$Name did not start" }
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        $child.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stdout"), $output)
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stderr"), $errorOutput)
        Write-Host $output
        Write-Host $errorOutput
        return @{ exit = $child.ExitCode; seconds = $timer.Elapsed.TotalSeconds; output = $output }
    } finally { $child.Dispose() }
}
function Require-Success([string]$Name, [string]$Image, [string[]]$Arguments, [string]$WorkingDirectory = $root) {
    $result = Invoke-Logged $Name $Image $Arguments $WorkingDirectory
    if ($result.exit -ne 0) { throw "$Name exited $($result.exit)" }
    return $result
}
function Assert-Amd64([string]$Image) {
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Image))
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw "Not a PE image: $Image" }
        $reader.BaseStream.Position = 0x3c
        $reader.BaseStream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) { throw "Not Windows x64: $Image" }
    } finally { $reader.Dispose() }
}

Push-Location $root
Start-Transcript -LiteralPath (Join-Path $evidence 'controller.log') | Out-Null
try {
    foreach ($name in @('nim.exe', 'gcc.exe', 'git.exe', '7z.exe')) {
        $image = (Get-Command $name -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $receipt.tools[$name] = @{ path = $image; sha256 = (Get-FileHash -LiteralPath $image -Algorithm SHA256).Hash }
    }
    $bootstrap = $receipt.tools['nim.exe'].path
    $bootstrapVersion = Require-Success 'bootstrap-version' $bootstrap @('--version')
    if ($bootstrapVersion.output -notmatch 'Nim Compiler Version 2\.2\.10\b') { throw 'Bootstrap must be the declared Nim 2.2.10' }
    $receipt.bootstrapVersion = $bootstrapVersion.output
    # Bind the invoked images to the EXISTING standard activation receipt.
    # A same-version ambient compiler is not canonical provisioning evidence.
    $inspectionPath = Join-Path $root '.repro/dev-env/default/tarball-tool-identities.inspect.json'
    if (-not (Test-Path -LiteralPath $inspectionPath -PathType Leaf)) { throw 'Canonical activation inspection is missing' }
    Copy-Item -LiteralPath $inspectionPath -Destination (Join-Path $evidence 'bootstrap-tool-identities.inspect.json')
    $inspection = Get-Content -LiteralPath $inspectionPath -Raw | ConvertFrom-Json
    if ($inspection.partial -eq $true) { throw 'Partial activation cannot qualify the factory inputs' }
    $selectors = @{ 'nim.exe' = 'nim'; 'gcc.exe' = 'gcc'; 'git.exe' = 'git'; '7z.exe' = '7zip' }
    foreach ($name in $selectors.Keys) {
        $profiles = @($inspection.profiles | Where-Object { $_.packageSelector -eq $selectors[$name] -and $_.installMethod -eq 'tarball' })
        if ($profiles.Count -ne 1) { throw "No unique canonical profile for $name" }
        $profile = $profiles[0]
        if (-not (Test-Path -LiteralPath $profile.resolvedExecutablePath -PathType Leaf)) { throw "Profile image is absent for $name" }
        if ((Get-FileHash -LiteralPath $profile.resolvedExecutablePath -Algorithm SHA256).Hash -cne $receipt.tools[$name].sha256) { throw "Invoked image differs from selected profile: $name" }
        $receipt.tools[$name].profilePath = $profile.resolvedExecutablePath
        $receipt.tools[$name].profileDigest = $profile.resolvedExecutableDigest
        $receipt.tools[$name].archiveSha256 = $profile.tarballSha256
    }
    if ($receipt.tools['nim.exe'].archiveSha256 -ine 'fe0686a9b298e5b13d0a983df37e002a8c6320f8b16cc45a51d15cf4046a109f') { throw 'Bootstrap is not the declared official2.2.10 archive' }
    $null = Require-Success 'gcc-version' $receipt.tools['gcc.exe'].path @('--version')
    $null = Require-Success 'git-version' $receipt.tools['git.exe'].path @('--version')
    $null = Require-Success '7zip-version' $receipt.tools['7z.exe'].path @('i')
    $oldWrapper = Join-Path (Split-Path -Parent $bootstrap) 'vccexe.exe'
    if (-not (Test-Path -LiteralPath $oldWrapper -PathType Leaf)) { throw 'Declared bootstrap prefix lacks its vccexe' }
    $receipt.oldWrapper = @{ path = $oldWrapper; sha256 = (Get-FileHash -LiteralPath $oldWrapper -Algorithm SHA256).Hash }
    $test = Join-Path $root 'tests/tools/vccexe/test.ps1'
    $old = Invoke-Logged 'old-wrapper-control' $hostImage @('-NoProfile', '-File', $test, '-WrapperPath', $oldWrapper, '-EvidenceRoot', (Join-Path $evidence 'old-wrapper'), '-TargetTriple', 'x86_64-pc-windows-msvc')
    $oldProof = Get-Content -LiteralPath (Join-Path $evidence 'old-wrapper/source-paths/receipt.json') -Raw | ConvertFrom-Json
    $absolute = @($oldProof.cases | Where-Object name -eq 'absolute')
    $direct = @($oldProof.cases | Where-Object name -eq 'direct')
    $unicode = @($oldProof.cases | Where-Object name -eq 'unicode-env')
    if ($old.exit -eq 0 -or $absolute.Count -ne 1 -or $absolute[0].exit -eq 0 -or $direct.Count -ne 1 -or $direct[0].exit -ne 0 -or -not $direct[0].object -or $unicode.Count -ne 1 -or $unicode[0].exit -eq 0) { throw 'Old failure did not have its real same-CL positive control' }
    $receipt.oldControl = 'real absolute-path and Unicode-env RED with same-CL positive'

    if ((Test-Path 'bin/nim.exe') -or (Test-Path 'build/nim-2.2.10.zip')) { throw 'Factory outputs must start absent' }
    $null = Require-Success 'build-koch' $bootstrap @('c', '--lib:lib', '-d:release', '--out:koch.exe', 'koch.nim')
    $koch = Join-Path $root 'koch.exe'
    $boot = Require-Success 'koch-boot' $koch @('boot', '-d:release', '--cc:gcc', '--cpu:amd64', '--parallelBuild:2')
    $receipt.boot = @{ exit = $boot.exit; seconds = $boot.seconds }
    $factory = Require-Success 'koch-zip' $koch @('zip', '-d:release', '--cc:gcc', '--parallelBuild:2')
    $receipt.factory = @{ exit = $factory.exit; seconds = $factory.seconds }
    $zip = Join-Path $root 'build/nim-2.2.10.zip'
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw 'The koch factory produced no complete ZIP' }
    $archive = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace('\', '/')
            if (-not $name.StartsWith('nim-2.2.10/') -or $name.Contains(':') -or ($name.Split('/') -contains '..')) { throw "Unexpected factory archive path: $name" }
        }
    } finally { $archive.Dispose() }
    $extract = Join-Path $evidence 'extracted'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract
    $prefix = Join-Path $extract 'nim-2.2.10'
    foreach ($relative in @('bin/nim.exe', 'bin/vccexe.exe', 'bin/nimble.exe', 'bin/atlas.exe', 'bin/nimsuggest.exe', 'bin/nimgrep.exe', 'bin/nimgrab.exe', 'bin/nimpretty.exe', 'bin/testament.exe', 'koch.exe', 'finish.exe', 'lib/system.nim', 'lib/system/compilation.nim', 'config/nim.cfg', 'compiler/nim.nim', 'tools/vccexe/vccexe.nim', 'tools/vccexe/vcvarsall.nim')) {
        if (-not (Test-Path -LiteralPath (Join-Path $prefix $relative) -PathType Leaf)) { throw "Incomplete prefix: $relative" }
    }
    foreach ($relative in @('lib/system/compilation.nim', 'tools/vccexe/vccexe.nim', 'tools/vccexe/vcvarsall.nim')) {
        if ((Get-FileHash (Join-Path $prefix $relative)).Hash -cne (Get-FileHash (Join-Path $root $relative)).Hash) { throw "Packaged source differs: $relative" }
    }
    foreach ($image in Get-ChildItem -LiteralPath (Join-Path $prefix 'bin') -Filter '*.exe') { Assert-Amd64 $image.FullName }
    $nim = Join-Path $prefix 'bin/nim.exe'
    $env:PATH = (Join-Path $prefix 'bin') + [IO.Path]::PathSeparator + $originalPath
    $version = Require-Success 'packaged-version' $nim @('--version')
    if ($version.output -notmatch 'Nim Compiler Version 2\.2\.10\b') { throw 'Packaged compiler version is not 2.2.10' }
    if ($version.output -notmatch [regex]::Escape("git hash: $revision")) { throw 'Compiled Git hash does not name this backport' }
    if (Test-Path -LiteralPath $scratch) { throw 'Private smoke scratch already exists' }
    if ($scratch.Replace('\', '/').Split('/') -contains '.repro') { throw 'Smoke scratch must be outside workspace .repro state' }
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $scratchOwned = $true
    [IO.File]::WriteAllText((Join-Path $scratch 'prefix_smoke.nim'), @'
import std/[json, sequtils, strutils]
static: doAssert NimMajor == 2 and NimMinor == 2 and NimPatch == 10
let data = parseJson("{\"values\":[2,3,5]}")
doAssert data["values"].getElems.mapIt(it.getInt).foldl(a + b) == 10
doAssert "prefix".toUpperAscii == "PREFIX"
echo "complete-prefix-stdlib-ok"
'@)
    foreach ($backend in @('gcc', 'vcc')) {
        $binary = Join-Path $scratch "smoke-$backend.exe"
        $null = Require-Success "compile-$backend" $nim @('c', '-d:release', "--cc:$backend", "--nimcache:cache-$backend", "--out:$binary", 'prefix_smoke.nim') $scratch
        $run = Require-Success "run-$backend" $binary @() $scratch
        if ($run.output -notmatch 'complete-prefix-stdlib-ok') { throw "$backend stdlib result missing" }
    }
    $null = Require-Success 'packaged-wrapper-control' $hostImage @('-NoProfile', '-File', $test, '-WrapperPath', (Join-Path $prefix 'bin/vccexe.exe'), '-EvidenceRoot', (Join-Path $evidence 'packaged-wrapper'), '-TargetTriple', 'x86_64-pc-windows-msvc')
    $files = @(Get-ChildItem -LiteralPath $prefix -File -Recurse | Sort-Object FullName | ForEach-Object { @{ path = [IO.Path]::GetRelativePath($prefix, $_.FullName).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
    $files | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $evidence 'prefix-manifest.json') -Encoding utf8
    $artifact = Join-Path $evidence "nim-2.2.10-vccexe-$revision-windows-x64.zip"
    Copy-Item -LiteralPath $zip -Destination $artifact
    $receipt.artifact = @{ file = [IO.Path]::GetFileName($artifact); bytes = (Get-Item $artifact).Length; sha256 = (Get-FileHash $artifact -Algorithm SHA256).Hash }
    $receipt.packagedNim = @{ path = $nim; sha256 = (Get-FileHash $nim -Algorithm SHA256).Hash; version = $version.output }
    $receipt.packagedWrapper = @{ path = (Join-Path $prefix 'bin/vccexe.exe'); sha256 = (Get-FileHash (Join-Path $prefix 'bin/vccexe.exe') -Algorithm SHA256).Hash }
    $receipt.dependencies = @('nimble', 'atlas', 'checksums', 'atlas/dist/sat') | ForEach-Object { @{ path = "dist/$_"; revision = (Read-Git (Join-Path $root "dist/$_") @('rev-parse', 'HEAD')) } }
    if (Read-Git $root @('status', '--porcelain', '--untracked-files=no')) { throw 'Factory changed tracked source' }
    if ((Read-Git $root @('rev-parse', 'HEAD')) -cne $revision) { throw 'Source revision changed' }
    $receipt.complete = $true
} catch {
    $receipt.failure = $_.Exception.Message
    throw
} finally {
    $env:PATH = $originalPath
    if ($scratchOwned -and (Test-Path -LiteralPath $scratch)) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    $receipt | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence 'qualification.json') -Encoding utf8
    Stop-Transcript | Out-Null
    Pop-Location
}
