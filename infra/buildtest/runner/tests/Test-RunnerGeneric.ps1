<#
.SYNOPSIS
Checks the standalone generic runner boundary and two unrelated candidate layouts.
.DESCRIPTION
Uses the real project parser and process owner with synthetic commands only. Records
contract failures separately from native execution failures. Never starts a product host.
.PARAMETER ScratchRoot
New isolated fixture directory under writable container storage.
.EXAMPLE
./Test-RunnerGeneric.ps1 -ScratchRoot /work/fixture
.OUTPUTS
System.String. Per-case results and a JSON summary. Exits one on any failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$cases = [Collections.Generic.List[object]]::new()
$pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-RunnerPipeline.ps1') -Raw
$contracts = [ordered]@{
    'explicit-config-path' = $pipeline.Contains('$env:PROJECT_CONFIG_PATH')
    'no-application-mode' = $pipeline -notmatch 'TEST_MODE|BotNexus|minimumTotals|Get-ExpectedTestProjects|infra/buildtest/project/'
    'unknown-tests-not-acceptance' = $pipeline -match 'tests\s*=\s*\$null' -and $pipeline -notmatch 'Get-RunnerTestResult'
}
foreach ($entry in $contracts.GetEnumerator()) {
    $cases.Add(@{ name = $entry.Key; passed = [bool]$entry.Value })
}
foreach ($layout in @('flat', 'nested')) {
    try {
        $root = Join-Path $ScratchRoot $layout
        $working = if ($layout -eq 'flat') {
            $root
        }
        else {
            Join-Path $root 'source/component'
        }
        New-Item -ItemType Directory -Path $working -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Invoke-FixtureCommand.ps1') -Destination $working
        $configPath = Join-Path $root 'project.json'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "fixtures/$layout/project.json") -Destination $configPath
        $hash = (Get-FileHash -LiteralPath $configPath).Hash
        $config = Read-RunnerProject -Path $configPath -PayloadRoot $root -ExpectedSha256 $hash
        $execution = Invoke-RunnerProject -Project $config -PayloadRoot $root -EvidenceRoot (Join-Path $root 'evidence')
        if ($execution.status -ne 'succeeded' -or -not $execution.cleanupComplete -or $execution.accepted) {
            throw "Execution or cleanup failed, or framework invented application acceptance: $($execution | ConvertTo-Json -Depth 8 -Compress)"
        }
        if ([IO.File]::ReadAllText((Join-Path $working 'result.txt')) -cne 'literal ; $value with spaces') {
            throw 'Literal argument bytes changed.'
        }
        $cases.Add(@{ name = "project-$layout"; passed = $true })
    }
    catch {
        $cases.Add(@{ name = "project-$layout"; passed = $false; error = $_.Exception.Message })
    }
}
foreach ($case in $cases) {
    Write-Output ($case | ConvertTo-Json -Compress)
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $ScratchRoot 'summary.json')
Write-Output "passed=$($cases.Count - $failed) failed=$failed"
if ($failed) {
    exit 1
}
