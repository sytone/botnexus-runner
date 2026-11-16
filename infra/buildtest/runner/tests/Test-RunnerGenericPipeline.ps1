<#
.SYNOPSIS
Runs the real generic snapshot pipeline with inert local transport.
.DESCRIPTION
Restores two disjoint exact-source payloads and negative hash, command, artifact and
hidden-file controls. Uses an existing fixture bundle without staging or committing.
No network, product hosts or real transport are invoked.
.PARAMETER ScratchRoot
New isolated fixture root under writable container storage.
.PARAMETER FixtureBundlePath
Existing read-only Git bundle containing a bounded standalone fixture source.
.PARAMETER SnapshotModulePath
Explicit trusted SourceSnapshot.psm1 verifier from this runner checkout.
.EXAMPLE
./Test-RunnerGenericPipeline.ps1 -ScratchRoot /work/fixture -FixtureBundlePath /inputs/fixture.bundle -SnapshotModulePath /source/scripts/repo/SourceSnapshot.psm1
.OUTPUTS
System.String. Per-case results and JSON counts; exits one on any failed assertion.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$FixtureBundlePath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$SnapshotModulePath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
Import-Module $SnapshotModulePath -Force
$cases = [Collections.Generic.List[object]]::new()
foreach ($scenario in @('flat', 'nested', 'wrong-hash', 'nonzero', 'missing-artifact', 'hidden-artifact')) {
    try {
        $fixture = Join-Path $ScratchRoot $scenario
        $candidate = Join-Path $fixture 'candidate'
        New-Item -ItemType Directory -Path $fixture | Out-Null
        & git clone --no-checkout $FixtureBundlePath $candidate 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Fixture bundle clone failed.'
        }
        $relativeWork = if ($scenario -eq 'nested') {
            'different/deep/component'
        }
        else {
            '.'
        }
        $working = Join-Path $candidate $relativeWork
        New-Item -ItemType Directory -Path $working -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $working 'source.txt'), 'tracked snapshot directory marker')
        $artifact = if ($scenario -eq 'hidden-artifact') {
            '.retained'
        }
        else {
            'result.txt'
        }
        $command = if ($scenario -eq 'nonzero') {
            'exit 9'
        }
        elseif ($scenario -eq 'missing-artifact') {
            'exit 0'
        }
        else {
            "[IO.File]::WriteAllText('$artifact', 'exact fixture bytes')"
        }
        $relativeArtifact = if ($relativeWork -eq '.') {
            $artifact
        }
        else {
            "$relativeWork/$artifact"
        }
        $document = @{
            schemaVersion = 1
            protocolVersion = 1
            requiredCapabilities = @('process-v1', 'artifacts-v1')
            limits = @{ budgetSeconds = 20; reserveSeconds = 5; maxConcurrency = 1; maxLogBytes = 65536; maxArtifactBytes = 65536; maxArtifacts = 8 }
            steps = @(@{ id = 'command'; executable = 'pwsh'; arguments = @('-NoProfile', '-Command', $command); workingDirectory = $relativeWork; dependsOn = @(); artifacts = @($relativeArtifact) })
        }
        $configRelative = if ($scenario -eq 'nested') {
            'unrelated.config.json'
        }
        else {
            'project.json'
        }
        $config = Join-Path $candidate $configRelative
        $document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
        $hash = (Get-FileHash -LiteralPath $config).Hash.ToLowerInvariant()
        $payload = Join-Path $fixture 'payload'
        New-Item -ItemType Directory -Path $payload | Out-Null
        $manifest = Get-SourceSnapshotManifest -RepoRoot $candidate
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $payload 'source-manifest.json')
        $zip = [IO.Compression.ZipFile]::Open((Join-Path $payload 'workspace.zip'), [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in $manifest.files) {
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $candidate $file.path), $file.path) | Out-Null
            }
        }
        finally {
            $zip.Dispose()
        }
        Copy-Item -LiteralPath $FixtureBundlePath -Destination (Join-Path $payload 'repository.bundle')
        Copy-Item -LiteralPath $SnapshotModulePath -Destination (Join-Path $payload 'SourceSnapshot.psm1')
        $archive = Join-Path $fixture 'payload.tar.gz'
        & tar -czf $archive -C $payload repository.bundle workspace.zip source-manifest.json SourceSnapshot.psm1
        if ($LASTEXITCODE -ne 0) {
            throw 'Fixture archive creation failed.'
        }
        $framework = Join-Path $fixture 'framework'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..') -Destination $framework -Recurse
        @'
<#
.SYNOPSIS
Copies an inert local source payload.
.DESCRIPTION
Matches the production transport interface without network access.
.PARAMETER Source
Fixture-owned source archive.
.PARAMETER Destination
Fixture-owned destination archive.
.PARAMETER EvidenceRoot
Reserved fixture evidence root.
.PARAMETER TimeoutSeconds
Remaining original execution allowance.
.EXAMPLE
./Invoke-RunnerTransport.ps1 -Source /tmp/source.tar.gz -Destination /work/payload.tar.gz -EvidenceRoot /work/transfer -TimeoutSeconds 10
.OUTPUTS
None.
#>
[CmdletBinding()]
param($Source, $Destination, $EvidenceRoot, $TimeoutSeconds)
$ErrorActionPreference = 'Stop'
if (-not $EvidenceRoot -or [int]$TimeoutSeconds -le 0) { throw 'Invalid original transport allowance.' }
Copy-Item -LiteralPath $Source -Destination $Destination
exit 0
'@ | Set-Content -LiteralPath (Join-Path $framework 'Invoke-RunnerTransport.ps1')
        $env:SOURCE_BLOB_URL = $archive
        $env:ARTIFACT_BLOB_URL = 'inert-no-upload'
        $env:PROJECT_CONFIG_PATH = $configRelative
        $env:PROJECT_CONFIG_SHA256 = if ($scenario -eq 'wrong-hash') {
            '0' * 64
        }
        else {
            $hash
        }
        $env:RUN_ID = $scenario
        $work = Join-Path $fixture 'run'
        & pwsh -NoProfile -File (Join-Path $framework 'Invoke-Runner.ps1') -WorkRoot $work -BudgetSeconds 30 -ReserveSeconds 8 -SkipUpload
        $code = $LASTEXITCODE
        $result = Get-Content -LiteralPath (Join-Path $work 'artifacts/result.json') -Raw | ConvertFrom-Json
        $success = $scenario -in @('flat', 'nested', 'hidden-artifact')
        if (($code -eq 0) -ne $success -or ($result.exitCode -eq 0) -ne $success) {
            throw "Unexpected exit: $code; $($result | ConvertTo-Json -Depth 12 -Compress)"
        }
        if ($null -ne $result.tests -or $result.accepted -or -not $result.sourceSnapshot.verified -or $result.sourceSnapshot.digest -cne $manifest.digest) {
            throw 'Lost exact-source proof or invented acceptance.'
        }
        if ($success) {
            $saved = Join-Path (Join-Path $work 'artifacts/project') $relativeArtifact
            if ([IO.File]::ReadAllText($saved) -cne 'exact fixture bytes' -or -not $result.projectExecution.cleanupComplete) {
                throw 'Artifact bytes or cleanup proof missing.'
            }
        }
        elseif ($scenario -eq 'wrong-hash' -and $result.error -notmatch 'SHA-256') {
            throw 'Configuration hash mismatch not retained.'
        }
        elseif ($scenario -eq 'nonzero' -and $result.projectExecution.steps[0].exitCode -ne 9) {
            throw 'Original command exit code lost.'
        }
        elseif ($scenario -eq 'missing-artifact' -and ($result.projectExecution.errors -join ';') -notmatch 'omitted declared artifact') {
            throw 'Missing artifact was not rejected.'
        }
        $cases.Add(@{ name = $scenario; passed = $true })
    }
    catch {
        $cases.Add(@{ name = $scenario; passed = $false; error = $_.Exception.Message })
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
$summary = @{ total = $cases.Count; passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() }
$summary | ConvertTo-Json -Depth 10 | Tee-Object -FilePath (Join-Path $ScratchRoot 'summary.json')
if ($failed) {
    exit 1
}
