<#
.SYNOPSIS
Measures the unchanged diagnostic fixtures with inherited ownership under external CPU limits.
.DESCRIPTION
Runs exact source fixtures in child PowerShell processes. The container applies CPU limits;
this script retains the existing one-minute architecture guard and all six-second budgets.
No product host, testhost, network, or new cleanup allowance is used.
.PARAMETER ScratchRoot
Isolated directory for the inherited registry.
.EXAMPLE
./Test-RunnerMembershipLoad.ps1 -ScratchRoot /tmp/membership-load
.OUTPUTS
System.String. Fixture output and measured duration.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$registry = Join-Path $ScratchRoot 'registry'
New-Item -ItemType Directory -Path $registry | Out-Null
foreach ($index in 1..128) {
    @{ Pid = 50000 + $index; Token = 'unrelated'; Parent = 60000; ParentToken = 'unrelated' } | ConvertTo-Json | Set-Content (Join-Path $registry "unrelated$index.json")
}
$oldRegistry = $env:RUNNER_OWNERSHIP_ROOT
$env:RUNNER_OWNERSHIP_ROOT = $registry
$failed = 0
try {
    foreach ($script in @('Test-RunnerDiagnosticCleanup.ps1', 'Test-RunnerDiagnosticDeadline.ps1')) {
        $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', (Join-Path $PSScriptRoot $script))) {
            [void]$info.ArgumentList.Add($argument)
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                $process.Kill($true)
                $process.WaitForExit()
                throw 'Harness failed: unchanged architecture guard expired. Stop this stage.'
            }
            "FIXTURE $script seconds=$($watch.Elapsed.TotalSeconds) exit=$($process.ExitCode)"
            $stdout.GetAwaiter().GetResult()
            $stderr.GetAwaiter().GetResult()
            if ($process.ExitCode -ne 0) {
                $failed++
            }
        }
        finally {
            $process.Dispose()
        }
    }
}
finally {
    $env:RUNNER_OWNERSHIP_ROOT = $oldRegistry
}
if ($failed) {
    exit 1
}
