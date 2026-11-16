<#
.SYNOPSIS
Reproduces Linux lock admission and asynchronous signal observations.
.DESCRIPTION
Synthetic native Linux only, in the authorized isolated container. Retains the exact
managed-open error and the eventual membership observations; no host signals or network.
.PARAMETER ScratchRoot
New isolated scratch directory.
.EXAMPLE
./Test-RunnerLinuxRepair.ps1 -ScratchRoot /tmp/linux-repair
.OUTPUTS
System.String. Actual native regression observations and failures.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsLinux) {
    throw 'Native Linux required.'
}
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
Add-Type -Path (Join-Path $PSScriptRoot '../DiagnosticContainment.cs')
Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class RepairLock {
 [DllImport("libc",SetLastError=true)] public static extern int flock(int fd,int operation);
}
'@
$oldRegistry = $env:RUNNER_OWNERSHIP_ROOT
$registry = Join-Path $ScratchRoot 'registry'
New-Item -ItemType Directory -Path $registry | Out-Null
$env:RUNNER_OWNERSHIP_ROOT = $registry
$observations = [Collections.Generic.List[object]]::new()
$held = $null
$owner = $null
try {
    $held = [IO.File]::Open((Join-Path $registry 'registry.lock'), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
    if ([RepairLock]::flock($held.SafeFileHandle.DangerousGetHandle().ToInt32(), 6) -ne 0) {
        throw 'Fixture lock failed.'
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $method = [DiagnosticContainment].GetMethod('LockRegistry', [Reflection.BindingFlags]'Static,NonPublic')
    $message = $null
    try {
        $null = $method.Invoke($null, @([string]$registry, $clock, [double]0.15))
    }
    catch {
        $message = $_.Exception.ToString()
    }
    $observations.Add(@{ name = 'held-lock-admission'; passed = ($message -match 'registry lock deadline' -and $clock.Elapsed.TotalSeconds -lt 2); error = $message; seconds = $clock.Elapsed.TotalSeconds })
    Write-Output ($observations[0] | ConvertTo-Json -Compress)
    $held.Dispose()
    $held = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $memberPath = Join-Path $ScratchRoot 'member'
    $command = 'set -m; sleep 60 >/dev/null 2>&1 & echo $! > "' + $memberPath + '"; wait'
    $owner = New-DiagnosticOwnedProcess -FilePath bash -ArgumentList @('-c', $command) -Root $ScratchRoot -Token probe -RunClock $clock -DeadlineSeconds 5
    while (-not (Test-Path $memberPath) -and $clock.Elapsed.TotalSeconds -lt 5) {
        Start-Sleep -Milliseconds 5
    }
    if (-not (Test-Path $memberPath)) {
        throw 'Member readiness failed.'
    }
    $memberId = [int][IO.File]::ReadAllText($memberPath)
    $expiredError = $null
    try {
        [DiagnosticContainment]::KillGroup($owner.GroupId, $clock, -1)
    }
    catch {
        $expiredError = $_.Exception.Message
    }
    $null = $owner.Process.WaitForExit(2000)
    $before = if (Test-Path "/proc/$memberId/stat") {
        [IO.File]::ReadAllText("/proc/$memberId/stat")
    }
    else {
        'disappeared after root signal'
    }
    $cleanupStart = $clock.Elapsed.TotalSeconds
    [DiagnosticContainment]::KillGroup($owner.GroupId, $clock, $cleanupStart + 2)
    $samples = [Collections.Generic.List[object]]::new()
    do {
        $members = @([DiagnosticContainment]::RegisteredMemberIds($owner.GroupId, $clock, $cleanupStart + 2))
        $stat = if (Test-Path "/proc/$memberId/stat") {
            [IO.File]::ReadAllText("/proc/$memberId/stat")
        }
        else {
            'disappeared'
        }
        $samples.Add(@{ seconds = $clock.Elapsed.TotalSeconds - $cleanupStart; members = $members; stat = $stat })
        if (-not $members.Count) {
            break
        }
        Start-Sleep -Milliseconds 5
    } while ($clock.Elapsed.TotalSeconds -lt ($cleanupStart + 1))
    $observations.Add(@{ name = 'expired-survivor-then-bounded-cleanup'; passed = ($null -ne $expiredError -and $members.Count -eq 0); expiredError = $expiredError; survivorBeforeSafetyCleanup = $before; samples = $samples.ToArray() })
}
finally {
    if ($null -ne $held) {
        $held.Dispose()
    }
    if ($null -ne $owner) {
        try {
            [DiagnosticContainment]::KillGroup($owner.GroupId, $clock, $clock.Elapsed.TotalSeconds + 1)
        }
        finally {
            $owner.Process.Dispose()
        }
    }
    $env:RUNNER_OWNERSHIP_ROOT = $oldRegistry
}
$failed = @($observations | Where-Object { -not $_.passed }).Count
@{ passed = $observations.Count - $failed; failed = $failed; cases = $observations.ToArray() } | ConvertTo-Json -Depth 8
if ($failed) {
    exit 1
}
