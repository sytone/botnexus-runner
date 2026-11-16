<#
.SYNOPSIS
Test-owned historical bootstrap contract; importing it performs no operations.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
<#
.SYNOPSIS
Exercise the historical ARM no-wait contract using an explicit offline command.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER Command
Injected synthetic response scriptblock; no command is resolved by name.
.PARAMETER SubscriptionId
Synthetic subscription selector.
.PARAMETER ResourceGroup
Synthetic group selector.
.PARAMETER DeploymentName
Synthetic deployment name.
.PARAMETER TemplateFile
Synthetic template path, not read.
.PARAMETER Parameters
Synthetic template arguments.
.PARAMETER TimeoutMinutes
Polling deadline in minutes; zero tests immediate timeout.
.PARAMETER PollSeconds
Delay between synthetic polls.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
function Invoke-BuildTestDeployment {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][scriptblock]$Command,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$DeploymentName,
        [Parameter(Mandatory)][string]$TemplateFile,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Parameters,
        [int]$TimeoutMinutes = 45,
        [int]$PollSeconds = 15
    )

    $global:LASTEXITCODE = 0
    try {
        $null = & $Command deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup --name $DeploymentName --template-file $TemplateFile --parameters @Parameters --no-wait --only-show-errors 2>$null 3>$null 4>$null 5>$null 6>$null
    }
    catch {
        throw 'ARM submission failed; response withheld.'
    }
    if ($LASTEXITCODE -ne 0) {
        throw 'ARM submission failed; response withheld.'
    }

    $terminal = @('Succeeded', 'Failed', 'Canceled')
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $state = $null

    while ($true) {
        $global:LASTEXITCODE = 0
        try {
            $state = & $Command deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $DeploymentName --query properties.provisioningState -o tsv 2>$null 3>$null 4>$null 5>$null 6>$null
        }
        catch {
            throw 'ARM state query failed; response withheld.'
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'ARM state query failed; response withheld.'
        }
        if ($state) {
            $state = "$state".Trim()
        }
        if ($state -notin @('Succeeded', 'Failed', 'Canceled', 'Running', 'Accepted', 'Creating', 'Updating')) {
            $state = 'unknown'
        }

        if ($state -and $terminal -contains $state) {
            break
        }

        if ((Get-Date) -ge $deadline) {
            $observed = if ($state) {
                $state
            }
            else {
                'unknown'
            }
            throw "ARM deployment did not reach a terminal state (last observed state: '$observed')."
        }

        Start-Sleep -Seconds $PollSeconds
    }

    if ($state -ne 'Succeeded') {
        $global:LASTEXITCODE = 0
        try {
            $detail = & $Command deployment group show --subscription $SubscriptionId --resource-group $ResourceGroup --name $DeploymentName --query properties.error -o json 2>$null 3>$null 4>$null 5>$null 6>$null
        }
        catch {
            throw 'ARM error query failed; response withheld.'
        }
        if ($LASTEXITCODE -ne 0) {
            throw 'ARM error query failed; response withheld.'
        }
        $availability = if ([string]::IsNullOrWhiteSpace(($detail -join ''))) {
            'unavailable'
        }
        else {
            'available'
        }
        throw "ARM deployment finished in state '$state'. ARM error detail: $availability (response withheld)."
    }

    return 'Succeeded'
}

<#
.SYNOPSIS
Derive a deterministic historical content tag.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER RunnerPath
Synthetic source directory; tests subdirectories are excluded.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
function Get-RunnerContentTag {
    param([Parameter(Mandatory)][string]$RunnerPath)

    $runnerFiles = Get-ChildItem -Path $RunnerPath -Recurse -File |
        Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } |
        Sort-Object { $_.FullName.Substring($RunnerPath.Length).Replace('\', '/') }

    if (-not $runnerFiles) {
        throw "Refusing to derive an image tag: no files found under $RunnerPath."
    }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = [System.IO.MemoryStream]::new()
        foreach ($file in $runnerFiles) {
            $relative = $file.FullName.Substring($RunnerPath.Length).Replace('\', '/').TrimStart('/')
            $content = (Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop) -replace "`r`n", "`n"
            $bytes = [System.Text.Encoding]::UTF8.GetBytes("$relative`n$content`n")
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        $buffer.Position = 0
        return 'src-' + [BitConverter]::ToString($sha.ComputeHash($buffer)).Replace('-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
        $buffer.Dispose()
    }
}

<#
.SYNOPSIS
Select a historical non-overwriting publication decision.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER Tag
Synthetic candidate tag.
.PARAMETER ExistingTags
Synthetic existing tags, possibly empty.
.PARAMETER WasDerived
Whether tag was content-derived.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
function Test-TagPublishDecision {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ExistingTags,
        [Parameter(Mandatory)][bool]$WasDerived
    )
    $exists = $ExistingTags -contains $Tag
    if ($exists -and -not $WasDerived) {
        return 'refuse'
    }
    if ($exists) {
        return 'skip'
    }
    return 'build'
}
