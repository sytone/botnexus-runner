<#
.SYNOPSIS
Checks real membership deadlines under controlled readiness delay and inherited ownership.
.DESCRIPTION
Runs synthetic PowerShell children only. A delayed logical-clock callback consumes the
original six-second real budget. Expired membership must return failed evidence, not
escape finalization or certify cleanup. No new proof allowance is supplied.
.PARAMETER ScratchRoot
Isolated writable fixture directory.
.PARAMETER UnknownOnly
Runs only the invalid registry observation control.
.EXAMPLE
./Test-RunnerMembershipRuntime.ps1 -ScratchRoot /tmp/membership-runtime
.OUTPUTS
System.String. Actual deadline and cleanup observations.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot, [switch]$UnknownOnly)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$registry = Join-Path $ScratchRoot 'registry'
New-Item -ItemType Directory -Path $registry | Out-Null
$previousRegistry = $env:RUNNER_OWNERSHIP_ROOT
$env:RUNNER_OWNERSHIP_ROOT = $registry
$state = @{ Delayed = $false }
$provider = {
    param($Phase, $Owner, $DumpChildren, $Captures)
    if (-not $state.Delayed -and $Phase -eq 'poll') {
        $state.Delayed = $true
        # A controlled readiness stall, not a scheduler or a fresh cleanup budget.
        [Threading.Thread]::Sleep(6100)
        Write-Output 3.0
        return
    }
    Write-Verbose "$Owner $DumpChildren $Captures"
    return 3.0
}.GetNewClosure()
$watch = [Diagnostics.Stopwatch]::StartNew()
try {
    if (-not $UnknownOnly) {
        $run = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Console]::WriteLine("ready"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null') -LogPath (Join-Path $ScratchRoot 'run.log') -TimeoutSeconds 6 -EvidenceRoot $ScratchRoot -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -ElapsedSecondsProvider $provider
        if ($run.ExitCode -eq 0 -or $run.CleanupComplete -or -not $run.TimedOut) {
            throw 'Expired original real deadline was certified or hidden.'
        }
        if (($run.CleanupErrors -join ' ') -notmatch 'deadline') {
            throw 'Original deadline failure evidence was lost.'
        }
        if ($watch.Elapsed.TotalSeconds -ge 10) {
            throw 'Finalization granted a fresh allowance after readiness exhausted the deadline.'
        }
        if (-not (Test-Path (Join-Path $ScratchRoot 'absolute-captures.json'))) {
            throw 'Failure escaped final evidence publication.'
        }
        "PASS expired original clock returns failed evidence logical=$($run.ElapsedSeconds) real=$($watch.Elapsed.TotalSeconds) cleanup=$($run.CleanupComplete) timedOut=$($run.TimedOut)"
        "ERRORS $($run.CleanupErrors -join ' | ')"
    }
    $invalidRoot = Join-Path $ScratchRoot 'invalid-observation'
    New-Item -ItemType Directory -Path $invalidRoot | Out-Null
    $invalidState = @{ Written = $false; Registry = $registry }
    $invalidProvider = {
        param($Phase, $Owner, $DumpChildren, $Captures)
        if (-not $invalidState.Written -and $Phase -eq 'poll') {
            # Admission was valid; corrupt observation only after the actual root
            # is owned, so the real native proof (not a fake empty list) fails.
            [IO.File]::WriteAllText((Join-Path $invalidState.Registry 'invalid.json'), '{broken')
            $invalidState.Written = $true
        }
        Write-Verbose "$Owner $DumpChildren $Captures"
        return 0.0
    }.GetNewClosure()
    $invalid = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null') -LogPath (Join-Path $invalidRoot 'run.log') -TimeoutSeconds 6 -EvidenceRoot $invalidRoot -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -ElapsedSecondsProvider $invalidProvider
    if ($invalid.ExitCode -eq 0 -or $invalid.CleanupComplete -or ($invalid.CleanupErrors -join ' ') -notmatch 'Diagnostic supervision failed.*Owned membership unknown') {
        throw 'Unknown native membership observation escaped or certified cleanup.'
    }
    "PASS native unknown observation retained failed result cleanup=$($invalid.CleanupComplete) timedOut=$($invalid.TimedOut)"
    "ERRORS $($invalid.CleanupErrors -join ' | ')"
}
finally {
    $env:RUNNER_OWNERSHIP_ROOT = $previousRegistry
}
