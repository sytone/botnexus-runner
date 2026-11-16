<#
.SYNOPSIS
Restores an exact candidate and executes its explicit generic project graph.
.DESCRIPTION
Image-owned pipeline. Requires source and artifact URLs, PROJECT_CONFIG_PATH and
PROJECT_CONFIG_SHA256 from the sender. Application acceptance belongs to the client;
missing test evidence remains unknown. The outer supervisor owns final upload on its
original clock, including download, extraction and malformed-result failures.
.EXAMPLE
pwsh -NoProfile -File /runner/Invoke-Runner.ps1
.OUTPUTS
None. Writes result.json and exits nonzero on transport, graph or cleanup failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'RunnerProject.psm1') -Force
$clock = [Diagnostics.Stopwatch]::StartNew()
$workRoot = $env:RUNNER_WORK_ROOT
if (-not $workRoot) {
    throw 'Image supervisor work root is missing.'
}
$payloadArchive = Join-Path $workRoot 'payload.tar.gz'
$payloadRoot = Join-Path $workRoot 'payload'
$sourceRoot = Join-Path $workRoot 'src'
$artifactsRoot = Join-Path $workRoot 'artifacts'
New-Item -ItemType Directory -Path $payloadRoot, $artifactsRoot -Force | Out-Null
$runId = $env:RUN_ID
$sourceSnapshot = $null
$projectExecution = $null
$failure = $null
$exitCode = 1
try {
    foreach ($name in @('SOURCE_BLOB_URL', 'ARTIFACT_BLOB_URL', 'PROJECT_CONFIG_PATH', 'PROJECT_CONFIG_SHA256', 'RUNNER_EXECUTION_DEADLINE_UTC')) {
        if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name))) {
            throw "Required environment variable $name is missing."
        }
    }
    $deadline = [DateTimeOffset]::Parse($env:RUNNER_EXECUTION_DEADLINE_UTC)
    $deadlineSeconds = ($deadline - [DateTimeOffset]::UtcNow).TotalSeconds
    $env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
    if ($env:AZURE_CLIENT_ID) {
        $env:AZCOPY_MSI_CLIENT_ID = $env:AZURE_CLIENT_ID
    }
    $remaining = [int][Math]::Floor($deadlineSeconds - $clock.Elapsed.TotalSeconds)
    if ($remaining -lt 1) {
        throw 'Original execution budget exhausted before source download.'
    }
    & (Join-Path $PSScriptRoot 'Invoke-RunnerTransport.ps1') -Source $env:SOURCE_BLOB_URL -Destination $payloadArchive -EvidenceRoot (Join-Path $workRoot 'download-transfer') -TimeoutSeconds $remaining
    if ($LASTEXITCODE -ne 0) {
        throw "Source download failed with exit code $LASTEXITCODE."
    }
    # BEGIN EXACT SOURCE RESTORE
    # The outer transport has exactly four regular files. Validate without extracting first;
    # the verifier module is a trusted sender artifact, not a bootstrap for an old image.
    $stream = [IO.File]::OpenRead($payloadArchive)
    $gzip = [IO.Compression.GZipStream]::new($stream, [IO.Compression.CompressionMode]::Decompress)
    $tar = [System.Formats.Tar.TarReader]::new($gzip)
    try {
        $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in @('repository.bundle', 'workspace.zip', 'source-manifest.json', 'SourceSnapshot.psm1')) {
            [void]$allowed.Add($name)
        }
        while ($null -ne ($entry = $tar.GetNextEntry())) {
            if (-not $allowed.Remove($entry.Name) -or $entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile)) {
                throw 'Unsafe source payload entry.'
            }
            $destination = [IO.File]::Create((Join-Path $payloadRoot $entry.Name))
            try {
                $entry.DataStream.CopyTo($destination)
            }
            finally {
                $destination.Dispose()
            }
        }
        if ($allowed.Count -ne 0) {
            throw 'Incomplete source payload; operator must deploy compatible sender and runner.'
        }
    }
    finally {
        $tar.Dispose()
        $gzip.Dispose()
        $stream.Dispose()
    }
    Import-Module (Join-Path $payloadRoot 'SourceSnapshot.psm1') -Force
    $manifest = Get-Content -LiteralPath (Join-Path $payloadRoot 'source-manifest.json') -Raw | ConvertFrom-Json
    # Do not checkout bundled HEAD: its files may be deleted or replaced in the candidate.
    # Clear inherited index selection for clone only; it belongs to the sender's repository.
    $hadIndex = Test-Path Env:GIT_INDEX_FILE
    $savedIndex = $env:GIT_INDEX_FILE
    try {
        Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        git clone --no-checkout (Join-Path $payloadRoot 'repository.bundle') $sourceRoot | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw 'Repository bundle clone failed.'
        }
    }
    finally {
        if ($hadIndex) {
            $env:GIT_INDEX_FILE = $savedIndex
        }
        else {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        }
    }
    $sourceSnapshot = Restore-SourceSnapshot -Root $sourceRoot -Archive (Join-Path $payloadRoot 'workspace.zip') -Manifest $manifest -RunId $runId
    # END EXACT SOURCE RESTORE

    $configurationRelativePath = $env:PROJECT_CONFIG_PATH
    # Read-RunnerProject rejects rooted paths, traversal, links and mismatched bytes.
    $configurationPath = Join-Path $sourceRoot $configurationRelativePath
    $project = Read-RunnerProject -Path $configurationPath -PayloadRoot $sourceRoot -ExpectedSha256 $env:PROJECT_CONFIG_SHA256
    $projectExecution = Invoke-RunnerProject -Project $project -PayloadRoot $sourceRoot -EvidenceRoot (Join-Path $artifactsRoot 'steps') -RunClock $clock -AbsoluteDeadlineSeconds $deadlineSeconds -FinalizationReserveSeconds 5 -OperatorLimits @{
        budgetSeconds = 3600
        maxConcurrency = 2
        maxLogBytes = 16777216
        maxArtifactBytes = 67108864
        maxArtifacts = 128
    } -ArgumentValues @{ '{resultsRoot}' = $artifactsRoot }
    # Copy only declared, verified artifacts, retaining relative identity and hidden files.
    foreach ($artifact in $projectExecution.artifacts) {
        $source = Join-Path $sourceRoot $artifact.path
        $destination = Join-Path (Join-Path $artifactsRoot 'project') $artifact.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        if ((Get-FileHash -LiteralPath $destination).Hash.ToLowerInvariant() -cne $artifact.sha256) {
            throw 'Artifact bytes changed during finalization.'
        }
    }
    if ($projectExecution.status -ne 'succeeded' -or -not $projectExecution.cleanupComplete) {
        throw "Project execution failed: $($projectExecution.status); $($projectExecution.errors -join '; ')"
    }
    $exitCode = 0
}
catch {
    $failure = $_.Exception.Message
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $artifactsRoot 'runner-error.log')
}
finally {
    @{
        runId = $runId
        exitCode = $exitCode
        completedUtc = [DateTime]::UtcNow.ToString('o')
        tests = $null
        accepted = $false
        error = $failure
        sourceSnapshot = $sourceSnapshot
        projectExecution = $projectExecution
        projectConfiguration = @{ version = 1; path = $env:PROJECT_CONFIG_PATH; sha256 = $env:PROJECT_CONFIG_SHA256 }
        executionIdentity = @{
            frameworkInputDigest = $env:RUNNER_INPUT_DIGEST
            operatorManifestSha256 = $env:RUNNER_MANIFEST_SHA256
            releaseId = $env:RUNNER_RELEASE_ID
            payloadVersion = 1
            evidenceVersion = 1
        }
        runnerProtocol = 1
        runnerImage = $env:RUNNER_IMAGE
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifactsRoot 'result.json')
}
exit $exitCode
