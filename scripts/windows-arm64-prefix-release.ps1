# The release half of the Windows ARM64 Nim prefix producer: the guards that
# admit a producer tag, and the publication of the prefixes built for it.
#
# Dot-source it, then call the functions:
#
#   . ./scripts/windows-arm64-prefix-release.ps1
#   Assert-ProducerTag -Tag $env:GITHUB_REF_NAME
#
# .github/workflows/windows-arm64-prefix.yml is the only production caller,
# and its header states the contract (reprobuild-pm
# spec/Distribution-And-Packaging.md §7.1, W2). In short: a person or a
# session pushes the tag `producer/nim-windows-arm64-prefixes/build-<n>` at a
# commit on `codetracer`; the tag push starts the workflow; the workflow builds
# and qualifies the prefixes and then creates a release FOR THAT EXISTING TAG.
# Nothing here creates, moves or deletes a tag: `gh release create
# --verify-tag` refuses unless the tag is already on the remote.
#
# Why the workflow never creates the tag (metacraft-labs reprobuild-pm issue
# 2026-11-19, run 44454493957): GITHUB_TOKEN was refused (HTTP 403, "Resource
# not accessible by integration") when the factory asked the releases API to
# create the tag at its own revision, and a tag pushed by GITHUB_TOKEN would
# start no workflow anyway. The pushed-tag route is the one the operator
# approved for reprobuild's windows-arm64 clingo producer on 2026-11-24, which
# published on its first run (reprobuild run 45419052413).
#
# Every function throws on refusal; none terminates the process, so the
# functions can be called from a test as well as from a workflow step.
# scripts/tests/windows-arm64-prefix-release.tests.ps1 runs the git guards
# against a real bare repository.

Set-StrictMode -Version Latest

# The producer tag namespace. A filter `*` never matches `/`, so no other
# workflow's tag filter can take these tags by accident
# (https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet).
$script:PrefixProducerTagPrefix = 'producer/nim-windows-arm64-prefixes'

# The GitHub CLI the release steps use, pinned by sha256 per runner
# architecture. The fleet's Windows images are not known to carry `gh`, so the
# steps bring their own instead of depending on whatever a runner has.
# Values: https://github.com/cli/cli/releases/download/v2.103.3/gh_2.103.3_checksums.txt
$script:GhVersion = '2.103.3'
$script:GhZipSha256 = @{
    ARM64 = '197211c98687d7770ac331fe8a3b6c198c389108c1536cdbedf659fe4703e484'
    X64   = '98d0cfa794721665d7973dd728c78aff7bd836d58f10f6d7a03568eccb0a22e0'
}

function Invoke-Native {
    ## Run a native command, return its stdout lines, and throw naming the
    ## command when it exits nonzero. stderr is left on the console so a
    ## refusal shows git's or gh's own reason.
    param([Parameter(Mandatory = $true)][string]$Image, [string[]]$Arguments = @())
    $out = & $Image @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Image $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
    return $out
}

function Assert-FullObjectId {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value, [string]$What = 'commit')
    # A full SHA-1 or SHA-256 id, never an abbreviation: an abbreviation would
    # compare unequal to every ls-remote line and read as a moved tag.
    if ($Value -notmatch '^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
        throw "$What must be a full 40- or 64-hex object id, got '$Value'"
    }
    return $Value.ToLowerInvariant()
}

function Assert-ProducerTag {
    ## Refuse unless $Tag is `<prefix>/build-<n>` with <n> a build number from
    ## 1 (no leading zero). Returns <n>.
    ##
    ## The release holds one prefix per Nim the x64 leg uses, so the tag names
    ## a producer build rather than a Nim version; each ZIP's name carries its
    ## own version and source commit. A rebuild takes the next <n>, so no tag
    ## is ever moved or reused.
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Tag,
          [string]$Prefix = $script:PrefixProducerTagPrefix)
    $pattern = '^' + [regex]::Escape($Prefix) + '/build-([1-9][0-9]*)$'
    $m = [regex]::Match($Tag, $pattern)
    if (-not $m.Success) {
        throw "tag '$Tag' is not '$Prefix/build-<n>' with <n> a build number from 1"
    }
    Write-Host "$Tag is producer build $($m.Groups[1].Value)."
    return [int]$m.Groups[1].Value
}

function Assert-CommitOnBranch {
    ## Refuse unless $Commit is reachable from $Branch on $Remote.
    ##
    ## A tag can name any commit, including one on a throwaway branch that was
    ## never reviewed. Requiring the commit to be on the mainline means a
    ## published compiler was always built by reviewed factory code.
    ##
    ## The remote is asked, not the runner's checkout, which is shallow. The
    ## branch is fetched into a private bare repository with
    ## --filter=tree:0, which brings the commit graph and no trees or blobs
    ## (https://git-scm.com/docs/git-rev-list#Documentation/git-rev-list.txt---filterltfilter-specgt),
    ## enough for `git merge-base --is-ancestor`. A commit the fetch did not
    ## bring is not on the branch by construction.
    param([Parameter(Mandatory = $true)][string]$Remote,
          [Parameter(Mandatory = $true)][string]$Branch,
          [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Commit)
    $Commit = Assert-FullObjectId $Commit
    $probe = Join-Path ([IO.Path]::GetTempPath()) ("prefix-branch-probe-" + [guid]::NewGuid().ToString('N'))
    # A commit missing from the probe must read as missing, not be fetched on
    # demand from the promisor remote.
    $savedLazy = $env:GIT_NO_LAZY_FETCH
    $env:GIT_NO_LAZY_FETCH = '1'
    try {
        $null = Invoke-Native git @('init', '-q', '--bare', $probe)
        & git -C $probe fetch -q --no-tags --filter=tree:0 $Remote "+refs/heads/${Branch}:refs/heads/probe"
        if ($LASTEXITCODE -ne 0) {
            throw "could not fetch $Branch from $Remote; refusing to publish from a commit whose branch cannot be verified"
        }
        & git -C $probe cat-file -e "$Commit^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "$Commit is not on $Branch at $Remote. Producer tags must name a commit that has landed on $Branch."
        }
        & git -C $probe merge-base --is-ancestor $Commit refs/heads/probe
        switch ($LASTEXITCODE) {
            0 { Write-Host "$Commit is on $Branch at $Remote." }
            1 { throw "$Commit is not on $Branch at $Remote. Producer tags must name a commit that has landed on $Branch." }
            default { throw "git merge-base failed (exit $LASTEXITCODE) checking $Commit against $Branch; refusing" }
        }
    } finally {
        $env:GIT_NO_LAZY_FETCH = $savedLazy
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
}

function Assert-TagNamesCommit {
    ## Refuse unless the tag $Tag on $Remote still names $Commit, the commit
    ## this run built from.
    ##
    ## The run builds `github.sha`, fixed when it starts, but publishes under
    ## the tag NAME, which resolves to whatever the tag names when it is read.
    ## The remote is asked, not the checkout, whose tag ref cannot have moved.
    ## An annotated tag matches through its peeled line, `refs/tags/<tag>^{}`
    ## (https://git-scm.com/docs/git-ls-remote); only exact ref names count,
    ## because ls-remote patterns also match a longer ref ending in the same
    ## name.
    param([Parameter(Mandatory = $true)][string]$Remote,
          [Parameter(Mandatory = $true)][string]$Tag,
          [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Commit)
    $Commit = Assert-FullObjectId $Commit
    $ref = "refs/tags/$Tag"
    $listing = & git ls-remote --tags $Remote $ref "$ref^{}"
    if ($LASTEXITCODE -ne 0) {
        throw "could not read $ref from $Remote; refusing to publish a release whose tag cannot be verified"
    }
    $direct = ''
    $peeled = ''
    foreach ($line in @($listing)) {
        if (-not $line) { continue }
        $oid, $name = $line -split "`t", 2
        if ($name -eq $ref) { $direct = $oid }
        elseif ($name -eq "$ref^{}") { $peeled = $oid }
    }
    if (-not $direct) {
        throw "$ref no longer exists on $Remote. This run built $Commit; refusing to publish it under a tag deleted after the run started."
    }
    $names = if ($peeled) { $peeled } else { $direct }
    if ($names -eq $Commit -or $direct -eq $Commit) {
        Write-Host "$ref on $Remote names $names, the commit this run built."
        return
    }
    throw "$ref on $Remote now names $names, but this run built $Commit. The tag moved after the run started; refusing. Push the next producer build tag instead of moving this one."
}

function Install-PinnedGh {
    ## Download the pinned GitHub CLI for this runner's architecture, check its
    ## sha256, put it first on PATH for this step and the later ones, and
    ## return the path of gh.exe.
    param([Parameter(Mandatory = $true)][string]$WorkRoot,
          [string]$RunnerArch = $env:RUNNER_ARCH)
    # RUNNER_ARCH is the runner's own architecture, so an ARM64 runner gets
    # the native arm64 gh even when this PowerShell is an emulated x64 one.
    if (-not $script:GhZipSha256.ContainsKey("$RunnerArch")) {
        throw "no pinned gh for runner architecture '$RunnerArch' (pinned: $($script:GhZipSha256.Keys -join ', '))"
    }
    $asset = if ($RunnerArch -eq 'ARM64') { 'windows_arm64' } else { 'windows_amd64' }
    $name = "gh_$($script:GhVersion)_$asset.zip"
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    $zip = Join-Path $WorkRoot $name
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri "https://github.com/cli/cli/releases/download/v$($script:GhVersion)/$name" -OutFile $zip
    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
    if ($sha -ne $script:GhZipSha256[$RunnerArch]) { throw "$name sha256 $sha does not match the pin $($script:GhZipSha256[$RunnerArch])" }
    $dir = Join-Path $WorkRoot "gh-$($script:GhVersion)-$asset"
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
    $bin = Join-Path $dir 'bin'
    $exe = Join-Path $bin 'gh.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "$name has no bin/gh.exe" }
    $env:PATH = "$bin;$env:PATH"
    if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $bin -Encoding utf8 }
    $null = Invoke-Native $exe @('--version')
    return $exe
}

function Test-ReleaseExists {
    param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$Tag)
    # The release list, not `releases/tags/<tag>`: that endpoint returns
    # published releases only, and a draft for the tag must count too
    # (https://docs.github.com/rest/releases/releases#get-a-release-by-tag-name).
    # `gh release view` is not used either: it exits 1 alike for "not found"
    # and for an API failure, and a failure must not read as "absent".
    $tags = @(Invoke-Native gh @('api', '--paginate', "repos/$Repository/releases?per_page=100", '--jq', '.[].tag_name'))
    return ($tags -ccontains $Tag)
}

function Assert-NoRelease {
    ## Refuse when a release (published or draft) for $Tag already exists: a
    ## producer tag publishes once.
    param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$Tag)
    if (Test-ReleaseExists -Repository $Repository -Tag $Tag) {
        throw "a release for $Tag already exists; a producer tag publishes once. Push the next producer build tag instead."
    }
    Write-Host "no release for $Tag yet."
}

function Get-PrefixProvenance {
    ## Name, for each label, the job of run $RunId that built and qualified its
    ## ZIP. Every attempt's jobs are listed: a prefix job that succeeded in an
    ## earlier attempt is carried, not re-run, by later ones.
    param([Parameter(Mandatory = $true)][string]$Repository,
          [Parameter(Mandatory = $true)][long]$RunId,
          [Parameter(Mandatory = $true)][string[]]$Labels)
    $jobs = @(Invoke-Native gh @('api', '--paginate', "repos/$Repository/actions/runs/$RunId/jobs?filter=all&per_page=100", '--jq', '.jobs[]') |
        ForEach-Object { $_ | ConvertFrom-Json })
    $provenance = [ordered]@{ repository = $Repository; run = $RunId; prefixes = [ordered]@{} }
    foreach ($label in $Labels) {
        $ok = @($jobs | Where-Object { $_.name -eq "Prefix $label (Windows ARM64)" -and $_.conclusion -eq 'success' } |
            Sort-Object completed_at -Descending)
        if ($ok.Count -eq 0) { throw "run $RunId has no successful prefix job for $label" }
        $j = $ok[0]
        $provenance.prefixes[$label] = [ordered]@{
            run = $RunId; attempt = [int]$j.run_attempt; jobId = [long]$j.id
            jobUrl = $j.html_url; runner = $j.runner_name; completedAt = $j.completed_at
        }
        Write-Host "$label <- run $RunId attempt $($j.run_attempt) job $($j.id) on $($j.runner_name)"
    }
    return $provenance
}

function New-PrefixReleaseBundle {
    ## Check each label's ZIP against its receipt, and write the release's
    ## files to $OutDir: the receipts with `producedBy`, SHA256SUMS and
    ## PROVENANCE.json. Returns the asset paths and the release notes.
    ##
    ## $PrefixesDir holds one `<label>-windows-arm64` directory per label, as
    ## the prefix jobs upload them (the evidence directory of
    ## scripts/windows-arm64-prefix.ps1).
    param([Parameter(Mandatory = $true)][string]$PrefixesDir,
          [Parameter(Mandatory = $true)][string]$OutDir,
          [Parameter(Mandatory = $true)][string[]]$Labels,
          [Parameter(Mandatory = $true)][string]$SourceSha,
          [Parameter(Mandatory = $true)]$Provenance,
          [Parameter(Mandatory = $true)][string]$Tag,
          [string]$LlvmMingwRelease = $env:LLVM_MINGW_RELEASE)
    $SourceSha = Assert-FullObjectId $SourceSha
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $assets = @()
    $sums = @()
    $lines = @()
    foreach ($label in $Labels) {
        $dir = Join-Path $PrefixesDir "$label-windows-arm64"
        $zips = @(Get-ChildItem -LiteralPath $dir -Filter '*-windows-arm64.zip' -File)
        if ($zips.Count -ne 1) { throw "${label}: expected one ZIP in $dir, found $($zips.Count)" }
        $receipt = Get-Content -Raw -LiteralPath (Join-Path $dir "receipt-$label.json") | ConvertFrom-Json
        if ($receipt.label -ne $label) { throw "${label}: receipt names label '$($receipt.label)'" }
        if ($receipt.zip -ne $zips[0].Name) { throw "${label}: receipt names '$($receipt.zip)', artifact holds '$($zips[0].Name)'" }
        if ($receipt.factoryRevision -ne $SourceSha) { throw "${label}: receipt factoryRevision $($receipt.factoryRevision) is not the tagged commit $SourceSha" }
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $zips[0].FullName).Hash.ToLowerInvariant()
        if ($sha -ne $receipt.zipSha256) { throw "${label}: ZIP sha256 $sha does not match the receipt's zipSha256 $($receipt.zipSha256)" }
        $p = $Provenance.prefixes[$label]
        $receipt | Add-Member -NotePropertyName producedBy -NotePropertyValue ([ordered]@{
            repository = $Provenance.repository; run = $p.run; attempt = $p.attempt
            jobId = $p.jobId; jobUrl = $p.jobUrl; runner = $p.runner })
        $receiptOut = Join-Path $OutDir "receipt-$label.json"
        $receipt | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath $receiptOut
        $assets += $zips[0].FullName, $receiptOut
        $sums += "$sha  $($zips[0].Name)"
        $lines += "- ``$($zips[0].Name)``: sha256 ``$sha``, built by run $($p.run) attempt $($p.attempt), job $($p.jobId) on ``$($p.runner)``."
    }
    $sumsPath = Join-Path $OutDir 'SHA256SUMS'
    $sums | Set-Content -Encoding ascii -LiteralPath $sumsPath
    $Provenance['tag'] = [ordered]@{ name = $Tag; sha = $SourceSha; createdBy = 'pushed by a person or session; this run only created the release for it' }
    $provPath = Join-Path $OutDir 'PROVENANCE.json'
    $Provenance | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath $provPath
    $assets += $sumsPath, $provPath
    $notes = (@(
        "Native Windows ARM64 Nim prefixes built by the factory at $SourceSha (producer tag $Tag). Each was compiled on eph-win-arm64 with llvm-mingw $LlvmMingwRelease from a seed that the pinned x64 compiler of the same source generated on Windows x64, rebuilt by koch boot to a byte-identical fixpoint, and qualified natively. Published by run $($Provenance.run).",
        ''
    ) + $lines + @(
        '',
        'Each receipt-*.json records the build steps and, under producedBy, the run, attempt and job that built its ZIP; PROVENANCE.json lists the same for both. Pinned by reprobuild windows/toolchain-versions.env (NIM_WIN_ARM64_*); not a Nim release.'
    )) -join "`n"
    return [pscustomobject]@{ Assets = $assets; Notes = $notes }
}

function Assert-AssetNamesUnpublished {
    ## Refuse when another producer release already carries an asset of one of
    ## these names (pass the ZIP names: every release carries a SHA256SUMS). A ZIP is named by Nim version and SOURCE commit, so a
    ## second producer build of the same source would publish different bytes
    ## (each build stamps its date into nim.exe) under the same name. A pin
    ## names URL and sha256, but a reader comparing names would not see the
    ## difference. Drafts are listed too. To publish a rebuild anyway, retire
    ## the earlier release first; that is a deliberate, visible step.
    param([Parameter(Mandatory = $true)][string]$Repository,
          [Parameter(Mandatory = $true)][string[]]$Names,
          [string]$Prefix = $script:PrefixProducerTagPrefix)
    $releases = @(Invoke-Native gh @('api', '--paginate', "repos/$Repository/releases?per_page=100", '--jq', '.[] | {tag: .tag_name, assets: [.assets[].name]}') |
        ForEach-Object { $_ | ConvertFrom-Json })
    $held = @()
    foreach ($r in $releases) {
        if (-not "$($r.tag)".StartsWith("$Prefix/")) { continue }
        foreach ($n in $Names) { if (@($r.assets) -ccontains $n) { $held += "$n (in $($r.tag))" } }
    }
    if ($held.Count -gt 0) { throw "already published by another producer release: $($held -join '; '). Refusing to publish a second file under the same name." }
}

function Publish-PrefixRelease {
    ## Create the release for the EXISTING tag $Tag and upload $Assets.
    ## --verify-tag makes gh refuse unless the tag is already on the remote,
    ## so this can only describe the pushed tag, never create one
    ## (https://cli.github.com/manual/gh_release_create). The release is a
    ## prerelease and never "Latest": releases/latest keeps naming the x64
    ## maintenance prefix.
    param([Parameter(Mandatory = $true)][string]$Repository,
          [Parameter(Mandatory = $true)][string]$Tag,
          [Parameter(Mandatory = $true)][string]$SourceSha,
          [Parameter(Mandatory = $true)][string[]]$Assets,
          [Parameter(Mandatory = $true)][string]$Notes,
          [Parameter(Mandatory = $true)][string]$WorkRoot)
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    $notesFile = Join-Path $WorkRoot 'release-notes.md'
    Set-Content -LiteralPath $notesFile -Value $Notes -Encoding utf8
    $title = "Nim Windows ARM64 prefixes ($($SourceSha.Substring(0, 12)), $Tag)"
    $null = Invoke-Native gh (@('release', 'create', $Tag, '--repo', $Repository, '--verify-tag',
        '--title', $title, '--prerelease', '--latest=false', '--notes-file', $notesFile) + $Assets)
    Write-Host "published https://github.com/$Repository/releases/tag/$Tag"
}

function Hide-PrefixRelease {
    ## Return the release to draft: its tag moved while it was publishing, so
    ## its assets no longer match the commit the tag names.
    param([Parameter(Mandatory = $true)][string]$Repository, [Parameter(Mandatory = $true)][string]$Tag)
    $null = Invoke-Native gh @('release', 'edit', $Tag, '--repo', $Repository, '--draft=true')
}
