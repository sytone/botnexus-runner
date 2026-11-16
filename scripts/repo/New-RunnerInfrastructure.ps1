<#
.SYNOPSIS
Creates runner infrastructure from runner-owned templates in two explicit phases.
.DESCRIPTION
Registry creates the selected resource group and registry. Build and publish the
image separately, then Infrastructure deploys main.bicep with an immutable image.
Uses the current explicitly bound Azure account, private hash-pinned ARM parameter
file and a retained private submission fence. Never signs in, changes identity or
starts a container job. WhatIf performs local checks only. An uncertain submission
must be reconciled by deployment name; it is never automatically submitted again.
The trusted operator must exclude other writers through completion and uncertainty.
.PARAMETER SourceRoot
Clean standalone runner checkout containing the templates and helper dependencies.
.PARAMETER ExpectedCommit
Exact lowercase Git commit whose raw checkout bytes are required.
.PARAMETER ConfigurationPath
Existing strict private maintenance profile selecting account, target and image.
.PARAMETER ConfigurationSha256
SHA256 of the exact private profile bytes.
.PARAMETER PrivateRoot
Existing owner-controlled private directory outside the source and Git.
.PARAMETER ParametersPath
Existing private ARM deployment-parameters JSON. Only literal supported template
parameters are allowed; secret references and unknown fields are rejected.
.PARAMETER ParametersSha256
SHA256 of the exact private ARM parameter-file bytes.
.PARAMETER StatePath
New private retained receipt. Reconcile selects the same file and never resubmits.
.PARAMETER Phase
Registry provisions the initial registry. Infrastructure deploys the complete job,
network, storage and managed identity using an already published immutable image.
.PARAMETER Location
Explicit Azure location for initial resource-group creation, not a target default.
.PARAMETER ProviderCommand
Existing Azure CLI executable. Offline tests supply an inert synthetic executable.
.PARAMETER TimeoutSeconds
Single native-operation allowance including capture and cleanup; no hidden retries.
.PARAMETER ValidateOnly
Runs Azure template validation against the existing resource group without creating
resources or receipts. Registry validation requires the group to exist already.
.PARAMETER Reconcile
Read-only deployment lookup using the original receipt and exact input bindings.
.EXAMPLE
./New-RunnerInfrastructure.ps1 -SourceRoot /runner -ExpectedCommit $commit -ConfigurationPath /private/target.json -ConfigurationSha256 $profileHash -PrivateRoot /private -ParametersPath /private/registry.parameters.json -ParametersSha256 $parametersHash -StatePath /private/registry.json -Phase Registry -Location eastus -WhatIf
Checks local inputs without creating resources or state.
.OUTPUTS
System.String. Redacted provisioning status and private receipt location is not
printed. Actual resource outputs remain only in the private receipt. No image,
container execution, application acceptance or deployment qualification is implied.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$ParametersPath,
    [Parameter(Mandatory)][string]$ParametersSha256,
    [Parameter(Mandatory)][string]$StatePath,
    [Parameter(Mandatory)][ValidateSet('Registry', 'Infrastructure')][string]$Phase,
    [Parameter(Mandatory)][string]$Location,
    [string]$ProviderCommand = 'az',
    [ValidateRange(4, 600)][int]$TimeoutSeconds = 120,
    [switch]$Reconcile,
    [switch]$ValidateOnly
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
    $null = Read-RunnerMaintenanceProfile -Path $ConfigurationPath -ExpectedSha256 $ConfigurationSha256 -Operation $(if ($Phase -ceq 'Registry') {
            'build'
        }
        else {
            'deploy'
        }) -SourceRoot $root -PrivateRoot $private -ExpectedCommit $ExpectedCommit
    $targetProfile = Read-RunnerPrivateObject -Path $ConfigurationPath
    $configuration = @{} + $targetProfile.account
    $configuration.resourceId = $targetProfile.target.resourceId
    Assert-RunnerAccountBinding -Configuration $configuration
    $targetMatch = [regex]::Match($configuration.resourceId, '^/subscriptions/[a-f0-9-]+/resourceGroups/(?<group>[A-Za-z0-9_().-]{1,90})/providers/Microsoft.App/jobs/(?<job>[a-zA-Z0-9-]{1,60})$')
    if (-not $targetMatch.Success -or $Location -cnotmatch '^[a-z][a-z0-9]{1,31}$') {
        throw 'Invalid explicit provisioning target.'
    }
    $group = $targetMatch.Groups['group'].Value
    $job = $targetMatch.Groups['job'].Value
    $parameterFile = Assert-ObservedPath -Path $ParametersPath
    $stateFile = [IO.Path]::GetFullPath($StatePath)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    foreach ($path in @($parameterFile, $stateFile)) {
        if (-not $path.StartsWith($private + [IO.Path]::DirectorySeparatorChar, $comparison) -or $path -ceq $ConfigurationPath) {
            throw 'Private provisioning boundary conflict.'
        }
        $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($path)) -Directory
        $ancestor = [IO.Path]::GetDirectoryName($path)
        while ($ancestor) {
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
                throw 'Private input belongs to Git.'
            }
            $ancestor = [IO.Path]::GetDirectoryName($ancestor)
        }
    }
    if ($stateFile -ceq $parameterFile -or $ParametersSha256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $parameterFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ParametersSha256) {
        throw 'Provisioning input conflict.'
    }
    $document = Read-RunnerPrivateObject -Path $parameterFile
    if ((($document.Keys | Sort-Object) -join ',') -cne '$schema,contentVersion,parameters' -or $document.contentVersion -cne '1.0.0.0' -or $document.'$schema' -cne 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#' -or $document.parameters -isnot [Collections.IDictionary]) {
        throw 'Unsupported parameter document.'
    }
    $required = @('registryName')
    if ($Phase -ceq 'Infrastructure') {
        $required += @('operatorObjectId', 'runnerImageRepository', 'runnerImageDigest', 'projectConfigPath', 'projectConfigSha256', 'storageAccountName', 'identityName', 'environmentName', 'jobName', 'vnetName', 'subnetName', 'natGatewayName', 'publicIpName')
    }
    if ((($document.parameters.Keys | Sort-Object) -join ',') -cne (($required | Sort-Object) -join ',')) {
        throw 'Template parameters incomplete or unexpected.'
    }
    foreach ($key in $required) {
        $value = $document.parameters[$key]
        if ($value -isnot [Collections.IDictionary] -or $value.Count -ne 1 -or -not $value.Contains('value') -or $value.value -isnot [string] -or [string]::IsNullOrWhiteSpace($value.value) -or $value.value.Length -gt 512 -or $value.value -match '[\x00-\x1f]') {
            throw 'Only bounded literal template inputs are supported.'
        }
    }
    $registry = $document.parameters.registryName.value
    if ($registry -cnotmatch '^[a-z0-9]{5,50}$') {
        throw 'Invalid registry name.'
    }
    $image = if ($Phase -ceq 'Registry') {
        $targetProfile.images.buildTag
    }
    else {
        $targetProfile.images.desiredImage
    }
    if (-not $image.StartsWith($registry + '.azurecr.io/', [StringComparison]::Ordinal)) {
        throw 'Registry target mismatch.'
    }
    if ($Reconcile -and $ValidateOnly) {
        throw 'Select validation or reconciliation, not both.'
    }
    $expectedOutputs = @{ acrName = $registry }
    if ($Phase -ceq 'Infrastructure') {
        $expectedIdentity = '/subscriptions/' + $configuration.subscriptionId + '/resourceGroups/' + $group + '/providers/Microsoft.ManagedIdentity/userAssignedIdentities/' + $document.parameters.identityName.value
        if ($document.parameters.jobName.value -cne $job -or ($document.parameters.runnerImageRepository.value + '@sha256:' + $document.parameters.runnerImageDigest.value) -cne $image -or $targetProfile.target.managedIdentityResourceId -cne $expectedIdentity) {
            throw 'Infrastructure image, job or identity target mismatch.'
        }
        $expectedOutputs.storageAccountName = $document.parameters.storageAccountName.value
        $expectedOutputs.jobName = $job
        $expectedOutputs.runnerIdentityId = $expectedIdentity
    }
    $template = Join-Path $root ('infra/buildtest/' + $(if ($Phase -ceq 'Registry') {
                'registry.bicep'
            }
            else {
                'main.bicep'
            }))
    $templateItem = Get-Item -LiteralPath $template -Force -ErrorAction Stop
    if ($templateItem -isnot [IO.FileInfo] -or $templateItem.LinkType -or ($templateItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $templateItem.Length -le 0 -or $templateItem.Length -gt 1048576) {
        throw 'Invalid source template.'
    }
    $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($template)) -Directory
    $templateHash = (Get-FileHash -LiteralPath $template -Algorithm SHA256).Hash.ToLowerInvariant()
    $operationText = $configuration.resourceId + ':' + $Phase + ':' + $ExpectedCommit + ':' + $ParametersSha256 + ':' + $ConfigurationSha256 + ':' + $Location
    $operationHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($operationText))).ToLowerInvariant()
    $deploymentName = 'runner-' + $Phase.ToLowerInvariant() + '-' + $operationHash.Substring(0, 20)
    $binding = @{ operationId = $operationHash; sourceCommit = $ExpectedCommit; phase = $Phase; profileSha256 = $ConfigurationSha256; parametersSha256 = $ParametersSha256; templateSha256 = $templateHash; target = $configuration.resourceId; deploymentName = $deploymentName; location = $Location; status = 'attempted-unknown' }
    if (-not $Reconcile -and (Test-Path -LiteralPath $stateFile)) {
        throw 'Existing state requires read-only reconciliation.'
    }
    if (-not $PSCmdlet.ShouldProcess('explicit runner infrastructure target', 'Provision or reconcile selected phase')) {
        return
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    . (Join-Path $root 'infra/buildtest/runner/Import-RunnerDiagnostic.ps1')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $accountText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('account', 'show', '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
    $account = ConvertFrom-RunnerPrivateJson -Text $accountText
    Assert-RunnerAccountBinding -Configuration $configuration -Account $account
    if ($ValidateOnly) {
        Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('deployment', 'group', 'validate', '--subscription', $configuration.subscriptionId, '--resource-group', $group, '--template-file', $template, '--parameters', ('@' + $parameterFile), ('location=' + $Location), '--mode', 'Incremental', '--output', 'none', '--only-show-errors') -Owned -LimitSeconds $TimeoutSeconds -RunClock $clock | Out-Null
        @{ status = 'template-validated'; phase = $Phase; sourceCommit = $ExpectedCommit } | ConvertTo-Json -Compress
        return
    }
    $reservation = Enter-RunnerTargetReservation -Resource ('provision:' + $configuration.resourceId + ':' + $Phase)
    $journal = Join-Path $reservation.Root ($reservation.Key + '.provision.json')
    if ($Reconcile) {
        foreach ($path in @($journal, $stateFile)) {
            Assert-RunnerJournalPath -Path $path
            $prior = Read-RunnerPrivateObject -Path $path
            foreach ($key in $binding.Keys) {
                if ($key -cne 'status' -and $prior[$key] -cne $binding[$key]) {
                    throw 'Original provisioning binding changed.'
                }
            }
            if ($prior.status -cnotin @('attempted-unknown', 'completed-reconciled')) {
                throw 'Unsupported provisioning state.'
            }
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
            if ($previous.status -cne 'completed-reconciled' -or $previous.operationId -cnotmatch '^[a-f0-9]{64}$') {
                throw 'Previous operation remains unresolved.'
            }
            $previousAudit = Join-Path $reservation.Root ($previous.operationId + '.infra-completed.json')
            Assert-RunnerJournalPath -Path $previousAudit
            if ((Get-FileHash -LiteralPath $previousAudit -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $journal -Algorithm SHA256).Hash) {
                throw 'Completed operation audit changed.'
            }
            $replaceCompleted = $true
        }
        Write-RunnerJournalRecord -Path $journal -Record $binding -Create:(-not $replaceCompleted)
        Write-RunnerJournalRecord -Path $stateFile -Record $binding -Create
        $attempted = $true
        if ($Phase -ceq 'Registry') {
            Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('group', 'create', '--subscription', $configuration.subscriptionId, '--name', $group, '--location', $Location, '--output', 'none', '--only-show-errors') -Owned -LimitSeconds $TimeoutSeconds -RunClock $clock | Out-Null
        }
        if ((Get-FileHash -LiteralPath $parameterFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ParametersSha256) {
            throw 'Provisioning parameters changed.'
        }
        Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('deployment', 'group', 'create', '--subscription', $configuration.subscriptionId, '--resource-group', $group, '--name', $deploymentName, '--template-file', $template, '--parameters', ('@' + $parameterFile), ('location=' + $Location), '--mode', 'Incremental', '--no-wait', '--output', 'none', '--only-show-errors') -Owned -LimitSeconds $TimeoutSeconds -RunClock $clock | Out-Null
    }
    $resultText = Invoke-PrivateCommand -Executable $ProviderCommand -Argument @('deployment', 'group', 'show', '--subscription', $configuration.subscriptionId, '--resource-group', $group, '--name', $deploymentName, '--output', 'json', '--only-show-errors') -Owned -Capture -LimitSeconds $TimeoutSeconds -RunClock $clock
    $result = ConvertFrom-RunnerPrivateJson -Text $resultText
    $expectedDeploymentId = '/subscriptions/' + $configuration.subscriptionId + '/resourceGroups/' + $group + '/providers/Microsoft.Resources/deployments/' + $deploymentName
    if ($result.id -cne $expectedDeploymentId -or $result.name -cne $deploymentName -or $result.properties.provisioningState -cne 'Succeeded' -or $result.properties.outputs -isnot [Collections.IDictionary]) {
        throw 'Exact provisioning completion not proven.'
    }
    foreach ($key in $expectedOutputs.Keys) {
        if (-not $result.properties.outputs.Contains($key) -or $result.properties.outputs[$key].value -cne $expectedOutputs[$key]) {
            throw 'Provisioning resource output mismatch.'
        }
    }
    $binding.outputs = $result.properties.outputs
    $binding.status = 'completed-reconciled'
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
    @{ status = 'provisioned'; phase = $Phase; sourceCommit = $ExpectedCommit; tests = $null; accepted = $false } | ConvertTo-Json -Compress
}
catch {
    $message = if ($attempted -or $Reconcile) {
        'Runner provisioning outcome is unknown. Retain private state and reconcile without resubmitting.'
    }
    else {
        'Runner provisioning validation failed.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $reservation) {
        Exit-RunnerTargetReservation -Reservation $reservation
    }
}
