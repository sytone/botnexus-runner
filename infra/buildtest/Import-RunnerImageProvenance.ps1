<#
.SYNOPSIS
Provides historical content-tag comparison helpers without running provider commands on load.
.DESCRIPTION
Derives a deterministic content tag from runner sources and compares explicit deployed
identities. This historical tag check is not independent image qualification or release
approval. Provider reads occur only when Get-DeployedRunnerTag is called explicitly.
.EXAMPLE
. ./infra/buildtest/Import-RunnerImageProvenance.ps1
Get-RunnerContentTag -RunnerPath ./infra/buildtest/runner
.OUTPUTS
None. Loading defines helper functions without performing provider operations.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RunnerContentTag {
    <#
    .SYNOPSIS
        Derives the content-addressed tag for a runner source directory.
    .DESCRIPTION
        Derives the historical source-content tag without importing any provisioner.
        The inert BootstrapContractFixture.psm1 contract and Test-DeployTagGuard.ps1
        retain tag-collision assertions. Test-RunnerImageProvenance.ps1 covers these helpers.
    .PARAMETER RunnerPath
        Existing runner source directory; test subdirectories are excluded.
    .EXAMPLE
        Get-RunnerContentTag -RunnerPath ./infra/buildtest/runner
    .OUTPUTS
        System.String. Deterministic historical source-content tag.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $RunnerPath
    )

    # Resolve to a canonical absolute path first. The caller may pass a path containing '..'
    # segments (Join-Path $PSScriptRoot '..' '..' ...), and Get-ChildItem returns FULLY RESOLVED
    # FullName values - so the unresolved prefix is longer than the resolved child paths and the
    # Substring below throws "startIndex cannot be larger than length of string". That is a silent
    # failure in practice: the caller catches it and treats provenance as unavailable, which is
    # exactly the "check that cannot fire" this file exists to prevent.
    $resolved = (Resolve-Path -LiteralPath $RunnerPath -ErrorAction Stop).ProviderPath.TrimEnd('\', '/')

    $runnerFiles = Get-ChildItem -Path $resolved -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
        Sort-Object { $_.FullName.Substring($resolved.Length).Replace('\', '/') }

    if (-not $runnerFiles) {
        throw "Refusing to derive a tag: no files under $resolved. An empty set hashes to a constant and would match nothing."
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = [System.IO.MemoryStream]::new()
        foreach ($file in $runnerFiles) {
            $relative = $file.FullName.Substring($resolved.Length).Replace('\', '/').TrimStart('/')
            # Line endings are normalised: a CRLF/LF difference between a Windows and a Linux
            # operator is not a content change and must not appear as a mismatch.
            $content = (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop) -replace "`r`n", "`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("$relative`n$content`n")
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $buffer.Position = 0
        return 'src-' + [BitConverter]::ToString($sha.ComputeHash($buffer)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-DeployedRunnerTag {
    <#
    .SYNOPSIS
        Reads the image tag the Container Apps Job is currently configured to run.
    .DESCRIPTION
        Makes one explicit read-only Azure CLI job request using the existing account.
        Returns no tag when the native request fails or the job has no image.
    .PARAMETER SubscriptionId
        Explicit subscription containing the existing job.
    .PARAMETER ResourceGroup
        Explicit resource group containing the existing job.
    .PARAMETER JobName
        Explicit existing job name.
    .EXAMPLE
        Get-DeployedRunnerTag -SubscriptionId $subscription -ResourceGroup $group -JobName $job
    .OUTPUTS
        System.String or null. Tag portion of the configured image reference.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SubscriptionId,
        [Parameter(Mandatory)][string] $ResourceGroup,
        [Parameter(Mandatory)][string] $JobName
    )

    $url = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.App/jobs/$JobName" +
    '?api-version=2024-03-01'

    $raw = az rest --method get --url $url --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }

    $job = $raw | ConvertFrom-Json
    $image = @($job.properties.template.containers)[0].image
    if ([string]::IsNullOrWhiteSpace($image)) {
        return $null
    }

    return ($image -split ':')[-1]
}

function Test-RunnerImageSource {
    <#
    .SYNOPSIS
        Compares the deployed image identity with the tag current sources derive to.
    .OUTPUTS
        A record carrying the expected tag, deployed identity, and a verdict: 'match', 'mismatch',
        or 'unknown'.
    .DESCRIPTION
        Azure Container Apps may normalise a tag-based image reference to its immutable digest. In
        that case callers resolve the digest's ACR tags and supply them as DeployedAliases; matching
        the source tag there is the same image, not drift.

        'unknown' is a distinct outcome from 'mismatch' and is NOT a failure. A developer with no
        Azure credentials cannot read the job, and turning that into a red check would make the guard
        unusable for everyone who is not an operator - which is how guards get bypassed.
    .PARAMETER RunnerPath
        Existing runner source directory used to derive the expected tag.
    .PARAMETER DeployedTag
        Explicit observed deployed tag or digest; absent input returns unknown.
    .PARAMETER DeployedAliases
        Explicit aliases independently resolved for the observed immutable image.
    .EXAMPLE
        Test-RunnerImageSource -RunnerPath ./infra/buildtest/runner -DeployedTag $observedTag
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RunnerPath,
        [string] $DeployedTag,
        [AllowEmptyCollection()][string[]] $DeployedAliases = @()
    )

    $expected = Get-RunnerContentTag -RunnerPath $RunnerPath

    if ([string]::IsNullOrWhiteSpace($DeployedTag)) {
        return [pscustomobject]@{ Expected = $expected; Deployed = $null; Verdict = 'unknown' }
    }

    $identities = @($DeployedTag) + @($DeployedAliases | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [pscustomobject]@{
        Expected = $expected
        Deployed = $DeployedTag
        Verdict = $(if ($identities -contains $expected) {
                'match'
            }
            else {
                'mismatch'
            })
    }
}
