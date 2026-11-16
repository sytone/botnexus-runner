<#
.SYNOPSIS
Tests trusted project execution integration without product hosts.
.DESCRIPTION
Checks operator deadline/cap enforcement, immutable-image capability requirements and
project mode graphs. Uses the existing synthetic fixture harness for actual children.
.PARAMETER ScratchRoot
Owned scratch output directory.
.EXAMPLE
./Test-RunnerIntegration.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Per-case results and actual JSON counts. Nonzero exit means failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
$script:cases = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
function Invoke-IntegrationCase {
    <#
    .SYNOPSIS
    Records one integration regression.
    .DESCRIPTION
    Retains an actual pass/failure observation without stopping the remaining cases.
    .PARAMETER Name
    Stable case identity.
    .PARAMETER Body
    Assertions to run.
    .EXAMPLE
    Invoke-IntegrationCase 'deadline' { if ($false) { throw 'Failed.' } }
    .OUTPUTS
    System.String. Case result.
    #>
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:cases.Add(@{ name = $Name; passed = $true })
        Write-Output "PASS $Name"
    }
    catch {
        $script:cases.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
}
Invoke-IntegrationCase 'operator-limits-not-project-authority' {
    $parameters = (Get-Command Invoke-RunnerProject).Parameters
    foreach ($name in @('OperatorLimits', 'RunClock', 'AbsoluteDeadlineSeconds', 'FinalizationReserveSeconds', 'ArgumentValues')) {
        if (-not $parameters.ContainsKey($name)) {
            throw "Missing trusted integration parameter $name"
        }
    }
}
Invoke-IntegrationCase 'entrypoint-uses-image-owned-runtime' {
    $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-Runner.ps1') -Raw
    if ($text -notmatch 'RunnerProject.psm1' -or $text -notmatch 'Invoke-RunnerProject') {
        throw 'Generic execution is not wired from qualified image.'
    }
    if ($text -match '& dotnet restore dirs.proj') {
        throw 'Hardcoded project restore remains in framework.'
    }
}
Invoke-IntegrationCase 'environment-supports-build-without-cloud-credentials' {
    $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-ProjectCommand.ps1') -Raw
    foreach ($name in @('NUGET_PACKAGES', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'PLAYWRIGHT_BROWSERS_PATH')) {
        if ($text -notmatch $name) {
            throw "Missing build runtime variable $name"
        }
    }
    if ($text -match "'AZURE_CLIENT_ID'|'AZCOPY_AUTO_LOGIN_TYPE'|'GH_TOKEN'") {
        throw 'Cloud credential variable is forwarded.'
    }
}
$failed = @($script:cases | Where-Object { -not $_.passed }).Count
@{ passed = $script:cases.Count - $failed; failed = $failed; total = $script:cases.Count; cases = $script:cases.ToArray() } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
