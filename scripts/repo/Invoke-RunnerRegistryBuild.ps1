<#
.SYNOPSIS
Builds and publishes the standalone runner image using Azure Container Registry.
.DESCRIPTION
Submits the runner-owned Docker build context to ACR using the explicitly selected
Azure account. No local registry credential, Podman push or application checkout is
used. A unique source-bound tag cannot overwrite an existing tag. Retains the ACR
run identifier and verifies its successful output against registry digest readback.
An incomplete or uncertain build requires Reconcile; it is never resubmitted.
WhatIf validates local inputs without provider calls or receipt writes. This command
creates an image only; it does not deploy infrastructure or start container jobs.
.PARAMETER SourceRoot
Exact clean standalone runner checkout with all image COPY files.
.PARAMETER ExpectedCommit
Full lowercase commit matching the checkout bytes and source-bound build tag.
.PARAMETER ConfigurationPath
Existing private maintenance profile selecting the Azure account and build tag.
.PARAMETER ConfigurationSha256
Lowercase SHA256 of the exact selected profile bytes.
.PARAMETER PrivateRoot
Existing operator-owned private directory outside the source repository.
.PARAMETER StatePath
New retained private receipt path under PrivateRoot. Reconcile selects this same path.
.PARAMETER ProviderCommand
Existing Azure CLI executable. Offline tests supply an inert command.
.PARAMETER TimeoutSeconds
Maximum local provider-call allowance, including owned cleanup. Defaults to 120.
.PARAMETER BuildTimeoutSeconds
Azure registry build timeout, from 300 to 3600 seconds. Defaults to 1200.
.PARAMETER Reconcile
Reads the previously submitted ACR run and registry digest without another build.
.EXAMPLE
./Invoke-RunnerRegistryBuild.ps1 -SourceRoot /runner -ExpectedCommit $commit -ConfigurationPath /private/target.json -ConfigurationSha256 $hash -PrivateRoot /private -StatePath /private/build.json -WhatIf
Checks local inputs; remove WhatIf to submit one ACR build and retain its run ID.
.EXAMPLE
./Invoke-RunnerRegistryBuild.ps1 -SourceRoot /runner -ExpectedCommit $commit -ConfigurationPath /private/target.json -ConfigurationSha256 $hash -PrivateRoot /private -StatePath /private/build.json -Reconcile
Reads the original build status and returns success only after exact digest readback.
.OUTPUTS
System.String. Redacted JSON status image-published when the run and registry agree.
The immutable image reference is retained in the private receipt. Nonzero exit means
validation failed or the outcome remains unknown; preserve the receipt before retry.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$StatePath,
    [string]$ProviderCommand = 'az',
    [ValidateRange(4, 600)][int]$TimeoutSeconds = 120,
    [ValidateRange(300, 3600)][int]$BuildTimeoutSeconds = 1200,
    [switch]$Reconcile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$reservation = $null
$attempted = $false
try {
    . (Join-Path $PSScriptRoot 'Import-RunnerMaintenanceProfile.ps1')
    . (Join-Path $PSScriptRoot 'Import-RunnerTargetJournal.ps1')
    $root = Assert-ObservedPath -Path $SourceRoot -Directory
    $private = (Assert-ObservedPath -Path $PrivateRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $selection = Read-RunnerMaintenanceProfile -Path $ConfigurationPath -ExpectedSha256 $ConfigurationSha256 -Operation build -SourceRoot $root -PrivateRoot $private -ExpectedCommit $ExpectedCommit
    $targetProfile = Read-RunnerPrivateObject -Path $ConfigurationPath
    $configuration = @{} + $targetProfile.account
    $configuration.resourceId = $targetProfile.target.resourceId
    Assert-RunnerAccountBinding -Configuration $configuration
    $tagMatch = [regex]::Match($selection.configuration.imageTag, '^(?<registry>[a-z0-9]{5,50})\.azurecr\.io/(?<repository>[a-z0-9][a-z0-9/_.-]*):(?<tag>src-[a-f0-9]{40})$')
    if (-not $tagMatch.Success) {
        throw 'Invalid selected registry tag.'
    }
    $registry = $tagMatch.Groups['registry'].Value
    $repository = $tagMatch.Groups['repository'].Value
    $tag = $tagMatch.Groups['tag'].Value
    $stateFile = [IO.Path]::GetFullPath($StatePath)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    if (-not $stateFile.StartsWith($private + [IO.Path]::DirectorySeparatorChar, $comparison) -or $stateFile -ceq $ConfigurationPath) {
        throw 'Private build receipt boundary conflict.'
    }
    $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($stateFile)) -Directory
    $ancestor = [IO.Path]::GetDirectoryName($stateFile)
    while ($ancestor) {
        if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
            throw 'Private receipt belongs to Git.'
        }
        $ancestor = [IO.Path]::GetDirectoryName($ancestor)
    }
    $context = Join-Path $root 'infra/buildtest/runner'
    $manifest = Read-RunnerPrivateObject -Path (Join-Path $context 'image-runtime.json')
    $dockerfile = Get-Content -LiteralPath (Join-Path $context 'Dockerfile') -Raw
    $copied = @()
    foreach ($line in $dockerfile.Split("`n")) {
        if ($line.StartsWith('COPY ') -and $line -notmatch '--from=') {
            $parts = $line.Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($parts[-1] -cne '/runner/') {
                throw 'Unsupported image COPY destination.'
            }
            $copied += $parts[1..($parts.Length - 2)]
        }
    }
    if ($copied.Count -eq 0 -or @($copied | Select-Object -Unique).Count -ne $copied.Count -or (($copied | Sort-Object) -join ',') -cne (($manifest.runtimeFiles | Sort-Object) -join ',')) {
        throw 'Image runtime closure mismatch.'
    }
    foreach ($file in $copied) {
        if ($file -cnotmatch '^[A-Za-z][A-Za-z0-9.-]+$') {
            throw 'Unsafe runtime path.'
        }
        $runtimeItem = Get-Item -LiteralPath (Join-Path $context $file) -Force -ErrorAction Stop
        if ($runtimeItem -isnot [IO.FileInfo] -or $runtimeItem.LinkType -or ($runtimeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $runtimeItem.Length -le 0 -or $runtimeItem.Length -gt 1048576) {
            throw 'Unsafe or missing runtime file.'
        }
    }
    $operationText = $configuration.resourceId + ':' + $selection.configuration.imageTag + ':' + $ConfigurationSha256 + ':' + $BuildTimeoutSeconds
    $operationId = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($operationText))).ToLowerInvariant()
    $binding = @{ operationId = $operationId; sourceCommit = $ExpectedCommit; profileSha256 = $ConfigurationSha256; imageTag = $selection.configuration.imageTag; buildTimeoutSeconds = $BuildTimeoutSeconds; status = 'attempted-unknown' }
    if (-not $Reconcile -and (Test-Path -LiteralPath $stateFile)) {
        throw 'Existing build receipt requires reconciliation.'
    }
    if (-not $PSCmdlet.ShouldProcess('selected runner registry', 'Build and publish or reconcile runner image')) {
        return
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    . (Join-Path $context 'Import-RunnerDiagnostic.ps1')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $accountText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('account', 'show', '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
    $account = ConvertFrom-RunnerPrivateJson -Text $accountText
    Assert-RunnerAccountBinding -Configuration $configuration -Account $account
    $reservation = Enter-RunnerTargetReservation -Resource ('registry-build:' + $registry + '/' + $repository)
    $journal = Join-Path $reservation.Root ($reservation.Key + '.registry-build.json')
    if ($Reconcile) {
        foreach ($path in @($journal, $stateFile)) {
            Assert-RunnerJournalPath -Path $path
            $prior = Read-RunnerPrivateObject -Path $path
            foreach ($key in $binding.Keys) {
                if ($key -cne 'status' -and $prior[$key] -cne $binding[$key]) {
                    throw 'Original image build inputs changed.'
                }
            }
            if ($prior.status -cnotin @('attempted-unknown', 'image-published') -or -not $prior.Contains('runId') -or $prior.runId -cnotmatch '^[a-zA-Z0-9_-]{1,64}$') {
                throw 'Build run identity unavailable; inspect original submission without rebuilding.'
            }
            $binding.runId = $prior.runId
        }
    }
    else {
        $replaceCompleted = $false
        $auditPath = Join-Path $reservation.Root ($binding.operationId + '.infra-completed.json')
        if (Test-Path -LiteralPath $auditPath) {
            throw 'Completed operation cannot be replayed.'
        }
        if (Test-Path -LiteralPath $journal) {
            Assert-RunnerJournalPath -Path $journal
            $previous = Read-RunnerPrivateObject -Path $journal
            if ($previous.status -cne 'image-published' -or $previous.operationId -cnotmatch '^[a-f0-9]{64}$') {
                throw 'Previous operation remains unresolved.'
            }
            $previousAudit = Join-Path $reservation.Root ($previous.operationId + '.infra-completed.json')
            Assert-RunnerJournalPath -Path $previousAudit
            if ((Get-FileHash -LiteralPath $previousAudit -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash) {
                throw 'Completed operation audit changed.'
            }
            $replaceCompleted = $true
        }
        $repositoriesText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('acr', 'repository', 'list', '--name', $registry, '--subscription', $configuration.subscriptionId, '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
        if (-not $repositoriesText.Trim().StartsWith('[')) {
            throw 'Repository inventory unavailable.'
        }
        $repositories = ConvertFrom-Json -InputObject $repositoriesText -NoEnumerate
        if ($repository -cin @($repositories)) {
            $tagsText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('acr', 'repository', 'show-tags', '--name', $registry, '--repository', $repository, '--subscription', $configuration.subscriptionId, '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
            $tags = ConvertFrom-Json -InputObject $tagsText -NoEnumerate
            if (-not $tagsText.Trim().StartsWith('[') -or $tag -cin @($tags)) {
                throw 'Existing source tag cannot be overwritten.'
            }
        }
        Write-RunnerJournalRecord -Path $journal -Record $binding -Create:(-not $replaceCompleted)
        Write-RunnerJournalRecord -Path $stateFile -Record $binding -Create
        $attempted = $true
        $buildText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('acr', 'build', '--registry', $registry, '--subscription', $configuration.subscriptionId, '--image', ($repository + ':' + $tag), '--file', (Join-Path $context 'Dockerfile'), '--platform', 'linux/amd64', '--timeout', [string]$BuildTimeoutSeconds, '--no-wait', '--no-logs', '--output', 'json', '--only-show-errors', $context) -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
        $build = ConvertFrom-RunnerPrivateJson -Text $buildText
        if ($build.runId -cnotmatch '^[a-zA-Z0-9_-]{1,64}$') {
            throw 'ACR build identity unavailable.'
        }
        $binding.runId = $build.runId
        Write-RunnerJournalRecord -Path $journal -Record $binding
        Write-RunnerJournalRecord -Path $stateFile -Record $binding
    }
    $runText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('acr', 'task', 'show-run', '--registry', $registry, '--subscription', $configuration.subscriptionId, '--run-id', $binding.runId, '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
    $run = ConvertFrom-RunnerPrivateJson -Text $runText
    if ($run.runId -cne $binding.runId -or $run.status -cne 'Succeeded') {
        throw 'Build has not succeeded.'
    }
    $images = @($run.outputImages | Where-Object { $_.registry -ceq ($registry + '.azurecr.io') -and $_.repository -ceq $repository -and $_.tag -ceq $tag })
    if ($images.Count -ne 1 -or $images[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$') {
        throw 'Exact ACR image output missing.'
    }
    $metadataText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('acr', 'manifest', 'show-metadata', '--registry', $registry, '--subscription', $configuration.subscriptionId, '--name', ($repository + ':' + $tag), '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
    $metadata = ConvertFrom-RunnerPrivateJson -Text $metadataText
    if ($metadata.name -cne $tag -or $metadata.digest -cne $images[0].digest) {
        throw 'Registry digest differs from exact build output.'
    }
    $binding.image = $registry + '.azurecr.io/' + $repository + '@' + $metadata.digest
    $binding.status = 'image-published'
    $auditPath = Join-Path $reservation.Root ($binding.operationId + '.infra-completed.json')
    if (-not (Test-Path -LiteralPath $auditPath)) {
        Write-RunnerJournalRecord -Path $auditPath -Record $binding -Create
    }
    else {
        Assert-RunnerJournalPath -Path $auditPath
        $audit = Read-RunnerPrivateObject -Path $auditPath
        foreach ($key in $binding.Keys) {
            if ($key -cne 'outputs' -and $audit[$key] -cne $binding[$key]) {
                throw 'Completed audit binding conflict.'
            }
        }
    }
    Write-RunnerJournalRecord -Path $journal -Record $binding
    Write-RunnerJournalRecord -Path $stateFile -Record $binding
    @{ status = 'image-published'; sourceCommit = $ExpectedCommit; tests = $null; accepted = $false } | ConvertTo-Json -Compress
}
catch {
    $message = if ($attempted -or $Reconcile) {
        'Runner registry build outcome is unknown. Preserve the original run receipt and reconcile without rebuilding.'
    }
    else {
        'Runner registry build validation failed.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $reservation) {
        Exit-RunnerTargetReservation -Reservation $reservation
    }
}
