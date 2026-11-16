<#
.SYNOPSIS
Provides bounded standalone test wrappers and strict output validation.
.DESCRIPTION
Uses the runner native ownership supervisor on the original wrapper clock. Retains
child output and scratch evidence before deleting only wrapper-owned scratch.
.EXAMPLE
Import-Module ./StandaloneTest.psm1
.OUTPUTS
None. Exports wrapper and proof validation functions.
#>
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
function Assert-StandaloneProof {
    <#
    .SYNOPSIS
    Requires successful exit and every mandatory output proof.
    .DESCRIPTION
    Rejects nonzero exit, missing output and explicit failure lines independently.
    .PARAMETER ExitCode
    Actual observed child exit code.
    .PARAMETER Output
    Drained child output, not predicted output.
    .PARAMETER Proof
    Exact mandatory output substrings.
    .EXAMPLE
    Assert-StandaloneProof -ExitCode 0 -Output 'RESULT failed=0' -Proof @('failed=0')
    .OUTPUTS
    None. Throws on rejected evidence.
    #>
    [CmdletBinding()]
    param([int]$ExitCode, [string]$Output, [string[]]$Proof)
    if ($ExitCode -ne 0 -or $Output -match '(?m)^FAIL\b|failed=[1-9]') {
        throw "Child failed: exit=$ExitCode; $Output"
    }
    foreach ($required in $Proof) {
        if (-not $Output.Contains($required)) {
            throw "Missing required proof: $required"
        }
    }
    if ($Proof.Count -eq 0) {
        throw 'Empty proof inventory is not acceptance.'
    }
}
function Invoke-StandaloneCase {
    <#
    .SYNOPSIS
    Runs one fixed inventory case under its original wrapper guard.
    .DESCRIPTION
    Starts an owned native child with bounded output drain and termination. Scratch
    must be absent. Retains all observations and then removes owned child scratch.
    .PARAMETER Case
    Fixed inventory row containing path, parameter, proofs and timeoutSeconds.
    .PARAMETER TestRoot
    Directory containing the exact source fixture.
    .PARAMETER EvidenceRoot
    New owned output directory for this wrapper.
    .PARAMETER HarnessPath
    Required PowerShell executable; missing harness fails closed.
    .EXAMPLE
    Invoke-StandaloneCase -Case $row -TestRoot $PSScriptRoot -EvidenceRoot /work/case -HarnessPath pwsh
    .OUTPUTS
    System.Object. Observed wrapper exit, cleanup and elapsed evidence.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($Case, [string]$TestRoot, [string]$EvidenceRoot, [string]$HarnessPath = 'pwsh')
    $scriptPath = Join-Path $TestRoot $Case.path
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Required fixture is missing: $scriptPath"
    }
    $null = Get-Command -Name $HarnessPath -CommandType Application -ErrorAction Stop
    New-Item -ItemType Directory -Path $EvidenceRoot -ErrorAction Stop | Out-Null
    $scratch = Join-Path $EvidenceRoot 'child-scratch'
    if (Test-Path -LiteralPath $scratch) {
        throw 'Child scratch must be absent at wrapper launch.'
    }
    $arguments = @('-NoProfile', '-File', $scriptPath)
    if ($Case.parameter) {
        $arguments += @(('-' + $Case.parameter), $scratch)
    }
    $log = Join-Path $EvidenceRoot 'output.log'
    $run = $null
    try {
        $run = Invoke-DiagnosticProcess -FilePath $HarnessPath -ArgumentList $arguments -LogPath $log -TimeoutSeconds $Case.timeoutSeconds -EvidenceRoot $EvidenceRoot -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50
        $run | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'wrapper-run.json')
        if ($run.TimedOut -or -not $run.CleanupComplete -or -not $run.DrainComplete -or -not $run.ReadersClosed -or $run.ElapsedSeconds -ge $Case.timeoutSeconds) {
            throw 'Original wrapper deadline, owned termination or drained-output proof failed.'
        }
        $output = Get-Content -LiteralPath $log -Raw
        Assert-StandaloneProof -ExitCode $run.ExitCode -Output $output -Proof $Case.proofs
    }
    finally {
        if (Test-Path -LiteralPath $scratch) {
            Copy-Item -LiteralPath $scratch -Destination (Join-Path $EvidenceRoot 'retained-child') -Recurse
            Remove-Item -LiteralPath $scratch -Recurse -Force
        }
        $absent = -not (Test-Path -LiteralPath $scratch)
        @{ scratchAbsent = $absent; source = $scriptPath } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'scratch-cleanup.json')
        if (-not $absent) {
            throw 'Wrapper-owned child scratch survived cleanup.'
        }
    }
    return @{ name = $Case.path; exitCode = $run.ExitCode; elapsedSeconds = $run.ElapsedSeconds; cleanupComplete = $run.CleanupComplete; drainComplete = $run.DrainComplete; readersClosed = $run.ReadersClosed; passed = $true }
}
Export-ModuleMember -Function Assert-StandaloneProof, Invoke-StandaloneCase
