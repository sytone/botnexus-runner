<#
.SYNOPSIS
Checks Windows original-clock membership and stop certification boundaries.
.DESCRIPTION
Uses inert job observations with the actual shared helpers. No native signal is sent.
Each case records its result, including expiry before and during a query.
.PARAMETER EvidenceRoot
Owned output directory for actual case results.
.EXAMPLE
./Test-RunnerWindowsProof.ps1 -EvidenceRoot Q:/scratch/windows-proof
.OUTPUTS
System.String. Per-case results; exits nonzero on any failed assertion.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
if (-not $IsWindows) {
    throw 'This fixture exercises the Windows job-query boundary.'
}
New-Item -ItemType Directory -Path $EvidenceRoot -Force | Out-Null
$cases = [Collections.Generic.List[object]]::new()
foreach ($name in @('expired-empty-membership', 'missing-clock', 'query-crosses-deadline', 'expired-exited-stop-signals', 'expired-live-stop-signals', 'zero-wait-signals', 'within-clock-proof', 'query-error-not-empty')) {
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $job = [pscustomobject]@{ Signals = 0; Queries = 0; Clock = $clock; CrossDeadline = $false; QueryError = $false }
        $job | Add-Member ScriptMethod Kill { $this.Signals++ }
        $job | Add-Member ScriptMethod get_MemberIds {
            $this.Queries++
            if ($this.QueryError) {
                throw 'Synthetic native query failure.'
            }
            if ($this.CrossDeadline) {
                while ($this.Clock.Elapsed.TotalSeconds -lt 0.1) {
                    [Threading.Thread]::SpinWait(100)
                }
            }
            return @()
        }
        $job | Add-Member ScriptProperty Active { return 0 }
        $owner = [pscustomobject]@{ Job = $job; Process = [pscustomobject]@{ HasExited = $true }; GroupId = 0; Observed = @{}; Stopped = $false }
        $failure = ''
        switch ($name) {
            'expired-empty-membership' {
                try {
                    $null = Get-DiagnosticOwnedMember $owner -RunClock $clock -DeadlineSeconds 0
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'deadline|certif' -or $job.Queries -ne 0) {
                    throw "Expired empty proof accepted or queried: $failure"
                }
            }
            'missing-clock' {
                try {
                    $null = Get-DiagnosticOwnedMember $owner
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'clock' -or $job.Queries -ne 0) {
                    throw "Missing original clock accepted: $failure"
                }
            }
            'query-crosses-deadline' {
                $job.CrossDeadline = $true
                try {
                    $null = Get-DiagnosticOwnedMember $owner -RunClock $clock -DeadlineSeconds 0.05
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'deadline|certif' -or $job.Queries -ne 1) {
                    throw "Late query certified: $failure"
                }
            }
            'expired-exited-stop-signals' {
                try {
                    Stop-DiagnosticOwnedProcess $owner -WaitTimeoutMilliseconds 5000 -RunClock $clock -DeadlineSeconds 0
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'deadline|certif' -or $job.Signals -ne 1) {
                    throw "Expired exited stop lost signal/failure: $failure"
                }
            }
            'expired-live-stop-signals' {
                $owner.Process.HasExited = $false
                try {
                    Stop-DiagnosticOwnedProcess $owner -WaitTimeoutMilliseconds 5000 -RunClock $clock -DeadlineSeconds 0
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'deadline|certif' -or $job.Signals -ne 1) {
                    throw "Expired live stop lost signal/failure: $failure"
                }
            }
            'zero-wait-signals' {
                Stop-DiagnosticOwnedProcess $owner -RunClock $clock -DeadlineSeconds 0
                if ($job.Signals -ne 1 -or $job.Queries -ne 0 -or -not $owner.Stopped) {
                    throw 'Signal-only stop performed proof or lost termination.'
                }
            }
            'within-clock-proof' {
                $null = Get-DiagnosticOwnedMember $owner -RunClock $clock -DeadlineSeconds 10
                Stop-DiagnosticOwnedProcess $owner -WaitTimeoutMilliseconds 5000 -RunClock $clock -DeadlineSeconds 10
                if ($job.Signals -ne 1 -or $job.Queries -lt 2) {
                    throw 'Timely stop bypassed common membership proof.'
                }
            }
            'query-error-not-empty' {
                $job.QueryError = $true
                try {
                    $null = Get-DiagnosticOwnedMember $owner -RunClock $clock -DeadlineSeconds 10
                }
                catch {
                    $failure = $_.Exception.Message
                }
                if ($failure -notmatch 'Synthetic native query failure') {
                    throw 'Native query error became empty membership.'
                }
            }
        }
        $cases.Add(@{ name = $name; passed = $true })
        "PASS $name"
    }
    catch {
        $cases.Add(@{ name = $name; passed = $false; error = $_.Exception.Message })
        "FAIL ${name}: $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ total = $cases.Count; passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'cases.json')
if ($failed) {
    exit 1
}
