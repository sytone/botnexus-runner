<#
.SYNOPSIS
Checks standalone budget, image helper and original-clock wiring contracts.
.DESCRIPTION
Uses current source and explicit caller budget. Runtime timeout, nonzero, partial
result and bounded upload behavior is exercised by Test-RunnerPipelineBoundary.
.EXAMPLE
./Test-RunnerDeadlineContract.ps1
.OUTPUTS
System.String. Actual generic source contract assertions; throws on any failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerTimeout.psm1') -Force
$budget = 20 * 60
$deadline = Get-RunnerDeadline -BudgetSeconds $budget
if ($deadline -ge $budget -or $deadline -ne 1110) {
    throw 'Explicit caller budget does not retain original finalization reserve.'
}
$dockerfile = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Dockerfile') -Raw
if ($dockerfile -notmatch 'COPY[^\r\n]*RunnerTimeout\.psm1') {
    throw 'Current timeout module is not shipped into the image.'
}
$bicep = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../main.bicep') -Raw
if ($bicep -notmatch 'replicaTimeout: 1200') {
    throw 'Deployed replica budget differs from explicit 20-minute caller budget.'
}
$supervisor = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-Runner.ps1') -Raw
$pipeline = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-RunnerPipeline.ps1') -Raw
foreach ($proof in @('Invoke-RunnerProject', '-RunClock $clock', 'pipelineExecution', 'timeout =', 'RUNNER_EXECUTION_DEADLINE_UTC', 'Original platform budget exhausted', '-AbsoluteDeadlineSeconds ($BudgetSeconds - 3)')) {
    if (-not $supervisor.Contains($proof)) {
        throw "Original supervisor clock/result/finalization contract missing: $proof"
    }
}
foreach ($proof in @('-RunClock $clock', '-AbsoluteDeadlineSeconds $deadlineSeconds', 'Original execution budget exhausted', 'PROJECT_CONFIG_PATH', 'PROJECT_CONFIG_SHA256')) {
    if (-not $pipeline.Contains($proof)) {
        throw "Generic pipeline clock/configuration contract missing: $proof"
    }
}
Write-Output 'RESULT passed=15 failed=0'
