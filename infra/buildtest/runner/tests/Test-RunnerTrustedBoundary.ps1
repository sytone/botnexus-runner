<#
.SYNOPSIS
Executes trusted-limit and evidence attack fixtures without product hosts.
.DESCRIPTION
Uses synthetic children and the canonical evidence validator. Proves caller deadline/cap
controls and config/image/cleanup proof independently of candidate acceptance claims.
.PARAMETER ScratchRoot
Owned output root for retained logs and case counts.
.EXAMPLE
./Test-RunnerTrustedBoundary.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Actual case results and JSON counts.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../RunnerEvidence.psm1') -Force
$script:cases = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
function Invoke-TrustedCase {
    <#
    .SYNOPSIS
    Records one trusted-boundary fixture.
    .DESCRIPTION
    Captures actual failures and continues independent cases.
    .PARAMETER Name
    Stable case identity.
    .PARAMETER Body
    Assertions to execute.
    .EXAMPLE
    Invoke-TrustedCase 'proof' { throw 'Mismatch' }
    .OUTPUTS
    System.String. Fixture outcome.
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
Invoke-TrustedCase 'no-application-dependency' {
    if (Get-Command -Name Get-RunnerProjectIdentity -ErrorAction SilentlyContinue) {
        throw 'Generic evidence verification loaded application config selection.'
    }
    $module = Get-Module -Name RunnerEvidence
    $source = Get-Content -LiteralPath $module.Path -Raw
    if ($source -match 'infra/buildtest/project|ValidateSet|BotNexus|12000|Import-Module') {
        throw 'Generic evidence module reacquired application policy or dependencies.'
    }
}
$identity = [pscustomobject]@{ version = 1; path = 'custom/build-plan.json'; sha256 = 'a' * 64 }
$image = 'example.invalid/runner@sha256:' + ('b' * 64)
$positive = [pscustomobject]@{
    runnerProtocol = 1
    runnerImage = $image
    projectConfiguration = $identity
    projectExecution = [pscustomobject]@{ protocolVersion = 1; configSha256 = $identity.sha256; status = 'succeeded'; cleanupComplete = $true; accepted = $false; steps = @([pscustomobject]@{ id = 'test'; status = 'succeeded'; exitCode = 0 }) }
}
Invoke-TrustedCase 'positive-execution-proof' { Assert-RunnerProjectEvidence -Result $positive -Identity $identity -Image $image }
$attacks = [ordered]@{
    'missing-protocol' = { param($r) $r.PSObject.Properties.Remove('runnerProtocol') }
    'wrong-image' = { param($r) $r.runnerImage = 'old-image' }
    'wrong-config' = { param($r) $r.projectConfiguration.sha256 = '0' * 64 }
    'self-accepted' = { param($r) $r.projectExecution.accepted = $true }
    'cleanup-incomplete' = { param($r) $r.projectExecution.cleanupComplete = $false }
    'missing-steps' = { param($r) $r.projectExecution.steps = @() }
    'nonzero-step' = { param($r) $r.projectExecution.steps[0].exitCode = 4 }
}
foreach ($attack in $attacks.GetEnumerator()) {
    Invoke-TrustedCase $attack.Key {
        $result = $positive | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        & $attack.Value $result
        $rejected = $false
        try {
            Assert-RunnerProjectEvidence -Result $result -Identity $identity -Image $image
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw 'Invalid execution proof accepted.'
        }
    }
}
foreach ($scenario in @('absolute-deadline', 'operator-log-cap')) {
    Invoke-TrustedCase $scenario {
        $root = Join-Path $ScratchRoot $scenario
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $command = if ($scenario -eq 'operator-log-cap') {
            'while ($true) { [Console]::WriteLine("x" * 1024) }'
        }
        else {
            'Start-Sleep -Seconds 30'
        }
        $config = @{
            schemaVersion = 1
            protocolVersion = 1
            requiredCapabilities = @('process-v1')
            limits = @{ budgetSeconds = 60; reserveSeconds = 4; maxConcurrency = 8; maxLogBytes = 16777216; maxArtifactBytes = 67108864; maxArtifacts = 128 }
            steps = @(@{ id = 'test'; executable = (Get-Process -Id $PID).Path; arguments = @('-NoProfile', '-Command', $command); workingDirectory = '.'; dependsOn = @(); artifacts = @() })
        }
        $path = Join-Path $root 'project.json'
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
        $project = Read-RunnerProject -Path $path -PayloadRoot $root -ExpectedSha256 (Get-FileHash -LiteralPath $path).Hash
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-RunnerProject -Project $project -PayloadRoot $root -EvidenceRoot (Join-Path $root 'evidence') -RunClock $clock -AbsoluteDeadlineSeconds 3 -FinalizationReserveSeconds 2 -OperatorLimits @{ maxConcurrency = 1; maxLogBytes = 1024 }
        if (-not $result.cleanupComplete -or $clock.Elapsed.TotalSeconds -ge 5) {
            throw 'Caller absolute deadline or cleanup reserve was reset.'
        }
        $expected = if ($scenario -eq 'operator-log-cap') {
            'failed'
        }
        else {
            'timedOut'
        }
        if ($result.status -ne $expected) {
            throw "Wrong caller-bound status: $($result | ConvertTo-Json -Depth 8 -Compress)"
        }
        $bytes = (Get-ChildItem (Join-Path $root 'evidence') -Filter '*.log' | Measure-Object -Property Length -Sum).Sum
        if ($bytes -gt 1024) {
            throw 'Project raised operator retained-log cap.'
        }
    }
}
$failed = @($script:cases | Where-Object { -not $_.passed }).Count
@{ passed = $script:cases.Count - $failed; failed = $failed; total = $script:cases.Count; cases = $script:cases.ToArray() } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
