<#
.SYNOPSIS
Reproduces candidate diagnostic fixtures under an inherited Linux ownership registry.
.DESCRIPTION
Synthetic PowerShell children only. Retains actual output and caps the reproducer below
unchanged architecture guard. Does not launch dotnet, product hosts or network commands.
.PARAMETER ScratchRoot
Owned ephemeral directory for registry and observations.
.EXAMPLE
./Test-RunnerCoreRuntime.ps1 -ScratchRoot /tmp/core-runtime
.OUTPUTS
System.String. Per-fixture output, duration and completion observations.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$oldRegistry = $env:RUNNER_OWNERSHIP_ROOT
$cases = [Collections.Generic.List[object]]::new()
try {
    $registry = Join-Path $ScratchRoot 'registry'
    New-Item -ItemType Directory -Path $registry | Out-Null
    # Reproduce production's wider inventory: unrelated published records remain
    # valid but must never become owned by these fixture generations.
    foreach ($index in 1..128) {
        @{ Pid = 50000 + $index; Token = 'unrelated'; Parent = 60000; ParentToken = 'unrelated' } | ConvertTo-Json | Set-Content (Join-Path $registry "unrelated$index.json")
    }
    $env:RUNNER_OWNERSHIP_ROOT = $registry
    foreach ($script in @('Test-RunnerDiagnosticCleanup.ps1', 'Test-RunnerDiagnosticDeadline.ps1')) {
        $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', (Join-Path $PSScriptRoot $script))) {
            [void]$info.ArgumentList.Add($argument)
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $process = [Diagnostics.Process]::Start($info)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $exited = $process.WaitForExit(25000)
        if (-not $exited) {
            $process.Kill($true); $process.WaitForExit()
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        Write-Output "FIXTURE $script completed=$exited seconds=$($clock.Elapsed.TotalSeconds)"
        Write-Output $output
        $cases.Add(@{ name = $script; completed = $exited; exitCode = $process.ExitCode; seconds = $clock.Elapsed.TotalSeconds; output = $output; passed = ($exited -and $process.ExitCode -eq 0) })
        $process.Dispose()
    }
}
finally {
    $env:RUNNER_OWNERSHIP_ROOT = $oldRegistry
}
$cases.ToArray() | ConvertTo-Json -Depth 6
if (@($cases | Where-Object { -not $_.passed }).Count) {
    exit 1
}
