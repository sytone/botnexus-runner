<#
.SYNOPSIS
Supervises the complete image-owned pipeline and final artifact transfer on one clock.
.DESCRIPTION
Owns setup, extraction, git and project process trees, including nested sessions. Reserves
operator time for partial result creation and upload even when the inner pipeline is killed.
Framework paths are image-owned, never loaded as an entrypoint override from the candidate.
.PARAMETER WorkRoot
New framework-owned run directory. Defaults to /work/<RUN_ID> in the container image.
.PARAMETER BudgetSeconds
Operator platform budget. Zero reads REPLICA_TIMEOUT_SECONDS or defaults to 1200.
.PARAMETER ReserveSeconds
Operator cleanup/finalization/upload reserve; candidate config cannot change it.
.PARAMETER PipelineScript
Image-owned pipeline script. Optional explicit path is for isolated synthetic harness copies.
.PARAMETER SkipUpload
Synthetic harness only: retains final local evidence without invoking native transport.
.PARAMETER TransportScript
Image-owned transfer script; an explicit inert native stub is permitted in isolated fixtures.
.EXAMPLE
pwsh -NoProfile -File /runner/Invoke-Runner.ps1
.OUTPUTS
System.String. Execution and upload result. Exits nonzero on any boundary failure.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$WorkRoot = '',
    [int]$BudgetSeconds = 0,
    [ValidateRange(3, 300)][int]$ReserveSeconds = 90,
    [string]$PipelineScript = '',
    [switch]$SkipUpload,
    [string]$TransportScript = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$clock = [Diagnostics.Stopwatch]::StartNew()
if (-not $TransportScript) {
    $TransportScript = Join-Path $PSScriptRoot 'Invoke-RunnerTransport.ps1'
}
if ($BudgetSeconds -eq 0) {
    $BudgetSeconds = if ($env:REPLICA_TIMEOUT_SECONDS) {
        [int]$env:REPLICA_TIMEOUT_SECONDS
    }
    else {
        1200
    }
}
if ($BudgetSeconds -gt 3600 -or $BudgetSeconds -le ($ReserveSeconds + 2)) {
    throw 'Operator budget must contain execution and finalization reserve.'
}
$runId = if ($env:RUN_ID) {
    $env:RUN_ID
}
else {
    [guid]::NewGuid().ToString('N')
}
if (-not $WorkRoot) {
    $WorkRoot = Join-Path '/work' $runId
}
if (-not $PipelineScript) {
    $PipelineScript = Join-Path $PSScriptRoot 'Invoke-RunnerPipeline.ps1'
}
if (-not $PSCmdlet.ShouldProcess($WorkRoot, 'Execute supervised image pipeline and final artifact transfer')) {
    return
}
New-Item -ItemType Directory -Path $WorkRoot -ErrorAction Stop | Out-Null
$artifacts = Join-Path $WorkRoot 'artifacts'
New-Item -ItemType Directory -Path $artifacts | Out-Null
Import-Module (Join-Path $PSScriptRoot 'RunnerProject.psm1') -Force
$previousWork = [Environment]::GetEnvironmentVariable('RUNNER_WORK_ROOT')
$previousDeadline = [Environment]::GetEnvironmentVariable('RUNNER_EXECUTION_DEADLINE_UTC')
[Environment]::SetEnvironmentVariable('RUNNER_WORK_ROOT', $WorkRoot)
[Environment]::SetEnvironmentVariable('RUNNER_EXECUTION_DEADLINE_UTC', [DateTimeOffset]::UtcNow.AddSeconds($BudgetSeconds - $ReserveSeconds - $clock.Elapsed.TotalSeconds).ToString('o'))
$document = @{
    schemaVersion = 1
    protocolVersion = 1
    requiredCapabilities = @('process-v1')
    limits = @{ budgetSeconds = $BudgetSeconds; reserveSeconds = $ReserveSeconds; maxConcurrency = 1; maxLogBytes = 16777216; maxArtifactBytes = 67108864; maxArtifacts = 128 }
    steps = @(@{ id = 'pipeline'; executable = (Get-Process -Id $PID).Path; arguments = @('-NoProfile', '-File', $PipelineScript); workingDirectory = '.'; dependsOn = @(); artifacts = @() })
}
$configuration = Join-Path $WorkRoot 'framework-pipeline.json'
$document | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configuration
$exitCode = 1
$execution = $null
try {
    $project = Read-RunnerProject -Path $configuration -PayloadRoot $WorkRoot -ExpectedSha256 (Get-FileHash -LiteralPath $configuration).Hash
    $execution = Invoke-RunnerProject -Project $project -PayloadRoot $WorkRoot -EvidenceRoot (Join-Path $WorkRoot 'supervisor') -RunClock $clock -AbsoluteDeadlineSeconds ($BudgetSeconds - $ReserveSeconds) -FinalizationReserveSeconds 2 -FrameworkCommand
    $exitCode = if ($execution.status -eq 'succeeded' -and $execution.cleanupComplete) {
        0
    }
    else {
        1
    }
    $resultPath = Join-Path $artifacts 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) {
        @{
            runId = $runId
            exitCode = 1
            completedUtc = [DateTime]::UtcNow.ToString('o')
            tests = $null
            sourceSnapshot = $null
            timeout = @{ timedOut = $execution.status -eq 'timedOut'; phase = 'pipeline'; elapsedSeconds = $clock.Elapsed.TotalSeconds; deadlineSeconds = $BudgetSeconds - $ReserveSeconds; attribution = 'Outer image pipeline exceeded its execution allowance before final artifact transfer.' }
            pipelineExecution = $execution
        } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $resultPath
    }
    $canonical = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json -AsHashtable
    $canonical['pipelineExecution'] = $execution
    if ($exitCode -ne 0) {
        $canonical['exitCode'] = 1
        $canonical['outerFailure'] = @{ status = $execution.status; cleanupComplete = $execution.cleanupComplete; errors = @($execution.errors) }
    }
    $canonical['transferEvidence'] = 'Upload completion is observed by the provider/sender; local upload-execution.json is written after transfer and is not in that transferred batch.'
    $canonical | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath
    $execution | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifacts 'pipeline-execution.json')

}
catch {
    $exitCode = 1
    $originalError = $_.Exception.Message
    $_ | Out-String | Set-Content -LiteralPath (Join-Path $artifacts 'outer-error.log')
    @{
        runId = $runId
        exitCode = 1
        tests = $null
        accepted = $false
        outerFailure = @{ error = $originalError }
        pipelineExecution = $execution
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $artifacts 'result.json')
    if ($null -ne $execution) {
        $execution | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifacts 'pipeline-execution.json')
    }
}
finally {
    try {
        if (-not $SkipUpload) {
            $remaining = [int][Math]::Floor($BudgetSeconds - $clock.Elapsed.TotalSeconds - 1)
            if ($remaining -lt 6) {
                throw 'Original platform budget exhausted before final artifact transfer.'
            }
            $uploadDocument = @{
                schemaVersion = 1
                protocolVersion = 1
                requiredCapabilities = @('process-v1')
                limits = @{ budgetSeconds = $BudgetSeconds; reserveSeconds = 2; maxConcurrency = 1; maxLogBytes = 16777216; maxArtifactBytes = 67108864; maxArtifacts = 128 }
                steps = @(@{
                        id = 'upload'
                        executable = (Get-Process -Id $PID).Path
                        arguments = @('-NoProfile', '-File', $TransportScript, '-Source', "$artifacts/*", '-Destination', $env:ARTIFACT_BLOB_URL, '-EvidenceRoot', (Join-Path $WorkRoot 'upload'), '-TimeoutSeconds', [string]$remaining, '-Recursive')
                        workingDirectory = '.'
                        dependsOn = @()
                        artifacts = @()
                    })
            }
            $uploadConfiguration = Join-Path $WorkRoot 'framework-upload.json'
            $uploadDocument | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $uploadConfiguration
            $uploadProject = Read-RunnerProject -Path $uploadConfiguration -PayloadRoot $WorkRoot -ExpectedSha256 (Get-FileHash -LiteralPath $uploadConfiguration).Hash
            $uploadExecution = Invoke-RunnerProject -Project $uploadProject -PayloadRoot $WorkRoot -EvidenceRoot (Join-Path $WorkRoot 'upload-supervisor') -RunClock $clock -AbsoluteDeadlineSeconds ($BudgetSeconds - 3) -FinalizationReserveSeconds 3 -FrameworkCommand
            $uploadExecution | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $artifacts 'upload-execution.json')
            if ($uploadExecution.status -ne 'succeeded' -or -not $uploadExecution.cleanupComplete) {
                $exitCode = 1
            }
        }
    }
    catch {
        $exitCode = 1
        $_ | Out-String | Set-Content -LiteralPath (Join-Path $artifacts 'upload-error.log')
    }
    finally {
        [Environment]::SetEnvironmentVariable('RUNNER_WORK_ROOT', $previousWork)
        [Environment]::SetEnvironmentVariable('RUNNER_EXECUTION_DEADLINE_UTC', $previousDeadline)
    }
}
exit $exitCode
