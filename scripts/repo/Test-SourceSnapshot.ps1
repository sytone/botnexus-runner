<#
.SYNOPSIS
Tests generic exact-source capture, payload packaging and runner restoration offline.
.DESCRIPTION
Runs Pester regressions using isolated Git repositories, SourceSnapshot APIs and the
generic pipeline restore boundary. Application sender, fingerprint, mode and receipt
policy assertions remain in the application-owned Test-SourceSnapshot.ps1 counterpart.
No Azure execution, gateway, dotnet or product test host is started. Two
case-sensitive filesystem acceptance cases require Linux and deliberately fail elsewhere.
Invoke Pester with this explicit file path because its approved command name does not
match Pester's default *.Tests.ps1 directory-discovery suffix.
.EXAMPLE
Invoke-Pester -Path ./scripts/repo/Test-SourceSnapshot.ps1 -Output Detailed
Runs all source transport cases, including the Linux filesystem acceptance checks.
.OUTPUTS
None. Pester reports assertion results to its caller.
#>
# Offline only: no Azure, gateway, test hosts, or caller Git configuration.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'SourceSnapshot.psm1') -Force -ErrorAction Stop
    $script:taskRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $script:scratch = Join-Path $taskRoot ('artifacts/source-snapshot-tests-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    $script:savedEnvironment = @{}
    Get-ChildItem Env: | Where-Object { $_.Name -match '^(GIT_|GH_|GITHUB_|HOME$|XDG_CONFIG_HOME$)' } | ForEach-Object {
        $savedEnvironment[$_.Name] = $_.Value
        Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue
    }
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $scratch 'no-config'
    $env:HOME = $scratch
    $env:XDG_CONFIG_HOME = $scratch
    $env:GIT_TERMINAL_PROMPT = '0'
    $env:GIT_ALLOW_PROTOCOL = 'file'
    $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'Snapshot Fixture'
    $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'snapshot@example.com'
    function Invoke-GitFixture {
        <#
        .SYNOPSIS
        Runs Git against an isolated fixture repository.
        .DESCRIPTION
        Preserves native output and throws immediately for a nonzero Git exit.
        .PARAMETER Arguments
        Exact Git argument array, including the isolated repository path.
        .EXAMPLE
        Invoke-GitFixture -Arguments @('-C', $repo, 'status', '--short')
        .OUTPUTS
        System.Object. Git standard output.
        #>
        param([string[]]$Arguments)
        $output = & git @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Fixture git failed: $output"
        }
        $output
    }
    function Invoke-SourceFragment {
        <#
        .SYNOPSIS
        Executes an extracted production fragment with explicit fixture variables.
        .DESCRIPTION
        Uses InvokeWithContext to supply named PSVariable instances from a dictionary.
        Production source stays unchanged; fixture dependencies are explicit and observable.
        .PARAMETER Source
        Exact production source fragment to execute.
        .PARAMETER Context
        Dictionary of variable names and fixture values visible to the fragment.
        .EXAMPLE
        Invoke-SourceFragment -Source $guard -Context $guardContext
        .OUTPUTS
        System.Object. Unmodified pipeline output from the production fragment.
        #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Source,
            [Parameter(Mandatory)][hashtable]$Context
        )
        $variables = [Collections.Generic.List[System.Management.Automation.PSVariable]]::new()
        foreach ($entry in $Context.GetEnumerator()) {
            $variables.Add([System.Management.Automation.PSVariable]::new($entry.Key, $entry.Value))
        }
        ([scriptblock]::Create($Source)).InvokeWithContext($null, $variables, @())
    }
    function Invoke-ProductionTransport {
        <#
        .SYNOPSIS
        Roundtrips a Git fixture through generic capture and runner restoration.
        .DESCRIPTION
        Captures source with the existing SourceSnapshot API, creates its bundle and archives,
        then executes the exact generic pipeline restore block with isolated paths.
        No application sender, fingerprint, release or receipt module is imported.
        .PARAMETER Repo
        Isolated source Git repository.
        .PARAMETER Area
        Owned fixture artifact directory for archive creation and extraction.
        .EXAMPLE
        Invoke-ProductionTransport -Repo $repo -Area $area
        .OUTPUTS
        System.String. Reconstructed source directory.
        #>
        [CmdletBinding()]
        param([string]$Repo, [string]$Area)
        $captureRoot = Join-Path $Area 'capture'
        [IO.Directory]::CreateDirectory($captureRoot) | Out-Null
        $manifest = Get-SourceSnapshotManifest -RepoRoot $Repo -CaptureRoot $captureRoot
        $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Area 'source-manifest.json')
        Invoke-GitFixture -Arguments @('-C', $Repo, 'bundle', 'create', (Join-Path $Area 'repository.bundle'), 'HEAD') | Out-Null
        [IO.Compression.ZipFile]::CreateFromDirectory($captureRoot, (Join-Path $Area 'workspace.zip'))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SourceSnapshot.psm1') -Destination $Area
        $context = @{
            payloadArchive = Join-Path $Area 'payload.tar.gz'
            payloadRoot = Join-Path $Area 'payload'
            sourceRoot = Join-Path $Area 'reconstructed'
            runId = 'fixture-run'
        }
        New-SourcePayloadArchive -Root $Area -Destination $context.payloadArchive | Out-Null
        [IO.Directory]::CreateDirectory($context.payloadRoot) | Out-Null
        $runner = [IO.File]::ReadAllText((Join-Path $taskRoot 'infra/buildtest/runner/Invoke-RunnerPipeline.ps1'))
        $restore = [regex]::Match($runner, '(?s)# BEGIN EXACT SOURCE RESTORE(.*?)# END EXACT SOURCE RESTORE').Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($restore)) {
            throw 'Generic pipeline restore block not found.'
        }
        Invoke-SourceFragment -Source $restore -Context $context | Out-Null
        $context.sourceRoot
    }
}
Describe 'Generic source transport regression' {
    BeforeEach {
        $script:area = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
        $script:repo = Join-Path $area 'repo'
        [IO.Directory]::CreateDirectory($repo) | Out-Null
        Invoke-GitFixture @('-C', $repo, 'init', '-b', 'main') | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'deleted-staged.md'), 'remove me')
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'keep me')
        $projectRoot = Join-Path $repo 'infra/buildtest/project'
        [IO.Directory]::CreateDirectory($projectRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $projectRoot 'core.json'), '{}')
        Invoke-GitFixture @('-C', $repo, 'add', '--all') | Out-Null
        Invoke-GitFixture @('-C', $repo, 'commit', '-m', 'fixture base') | Out-Null
    }
    AfterAll {
        Get-ChildItem Env: | Where-Object { $_.Name -match '^(GIT_|GH_|GITHUB_|HOME$|XDG_CONFIG_HOME$)' } | ForEach-Object { Remove-Item "Env:$($_.Name)" -ErrorAction SilentlyContinue }
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value)
        }
        if (Test-Path -LiteralPath $scratch) {
            Remove-Item -LiteralPath $scratch -Recurse -Force
        }
    }
    It 'creates a runner-compatible payload without recompressing compressed inputs' {
        $payloadArea = Join-Path $area 'payload-archive'
        [IO.Directory]::CreateDirectory($payloadArea) | Out-Null
        $random = [byte[]]::new(2MB)
        [Security.Cryptography.RandomNumberGenerator]::Fill($random)
        foreach ($name in @('repository.bundle', 'workspace.zip')) {
            [IO.File]::WriteAllBytes((Join-Path $payloadArea $name), $random)
        }
        [IO.File]::WriteAllText((Join-Path $payloadArea 'source-manifest.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $payloadArea 'SourceSnapshot.psm1'), '# fixture')
        $payload = Join-Path $payloadArea 'payload.tar.gz'

        $proof = New-SourcePayloadArchive -Root $payloadArea -Destination $payload

        $proof.compression | Should -Be 'gzip-no-compression'
        $proof.inputBytes | Should -BeGreaterThan 4MB
        $proof.outputBytes | Should -BeGreaterThan 4MB
        $proof.outputBytes | Should -BeLessThan ($proof.inputBytes + 1MB)
        $listed = @(& tar -tzf $payload)
        $LASTEXITCODE | Should -Be 0
        $listed | Should -Be @('repository.bundle', 'workspace.zip', 'source-manifest.json', 'SourceSnapshot.psm1')
    }
    It 'captures deletions, renames, additions, modifications and literal portable names' {
        Remove-Item -LiteralPath (Join-Path $repo 'deleted-staged.md')
        Invoke-GitFixture @('-C', $repo, 'mv', 'keep.md', 'renamed.md') | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'renamed.md'), "modified`r`nbytes")
        foreach ($name in @('staged.md', 'space name.md', 'café.md', '-leading.md', '[brackets].md')) {
            [IO.File]::WriteAllText((Join-Path $repo $name), $name)
        }
        Invoke-GitFixture @('-C', $repo, 'add', '--', 'staged.md') | Out-Null
        $restored = Invoke-ProductionTransport $repo $area
        Test-Path -LiteralPath (Join-Path $restored 'deleted-staged.md') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $restored 'keep.md') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $restored 'renamed.md')) | Should -Be "modified`r`nbytes"
        foreach ($name in @('staged.md', 'space name.md', 'café.md', '-leading.md', '[brackets].md')) {
            [IO.File]::ReadAllText((Join-Path $restored $name)) | Should -Be $name
        }
    }
    It 'fingerprints raw bytes and preserves forced ignored additions and caller index' {
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), 'forced.md')
        [IO.File]::WriteAllText((Join-Path $repo 'forced.md'), 'forced')
        Invoke-GitFixture @('-C', $repo, 'add', '-f', '--', 'forced.md') | Out-Null
        $index = Join-Path $repo '.git/index'
        $env:GIT_INDEX_FILE = $index
        try {
            $before = (Get-FileHash -LiteralPath $index).Hash
            $first = Get-SourceSnapshotManifest -RepoRoot $repo
            $env:GIT_INDEX_FILE | Should -Be $index
            (Get-FileHash -LiteralPath $index).Hash | Should -Be $before
            $restored = Invoke-ProductionTransport $repo $area
            [IO.File]::ReadAllText((Join-Path $restored 'forced.md')) | Should -Be 'forced'
            [IO.File]::ReadAllText((Join-Path $restored '.gitignore')) | Should -Be 'forced.md'
            $env:GIT_INDEX_FILE | Should -Be $index
            (Get-FileHash -LiteralPath $index).Hash | Should -Be $before
            $missing = Join-Path $area 'missing-repository'
            { Get-SourceSnapshotManifest -RepoRoot $missing } | Should -Throw
            $env:GIT_INDEX_FILE | Should -Be $index
            (Get-FileHash -LiteralPath $index).Hash | Should -Be $before
            [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), "keep me`r`n")
            $crlf = Get-SourceSnapshotManifest -RepoRoot $repo
            [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), "keep me`n")
            $lf = Get-SourceSnapshotManifest -RepoRoot $repo
            $crlf.digest | Should -Not -Be $lf.digest
            $first.version | Should -Be 1
        }
        finally {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        }
    }
    It 'rejects unresolved conflicts but accepts resolved uncommitted merge without mutating Git state' {
        Invoke-GitFixture @('-C', $repo, 'checkout', '-b', 'side') | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'side')
        Invoke-GitFixture @('-C', $repo, 'commit', '-am', 'side') | Out-Null
        Invoke-GitFixture @('-C', $repo, 'checkout', 'main') | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'main')
        Invoke-GitFixture @('-C', $repo, 'commit', '-am', 'main') | Out-Null
        & git -C $repo merge side 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
        { Get-SourceSnapshotManifest -RepoRoot $repo } | Should -Throw '*unmerged*'
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'resolved')
        Invoke-GitFixture @('-C', $repo, 'add', '--', 'keep.md') | Out-Null
        Invoke-GitFixture @('-C', $repo, 'rm', '--', 'deleted-staged.md') | Out-Null
        $paths = @('HEAD', 'MERGE_HEAD', 'index') | ForEach-Object { Join-Path $repo ".git/$_" }
        $before = @($paths | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ','
        $restored = Invoke-ProductionTransport $repo $area
        [IO.File]::ReadAllText((Join-Path $restored 'keep.md')) | Should -Be 'resolved'
        Test-Path -LiteralPath (Join-Path $restored 'deleted-staged.md') | Should -BeFalse
        (@($paths | ForEach-Object { (Get-FileHash -LiteralPath $_).Hash }) -join ',') | Should -Be $before
    }
    It 'rejects unsafe manifest path <path>' -ForEach @(
        @{path = '../escape' }, @{path = '/absolute' }, @{path = 'C:/drive' }, @{path = 'a\b' },
        @{path = '.git/config' }, @{path = 'a/../b' }, @{path = 'a//b' }, @{path = "bad`nname" }, @{path = 'a/.git/config' }
    ) {
        { Assert-SourceSnapshotPath $path } | Should -Throw '*Unsafe*'
    }
    It 'rejects index links and submodules' {
        $blob = (Invoke-GitFixture @('-C', $repo, 'rev-parse', 'HEAD:keep.md')).Trim()
        Invoke-GitFixture @('-C', $repo, 'update-index', '--add', '--cacheinfo', "120000,$blob,link") | Out-Null
        { Get-SourceSnapshotManifest -RepoRoot $repo } | Should -Throw '*Unsupported*'
        Invoke-GitFixture @('-C', $repo, 'update-index', '--force-remove', '--', 'link') | Out-Null
        $head = (Invoke-GitFixture @('-C', $repo, 'rev-parse', 'HEAD')).Trim()
        Invoke-GitFixture @('-C', $repo, 'update-index', '--add', '--cacheinfo', "160000,$head,submodule") | Out-Null
        { Get-SourceSnapshotManifest -RepoRoot $repo } | Should -Throw '*Unsupported*'
    }
    It 'rejects missing, tampered and extra restored files' {
        $restored = Invoke-ProductionTransport $repo $area
        $manifest = Get-Content -LiteralPath (Join-Path $area 'source-manifest.json') -Raw | ConvertFrom-Json
        [IO.File]::WriteAllText((Join-Path $restored 'keep.md'), 'tampered')
        { Assert-SourceSnapshot -Root $restored -Manifest $manifest } | Should -Throw
        [IO.File]::WriteAllText((Join-Path $restored 'keep.md'), 'keep me')
        Remove-Item -LiteralPath (Join-Path $restored 'keep.md')
        { Assert-SourceSnapshot -Root $restored -Manifest $manifest } | Should -Throw
        [IO.File]::WriteAllText((Join-Path $restored 'keep.md'), 'keep me')
        [IO.File]::WriteAllText((Join-Path $restored 'extra.md'), 'extra')
        { Assert-SourceSnapshot -Root $restored -Manifest $manifest } | Should -Throw
    }
    It 'rejects archive traversal, link entries and missing files before replacing existing contents' {
        $manifest = Get-SourceSnapshotManifest -RepoRoot $repo
        $archive = Join-Path $area 'hostile.zip'
        foreach ($attack in @('../escape', '.git/config', 'link', 'missing')) {
            $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $zip.CreateEntry($attack)
                if ($attack -eq 'link') {
                    $entry.ExternalAttributes = [int](0xA000 -shl 16)
                }
            }
            finally {
                $zip.Dispose()
            }
            { Restore-SourceSnapshot -Root $repo -Archive $archive -Manifest $manifest -RunId test } | Should -Throw
            [IO.File]::ReadAllText((Join-Path $repo 'keep.md')) | Should -Be 'keep me'
            Remove-Item -LiteralPath $archive
        }
    }
    It 'refuses filesystem reparse traversal' {
        $outside = Join-Path $area 'outside'
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        [IO.File]::WriteAllText((Join-Path $outside 'file.md'), 'outside')
        $link = Join-Path $repo 'linked'
        $type = if ($IsWindows) {
            'Junction'
        }
        else {
            'SymbolicLink'
        }
        New-Item -ItemType $type -Path $link -Target $outside | Out-Null
        try {
            $blob = (Invoke-GitFixture @('-C', $repo, 'rev-parse', 'HEAD:keep.md')).Trim()
            Invoke-GitFixture @('-C', $repo, 'update-index', '--add', '--cacheinfo', "100644,$blob,linked/file.md") | Out-Null
            { Get-SourceSnapshotManifest -RepoRoot $repo } | Should -Throw '*reparse*'
        }
        finally {
            Remove-Item -LiteralPath $link -Force
        }
    }
    It 'preserves absent index environment after generic capture success and failure' {
        Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        $manifest = Get-SourceSnapshotManifest -RepoRoot $repo
        $manifest.version | Should -Be 1
        Test-Path Env:GIT_INDEX_FILE | Should -BeFalse
        $missing = Join-Path $area 'missing-repository'
        { Get-SourceSnapshotManifest -RepoRoot $missing } | Should -Throw
        Test-Path Env:GIT_INDEX_FILE | Should -BeFalse
    }
    It 'rejects missing and mismatched generic restore proof before replacing the sentinel' {
        $capture = Join-Path $area 'proof-capture'
        [IO.Directory]::CreateDirectory($capture) | Out-Null
        $manifest = Get-SourceSnapshotManifest -RepoRoot $repo -CaptureRoot $capture
        $archive = Join-Path $area 'proof.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($capture, $archive)
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'proof sentinel')
        { Restore-SourceSnapshot -Root $repo -Archive $archive -Manifest $null -RunId test } | Should -Throw
        [IO.File]::ReadAllText((Join-Path $repo 'keep.md')) | Should -Be 'proof sentinel'
        $manifest.digest = 'wrong'
        { Restore-SourceSnapshot -Root $repo -Archive $archive -Manifest $manifest -RunId test } | Should -Throw '*Invalid source manifest*'
        [IO.File]::ReadAllText((Join-Path $repo 'keep.md')) | Should -Be 'proof sentinel'
    }
    It 'roundtrips a tracked file replaced by an unstaged directory' {
        Invoke-GitFixture @('-C', $repo, 'mv', 'keep.md', 'config') | Out-Null
        Invoke-GitFixture @('-C', $repo, 'commit', '-am', 'config file') | Out-Null
        Remove-Item -LiteralPath (Join-Path $repo 'config')
        [IO.Directory]::CreateDirectory((Join-Path $repo 'config')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $repo 'config/settings.json'), '{"new":true}')
        $restored = Invoke-ProductionTransport $repo $area
        Test-Path -LiteralPath (Join-Path $restored 'config') -PathType Container | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $restored 'config/settings.json')) | Should -Be '{"new":true}'
    }
    It 'roundtrips an unstaged case-only rename on a real case-sensitive filesystem' -Tag LinuxCaseSensitive {
        $IsLinux | Should -BeTrue -Because 'this acceptance test requires the isolated Linux harness'
        Invoke-GitFixture @('-C', $repo, 'mv', 'keep.md', 'A.cs') | Out-Null
        Invoke-GitFixture @('-C', $repo, 'commit', '-am', 'uppercase file') | Out-Null
        [IO.File]::Move((Join-Path $repo 'A.cs'), (Join-Path $repo 'a.cs'))
        Test-Path -LiteralPath (Join-Path $repo 'A.cs') | Should -BeFalse
        $restored = Invoke-ProductionTransport $repo $area
        Test-Path -LiteralPath (Join-Path $restored 'A.cs') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $restored 'a.cs')) | Should -Be 'keep me'
    }
    It 'rejects two existing case-colliding files on a case-sensitive filesystem' -Tag LinuxCaseSensitive {
        $IsLinux | Should -BeTrue
        [IO.File]::WriteAllText((Join-Path $repo 'A.cs'), 'upper')
        [IO.File]::WriteAllText((Join-Path $repo 'a.cs'), 'lower')
        @(Get-ChildItem -LiteralPath $repo | Where-Object Name -CLike '*.cs').Count | Should -Be 2
        { Get-SourceSnapshotManifest -RepoRoot $repo } | Should -Throw '*Unsafe case-colliding source path*'
    }
    It 'rejects only link attributes in an otherwise valid archive and accepts its regular-file control' {
        $manifest = Get-SourceSnapshotManifest -RepoRoot $repo
        $capture = Join-Path $area 'link-control'
        [IO.Directory]::CreateDirectory($capture) | Out-Null
        Get-SourceSnapshotManifest -RepoRoot $repo -CaptureRoot $capture | Out-Null
        $archive = Join-Path $area 'matching.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($capture, $archive)
        $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $zip.GetEntry('keep.md').ExternalAttributes = [int](0xA000 -shl 16)
        }
        finally {
            $zip.Dispose()
        }
        [IO.File]::WriteAllText((Join-Path $repo 'keep.md'), 'destination sentinel')
        { Restore-SourceSnapshot -Root $repo -Archive $archive -Manifest $manifest -RunId test } | Should -Throw '*Unsupported archive link/directory.*'
        [IO.File]::ReadAllText((Join-Path $repo 'keep.md')) | Should -Be 'destination sentinel'
        $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Update)
        try {
            $zip.GetEntry('keep.md').ExternalAttributes = [int](0x8000 -shl 16)
        }
        finally {
            $zip.Dispose()
        }
        $proof = Restore-SourceSnapshot -Root $repo -Archive $archive -Manifest $manifest -RunId test
        $proof.verified | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $repo 'keep.md')) | Should -Be 'keep me'
    }
    It 'does not resurrect a staged deletion from bundled HEAD' {
        Invoke-GitFixture @('-C', $repo, 'rm', '--', 'deleted-staged.md') | Out-Null
        $restored = Invoke-ProductionTransport $repo $area
        Test-Path -LiteralPath (Join-Path $restored 'deleted-staged.md') | Should -BeFalse
        [IO.File]::ReadAllText((Join-Path $restored 'keep.md')) | Should -Be 'keep me'
    }
}
