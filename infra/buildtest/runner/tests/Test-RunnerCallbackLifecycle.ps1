<#
.SYNOPSIS
Checks persistent and one-shot elapsed callback faults with real owned child pipes.
.DESCRIPTION
Uses the actual native supervisor, nonblocking readiness observations, and unchanged
six-second lifecycle budget. Requires original error retention, no callback replay,
pipe disposal and final publication after the callback fails.
.PARAMETER ScratchRoot
Isolated writable fixture directory.
.EXAMPLE
./Test-RunnerCallbackLifecycle.ps1 -ScratchRoot /tmp/callback-lifecycle
.OUTPUTS
System.String. Actual callback counts and failure-retention assertions.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$failures = 0
foreach ($persistent in @($true, $false)) {
    $directory = Join-Path $ScratchRoot ([string]$persistent)
    New-Item -ItemType Directory -Path $directory | Out-Null
    $marker = Join-Path $directory 'ready'
    $child = Join-Path $directory 'child.ps1'
    Set-Content $child '[Console]::WriteLine("callback stdout"); [Console]::Error.WriteLine("callback stderr"); [IO.File]::WriteAllText($args[0],"ready"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
    $state = @{ Marker = $marker; Persistent = $persistent; Faulted = $false; Replayed = 0; Calls = 0; Handle = $null; Reader = $null }
    $provider = {
        param($Phase, $Owner, $DumpChildren, $Captures)
        $state.Calls++
        Write-Verbose "$Phase $DumpChildren $Captures"
        if ($state.Faulted) {
            $state.Replayed++
            if ($state.Persistent) {
                throw 'Persistent elapsed callback failure'
            }
        }
        if (-not $state.Faulted -and [IO.File]::Exists($state.Marker)) {
            $state.Handle = $Owner.Process.SafeHandle
            $state.Reader = $Owner.Process.StandardError
            $state.Faulted = $true
            throw 'Original elapsed callback failure'
        }
        return 0.25
    }.GetNewClosure()
    try {
        $run = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $child, $marker) -LogPath (Join-Path $directory 'run.log') -TimeoutSeconds 6 -EvidenceRoot $directory -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -ElapsedSecondsProvider $provider
        if (-not $state.Faulted) {
            $retained = Get-DiagnosticFailureEnvelope -Run $run
            Write-Output "CALLBACK_FAILED_RUN $retained"
            Set-Content (Join-Path $directory 'callback-failed-run.json') $retained
            throw 'HARNESS readiness failed: child never signalled within original execution budget. Stop runtime checks.'
        }
        if ($state.Replayed -ne 0) {
            throw "Faulted provider replayed $($state.Replayed) times"
        }
        if ($run.ExitCode -eq 0 -or $run.CleanupComplete -or ($run.CleanupErrors -join ' ') -notmatch 'Original elapsed callback failure') {
            throw 'Callback error lost or cleanup falsely certified'
        }
        if ($run.ElapsedSeconds -ne 0.25 -or -not $state.Handle.IsClosed) {
            throw 'Cached successful elapsed or process disposal missing'
        }
        $disposed = $false
        try {
            $null = $state.Reader.Peek()
        }
        catch [ObjectDisposedException] {
            $disposed = $true
        }
        if (-not $disposed) {
            throw 'Nonempty pipe reader not disposed'
        }
        $log = Get-Content (Join-Path $directory 'run.log') -Raw
        if (-not $log.Contains('callback stdout') -or -not $log.Contains('callback stderr') -or -not (Test-Path (Join-Path $directory 'absolute-captures.json')) -or -not (Test-Path (Join-Path $directory 'supervision-state.json'))) {
            throw 'Nonempty child output or final publication lost'
        }
        "PASS persistent=$persistent calls=$($state.Calls) replay=$($state.Replayed) elapsed=$($run.ElapsedSeconds) disposed=$($state.Handle.IsClosed) cleanup=$($run.CleanupComplete)"
    }
    catch {
        if ($_.Exception.Message -like 'HARNESS readiness failed*') {
            throw
        }
        $failures++
        "FAIL persistent=${persistent}: $($_.Exception.Message)"
    }
}
if ($failures) {
    throw "Callback regressions failed=$failures"
}
