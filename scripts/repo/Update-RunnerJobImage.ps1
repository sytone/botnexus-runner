<#
.SYNOPSIS
Updates only the image of one explicitly configured existing runner job.
.DESCRIPTION
Requires clean exact source, an immutable approved image, hashed private external
configuration and an exclusive private operation-state path. Validates the current
explicitly selected account binding and existing manual single-runner topology. Uses the
2024-03-01 JSON Merge Patch API under a single trusted operator and preserves the complete
container object. Never provisions resources, signs in, lists secrets or grants
access. Readback must prove the image and all other job invariants unchanged.
Actual HTTP 200 terminal write proof and fresh exact readback are required.
HTTP 202 retains its private operation reference for explicit read-only continuation.
A native failure or asynchronous response is not completion. An uncertain write
keeps its operation fence: use Reconcile to verify the same causal operation and read back without a second write.
WhatIf performs local read-only validation only, with no provider call or output
creation. Actual deployment requires separate operator authority and qualification.
.PARAMETER SourceRoot
Exact clean runner Git checkout with raw bytes matching its commit.
.PARAMETER ExpectedCommit
Full lowercase source commit approved for the immutable image.
.PARAMETER ConfigurationPath
One strict versioned external private maintenance target profile. No legacy
per-operation configuration is accepted. Reader returns a private in-memory projection.
.PARAMETER PrivateRoot
Explicit existing operator-controlled directory containing the profile, outside Git.
.PARAMETER ConfigurationSha256
Expected lowercase SHA256 of the exact private configuration bytes.
.PARAMETER ApprovalPath
Private external approval JSON with approved true, sourceCommit, image and
runtimeManifestSha256. Issued only after independent source/image/privacy review;
this command does not issue approvals or qualify images itself.
.PARAMETER CurrentImageApprovalPath
Optional private external independent provenance approval for a currently tagged image.
Required only for that transition. Exact fields approved, observedImage, image,
sourceCommit and runtimeManifestSha256 bind the observed Azure registry tag to an
independently verified immutable digest and its historical source/runtime provenance.
This command checks approval, never creates provenance or qualifies an image.
.PARAMETER CurrentImageApprovalSha256
Lowercase SHA256 of the current-image approval bytes. Both current-image parameters
must be supplied together. Missing, changed or conflicting approval fails closed.
.PARAMETER StatePath
Private external receipt in an existing operator-controlled directory. A canonical
OS-local target journal owns the once-only fence, not this caller-selected path.
Keep both after success or uncertainty. Reconcile never repeats a provider write.
Other writers must remain excluded through UNKNOWN investigation; no atomic CAS
is claimed when the provider supplies no ETag.
.PARAMETER ProviderCommand
Approved native Azure CLI executable, default az. Inert tests supply a fake tool.
Uses only the explicitly selected existing account; never signs in, switches or falls back.
.PARAMETER TimeoutSeconds
One provider-phase allowance including identity, read, write, readback and owned
cleanup/drain. Defaults to 120 seconds; does not change the job's 1200-second budget.
.PARAMETER Reconcile
Read-only reconciliation of an existing operation fence. Never repeats PATCH.
.EXAMPLE
./Update-RunnerJobImage.ps1 -SourceRoot /source -ExpectedCommit $commit -ConfigurationPath /private/job.json -ConfigurationSha256 $hash -PrivateRoot /private -ApprovalPath /private/approval.json -StatePath /private/update.json -WhatIf
Validates local source and private approval without touching the provider or files.
.EXAMPLE
./Update-RunnerJobImage.ps1 -SourceRoot /source -ExpectedCommit $commit -ConfigurationPath /private/job.json -ConfigurationSha256 $hash -PrivateRoot /private -ApprovalPath /private/approval.json -StatePath /private/update.json -Reconcile
Verifies one previously attempted update without repeating the remote write.
.OUTPUTS
System.String. Redacted JSON status updated, tests null and accepted false only
when readback proves completion. Otherwise a fixed redacted error and nonzero exit;
unknown writes retain private state. No run, image qualification or acceptance.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [Parameter(Mandatory)][string]$ApprovalPath,
    [Parameter(Mandatory)][string]$StatePath,
    [string]$CurrentImageApprovalPath,
    [string]$CurrentImageApprovalSha256,
    [string]$ProviderCommand = 'az',
    [ValidateRange(4, 600)][int]$TimeoutSeconds = 120,
    [switch]$Reconcile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-RunnerInvariantText {
    <#
    .SYNOPSIS
    Produces deterministic JSON for invariant comparison, not public output.
    .DESCRIPTION
    Sorts object keys recursively while preserving array order and JSON types.
    .PARAMETER Value
    Parsed private JSON value.
    .EXAMPLE
    Get-RunnerInvariantText -Value $job
    .OUTPUTS
    System.String. Canonical private JSON text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][object]$Value)
    if ($Value -is [Collections.IDictionary]) {
        $parts = foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
            ($key | ConvertTo-Json -Compress) + ':' + (Get-RunnerInvariantText -Value $Value[$key])
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [array]) {
        $parts = foreach ($entry in $Value) {
            Get-RunnerInvariantText -Value $entry
        }
        return '[' + ($parts -join ',') + ']'
    }
    return ConvertTo-Json -InputObject $Value -Compress -Depth 100
}

function Get-RunnerJobInvariant {
    <#
    .SYNOPSIS
    Validates one existing runner topology and hashes all non-image invariants.
    .DESCRIPTION
    Rejects command overrides, unexpected topology, unknown identity and changed
    manual trigger/retry/deadline. Excludes only server-managed ETag, systemData,
    provisioningState and the intended main container image from comparison.
    .PARAMETER Job
    Private provider response, never emitted to public streams.
    .PARAMETER AllowCurrentTag
    Allows only a syntactically bounded current Azure registry tag for initial
    invariant capture. Caller must independently resolve and approve its digest
    before writing; terminal responses never use this switch.
    .PARAMETER Resource
    Exact explicit configured resource identity.
    .EXAMPLE
    Get-RunnerJobInvariant -Job $job -Resource $resourceId
    .OUTPUTS
    System.String. SHA256 of canonical non-image job invariants.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Collections.IDictionary]$Job, [string]$Resource, [switch]$AllowCurrentTag)
    $matchingIdentities = @($Job.identity.userAssignedIdentities.Keys | Where-Object { [string]::Equals($_, $configuration.managedIdentityResourceId, [StringComparison]::OrdinalIgnoreCase) })
    if (-not [string]::Equals($Job.id, $Resource, [StringComparison]::OrdinalIgnoreCase) -or $Job.type -ine 'Microsoft.App/jobs' -or $Job.identity.type -cne 'UserAssigned' -or $Job.identity.userAssignedIdentities.Count -ne 1 -or $matchingIdentities.Count -ne 1) {
        throw 'Unexpected job identity.'
    }
    $configuration = $Job.properties.configuration
    if ($configuration.triggerType -cne 'Manual' -or $configuration.replicaTimeout -ne 1200 -or $configuration.replicaRetryLimit -ne 0 -or $configuration.manualTriggerConfig.parallelism -ne 1 -or $configuration.manualTriggerConfig.replicaCompletionCount -ne 1) {
        throw 'Unexpected job execution policy.'
    }
    $containers = @($Job.properties.template.containers)
    if ($containers.Count -ne 1 -or $containers[0].name -cne 'runner' -or $containers[0].Contains('command') -or $containers[0].Contains('args')) {
        throw 'Unexpected job container topology.'
    }
    if ($containers[0].image -isnot [string] -or $containers[0].image.Length -gt 512 -or ($containers[0].image -cnotmatch '^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$' -and (-not $AllowCurrentTag -or $containers[0].image -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\.azurecr\.io/[a-z0-9]+(?:[._/-][a-z0-9]+)*:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'))) {
        throw 'Unexpected current job image.'
    }
    $copy = ConvertFrom-Json -InputObject ($Job | ConvertTo-Json -Depth 100 -Compress) -AsHashtable
    [void]$copy.Remove('etag')
    [void]$copy.Remove('systemData')
    [void]$copy.properties.Remove('provisioningState')
    $copy.properties.template.containers[0].image = '<image>'
    $text = Get-RunnerInvariantText -Value $copy
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($text))).ToLowerInvariant()
}

function Resolve-RunnerCurrentImage {
    <#
    .SYNOPSIS
    Verifies a current tag against pinned independent immutable provenance.
    .DESCRIPTION
    Uses explicit existing-account bounded registry metadata queries. Tags are only
    lookup keys, never provenance. Exact registry/repository lookup arguments bind
    both responses to the approved repository. CLI tag attributes carry the tag in
    name; manifest attributes carry digest and tags, not a repository name field.
    Both must prove the approved digest. Revalidation repeats only the tag lookup before
    the write fence. No authentication, fallback, image pull or approval creation.
    The trusted operator must exclude other writers; this is not registry atomicity.
    .PARAMETER ObservedImage
    Exact tagged image from the validated current job.
    .PARAMETER Revalidate
    Repeats only the final tag lookup under the original operation clock.
    .EXAMPLE
    Resolve-RunnerCurrentImage -ObservedImage $currentTag
    .OUTPUTS
    System.String. Independently approved immutable current-image identity.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ObservedImage, [switch]$Revalidate)
    if ($null -eq $currentApproval -or $ObservedImage -cne $currentApproval.observedImage -or
        $ObservedImage -cnotmatch '^(?<registry>[a-z0-9]+(?:-[a-z0-9]+)*)\.azurecr\.io/(?<repository>[a-z0-9]+(?:[._/-][a-z0-9]+)*):(?<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})$') {
        throw 'Current image provenance is unavailable.'
    }
    $registry = $Matches.registry
    $repository = $Matches.repository
    $tag = $Matches.tag
    $prefix = "${registry}.azurecr.io/${repository}@"
    if (-not $currentApproval.image.StartsWith($prefix, [StringComparison]::Ordinal) -or
        $currentApproval.image.Substring($prefix.Length) -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Current image provenance conflicts.'
    }
    $digest = $currentApproval.image.Substring($prefix.Length)
    $queries = @("${repository}:$tag")
    if (-not $Revalidate) {
        $queries += "${repository}@$digest"
    }
    foreach ($query in $queries) {
        $arguments = @('acr', 'manifest', 'show-metadata', '--registry', $registry, '--name', $query, '--subscription', $configuration.subscriptionId, '--only-show-errors', '--output', 'json')
        $text = Invoke-PrivateCommand -Executable $providerExecutable -Argument $arguments -LimitSeconds $providerLimit -RunClock $operationClock -Owned -Capture
        $metadata = ConvertFrom-RunnerPrivateJson -Text $text
        if ($metadata.digest -isnot [string] -or $metadata.digest -cne $digest) {
            throw 'Current immutable provider identity conflicts.'
        }
        if ($query -ceq "${repository}:$tag") {
            if ($metadata.name -isnot [string] -or $metadata.name -cne $tag) {
                throw 'Current provider tag identity conflicts.'
            }
        }
        else {
            if ($metadata.tags -isnot [array] -or $metadata.tags.Count -eq 0 -or $metadata.tags.Count -gt 1024) {
                throw 'Current manifest tag evidence is unavailable.'
            }
            $seenTags = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($alias in $metadata.tags) {
                if ($alias -isnot [string] -or $alias -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' -or -not $seenTags.Add($alias)) {
                    throw 'Current manifest tag evidence is malformed.'
                }
            }
            if (-not $seenTags.Contains($tag)) {
                throw 'Current manifest does not confirm the observed tag.'
            }
        }
    }
    return $currentApproval.image
}

function Assert-RunnerUpdateJob {
    <#
    .SYNOPSIS
    Requires an exact terminal job image and all preserved invariants.
    .DESCRIPTION
    Validates private response bodies without treating HTTP acceptance as success.
    .PARAMETER Job
    Private actual HTTP response job object.
    .PARAMETER Invariant
    Original non-image invariant hash.
    .EXAMPLE
    Assert-RunnerUpdateJob -Job $response.Body -Invariant $beforeInvariant
    .OUTPUTS
    None. Throws unless terminal exact job proof is present.
    #>
    [CmdletBinding()]
    param([Collections.IDictionary]$Job, [string]$Invariant)
    if ((Get-RunnerJobInvariant -Job $Job -Resource $configuration.resourceId) -cne $Invariant -or $Job.properties.template.containers[0].image -cne $image -or $Job.properties.provisioningState -cne 'Succeeded') {
        throw 'Update outcome is unknown.'
    }
}

$attempted = $false
$scratch = $null
$responseContext = $null
$reservation = $null
try {
    . (Join-Path $PSScriptRoot 'Import-RunnerMaintenanceProfile.ps1')
    . (Join-Path $PSScriptRoot 'Import-RunnerResponseTransport.ps1')
    . (Join-Path $PSScriptRoot 'Import-RunnerTargetJournal.ps1')
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$' -or $ConfigurationSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Invalid exact identities.'
    }
    $root = (Assert-ObservedPath -Path $SourceRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $configurationFile = Assert-ObservedPath -Path $ConfigurationPath
    $approvalFile = Assert-ObservedPath -Path $ApprovalPath
    $stateFile = [IO.Path]::GetFullPath($StatePath)
    $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($stateFile)) -Directory
    foreach ($privatePath in @($configurationFile, $approvalFile, $stateFile)) {
        if ($privatePath.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Private input or state is inside source.'
        }
    }
    if ($stateFile -eq $configurationFile -or $stateFile -eq $approvalFile) {
        throw 'State conflicts with an input.'
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    if ((Get-FileHash -LiteralPath $configurationFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ConfigurationSha256) {
        throw 'Private configuration hash mismatch.'
    }
    $profileSelection = Read-RunnerMaintenanceProfile -Path $configurationFile -ExpectedSha256 $ConfigurationSha256 -Operation deploy -SourceRoot $root -PrivateRoot $PrivateRoot -ExpectedCommit $ExpectedCommit
    $configuration = $profileSelection.configuration
    $approval = Read-RunnerPrivateObject -Path $approvalFile
    $image = $configuration.image
    if ($image -cnotmatch '^[a-z0-9][a-z0-9./_-]*@sha256:[0-9a-f]{64}$' -or $image.Length -gt 512 -or $configuration.resourceId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.App/jobs/[a-z][a-z0-9-]{0,62}$') {
        throw 'Invalid immutable image or explicit resource.'
    }
    if ($configuration.managedIdentityResourceId -cnotmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[A-Za-z0-9_-]+$') {
        throw 'Unknown configured runner identity.'
    }
    Assert-RunnerAccountBinding -Configuration $configuration
    $runtimeHash = (Get-FileHash -LiteralPath (Join-Path $root 'infra/buildtest/runner/image-runtime.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((($approval.Keys | Sort-Object) -join ',') -cne 'approved,image,runtimeManifestSha256,sourceCommit' -or $approval.approved -isnot [bool] -or -not $approval.approved -or $approval.sourceCommit -cne $ExpectedCommit -or $approval.image -cne $image -or $approval.runtimeManifestSha256 -cne $runtimeHash) {
        throw 'Missing exact independent image approval.'
    }
    $currentApproval = $null
    $currentApprovalFile = $null
    if ($CurrentImageApprovalPath -or $CurrentImageApprovalSha256) {
        if (-not $CurrentImageApprovalPath -or $CurrentImageApprovalSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Current image approval requires a pinned pair.'
        }
        $currentApprovalFile = Assert-ObservedPath -Path $CurrentImageApprovalPath
        if ($currentApprovalFile.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $currentApprovalFile -eq $stateFile -or
            (Get-FileHash -LiteralPath $currentApprovalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CurrentImageApprovalSha256) {
            throw 'Current image approval path or hash conflicts.'
        }
        $currentApproval = Read-RunnerPrivateObject -Path $currentApprovalFile
        if ((($currentApproval.Keys | Sort-Object) -join ',') -cne 'approved,image,observedImage,runtimeManifestSha256,sourceCommit' -or
            $currentApproval.approved -isnot [bool] -or -not $currentApproval.approved) {
            throw 'Current image provenance is not approved.'
        }
        foreach ($field in @('image', 'observedImage', 'sourceCommit', 'runtimeManifestSha256')) {
            if ($currentApproval[$field] -isnot [string] -or $currentApproval[$field].Length -gt 512) {
                throw 'Current image provenance has invalid types.'
            }
        }
        if ($currentApproval.sourceCommit -cnotmatch '^[0-9a-f]{40}$' -or $currentApproval.runtimeManifestSha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Current image source provenance is incomplete.'
        }
    }
    $approvalHash = (Get-FileHash -LiteralPath $approvalFile -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $Reconcile -and (Test-Path -LiteralPath $stateFile)) {
        throw 'Existing operation receipt requires reconciliation.'
    }
    if (-not $PSCmdlet.ShouldProcess('validated existing runner job', 'Update only approved immutable image or reconcile prior write')) {
        return
    }
    $reservation = Enter-RunnerTargetReservation -Resource $configuration.resourceId
    $journalPath = $reservation.DeploymentPath
    $operationIdentity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($configuration.resourceId.ToLowerInvariant() + "`n" + $ExpectedCommit + "`n" + $image)))).ToLowerInvariant()
    if (Test-Path -LiteralPath $reservation.RunPath) {
        Assert-RunnerJournalPath -Path $reservation.RunPath
        $run = Read-RunnerPrivateObject -Path $reservation.RunPath
        if ($run.status -cne 'completed-reconciled' -or $run.evidenceVerified -isnot [bool] -or -not $run.evidenceVerified -or $run.terminalStatus -cnotin @('Succeeded', 'Failed', 'Cancelled') -or $run.runId -cnotmatch '^[0-9a-f]{32}$') {
            throw 'Target has an unresolved run.'
        }
        $auditPath = Join-Path $reservation.Root ($run.runId + '.completed.json')
        Assert-RunnerJournalPath -Path $auditPath
        if ((Get-RunnerInvariantText -Value (Read-RunnerPrivateObject -Path $auditPath)) -cne (Get-RunnerInvariantText -Value $run)) {
            throw 'Run audit conflicts.'
        }
    }
    $prior = $null
    $previous = $null
    if (Test-Path -LiteralPath $journalPath) {
        Assert-RunnerJournalPath -Path $journalPath
        $previous = Read-RunnerPrivateObject -Path $journalPath
    }
    if ($Reconcile) {
        if ($null -eq $previous) {
            throw 'Canonical journal is missing.'
        }
        Assert-RunnerJournalPath -Path $stateFile
        $prior = Read-RunnerPrivateObject -Path $stateFile
        if ((Get-RunnerInvariantText -Value $prior) -cne (Get-RunnerInvariantText -Value $previous) -or $prior.sourceCommit -cne $ExpectedCommit -or $prior.configurationSha256 -cne $ConfigurationSha256 -or $prior.approvalSha256 -cne $approvalHash -or $prior.beforeInvariant -cnotmatch '^[0-9a-f]{64}$' -or $prior.operationIdentity -cne $operationIdentity -or $prior.targetKey -cne $reservation.Key -or $prior.image -cne $image) {
            throw 'Operation journal binding mismatch.'
        }
        if ($prior.Contains('currentApprovalSha256') -and ($null -eq $currentApproval -or $prior.currentApprovalSha256 -cne $CurrentImageApprovalSha256 -or $prior.currentImage -cne $currentApproval.image -or $prior.currentSourceCommit -cne $currentApproval.sourceCommit -or $prior.currentRuntimeManifestSha256 -cne $currentApproval.runtimeManifestSha256)) {
            throw 'Current image provenance journal binding conflicts.'
        }
        $attempted = $true
        if ($prior.operationId -cnotmatch '^[0-9a-f]{32}$' -or $prior.causalStatus -isnot [long] -or $prior.causalStatus -notin @(200, 202)) {
            throw 'Prior causal record is incomplete.'
        }
    }
    else {
        if ($null -ne $previous) {
            if ($previous.status -cne 'completed-reconciled' -or $previous.targetKey -cne $reservation.Key -or $previous.operationId -cnotmatch '^[0-9a-f]{32}$') {
                throw 'Target has an unresolved deployment.'
            }
            $auditPath = Join-Path $reservation.Root ($previous.operationId + '.deployment-completed.json')
            Assert-RunnerJournalPath -Path $auditPath
            if ((Get-RunnerInvariantText -Value (Read-RunnerPrivateObject -Path $auditPath)) -cne (Get-RunnerInvariantText -Value $previous)) {
                throw 'Completed deployment audit conflicts.'
            }
        }
        foreach ($auditFile in Get-ChildItem -LiteralPath $reservation.Root -Filter '*.deployment-completed.json' -Force) {
            Assert-RunnerJournalPath -Path $auditFile.FullName
            $audit = Read-RunnerPrivateObject -Path $auditFile.FullName
            if ($audit.operationIdentity -ceq $operationIdentity) {
                throw 'Completed deployment cannot be replayed.'
            }
        }
    }
    . (Join-Path $root 'infra/buildtest/runner/Import-RunnerDiagnostic.ps1')
    $providerExecutable = $ProviderCommand
    $providerLimit = $TimeoutSeconds
    $operationClock = [Diagnostics.Stopwatch]::StartNew()
    $transport = @{
        Configuration = $configuration
        ProviderCommand = $providerExecutable
        RunClock = $operationClock
        DeadlineSeconds = $providerLimit
    }
    $responseContext = New-RunnerResponseContext @transport
    $transport.ContextId = $responseContext
    $url = 'https://management.azure.com' + $configuration.resourceId + '?api-version=2024-03-01'
    if ($Reconcile) {
        if ($prior.causalStatus -eq 202) {
            $validated = Assert-RunnerResponseUri -Text $prior.operationUri -Configuration $configuration -Operation
            $operation = Invoke-RunnerResponseTransport @transport -Uri $validated.AbsoluteUri
            if ($operation.StatusCode -ne 200) {
                throw 'Prior operation is not terminal.'
            }
            if ($validated.AbsolutePath -ceq $configuration.resourceId) {
                Assert-RunnerUpdateJob -Job $operation.Body -Invariant $prior.beforeInvariant
            }
            elseif ($operation.Body.status -cne 'Succeeded') {
                throw 'Prior operation is not terminal.'
            }
        }
        elseif ($prior.causalStatus -ne 200 -or $prior.terminalInvariant -cne $prior.beforeInvariant) {
            throw 'Prior causal proof is absent.'
        }
        $readback = Invoke-RunnerResponseTransport @transport -Uri $url
        if ($readback.StatusCode -ne 200) {
            throw 'Prior readback is not terminal.'
        }
        Assert-RunnerUpdateJob -Job $readback.Body -Invariant $prior.beforeInvariant
    }
    else {
        $read = Invoke-RunnerResponseTransport @transport -Uri $url
        if ($read.StatusCode -ne 200) {
            throw 'Current job response is not ready.'
        }
        $before = $read.Body
        $beforeInvariant = Get-RunnerJobInvariant -Job $before -Resource $configuration.resourceId -AllowCurrentTag
        $observedImage = $before.properties.template.containers[0].image
        $currentImage = $observedImage
        $currentWasTagged = $observedImage -cnotmatch '@sha256:[0-9a-f]{64}$'
        if ($currentWasTagged) {
            $currentImage = Resolve-RunnerCurrentImage -ObservedImage $observedImage
        }
        if ($before.properties.provisioningState -cne 'Succeeded') {
            throw 'Current job is not ready.'
        }
        # Revalidate mutable operator inputs immediately before the once-only fence.
        Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
        if ((Get-FileHash -LiteralPath $configurationFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ConfigurationSha256 -or (Get-FileHash -LiteralPath $approvalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $approvalHash) {
            throw 'Operation inputs changed before write.'
        }
        if ($operationClock.Elapsed.TotalSeconds -ge ($providerLimit - 2)) {
            throw 'Original operation allowance exhausted before write.'
        }
        if ($currentWasTagged) {
            $fresh = Invoke-RunnerResponseTransport @transport -Uri $url
            if ($fresh.StatusCode -ne 200 -or $fresh.Body.properties.template.containers[0].image -cne $observedImage -or $fresh.Body.properties.provisioningState -cne 'Succeeded' -or
                (Get-RunnerJobInvariant -Job $fresh.Body -Resource $configuration.resourceId -AllowCurrentTag) -cne $beforeInvariant -or
                (Resolve-RunnerCurrentImage -ObservedImage $observedImage -Revalidate) -cne $currentImage) {
                throw 'Current image or job changed before write.'
            }
        }
        if ($currentWasTagged) {
            # Registry/native reads may take time or expose concurrent local edits.
            # Recheck source and both independent inputs after those reads too.
            Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
            if ((Get-FileHash -LiteralPath $configurationFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ConfigurationSha256 -or
                (Get-FileHash -LiteralPath $approvalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $approvalHash -or
                $operationClock.Elapsed.TotalSeconds -ge ($providerLimit - 2)) {
                throw 'Tagged operation inputs changed or original allowance expired.'
            }
        }
        if ($null -ne $currentApprovalFile -and (Get-FileHash -LiteralPath $currentApprovalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CurrentImageApprovalSha256) {
            throw 'Current image provenance changed before write.'
        }
        $containers = $before.properties.template.containers
        $containers[0].image = $image
        $patch = @{ properties = @{ template = @{ containers = $containers } } } | ConvertTo-Json -Depth 100 -Compress
        $fence = @{ sourceCommit = $ExpectedCommit; configurationSha256 = $ConfigurationSha256; approvalSha256 = $approvalHash; beforeInvariant = $beforeInvariant; operationId = [guid]::NewGuid().ToString('N'); causalStatus = 0; targetKey = $reservation.Key; operationIdentity = $operationIdentity; image = $image; status = 'attempted-unknown' }
        if ($currentWasTagged) {
            $fence.currentApprovalSha256 = $CurrentImageApprovalSha256
            $fence.currentImage = $currentImage
            $fence.currentSourceCommit = $currentApproval.sourceCommit
            $fence.currentRuntimeManifestSha256 = $currentApproval.runtimeManifestSha256
        }
        # Persist canonical UNKNOWN before the receipt and before any provider write.
        # A receipt copy failure retains the canonical journal and blocks replay.
        Write-RunnerJournalRecord -Path $journalPath -Record $fence -Create:($null -eq $previous)
        $attempted = $true
        Write-RunnerJournalRecord -Path $stateFile -Record $fence -Create
        $request = @{ Uri = $url; Method = 'PATCH'; Body = $patch }
        if ($before.Contains('etag') -and $before.etag -is [string] -and $before.etag -cmatch '^"[A-Za-z0-9_.:-]+"$') {
            $request.IfMatch = $before.etag
        }
        # Optional ETag is defense in depth, never an assumed provider guarantee.
        $response = Invoke-RunnerResponseTransport @transport @request
        if ($response.StatusCode -eq 200) {
            Assert-RunnerUpdateJob -Job $response.Body -Invariant $beforeInvariant
            $fence.terminalInvariant = $beforeInvariant
        }
        elseif ($response.StatusCode -eq 202 -and $response.OperationUri) {
            $fence.operationUri = $response.OperationUri
        }
        else {
            throw 'Missing causal response.'
        }
        $fence.causalStatus = $response.StatusCode
        Write-RunnerJournalRecord -Path $journalPath -Record $fence
        Write-RunnerJournalRecord -Path $stateFile -Record $fence
        if ($response.StatusCode -eq 202) {
            throw 'Accepted operation requires read-only continuation.'
        }
        $readback = Invoke-RunnerResponseTransport @transport -Uri $url
        if ($readback.StatusCode -ne 200) {
            throw 'Readback is not terminal.'
        }
        Assert-RunnerUpdateJob -Job $readback.Body -Invariant $beforeInvariant
    }
    if ($operationClock.Elapsed.TotalSeconds -ge $providerLimit) {
        throw 'Original operation allowance exhausted.'
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    if ((Get-FileHash -LiteralPath $configurationFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ConfigurationSha256 -or (Get-FileHash -LiteralPath $approvalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $approvalHash) {
        throw 'Operation inputs changed during completion.'
    }
    if ($operationClock.Elapsed.TotalSeconds -ge $providerLimit) {
        throw 'Original operation allowance exhausted during completion.'
    }
    if ($null -ne $currentApprovalFile -and (Get-FileHash -LiteralPath $currentApprovalFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $CurrentImageApprovalSha256) {
        throw 'Current image provenance changed during completion.'
    }
    $completed = if ($Reconcile) {
        $prior
    }
    else {
        $fence
    }
    $completed.status = 'completed-reconciled'
    $auditPath = Join-Path $reservation.Root ($completed.operationId + '.deployment-completed.json')
    if (Test-Path -LiteralPath $auditPath) {
        Assert-RunnerJournalPath -Path $auditPath
        if ((Get-RunnerInvariantText -Value (Read-RunnerPrivateObject -Path $auditPath)) -cne (Get-RunnerInvariantText -Value $completed)) {
            throw 'Completed audit conflicts.'
        }
    }
    else {
        Write-RunnerJournalRecord -Path $auditPath -Record $completed -Create
    }
    Write-RunnerJournalRecord -Path $journalPath -Record $completed
    Write-RunnerJournalRecord -Path $stateFile -Record $completed

}
catch {
    $message = if ($attempted) {
        'Runner job update outcome is unknown. Preserve private state and reconcile; do not repeat the write.'
    }
    else {
        'Runner job update validation failed. No update was attempted.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $reservation) {
        try {
            Exit-RunnerTargetReservation -Reservation $reservation
        }
        catch {
            [Console]::Error.WriteLine('Runner target reservation cleanup is unknown. Preserve private state.')
            exit 1
        }
    }
    if ($null -ne $responseContext) {
        Remove-RunnerResponseContext -ContextId $responseContext
    }
    if ($null -ne $scratch) {
        try {
            Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
        }
        catch {
            [Console]::Error.WriteLine('Runner job private cleanup is unknown. Preserve operation state.')
            exit 1
        }
    }
}
@{ sourceCommit = $ExpectedCommit; runtimeManifestSha256 = $runtimeHash; status = 'updated'; tests = $null; accepted = $false } | ConvertTo-Json -Compress
