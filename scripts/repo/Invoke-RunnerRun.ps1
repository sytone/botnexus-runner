<#
.SYNOPSIS
Submits one exact-source generic execution to an existing immutable runner job.
.DESCRIPTION
Validates clean raw source, the real project schema, private provider identity and
existing image-owned job entrypoint. Captures the canonical source payload and
uploads it before one execution-only POST. Never updates the job definition.
A retained canonical per-target journal prevents alternate StatePath replay after
an uncertain start. Current independent release approval is mandatory; this command
never issues approval. Submission is not completion or application acceptance.
The trusted operator must keep the OS user/data home stable and exclude other
operators through reconciliation. This is cooperative exclusion, not provider atomicity. Remote artifacts
remain at the explicit private destination, including partial failure evidence.
.PARAMETER SourceRoot
Clean candidate Git checkout. Framework modules are loaded from this command's installation.
.PARAMETER ExpectedCommit
Exact lowercase candidate commit.
.PARAMETER ProjectConfigPath
Candidate-relative generic project configuration file.
.PARAMETER ProjectConfigSha256
SHA256 of the exact project configuration bytes.
.PARAMETER RunnerImage
Explicit immutable image reference. Must equal the existing job image.
.PARAMETER ArtifactDestination
Explicit credential-free HTTPS artifact destination.
.PARAMETER ConfigurationPath
One strict versioned external private maintenance target profile. No legacy
per-operation configuration is accepted. Reader returns a private in-memory projection.
.PARAMETER PrivateRoot
Explicit existing operator-controlled directory containing the profile, outside Git.
.PARAMETER ConfigurationSha256
Exact SHA256 of the private configuration bytes.
.PARAMETER StatePath
New private receipt file in an existing external directory. Retained after submission.
A separate canonical journal under the OS local application-data directory owns the
target fence; changing this receipt path cannot bypass it. Completed journals retain audit records; only explicitly different transports may start later.
.PARAMETER ReleaseManifestPath
Current independent external release approval. Revalidated at upload, start and
reconciliation against installed runtime inputs, immutable image and project capability.
.PARAMETER Reconcile
Reads one recorded provider execution without upload, start, replay or polling.
Validates terminal status and downloaded generic evidence, never application acceptance.
Retains verified result.json and project artifacts in a private run-ID.evidence directory
beside StatePath; the private receipt records evidencePath. Existing different bytes
fail closed without replacement. Public output reports evidenceRetained, not private paths.
Missing immutable execution identity remains unknown and cannot authorize replay.
.PARAMETER ProviderCommand
Native provider executable. Defaults to az; inert substitutes are for fixtures only.
.PARAMETER TimeoutSeconds
Original local operation allowance including preparation and owned provider drain.
The image execution retains its separate fixed 1200-second platform allowance.
.EXAMPLE
./Invoke-RunnerRun.ps1 -SourceRoot /candidate -ExpectedCommit $commit -ProjectConfigPath ci/project.json -ProjectConfigSha256 $hash -RunnerImage $image -ArtifactDestination $destination -ConfigurationPath /private/run.json -ConfigurationSha256 $privateHash -PrivateRoot /private -StatePath /private/fence.json -ReleaseManifestPath /operator/release.json -WhatIf
Validates local inputs without provider requests, temporary files or environment changes.
.OUTPUTS
System.String. Redacted submitted-unverified receipt with tests null and accepted
false. Nonzero fixed redacted error on denial or uncertain submission. Retains the
private fence and target-wide journal; explicit read-only reconciliation never replays.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ProjectConfigPath,
    [Parameter(Mandatory)][string]$ProjectConfigSha256,
    [Parameter(Mandatory)][string]$RunnerImage,
    [Parameter(Mandatory)][string]$ArtifactDestination,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][string]$ReleaseManifestPath,
    [switch]$Reconcile,
    [string]$ProviderCommand = 'az',
    [ValidateRange(4, 1200)][int]$TimeoutSeconds = 1200
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$operationClock = [Diagnostics.Stopwatch]::StartNew()
$scratch = $null
$attempted = $false
$providerExecutable = $ProviderCommand
function Invoke-RunnerRunProvider {
    <#
    .SYNOPSIS
    Runs one private provider command on the original operation clock.
    .DESCRIPTION
    Reuses bounded capture, dual-stream draining and owned process containment.
    .PARAMETER Argument
    Literal native arguments. No shell expansion or public provider output.
    .EXAMPLE
    Invoke-RunnerRunProvider -Argument @('account', 'show', '--output', 'json')
    .OUTPUTS
    System.String. Bounded private provider output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$Argument)
    $remaining = [int][Math]::Floor($TimeoutSeconds - $operationClock.Elapsed.TotalSeconds)
    if ($remaining -lt 2) {
        throw 'Original operation allowance exhausted.'
    }
    if ($Argument[0] -cne 'account') {
        $Argument += @('--subscription', $configuration.subscriptionId)
    }
    Invoke-PrivateCommand -Executable $providerExecutable -Argument $Argument -LimitSeconds $remaining -Owned -Capture
}
$targetReservation = $null
try {
    . (Join-Path $PSScriptRoot 'Import-RunnerMaintenanceProfile.ps1')
    . (Join-Path $PSScriptRoot 'Import-RunnerTargetJournal.ps1')
    if ($ExpectedCommit -cnotmatch '^[a-f0-9]{40}$' -or $ProjectConfigSha256 -cnotmatch '^[a-f0-9]{64}$' -or $ConfigurationSha256 -cnotmatch '^[a-f0-9]{64}$' -or $RunnerImage -cnotmatch '^[a-z0-9][a-z0-9./_-]*@sha256:[a-f0-9]{64}$') {
        throw 'Invalid exact identities.'
    }
    $root = Assert-ObservedPath -Path $SourceRoot -Directory
    $privateFile = Assert-ObservedPath -Path $ConfigurationPath
    $stateFile = [IO.Path]::GetFullPath($StatePath)
    $stateParent = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($stateFile)) -Directory
    foreach ($path in @($privateFile, $stateFile)) {
        if ($path.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Private input must be external.'
        }
    }
    if ($stateFile -eq $privateFile -or (-not $Reconcile -and (Test-Path -LiteralPath $stateFile))) {
        throw 'Existing or conflicting operation fence.'
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    if ((Get-FileHash -LiteralPath $privateFile).Hash.ToLowerInvariant() -cne $ConfigurationSha256) {
        throw 'Private configuration hash mismatch.'
    }
    $profileSelection = Read-RunnerMaintenanceProfile -Path $privateFile -ExpectedSha256 $ConfigurationSha256 -Operation run -SourceRoot $root -PrivateRoot $PrivateRoot -ExpectedCommit $ExpectedCommit
    $configuration = $profileSelection.configuration
    if ($RunnerImage -cne $profileSelection.runnerImage -or $ArtifactDestination -cne $profileSelection.artifactDestination) {
        throw 'Explicit execution inputs conflict with the selected profile.'
    }
    if ($configuration.resourceId -cnotmatch '^/subscriptions/[a-f0-9-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.App/jobs/[a-z][a-z0-9-]{0,62}$') {
        throw 'Invalid explicit job.'
    }
    foreach ($id in @($configuration.managedIdentityClientId)) {
        if ($id -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
            throw 'Unknown identity.'
        }
    }
    Assert-RunnerAccountBinding -Configuration $configuration
    foreach ($destination in @($configuration.sourceBlobUrl, $ArtifactDestination)) {
        $uri = [uri]$destination
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -eq '/') {
            throw 'Invalid credential-free destination.'
        }
    }
    if ($configuration.sourceBlobUrl -ceq $ArtifactDestination) {
        throw 'Conflicting transport destinations.'
    }
    Import-Module (Join-Path $PSScriptRoot '../../infra/buildtest/runner/RunnerProject.psm1') -Force -WarningAction SilentlyContinue
    $project = Read-RunnerProject -Path (Join-Path $root $ProjectConfigPath) -PayloadRoot $root -ExpectedSha256 $ProjectConfigSha256
    Import-Module (Join-Path $PSScriptRoot 'SourceSnapshot.psm1') -Force -WarningAction SilentlyContinue
    $manifest = Get-SourceSnapshotManifest -RepoRoot $root
    Import-Module (Join-Path $PSScriptRoot 'RunnerReleaseCompatibility.psm1') -Force -WarningAction SilentlyContinue
    $runtimeRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $releaseFile = Assert-ObservedPath -Path $ReleaseManifestPath
    if ($releaseFile.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Approval must be independent of candidate.'
    }
    $release = Assert-RunnerReleaseCompatibility -ManifestPath $releaseFile -CandidateRoot $runtimeRoot -DeployedImage $RunnerImage -Mode project
    $journalRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData, [Environment+SpecialFolderOption]::DoNotVerify)) 'BotNexus/runner-operations'
    $targetKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($configuration.resourceId.ToLowerInvariant()))).ToLowerInvariant()
    $journalPath = Join-Path $journalRoot ($targetKey + '.json')
    $operationIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($configuration.resourceId.ToLowerInvariant() + "`n" + $configuration.sourceBlobUrl + "`n" + $ArtifactDestination)))).ToLowerInvariant()
    $previous = $null
    if (-not $Reconcile -and (Test-Path -LiteralPath $journalPath)) {
        $previous = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $journalPath)
        if ($previous.status -cne 'completed-reconciled' -or $previous.operationIdentity -ceq $operationIdentity -or $previous.terminalStatus -cnotin @('Succeeded', 'Failed', 'Cancelled') -or $previous.evidenceVerified -isnot [bool] -or -not $previous.evidenceVerified) {
            throw 'Target has a retained operation; reconciliation is required.'
        }
        $audit = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path (Join-Path $journalRoot ($previous.runId + '.completed.json')))
        if (($audit | ConvertTo-Json -Depth 20 -Compress) -cne ($previous | ConvertTo-Json -Depth 20 -Compress)) {
            throw 'Completed operation audit conflicts.'
        }
        foreach ($completedFile in Get-ChildItem -LiteralPath $journalRoot -Filter '*.completed.json' -File -Force) {
            $completed = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $completedFile.FullName)
            if ($completed.operationIdentity -ceq $operationIdentity) {
                throw 'Previously completed operation cannot be replayed.'
            }
        }
    }
    if (-not $PSCmdlet.ShouldProcess('validated generic runner execution', 'Upload exact source and submit one execution without updating job')) {
        return
    }
    . (Join-Path $PSScriptRoot '../../infra/buildtest/runner/Import-RunnerDiagnostic.ps1')
    $accountText = Invoke-RunnerRunProvider -Argument @('account', 'show', '--output', 'json', '--only-show-errors')
    $account = ConvertFrom-RunnerPrivateJson -Text $accountText
    Assert-RunnerAccountBinding -Configuration $configuration -Account $account
    $targetReservation = Enter-RunnerTargetReservation -Resource $configuration.resourceId
    if (Test-Path -LiteralPath $targetReservation.DeploymentPath) {
        Assert-RunnerJournalPath -Path $targetReservation.DeploymentPath
        $deployment = Read-RunnerPrivateObject -Path $targetReservation.DeploymentPath
        if ($deployment.status -cne 'completed-reconciled' -or $deployment.targetKey -cne $targetReservation.Key -or $deployment.operationId -cnotmatch '^[0-9a-f]{32}$' -or $deployment.causalStatus -notin @(200, 202)) {
            throw 'Target has an unresolved deployment.'
        }
        $deploymentAudit = Join-Path $targetReservation.Root ($deployment.operationId + '.deployment-completed.json')
        Assert-RunnerJournalPath -Path $deploymentAudit
        if (((Read-RunnerPrivateObject -Path $deploymentAudit) | ConvertTo-Json -Depth 20 -Compress) -cne ($deployment | ConvertTo-Json -Depth 20 -Compress)) {
            throw 'Deployment audit conflicts.'
        }
    }
    $url = 'https://management.azure.com' + $configuration.resourceId
    if ($Reconcile) {
        $record = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $journalPath)
        $state = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $stateFile)
        if ($record.operationIdentity -cne $operationIdentity -or $state.runId -cne $record.runId -or $record.sourceCommit -cne $ExpectedCommit -or $record.sourceDigest -cne $manifest.digest -or $record.configurationSha256 -cne $ConfigurationSha256 -or $record.projectConfigSha256 -cne $ProjectConfigSha256 -or $record.image -cne $RunnerImage -or $record.releaseManifestSha256 -cne $release.manifestSha256 -or -not $record.Contains('executionId')) {
            throw 'Recorded operation is unknown or does not match current inputs.'
        }
        foreach ($key in $record.Keys) {
            if (-not $state.Contains($key) -or ($state[$key] | ConvertTo-Json -Depth 20 -Compress) -cne ($record[$key] | ConvertTo-Json -Depth 20 -Compress)) {
                throw 'Private operation records conflict.'
            }
        }
        $executionId = [string]$record.executionId
        if (-not $executionId.StartsWith($configuration.resourceId + '/executions/', [StringComparison]::Ordinal) -or $executionId.Substring(($configuration.resourceId + '/executions/').Length) -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$') {
            throw 'Unknown execution identity.'
        }
        $execution = Invoke-RunnerRunProvider -Argument @('rest', '--method', 'get', '--url', ('https://management.azure.com' + $executionId + '?api-version=2024-03-01'), '--output', 'json', '--only-show-errors') | ConvertFrom-Json -AsHashtable
        $executionContainers = @($execution.properties.template.containers)
        if ($execution.id -cne $executionId -or $executionContainers.Count -ne 1 -or $executionContainers[0].image -cne $RunnerImage -or $executionContainers[0].Contains('command') -or $executionContainers[0].Contains('args')) {
            throw 'Provider execution does not match recorded release.'
        }
        $terminalStatus = $execution.properties.status
        if ($terminalStatus -isnot [string] -or $terminalStatus -cnotin @('Succeeded', 'Failed', 'Cancelled')) {
            throw 'Execution is not a known terminal state.'
        }
        $environment = @{}
        foreach ($item in $executionContainers[0].env) {
            if ($environment.Contains($item.name)) {
                throw 'Duplicate execution environment.'
            }
            $environment[$item.name] = $item.value
        }
        foreach ($pair in @(@('RUN_ID', $record.runId), @('PROJECT_CONFIG_PATH', $ProjectConfigPath), @('PROJECT_CONFIG_SHA256', $ProjectConfigSha256), @('ARTIFACT_BLOB_URL', $ArtifactDestination), @('SOURCE_BLOB_URL', $configuration.sourceBlobUrl))) {
            if ($environment[$pair[0]] -cne $pair[1]) {
                throw 'Execution environment identity mismatch.'
            }
        }
        $scratch = Join-Path $stateParent ('runner-run-' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($scratch)
        if ($IsLinux) {
            [IO.File]::SetUnixFileMode($scratch, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
        }
        Import-Module (Join-Path $PSScriptRoot 'RunnerRunEvidence.psm1') -Force -WarningAction SilentlyContinue
        $proof = Get-RunnerRunEvidence -Destination $ArtifactDestination -Root $scratch -Record $record -Project $project -ProjectPath $ProjectConfigPath -TerminalStatus $terminalStatus -ProviderRead { param($Argument) Invoke-RunnerRunProvider -Argument $Argument }
        $current = Assert-RunnerReleaseCompatibility -ManifestPath $releaseFile -CandidateRoot $runtimeRoot -DeployedImage $RunnerImage -Mode project
        if ($current.manifestSha256 -cne $release.manifestSha256 -or $operationClock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw 'Approval or operation allowance changed during reconciliation.'
        }
        Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
        if ((Get-SourceSnapshotManifest -RepoRoot $root).digest -cne $manifest.digest -or (Get-FileHash -LiteralPath $privateFile).Hash.ToLowerInvariant() -cne $ConfigurationSha256) {
            throw 'Inputs changed during reconciliation.'
        }
        if ($record.runId -cnotmatch '^[a-f0-9]{32}$') {
            throw 'Invalid retained run identity.'
        }
        $evidencePath = Join-Path $stateParent ($record.runId + '.evidence')
        if (Test-Path -LiteralPath $evidencePath) {
            Assert-ObservedPath -Path $evidencePath -Directory | Out-Null
        }
        $record.evidencePath = Save-RunnerRunEvidence -Root $scratch -Destination $evidencePath -Confirm:$false
        if (-not [IO.Directory]::Exists($scratch)) {
            $scratch = $null
        }
        $record.status = 'completed-reconciled'
        $record.terminalStatus = $terminalStatus
        $record.evidenceVerified = $true
        $record.resultSha256 = $proof
        $auditPath = Join-Path $journalRoot ($record.runId + '.completed.json')
        if (Test-Path -LiteralPath $auditPath) {
            $audit = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $auditPath)
            if (($audit | ConvertTo-Json -Depth 20 -Compress) -cne ($record | ConvertTo-Json -Depth 20 -Compress)) {
                throw 'Completed audit conflicts with reconciliation.'
            }
        }
        else {
            $auditFile = [IO.File]::Open($auditPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                if ($IsLinux) {
                    [IO.File]::SetUnixFileMode($auditPath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 20 -Compress))
                $auditFile.Write($bytes)
                $auditFile.Flush($true)
            }
            finally {
                $auditFile.Dispose()
            }
        }
        foreach ($fencePath in @($journalPath, $stateFile)) {
            $fence = [IO.File]::Open($fencePath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 20 -Compress))
                $fence.SetLength(0)
                $fence.Write($bytes)
                $fence.Flush($true)
            }
            finally {
                $fence.Dispose()
            }
        }
        @{ status = 'execution-observed-unverified'; terminalStatus = $terminalStatus; evidenceVerified = $true; evidenceRetained = $true; tests = $null; accepted = $false } | ConvertTo-Json -Compress
        return
    }
    $job = Invoke-RunnerRunProvider -Argument @('rest', '--method', 'get', '--url', ($url + '?api-version=2024-03-01'), '--output', 'json', '--only-show-errors') | ConvertFrom-Json -AsHashtable
    $policy = $job.properties.configuration
    $containers = @($job.properties.template.containers)
    $identities = @($job.identity.userAssignedIdentities.Values)
    if ($job.id -cne $configuration.resourceId -or $identities.Count -ne 1 -or $identities[0].clientId -cne $configuration.managedIdentityClientId -or $containers.Count -ne 1 -or $containers[0].image -cne $RunnerImage -or $containers[0].name -cne 'runner' -or $containers[0].Contains('command') -or $containers[0].Contains('args')) {
        throw 'Unexpected job image, entrypoint or identity.'
    }
    if ($policy.triggerType -cne 'Manual' -or $policy.replicaTimeout -ne 1200 -or $policy.replicaRetryLimit -ne 0 -or $policy.manualTriggerConfig.parallelism -ne 1 -or $policy.manualTriggerConfig.replicaCompletionCount -ne 1) {
        throw 'Unexpected platform execution policy.'
    }
    $scratch = Join-Path $stateParent ('runner-run-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($scratch)
    if ($IsLinux) {
        [IO.File]::SetUnixFileMode($scratch, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $capture = Join-Path $scratch 'capture'
    [void][IO.Directory]::CreateDirectory($capture)
    $captured = Get-SourceSnapshotManifest -RepoRoot $root -CaptureRoot $capture
    if ($captured.digest -cne $manifest.digest) {
        throw 'Source changed during capture.'
    }
    $captured | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $scratch 'source-manifest.json') -Encoding utf8NoBOM
    $zip = [IO.Compression.ZipFile]::Open((Join-Path $scratch 'workspace.zip'), [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $captured.files) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $capture $file.path), $file.path) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
    $remaining = [int][Math]::Floor($TimeoutSeconds - $operationClock.Elapsed.TotalSeconds)
    Invoke-PrivateCommand -Executable git -Argument @('-C', $root, 'bundle', 'create', (Join-Path $scratch 'repository.bundle'), 'HEAD') -LimitSeconds $remaining | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SourceSnapshot.psm1') -Destination (Join-Path $scratch 'SourceSnapshot.psm1')
    $archive = Join-Path $scratch 'source.tar.gz'
    New-SourcePayloadArchive -Root $scratch -Destination $archive | Out-Null
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    if ((Get-SourceSnapshotManifest -RepoRoot $root).digest -cne $manifest.digest -or (Get-FileHash -LiteralPath $privateFile).Hash.ToLowerInvariant() -cne $ConfigurationSha256) {
        throw 'Inputs changed before submission.'
    }
    $current = Assert-RunnerReleaseCompatibility -ManifestPath $releaseFile -CandidateRoot $runtimeRoot -DeployedImage $RunnerImage -Mode project
    if ($current.manifestSha256 -cne $release.manifestSha256) {
        throw 'Approval changed before upload.'
    }
    $artifactDestinationSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ArtifactDestination))).ToLowerInvariant()
    $runId = [guid]::NewGuid().ToString('N')
    [void][IO.Directory]::CreateDirectory($journalRoot)
    Assert-ObservedPath -Path $journalRoot -Directory | Out-Null
    if ($IsLinux) {
        [IO.File]::SetUnixFileMode($journalRoot, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
    }
    $record = @{ runId = $runId; operationIdentity = $operationIdentity; sourceCommit = $ExpectedCommit; sourceDigest = $manifest.digest; configurationSha256 = $ConfigurationSha256; projectConfigSha256 = $ProjectConfigSha256; artifactDestinationSha256 = $artifactDestinationSha256; image = $RunnerImage; releaseManifestSha256 = $release.manifestSha256; status = 'attempted-unknown' }
    foreach ($fencePath in @($journalPath, $stateFile)) {
        $mode = [IO.FileMode]::CreateNew
        if ($fencePath -ceq $journalPath -and $null -ne $previous) {
            $observed = Read-RunnerPrivateObject -Path (Assert-ObservedPath -Path $journalPath)
            if (($observed | ConvertTo-Json -Depth 20 -Compress) -cne ($previous | ConvertTo-Json -Depth 20 -Compress)) {
                throw 'Completed journal changed before new operation.'
            }
            $mode = [IO.FileMode]::Open
        }
        $fence = [IO.File]::Open($fencePath, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            if ($IsLinux) {
                [IO.File]::SetUnixFileMode($fencePath, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
            }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))
            $fence.SetLength(0)
            $fence.Write($bytes)
            $fence.Flush($true)
        }
        finally {
            $fence.Dispose()
        }
    }
    $attempted = $true
    Invoke-RunnerRunProvider -Argument @('storage', 'blob', 'upload', '--blob-url', $configuration.sourceBlobUrl, '--file', $archive, '--auth-mode', 'login', '--overwrite', 'false', '--if-none-match', '*', '--only-show-errors', '--output', 'json') | Out-Null
    $environment = @{
        AZURE_CLIENT_ID = $configuration.managedIdentityClientId
        RUN_ID = $runId
        SOURCE_BLOB_URL = $configuration.sourceBlobUrl
        ARTIFACT_BLOB_URL = $ArtifactDestination
        PROJECT_CONFIG_PATH = $ProjectConfigPath
        PROJECT_CONFIG_SHA256 = $project['_configSha256']
        RUNNER_IMAGE = $RunnerImage
        REPLICA_TIMEOUT_SECONDS = '1200'
    }
    $container = @{ name = 'runner'; image = $RunnerImage; resources = $containers[0].resources; env = @() }
    foreach ($key in $environment.Keys) {
        $container.env += @{ name = $key; value = $environment[$key] }
    }
    $body = Join-Path $scratch 'execution.json'
    @{ containers = @($container) } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $body -Encoding utf8NoBOM
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    if ((Get-SourceSnapshotManifest -RepoRoot $root).digest -cne $manifest.digest -or (Get-FileHash -LiteralPath $privateFile).Hash.ToLowerInvariant() -cne $ConfigurationSha256) {
        throw 'Inputs changed before start.'
    }
    $current = Assert-RunnerReleaseCompatibility -ManifestPath $releaseFile -CandidateRoot $runtimeRoot -DeployedImage $RunnerImage -Mode project
    if ($current.manifestSha256 -cne $release.manifestSha256) {
        throw 'Approval changed before start.'
    }
    $response = Invoke-RunnerRunProvider -Argument @('rest', '--method', 'post', '--url', ($url + '/start?api-version=2024-03-01'), '--body', ('@' + $body), '--output', 'json', '--only-show-errors') | ConvertFrom-Json -AsHashtable
    $executionPrefix = $configuration.resourceId + '/executions/'
    if ($response.id -isnot [string] -or -not $response.id.StartsWith($executionPrefix, [StringComparison]::Ordinal) -or $response.id.Substring($executionPrefix.Length) -cnotmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}$') {
        throw 'Provider did not return immutable execution identity.'
    }
    $record.executionId = $response.id
    $record.status = 'submitted-unverified'
    foreach ($fencePath in @($journalPath, $stateFile)) {
        $fence = [IO.File]::Open($fencePath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress))
            $fence.SetLength(0)
            $fence.Write($bytes)
            $fence.Flush($true)
        }
        finally {
            $fence.Dispose()
        }
    }
    @{ status = 'submitted-unverified'; sourceCommit = $ExpectedCommit; sourceDigest = $manifest.digest; projectConfigSha256 = $ProjectConfigSha256; tests = $null; accepted = $false } | ConvertTo-Json -Compress
}
catch {
    $message = if ($attempted) {
        'Runner submission outcome is unknown. Retain the operation fence and reconcile read-only; do not retry.'
    }
    else {
        'Runner run validation or preparation failed. Check exact source, configuration, image and provider identity.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $targetReservation) {
        try {
            Exit-RunnerTargetReservation -Reservation $targetReservation
        }
        catch {
            [Console]::Error.WriteLine('Runner target reservation cleanup is unknown. Preserve private state.')
            exit 1
        }
    }
    if ($null -ne $scratch) {
        try {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
        }
        catch {
            [Console]::Error.WriteLine('Runner private preparation cleanup is unknown. Retain the operation fence.')
            exit 1
        }
    }
}
