# Real MSVC/vccexe file-argument control. No compiler or filesystem is mocked.
# A short absolute C file must remain usable from a valid deep caller directory.
param(
    [Parameter(Mandatory = $true)][string]$EvidenceRoot,
    [Parameter(Mandatory = $true)][string]$WrapperPath,
    [Parameter(Mandatory = $true)][string]$TargetTriple,
    [switch]$BuildSubject
)
$ErrorActionPreference = 'Stop'
# Use the actual target already selected by the native CRT driver, including
# an ARM-labelled runner whose installed Rust toolchain is in fact x64.
$platform = switch -Regex ($TargetTriple) {
    '^x86_64-.*-windows-msvc$' { 'amd64'; break }
    '^aarch64-.*-windows-msvc$' { 'x64_arm64'; break }
    '^i[3-6]86-.*-windows-msvc$' { 'x86'; break }
    default { throw "No existing vccexe platform mapping for selected target $TargetTriple" }
}
$evidence = Join-Path $EvidenceRoot 'source-paths'
if ([IO.Directory]::Exists($evidence)) { throw 'source-path evidence already exists' }
[IO.Directory]::CreateDirectory($evidence) | Out-Null
$identity = [Guid]::NewGuid().ToString('N')
$scratch = Join-Path ([IO.Path]::GetTempPath()) "vcc-path-$identity"
if ([IO.Directory]::Exists($scratch)) { throw 'source-path scratch already exists' }
[IO.Directory]::CreateDirectory($scratch) | Out-Null
$receipt = @{ complete = $false; source_revision = (& git rev-parse HEAD); target = $TargetTriple; compiler_platform = $platform; cases = @() }
try {
    $nim = (Get-Command nim.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $receipt.nim = @{ path = $nim; sha256 = (Get-FileHash -LiteralPath $nim -Algorithm SHA256).Hash }
    $receipt.nim.version_output = @(& $nim --version)
    $receipt.nim.version_exit = $LASTEXITCODE
    Write-Host ('Selected test compiler: ' + ($receipt.nim | ConvertTo-Json -Compress))
    if ($receipt.nim.version_exit -ne 0) { throw 'selected Nim version probe failed' }
    if ($BuildSubject) {
        # The compiler owner's normal koch buildVccTool compilation route.
        # Bind the exact measured executable, not another PATH lookup.
        & $nim c ('-o:' + $WrapperPath) tools/vccexe/vccexe.nim
        $receipt.subject_build_exit = $LASTEXITCODE
        if ($receipt.subject_build_exit -ne 0) { throw 'owning wrapper compilation failed' }
    }
    $wrapper = (Resolve-Path -LiteralPath $WrapperPath).Path
    $receipt.wrapper = @{ path = $wrapper; sha256 = (Get-FileHash -LiteralPath $wrapper -Algorithm SHA256).Hash }
    $source = Join-Path $scratch '@mgenerated source é.nim.c'
    [IO.File]::WriteAllText($source, '#ifndef TEST_MESSAGE
#error Missing quoted definition
#endif
typedef char checked_message[(sizeof(TEST_MESSAGE) == sizeof("quoted value")) ? 1 : -1];
int path_control(void) { return 37; }', [Text.UTF8Encoding]::new($false))
    $responses = Join-Path $scratch 'responses'
    [IO.Directory]::CreateDirectory($responses) | Out-Null
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $caller = Join-Path $scratch 'caller'
    while ($caller.Length -lt 210) { $caller = Join-Path $caller 'deep-caller' }
    if ($source.Length -ge 240 -or $caller.Length -ge 240) { throw 'fixture itself exceeds ordinary Windows path limits' }
    [IO.Directory]::CreateDirectory($caller) | Out-Null
    [IO.File]::WriteAllText((Join-Path $caller 'cwd-marker'), $identity)
    [IO.File]::WriteAllText((Join-Path $caller 'relative.c'), 'int relative_control(void) { return 41; }')
    $relative = [IO.Path]::GetRelativePath($caller, $source)
    if (($caller.Length + 1 + $relative.Length) -lt 260) { throw 'deep relative spelling did not cross the intended boundary' }
    $receipt.source = @{ path = $source; exists_before = [IO.File]::Exists($source); sha256 = $sourceHash }
    $receipt.caller = $caller
    $receipt.relative = $relative
    $receipt.units = @{ absolute = $source.Length; relative = $relative.Length; caller = $caller.Length; unreduced = $caller.Length + 1 + $relative.Length }

    function Invoke-PathControl([string]$Name, [string[]]$Arguments) {
        $start = [Diagnostics.ProcessStartInfo]::new($wrapper)
        $start.WorkingDirectory = $caller
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
        $start.Environment['TEMP'] = $responses
        $start.Environment['TMP'] = $responses
        $start.Environment['CT_PATH_SOURCE'] = $source
        $start.Environment['CT_PATH_OBJECT'] = Join-Path $scratch "$Name.obj"
        $start.Environment['CT_PATH_OBSERVATION'] = Join-Path $evidence 'direct-observation.json'
        $start.Environment['CT_PATH_MARKER'] = $identity
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'vccexe did not start' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stdout"), $stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText((Join-Path $evidence "$Name.stderr"), $stderr.GetAwaiter().GetResult())
        return @{ name = $Name; exit = $process.ExitCode; object = [IO.File]::Exists((Join-Path $scratch "$Name.obj")); response_files_after = @(Get-ChildItem -LiteralPath $responses -Filter 'vccexe_*').Count }
    }

    # The wrapper's documented --command interface supplies the SAME MSVC
    # environment. Pass the source through this child's environment so vccexe
    # cannot rewrite it before the real cl.exe absolute-path control sees it.
    # This is fixture observation, never a production compilation workaround.
    $direct = @'
$ErrorActionPreference = 'Stop'
$compiler = (Get-Command cl.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$cwd = [IO.Directory]::GetCurrentDirectory()
$marker = [IO.File]::ReadAllText((Join-Path $cwd 'cwd-marker'))
$observation = @{
    cwd = $cwd
    marker_matches = ($marker -ceq $env:CT_PATH_MARKER)
    source_exists = [IO.File]::Exists($env:CT_PATH_SOURCE)
    compiler = $compiler
    compiler_sha256 = (Get-FileHash -LiteralPath $compiler -Algorithm SHA256).Hash
}
$observation | ConvertTo-Json | Set-Content -LiteralPath $env:CT_PATH_OBSERVATION -Encoding utf8
if (-not $observation.marker_matches -or -not $observation.source_exists) { throw 'actual child cwd/source control failed' }
$arguments = @('/nologo', '/c', '/DTEST_MESSAGE="quoted value"', ('/Fo' + $env:CT_PATH_OBJECT), $env:CT_PATH_SOURCE)
& $compiler @arguments
exit $LASTEXITCODE
'@
    $shellImage = [Environment]::ProcessPath
    $receipt.driver = @{ path = $shellImage; sha256 = (Get-FileHash -LiteralPath $shellImage -Algorithm SHA256).Hash }
    $arguments = @("--platform:$platform", "--command:$shellImage", '-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $direct)
    $directResult = Invoke-PathControl 'direct' $arguments
    $receipt.cases += $directResult

    $arguments = @("--platform:$platform", '/nologo', '/c', '/DTEST_MESSAGE="quoted value"', ('/Fo' + (Join-Path $scratch 'absolute.obj')), $source)
    $absoluteResult = Invoke-PathControl 'absolute' $arguments
    $receipt.cases += $absoluteResult
    $arguments = @("--platform:$platform", '/nologo', '/c', ('/Fo' + (Join-Path $scratch 'relative.obj')), 'relative.c')
    $relativeResult = Invoke-PathControl 'relative' $arguments
    $receipt.cases += $relativeResult
    $arguments = @("--platform:$platform", '/nologo', '/c', ('/Fo' + (Join-Path $scratch 'missing.obj')), (Join-Path $scratch 'missing.c'))
    $missingResult = Invoke-PathControl 'missing' $arguments
    $receipt.cases += $missingResult
    # Preserve #22025's long-link behavior without shortening source paths.
    # Build one real empty COFF object and link hundreds of distinct real files;
    # the incoming response expands beyond CreateProcess's command-line limit.
    $emptySource = Join-Path $scratch 'empty.c'
    [IO.File]::WriteAllText($emptySource, 'extern int declared_only;')
    $emptyResult = Invoke-PathControl 'empty' @("--platform:$platform", '/nologo', '/c', ('/Fo' + (Join-Path $scratch 'empty.obj')), $emptySource)
    $receipt.cases += $emptyResult
    if ($emptyResult.exit -ne 0 -or -not $emptyResult.object) { throw 'empty real object compile failed' }
    $objects = Join-Path $scratch 'link objects é'
    [IO.Directory]::CreateDirectory($objects) | Out-Null
    $inputs = @((Join-Path $scratch 'absolute.obj'))
    for ($i = 0; $i -lt 600; $i++) {
        $copy = Join-Path $objects ("empty-$i.obj")
        [IO.File]::Copy((Join-Path $scratch 'empty.obj'), $copy)
        $inputs += $copy
    }
    $dll = Join-Path $scratch 'long-link.dll'
    $linkArguments = @('/nologo') + $inputs + @('/link', '/DLL', '/NOENTRY', '/NODEFAULTLIB', ('/OUT:' + $dll))
    $content = ($linkArguments | ForEach-Object { '"' + $_ + '"' }) -join "`n"
    if ($content.Length -le 40000) { throw 'long-link control did not exceed command-line limit' }
    $linkResponse = Join-Path $scratch 'incoming-link.rsp'
    [IO.File]::WriteAllText($linkResponse, $content, [Text.UTF8Encoding]::new($false))
    $linkResult = Invoke-PathControl 'long-link' @("--platform:$platform", ('@' + $linkResponse))
    $linkResult.dll_exists = [IO.File]::Exists($dll)
    $linkResult.expanded_units = $content.Length
    $receipt.cases += $linkResult
    if ($linkResult.exit -ne 0 -or -not $linkResult.dll_exists) { throw 'long real response-file object link failed' }
    foreach ($case in $receipt.cases) {
        if ($case.response_files_after -ne 0) { throw 'wrapper left an owned response file after its child exited' }
    }
    $receipt.source.exists_after = [IO.File]::Exists($source)
    $receipt.source.hash_unchanged = ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ceq $sourceHash)
    if ($directResult.exit -ne 0 -or -not $directResult.object) { throw 'same-MSVC absolute compile control failed' }
    if ($relativeResult.exit -ne 0 -or -not $relativeResult.object) { throw 'ordinary relative input failed' }
    if ($missingResult.exit -eq 0 -or $missingResult.object) { throw 'missing-file negative control falsely succeeded' }
    if (-not $receipt.source.exists_after -or -not $receipt.source.hash_unchanged) { throw 'source changed during compilation' }
    if ($absoluteResult.exit -ne 0 -or -not $absoluteResult.object) { throw 'vccexe rejected the existing short absolute source from a valid deep cwd' }
    $receipt.complete = $true
    Write-Host 'PASS real MSVC absolute/deep-cwd, relative and missing-file controls'
} finally {
    $receipt | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $evidence 'receipt.json') -Encoding utf8
    # Only files created by this invocation; all evidence is retained above.
    try { Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop }
    catch { Write-Warning "Could not remove owned source-path scratch $scratch; evidence remains at $evidence" }
}
