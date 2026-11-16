<#
.SYNOPSIS
Provides deterministic logical time for synthetic ownership and publication tests.
.DESCRIPTION
Coordinates real child readiness with file-change signals. Does not launch product hosts.
.EXAMPLE
. ./Test-Test-DiagnosticFixtureClock.ps1
.OUTPUTS
None. Declares fixture helpers and in-process signal types.
#>
[CmdletBinding()]
param()
# Test-only logical time, driven by actual atomic readiness markers and owned results.
# The real architecture harness retains its one-minute emergency guard.
if (-not ('DiagnosticFixtureSignal' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
// Fault injection at the real wrapper's WriteAllText calls: hold the file open
// after creation, before writing any bytes. File markers order both processes.
public static class DiagnosticFixturePublication
{
    public static string Result;
    public static void WriteAllText(string path, string text)
    {
        if (path != Result && path != Result + ".tmp") { File.WriteAllText(path, text); return; }
        using (var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
        {
            File.WriteAllText(Result + ".opened.tmp", path);
            File.Move(Result + ".opened.tmp", Result + ".opened");
            DiagnosticFixtureSignal.Wait(Result + ".continue");
            using var writer = new StreamWriter(stream);
            writer.Write(text);
        }
    }
}
// A native watcher cancels only after both leaf publications. No timer guesses,
// PowerShell callbacks on foreign threads, new sleeps, or replacement run clock.
public sealed class DiagnosticFixtureCancellation : IDisposable
{
    private readonly string root;
    private readonly CancellationTokenSource cancellation;
    private readonly System.Diagnostics.Stopwatch clock;
    private readonly double deadline;
    private readonly FileSystemWatcher watcher;
    private readonly object gate = new object();
    private bool disposed;
    public bool Ready { get; private set; }
    public double ReadySeconds { get; private set; }
    public DiagnosticFixtureCancellation(string root, CancellationTokenSource cancellation,
        System.Diagnostics.Stopwatch clock, double deadline)
    {
        this.root = root; this.cancellation = cancellation;
        this.clock = clock; this.deadline = deadline;
        watcher = new FileSystemWatcher(root);
        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite;
        watcher.Created += (_, e) => Observe();
        watcher.Changed += (_, e) => Observe();
        watcher.Renamed += (_, e) => Observe();
        watcher.EnableRaisingEvents = true;
        Observe();
    }
    public void Observe()
    {
        lock (gate)
        {
            if (disposed || Ready || clock.Elapsed.TotalSeconds >= deadline) return;
            try
            {
                var identity = Path.Combine(root, "leaf.json");
                var partial = Path.Combine(root, "partial.txt");
                if (!File.Exists(identity) || !File.Exists(partial)) return;
                using var document = System.Text.Json.JsonDocument.Parse(File.ReadAllText(identity));
                if (!document.RootElement.TryGetProperty("processId", out _) ||
                    !document.RootElement.TryGetProperty("startUtc", out _) ||
                    File.ReadAllText(partial) != "partial evidence") return;
                ReadySeconds = clock.Elapsed.TotalSeconds;
                Ready = true;
                cancellation.Cancel();
            }
            catch (IOException) { } // A writer still owns an incomplete publication.
            catch (System.Text.Json.JsonException) { }
        }
    }
    public void Dispose()
    {
        lock (gate) { disposed = true; }
        watcher.Dispose();
    }
}
public static class DiagnosticFixtureSignal
{
    public static void Wait(string path) => Wait(path, System.Diagnostics.Stopwatch.StartNew(), 15);
    public static void Wait(string path, System.Diagnostics.Stopwatch clock, double deadlineSeconds)
    {
        if (clock.Elapsed.TotalSeconds >= deadlineSeconds)
            throw new TimeoutException("Fixture readiness deadline exhausted: " + path);
        using var signal = new ManualResetEventSlim(false);
        using var watcher = new FileSystemWatcher(Path.GetDirectoryName(path));
        watcher.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite;
        FileSystemEventHandler changed = (_, e) => signal.Set();
        RenamedEventHandler renamed = (_, e) => signal.Set();
        watcher.Created += changed;
        watcher.Changed += changed;
        watcher.Renamed += renamed;
        watcher.EnableRaisingEvents = true;
        var guard = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            signal.Reset();
            if (clock.Elapsed.TotalSeconds >= deadlineSeconds)
                throw new TimeoutException("Fixture readiness deadline exhausted: " + path);
            if (File.Exists(path)) return;
            var remaining = TimeSpan.FromSeconds(Math.Min(15 - guard.Elapsed.TotalSeconds, deadlineSeconds - clock.Elapsed.TotalSeconds));
            if (remaining <= TimeSpan.Zero || !signal.Wait(remaining))
                throw new TimeoutException("Fixture readiness not signalled: " + path);
        }
    }
}
'@
}
function Get-FixtureElapsedProvider {
    <#
    .SYNOPSIS
    Creates a logical clock driven by real child readiness.
    .DESCRIPTION
    Returns a nonblocking file-observation closure. Missing readiness returns the last
    logical value; only the supervisor's original real clock bounds startup and teardown.
    .PARAMETER ReadyPath
    Atomic child readiness marker.
    .PARAMETER DumpReadyPath
    Capture child readiness marker.
    .PARAMETER BlockedDump
    Simulates a capture that consumes its budget.
    .PARAMETER MissingDump
    Simulates a capture executable that cannot start.
    .PARAMETER Descendant
    Requires launcher completion while its descendant remains live.
    .EXAMPLE
    Get-FixtureElapsedProvider -ReadyPath /fixture/ready -Descendant
    .OUTPUTS
    System.Collections.Hashtable. Provider closure and shared state.
    #>

    param([string]$ReadyPath, [string]$DumpReadyPath = '', [switch]$BlockedDump, [switch]$MissingDump, [switch]$Descendant)
    $state = @{Seconds = 0.0; Ready = $ReadyPath; DumpReady = $DumpReadyPath; Blocked = $BlockedDump.IsPresent; Missing = $MissingDump.IsPresent; Descendant = $Descendant.IsPresent; DumpConfirmed = $false; BudgetAdvanced = $false; CaptureBeforeKill = $false; DescendantConfirmed = $false; Observations = [Collections.Generic.List[object]]::new() }
    $readLiveProcess = ${function:Get-DiagnosticFixtureLiveProcess}
    $provider = {
        param($Phase, $Owner, $DumpChildren, $Captures)
        $state.Observations.Add(@{ phase = $Phase; seconds = $state.Seconds; ready = [IO.File]::Exists($state.Ready); identity = $null -ne $Owner -and [IO.File]::Exists($Owner.Identity) })
        if ($state.Seconds -eq 0) {
            if (-not [IO.File]::Exists($state.Ready)) {
                return $state.Seconds
            }
            if ($state.Descendant) {
                if ($null -eq $Owner -or -not [IO.File]::Exists($Owner.Identity)) {
                    return $state.Seconds
                }
                $leafId = [int][IO.File]::ReadAllText($state.Ready)
                if (-not $Owner.Observed.ContainsKey($leafId)) {
                    return $state.Seconds
                }
                $live = & $readLiveProcess $leafId
                if ($null -eq $live) {
                    throw 'Registered descendant exited before readiness.'
                }
                $live.Dispose()
                $state.DescendantConfirmed = $true
            }
            $state.Seconds = 3.0
        }
        elseif ($Phase -eq 'poll' -and $state.Descendant) {
            # Prove launcher exit before the deadline, with the inherited-pipe leaf live.
            if (-not [IO.File]::Exists($Owner.Result)) {
                return $state.Seconds
            }
            if ([IO.File]::ReadAllText($Owner.Result) -ne '0') {
                throw 'Synthetic launcher failed.'
            }
            $leafId = [int][IO.File]::ReadAllText($state.Ready)
            $live = & $readLiveProcess $leafId
            if ($null -eq $live) {
                throw 'Leaf exited before containment cleanup.'
            }
            $live.Dispose()
            $state.Seconds = 5.0
        }
        elseif ($DumpChildren.Count -gt 0) {
            $child = $DumpChildren[0]
            if ($state.Missing) {
                if ($null -eq $child.Record.exitCode -and -not [IO.File]::Exists($child.Owner.Result)) {
                    return $state.Seconds
                }
                if ($Phase -eq 'poll' -and $null -ne $child.Record.exitCode) {
                    $state.Seconds = 5.0
                }
            }
            elseif (-not $state.DumpConfirmed) {
                # Identity confirms Process.Start, marker confirms the dump script itself ran.
                if (-not [IO.File]::Exists($child.Owner.Identity) -or -not [IO.File]::Exists($state.DumpReady)) {
                    return $state.Seconds
                }
                if (-not $state.Blocked -and -not [IO.File]::Exists($child.Owner.Result)) {
                    return $state.Seconds
                }
                $state.DumpConfirmed = $true
            }
            elseif ($Phase -eq 'poll' -and $child.LaunchConfirmed -and -not $state.BudgetAdvanced -and $state.Blocked) {
                if ($child.Deadline -ne 4.0) {
                    throw "Dump budget is not one logical second after confirmed startup: $($child.Deadline)"
                }
                $state.Seconds = 4.0; $state.BudgetAdvanced = $true
            }
            elseif ($Phase -eq 'poll' -and $null -ne $child.Record.exitCode) {
                $state.CaptureBeforeKill = $Captures.Count -eq 1 -and $state.DumpConfirmed
                $state.Seconds = 5.0
            }
        }
        return $state.Seconds
    }.GetNewClosure()
    return @{Provider = $provider; State = $state }
}
function Assert-FixtureClock {
    <#
    .SYNOPSIS
    Requires deadline, capture and cleanup proof.
    .DESCRIPTION
    Checks actual owned-process results against injected logical phase transitions.
    .PARAMETER Fixture
    Closure state returned by Get-FixtureElapsedProvider.
    .PARAMETER Run
    Actual diagnostic supervisor result.
    .PARAMETER Dump
    Requires capture before termination.
    .PARAMETER Blocked
    Requires capture budget exhaustion.
    .EXAMPLE
    Assert-FixtureClock $fixture $result -Dump
    .OUTPUTS
    System.String. Observed proof summary.
    #>
    param($fixture, $run, [switch]$Dump, [switch]$Blocked)
    if ($fixture.State.Seconds -ne 5 -or -not $run.CleanupComplete) {
        # Captured values only: no marker/provider/clock observation or new wait.
        $predicate = if ($fixture.State.Seconds -ne 5 -or $run.ElapsedSeconds -ne 5) {
            'logical-deadline'
        }
        else {
            'containment-cleanup'
        }
        "FIXTURE_FAILED_RUN $(Get-DiagnosticFailureEnvelope -Run $run)"
        "FIXTURE_FAILURE_STATE predicate=$predicate logical=$($fixture.State.Seconds) descendant=$($fixture.State.Descendant) registeredDescendant=$($fixture.State.DescendantConfirmed) observations=$($fixture.State.Observations | ConvertTo-Json -Compress) dumpRequired=$($Dump.IsPresent) blockedRequired=$($Blocked.IsPresent) dumpConfirmed=$($fixture.State.DumpConfirmed) budgetAdvanced=$($fixture.State.BudgetAdvanced) captureBeforeKill=$($fixture.State.CaptureBeforeKill)"
        "STATE real=$($run.RealElapsedSeconds) logical=$($run.ElapsedSeconds) owners=$($run.PhaseState | ConvertTo-Json -Compress) errors=$($run.CleanupErrors -join ' | ') output=$($run.OutputTail)"
    }
    Assert-DiagnosticInvariant ($fixture.State.Seconds -eq 5 -and $run.ElapsedSeconds -eq 5) "Logical outer kill deadline did not execute. Actual errors: $($run.CleanupErrors -join ' | ')"
    Assert-DiagnosticInvariant ($run.TimedOut -and $run.CleanupComplete -and $run.DrainComplete -and $run.ReadersClosed) "Real containment/EOF cleanup failed. Actual errors: $($run.CleanupErrors -join ' | ')"
    foreach ($identity in $run.OwnedProcesses) {
        Assert-DiagnosticInvariant (-not (Get-DiagnosticFixtureLiveProcess $identity.processId)) "Observed owned process survived: $($identity.processId)"
    }
    if ($Dump) {
        Assert-DiagnosticInvariant ($fixture.State.DumpConfirmed -and $fixture.State.CaptureBeforeKill -and $run.Captures[0].startedSeconds -eq 3) 'Capture startup was not proven before logical kill.'
    }
    if ($Blocked) {
        Assert-DiagnosticInvariant ($fixture.State.BudgetAdvanced -and $run.Captures[0].timedOut) 'Confirmed dump did not consume its one-second logical budget.'
    }
    "PROOF logicalElapsed=$($run.ElapsedSeconds) captureBeforeKill=$($fixture.State.CaptureBeforeKill) dumpReady=$($fixture.State.DumpConfirmed) dumpBudgetAdvanced=$($fixture.State.BudgetAdvanced) cleanup=$($run.CleanupComplete) EOF=$($run.DrainComplete) readersClosed=$($run.ReadersClosed)"
}
function Get-DiagnosticFixtureLiveProcess {
    <#
    .SYNOPSIS
    Reads a live fixture process without counting Linux zombies.
    .DESCRIPTION
    Returns null after termination. Callers must dispose any returned process handle.
    .PARAMETER ProcessId
    Observed owned child process identifier.
    .EXAMPLE
    Get-DiagnosticFixtureLiveProcess -ProcessId 123
    .OUTPUTS
    System.Diagnostics.Process. Live process or null.
    #>
    param([int]$processId)
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if ($IsLinux -and $null -ne $process) {
        $stat = [IO.File]::ReadAllText("/proc/$processId/stat")
        if ($stat.Substring($stat.LastIndexOf(')') + 2).StartsWith('Z ')) {
            $process.Dispose(); return $null
        }
    }
    return $process
}
