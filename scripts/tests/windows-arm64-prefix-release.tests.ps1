# Tests for the Windows ARM64 Nim prefix producer's release route:
# scripts/windows-arm64-prefix-release.ps1 and the triggers and jobs of
# .github/workflows/windows-arm64-prefix.yml.
#
#   pwsh -NoProfile -File scripts/tests/windows-arm64-prefix-release.tests.ps1
#
# Exit 0 when every case passes; otherwise each failure is printed and the
# exit code is 1. Runs on Linux, macOS and Windows; needs git.
#
# What is held: the workflow starts only on a pushed producer tag or a
# dispatch; the only write is `gh release create --verify-tag` in a job a
# dispatch cannot reach; nothing creates or moves a tag; and the git guards
# the `admit` and `publish` jobs run refuse a wrong tag shape, a commit not on
# the branch, and a moved or deleted tag.
#
# Nothing is mocked. The remote is a real bare repository on the filesystem,
# which `git fetch` and `git ls-remote` treat as they treat github.com. Only
# GitHub itself (`gh`) is absent, so the release-existence and publishing
# functions are checked by the workflow's shape, not run.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
. (Join-Path $root 'scripts/windows-arm64-prefix-release.ps1')
$workflowPath = Join-Path $root '.github/workflows/windows-arm64-prefix.yml'
$workflow = [IO.File]::ReadAllText($workflowPath)
$helper = [IO.File]::ReadAllText((Join-Path $root 'scripts/windows-arm64-prefix-release.ps1'))

$script:failures = @()
$script:passed = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Host "ok   $Name"
    } catch {
        $script:failures += "$Name -- $($_.Exception.Message)"
        Write-Host "FAIL $Name -- $($_.Exception.Message)"
    }
}

function Assert-Throws([scriptblock]$Body, [string]$Like) {
    $threw = $false
    try { & $Body *> $null } catch {
        $threw = $true
        if ($Like -and $_.Exception.Message -notlike $Like) {
            throw "threw '$($_.Exception.Message)', expected a message like '$Like'"
        }
    }
    if (-not $threw) { throw 'expected a refusal, got none' }
}

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }

# git with a fixed identity and no user or system configuration, so the
# fixture does not depend on the caller's git setup.
$env:GIT_CONFIG_GLOBAL = if ($IsWindows) { 'NUL' } else { '/dev/null' }
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@example.invalid'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@example.invalid'
function G {
    # $args, not a parameter: git's own flags (-C, -m, ...) must not be read
    # as PowerShell parameter names.
    $out = & git @args
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed ($LASTEXITCODE)" }
    return $out
}

# A GitHub ref filter as a regex: `*` stops at `/`, `**` does not.
# https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions#filter-pattern-cheat-sheet
function ConvertFrom-RefFilter([string]$Pattern) {
    if ($Pattern -match '[?+\[\]!]') { throw "pattern '$Pattern' uses syntax this model omits" }
    $out = ''
    for ($i = 0; $i -lt $Pattern.Length; $i++) {
        if ($Pattern.Substring($i).StartsWith('**')) { $out += '.*'; $i++ }
        elseif ($Pattern[$i] -eq '*') { $out += '[^/]*' }
        else { $out += [regex]::Escape([string]$Pattern[$i]) }
    }
    return "^$out$"
}

# The top-level block under `<header>` at column 0, and a job's block.
function Get-TopBlock([string]$Header) {
    $m = [regex]::Match($workflow, "(?ms)^$([regex]::Escape($Header))\r?\n(.*?)(?=^\S|\z)")
    if (-not $m.Success) { throw "no top-level '$Header'" }
    return $m.Groups[1].Value
}
function Get-Job([string]$Name) {
    $jobs = Get-TopBlock 'jobs:'
    $m = [regex]::Match($jobs, "(?ms)^  $([regex]::Escape($Name)):\r?\n(.*?)(?=^  \S|\z)")
    if (-not $m.Success) { throw "no job '$Name'" }
    return $m.Groups[1].Value
}

# ── the producer tag ─────────────────────────────────────────────────────────

Test-Case 'a producer build tag is admitted and its number returned' {
    Assert-True ((Assert-ProducerTag -Tag 'producer/nim-windows-arm64-prefixes/build-1') -eq 1) 'build-1 is not build 1'
    Assert-True ((Assert-ProducerTag -Tag 'producer/nim-windows-arm64-prefixes/build-12') -eq 12) 'build-12 is not build 12'
}

Test-Case 'a tag of any other shape is refused' {
    foreach ($t in @('', 'producer/nim-windows-arm64-prefixes/build-0',
                     'producer/nim-windows-arm64-prefixes/build-01',
                     'producer/nim-windows-arm64-prefixes/build-',
                     'producer/nim-windows-arm64-prefixes/v1',
                     'producer/nim-windows-arm64-prefixes/build-1/x',
                     'producer/nim-windows-arm64-prefixes/build-1 ',
                     'producer/clingo-windows-arm64/build-1',
                     'nim-windows-arm64-prefixes-445718d56af2', 'v2.2.10')) {
        Assert-Throws { Assert-ProducerTag -Tag $t } "tag '*' is not 'producer/nim-windows-arm64-prefixes/build-<n>'*"
    }
}

# ── the workflow's triggers ──────────────────────────────────────────────────

Test-Case 'the workflow starts only on a producer tag push or a dispatch' {
    $on = Get-TopBlock 'on:'
    $events = @([regex]::Matches($on, '(?m)^  ([a-z_]+):') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (($events -join ',') -eq 'push,workflow_dispatch') "events are '$($events -join ',')'"
    $pushKeys = @([regex]::Matches($on, '(?m)^    ([a-z_-]+):') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (($pushKeys -join ',') -eq 'tags') "push filters are '$($pushKeys -join ',')', expected only tags"
    $patterns = @([regex]::Matches($on, '(?m)^      - "([^"]+)"$') | ForEach-Object { $_.Groups[1].Value })
    Assert-True (($patterns -join ',') -eq 'producer/nim-windows-arm64-prefixes/build-*') "tag patterns are '$($patterns -join ',')'"
    Assert-True ($on -notmatch '(?m)^\s+inputs:') 'the dispatch takes inputs; a dry run needs none'
}

Test-Case 'the tag filter takes producer build tags and none of the other tags here' {
    $rx = ConvertFrom-RefFilter 'producer/nim-windows-arm64-prefixes/build-*'
    Assert-True ('producer/nim-windows-arm64-prefixes/build-1' -match $rx) 'build-1 does not start the workflow'
    foreach ($t in @('nim-windows-arm64-prefixes-445718d56af2', 'nim-2.2.10-vccexe-8910b50d2d21ca1a3e982fe8b8b9bf0d8832e633',
                     'v2.2.10', 'producer/nim-windows-arm64-prefixes/build-1/x')) {
        Assert-True ($t -notmatch $rx) "'$t' would start the workflow"
    }
    # Every tag the filter takes that Assert-ProducerTag refuses is stopped by
    # `admit` before a build starts; the filter only has to be no wider than
    # the namespace.
    Assert-True ('producer/nim-windows-arm64-prefixes/build-x' -match $rx) 'model check: the filter is a glob'
}

Test-Case 'no other workflow here starts on a tag push' {
    # A `push` trigger with neither a branch nor a tag filter starts on every
    # tag push, and its path filters are not evaluated for tags
    # (https://docs.github.com/actions/writing-workflows/workflow-syntax-for-github-actions#onpushpull_requestpull_request_targetpathspaths-ignore),
    # so each other push trigger must name its branches and no tags.
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $root '.github/workflows') -Filter '*.yml') {
        if ($f.Name -eq 'windows-arm64-prefix.yml') { continue }
        $text = [IO.File]::ReadAllText($f.FullName)
        Assert-True ($text -notmatch '(?m)^\s+tags(-ignore)?:') "$($f.Name) has a tag filter"
        $push = [regex]::Match($text, '(?ms)^  push:[^\n]*\n(.*?)(?=^  \S|^\S|\z)')
        if ($push.Success) {
            Assert-True ($push.Groups[1].Value -match '(?m)^    branches(-ignore)?:') "$($f.Name) starts on every tag push: its push trigger names no branches"
        }
    }
}

# ── what the workflow may write ──────────────────────────────────────────────

Test-Case 'only the publish job holds contents: write, and only a tag push reaches it' {
    foreach ($job in @('admit', 'seed', 'prefix')) {
        Assert-True ((Get-Job $job) -notmatch 'contents:\s*write') "job '$job' holds contents: write"
    }
    Assert-True ((Get-TopBlock 'permissions:') -match '^\s*contents:\s*read\s*$') 'the default permission is not contents: read'
    $publish = Get-Job 'publish'
    Assert-True ($publish -match '(?m)^      contents: write$') 'publish does not hold contents: write'
    $if = [regex]::Match($publish, "(?ms)^    if: >-\r?\n(.*?)(?=^    \S)").Groups[1].Value
    Assert-True ($if -match "github\.event_name == 'push'") "publish's if does not require a push: $if"
    Assert-True ($if -match "startsWith\(github\.ref, 'refs/tags/producer/nim-windows-arm64-prefixes/'\)") "publish's if does not require a producer tag: $if"
    Assert-True ($if -match "needs\.admit\.result == 'success'") "publish's if does not require admit: $if"
    Assert-True ($if -notmatch 'always\(\)|!cancelled\(\)|failure\(\)') "publish's if overrides the needs' results: $if"
}

Test-Case 'the release is created with --verify-tag, and nothing creates or moves a tag' {
    Assert-True ($helper -match "'release', 'create', \`$Tag, '--repo', \`$Repository, '--verify-tag'") 'gh release create is not called with --verify-tag'
    # Code only: the comments quote the commands a person runs to cut a tag.
    $code = @($helper, $workflow) | ForEach-Object {
        ($_ -split "\r?\n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
    }
    $creates = [regex]::Matches(($code -join "`n"), "release['\s,]+create")
    Assert-True ($creates.Count -eq 1) "gh release create appears $($creates.Count) times"
    foreach ($text in $code) {
        foreach ($forbidden in @('target_commitish', '--target', 'git tag', "'tag',", 'git push', "'push',", 'git/refs', '/releases"', 'Method Post')) {
            Assert-True (-not $text.Contains($forbidden)) "found '$forbidden'"
        }
    }
    foreach ($job in @('admit', 'prefix', 'publish')) {
        Assert-True ((Get-Job $job) -match 'persist-credentials: false') "job '$job' keeps the checkout's credentials"
    }
}

Test-Case 'the admit job refuses before the builds start, and the builds wait for it' {
    $admit = Get-Job 'admit'
    foreach ($fn in @('Assert-ProducerTag', 'Assert-CommitOnBranch', 'Assert-TagNamesCommit', 'Assert-NoRelease')) {
        Assert-True ($admit.Contains($fn)) "admit does not run $fn"
    }
    Assert-True ((Get-Job 'seed') -match '(?m)^    needs: admit$') 'seed does not need admit'
    Assert-True ((Get-Job 'prefix') -match '(?m)^    needs: seed$') 'prefix does not need seed'
    Assert-True ($workflow -match '(?m)^  PRODUCER_SOURCE_BRANCH: codetracer$') 'the source branch is not codetracer'
}

# ── the git guards, against a real bare repository ──────────────────────────

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("prefix-release-tests-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $remote = Join-Path $tmp 'remote.git'
    $work = Join-Path $tmp 'work'
    $null = G init -q --bare $remote
    $null = G init -q -b codetracer $work
    $null = G -C $work commit -q --allow-empty -m one
    $first = (G -C $work rev-parse HEAD).Trim()
    $null = G -C $work commit -q --allow-empty -m two
    $tip = (G -C $work rev-parse HEAD).Trim()
    $null = G -C $work switch -q -c side
    $null = G -C $work commit -q --allow-empty -m side
    $side = (G -C $work rev-parse HEAD).Trim()
    $null = G -C $work push -q $remote codetracer side
    # The guards pass the remote straight to git, as the workflow passes
    # https://github.com/<repo>.git.
    $url = $remote

    Test-Case 'a commit on the branch, tip or ancestor, is admitted' {
        Assert-CommitOnBranch -Remote $url -Branch codetracer -Commit $tip
        Assert-CommitOnBranch -Remote $url -Branch codetracer -Commit $first.ToUpperInvariant()
    }
    Test-Case 'a commit only on another branch is refused' {
        Assert-Throws { Assert-CommitOnBranch -Remote $url -Branch codetracer -Commit $side } '*is not on codetracer*'
    }
    Test-Case 'a commit the remote does not have is refused' {
        Assert-Throws { Assert-CommitOnBranch -Remote $url -Branch codetracer -Commit ('0' * 39 + '1') } '*is not on codetracer*'
    }
    Test-Case 'a branch the remote does not have is refused' {
        Assert-Throws { Assert-CommitOnBranch -Remote $url -Branch no-such-branch -Commit $tip } '*could not fetch no-such-branch*'
    }
    Test-Case 'an abbreviated or empty commit id is refused, not compared' {
        Assert-Throws { Assert-CommitOnBranch -Remote $url -Branch codetracer -Commit $tip.Substring(0, 12) } '*full 40- or 64-hex*'
        Assert-Throws { Assert-TagNamesCommit -Remote $url -Tag x -Commit '' } '*full 40- or 64-hex*'
    }

    $light = 'producer/nim-windows-arm64-prefixes/build-1'
    $annotated = 'producer/nim-windows-arm64-prefixes/build-2'
    $null = G -C $work tag $light $tip
    $null = G -C $work tag -a $annotated $tip -m 'producer build 2'
    $null = G -C $work push -q $remote "refs/tags/${light}" "refs/tags/${annotated}"

    Test-Case 'a lightweight or annotated tag naming the built commit is admitted' {
        Assert-TagNamesCommit -Remote $url -Tag $light -Commit $tip
        Assert-TagNamesCommit -Remote $url -Tag $annotated -Commit $tip
    }
    Test-Case 'a tag naming another commit is refused' {
        Assert-Throws { Assert-TagNamesCommit -Remote $url -Tag $annotated -Commit $first } '*now names*'
    }
    Test-Case 'a tag that only ends in the same name does not vouch for the build' {
        $null = G -C $work tag "x/refs/tags/producer/nim-windows-arm64-prefixes/build-3" $tip
        $null = G -C $work push -q $remote "refs/tags/x/refs/tags/producer/nim-windows-arm64-prefixes/build-3"
        Assert-Throws { Assert-TagNamesCommit -Remote $url -Tag 'producer/nim-windows-arm64-prefixes/build-3' -Commit $tip } '*no longer exists*'
    }
    Test-Case 'a tag moved after the run started is refused' {
        $null = G -C $work push -q --force $remote "${first}:refs/tags/${light}"
        Assert-Throws { Assert-TagNamesCommit -Remote $url -Tag $light -Commit $tip } "*now names $first*"
    }
    Test-Case 'a deleted tag is refused' {
        $null = G -C $work push -q $remote ":refs/tags/${light}"
        Assert-Throws { Assert-TagNamesCommit -Remote $url -Tag $light -Commit $tip } '*no longer exists*'
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "$($script:passed) passed, $($script:failures.Count) failed"
if ($script:failures.Count -gt 0) { exit 1 }
exit 0
