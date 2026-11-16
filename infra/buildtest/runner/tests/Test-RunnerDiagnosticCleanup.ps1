<#
.SYNOPSIS
Runs synthetic diagnostic contract regressions.
.DESCRIPTION
Uses isolated journals and owned PowerShell children, never product hosts or remote jobs.
.EXAMPLE
./Test-RunnerDiagnosticCleanup.ps1
.OUTPUTS
System.String. Actual case counts and process cleanup proof.
#>
[CmdletBinding()]
param()
# Synthetic pwsh-only containment and concurrent journal regressions; no gateway/testhost.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
. (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('cleanup4777-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$passed = 0; $failed = @()
function Invoke-DiagnosticCase {
    <#
    .SYNOPSIS
    Invoke DiagnosticCase for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER name
    Synthetic name control or observed value for this fixture.
    .PARAMETER body
    Synthetic body control or observed value for this fixture.
    .EXAMPLE
    Invoke-DiagnosticCase -name $name -body $body
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param([string]$name, [scriptblock]$body)

    try {
        & $body; $script:passed++; "PASS $name"
    }
    catch {
        $script:failed += $name; "FAIL ${name}: $_"
    }
}
function Assert-DiagnosticInvariant {
    <#
    .SYNOPSIS
    Assert DiagnosticInvariant for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER ok
    Synthetic ok control or observed value for this fixture.
    .PARAMETER message
    Synthetic message control or observed value for this fixture.
    .EXAMPLE
    Assert-DiagnosticInvariant -ok $ok -message $message
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param([bool]$ok, [string]$message)

    if (-not $ok) {
        throw $message
    }
}
function Clear-DiagnosticJournal {
    <#
    .SYNOPSIS
    Clear DiagnosticJournal for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .EXAMPLE
    Clear-DiagnosticJournal
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>

    Get-ChildItem $root -Filter 'events-*.jsonl' | Remove-Item
}
function Invoke-DiagnosticFixture {
    <#
    .SYNOPSIS
    Invoke DiagnosticFixture for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER script
    Synthetic script control or observed value for this fixture.
    .PARAMETER prefix
    Synthetic prefix control or observed value for this fixture.
    .PARAMETER fixture
    Synthetic fixture control or observed value for this fixture.
    .EXAMPLE
    Invoke-DiagnosticFixture -script $script -prefix $prefix -fixture $fixture
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param([string]$script, [string[]]$prefix = @(), $fixture)

    Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $script, $root, (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')) -LogPath (Join-Path $root 'run.log') -TimeoutSeconds 6 -EvidenceRoot $root -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -DumpFilePath 'pwsh' -DumpArgumentPrefix $prefix -ElapsedSecondsProvider $fixture.Provider
}
try {
    Invoke-DiagnosticCase 'live collector write handle permits journal snapshots' {
        $path = Join-Path $root 'events-open.jsonl'
        $writer = [IO.StreamWriter]::new([IO.FileStream]::new($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read))
        try {
            $e = @{event = 'TestCaseStart'; sequence = 1; utc = [DateTime]::UtcNow.ToString('o'); processId = 123; id = [guid]::NewGuid().ToString(); source = 'Synthetic.dll'; fullyQualifiedName = 'Synthetic.Open' }
            $writer.WriteLine(($e | ConvertTo-Json -Compress)); $writer.Flush()
            $snapshot = Read-DiagnosticEvent -Root $root -Live
            Assert-DiagnosticInvariant (-not $snapshot.Invalid -and $snapshot.Events.Count -eq 1) 'Live writer prevented journal snapshot.'
        }
        finally {
            $writer.Dispose(); Remove-Item $path
        }
    }
    Invoke-DiagnosticCase 'live trailing fragment deferred but final certification remains strict' {
        $path = Join-Path $root 'events-live.jsonl'
        [IO.File]::WriteAllText($path, '{"event":')
        $live = Read-DiagnosticEvent -Root $root -Live
        Assert-DiagnosticInvariant (-not $live.Invalid -and $live.Incomplete) 'Live partial line was treated as corruption.'
        Assert-DiagnosticInvariant (Read-DiagnosticEvent -Root $root).Invalid 'Final partial JSON accepted.'
    }
    Invoke-DiagnosticCase 'live malformed newline-terminated or middle lines remain invalid' {
        $path = Join-Path $root 'events-live.jsonl'
        [IO.File]::WriteAllText($path, ('{broken' + [Environment]::NewLine + '{"event":'))
        Assert-DiagnosticInvariant (Read-DiagnosticEvent -Root $root -Live).Invalid 'Malformed complete middle line ignored.'
        [IO.File]::WriteAllText($path, ('{broken' + [Environment]::NewLine))
        Assert-DiagnosticInvariant (Read-DiagnosticEvent -Root $root -Live).Invalid 'Malformed complete final line ignored.'
    }
    Invoke-DiagnosticCase 'launcher exits first but inherited pipes and descendant are contained' {
        Clear-DiagnosticJournal
        $leaf = Join-Path $root 'leaf.ps1'; $launcher = Join-Path $root 'Invoke-CleanupLauncher.ps1'
        Set-Content $leaf '[Console]::WriteLine("leaf stdout"); [Console]::Error.WriteLine("leaf stderr"); [IO.File]::WriteAllText((Join-Path $args[0] "leaf.pid"),[string]$PID); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
        @'
<#
.SYNOPSIS
Starts an inherited-pipe leaf and exits after its readiness publication.
.DESCRIPTION
Uses a file event, not an extra compiler or startup sleep. The original supervisor
clock still bounds the launcher and descendant, including this readiness wait.
.PARAMETER Root
Isolated fixture directory containing the leaf script.
.PARAMETER ClockHelper
Unused compatibility argument supplied by the diagnostic fixture invocation.
.EXAMPLE
./Invoke-CleanupLauncher.ps1 -Root /work/fixture -ClockHelper /source/Test-DiagnosticFixtureClock.ps1
.OUTPUTS
None. The descendant inherits stdout and stderr until containment terminates it.
#>
[CmdletBinding()]
param([string]$Root, [string]$ClockHelper)
$ErrorActionPreference = 'Stop'
$null = $ClockHelper
$watcher = [IO.FileSystemWatcher]::new($Root)
$watcher.Filter = 'leaf.pid'
$watcher.EnableRaisingEvents = $true
$info = [Diagnostics.ProcessStartInfo]::new('pwsh')
$info.UseShellExecute = $false
foreach ($argument in @('-NoProfile', '-File', (Join-Path $Root 'leaf.ps1'), $Root)) {
    [void]$info.ArgumentList.Add($argument)
}
$child = [Diagnostics.Process]::Start($info)
try {
    while (-not [IO.File]::Exists((Join-Path $Root 'leaf.pid'))) {
        $change = $watcher.WaitForChanged([IO.WatcherChangeTypes]::All, 5000)
        if ($change.TimedOut) {
            throw 'Leaf startup not ready within original allowance.'
        }
    }
}
finally {
    $watcher.Dispose()
    $child.Dispose()
}
exit 0
'@ | Set-Content -LiteralPath $launcher

        $fixture = Get-FixtureElapsedProvider -ReadyPath (Join-Path $root 'leaf.pid') -Descendant
        try {
            $r = Invoke-DiagnosticFixture -script $launcher -prefix @() -fixture $fixture
            "READINESS_OBSERVATIONS $($fixture.State.Observations | ConvertTo-Json -Compress)"
            Assert-FixtureClock $fixture $r
            Assert-DiagnosticInvariant $fixture.State.DescendantConfirmed 'Leaf identity was not observed in registered ownership before original allowance expired.'
            $leafId = [int](Get-Content (Join-Path $root 'leaf.pid'))
            $live = Get-Process -Id $leafId -ErrorAction SilentlyContinue
            if ($IsLinux -and $null -ne $live) {
                $stat = [IO.File]::ReadAllText("/proc/$leafId/stat"); if ($stat.Substring($stat.LastIndexOf([char]41) + 2).StartsWith('Z ')) {
                    $live.Dispose(); $live = $null
                }
            }
            Assert-DiagnosticInvariant ($null -eq $live) 'Descendant survived launcher exit.'
            Assert-DiagnosticInvariant ($r.CleanupComplete -and $r.DrainComplete -and $r.ReadersClosed) 'Containment or pipe cleanup not proven.'
            Assert-DiagnosticInvariant ($r.ElapsedSeconds -lt 7) 'Deadline extended during cleanup.'
            Assert-DiagnosticInvariant ((Get-Content (Join-Path $root 'run.log') -Raw).Contains('leaf stderr')) 'Pre-kill stderr lost.'
        }
        finally {
            if (Test-Path (Join-Path $root 'leaf.pid')) {
                Stop-Process -Id ([int](Get-Content (Join-Path $root 'leaf.pid'))) -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Invoke-DiagnosticCase 'partial append at first capture does not permanently suppress target' {
        Clear-DiagnosticJournal
        $child = Join-Path $root 'partial.ps1'; $dump = Join-Path $root 'complete.ps1'; $marker = Join-Path $root 'captured.txt'
        Set-Content $child '$path=Join-Path $args[0] "events-partial.jsonl"; $e=@{event="TestHostLaunched";sequence=1;utc=[DateTime]::UtcNow.ToString("o");processId=$PID;testHostProcessId=$PID;testHostStartUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o");testHostStartToken=if($IsLinux){$stat=[IO.File]::ReadAllText("/proc/$PID/stat");$stat.Substring($stat.LastIndexOf([char]41)+2).Split([char]32,[StringSplitOptions]::RemoveEmptyEntries)[19]}else{(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}}; [IO.File]::WriteAllText($path,($e | ConvertTo-Json -Compress)+[Environment]::NewLine+"{`"event`":"); [IO.File]::WriteAllText((Join-Path $args[0] "partial.ready"),"ready"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
        Set-Content $dump '$path=Join-Path $args[0] "events-partial.jsonl"; $first=(Get-Content $path | Select-Object -First 1 | ConvertFrom-Json); $e=@{event="TestCaseStart";sequence=2;utc=[DateTime]::UtcNow.ToString("o");processId=$first.processId;id=[guid]::NewGuid().ToString();source="Synthetic.dll";fullyQualifiedName="Synthetic.Partial"}; $json=$e | ConvertTo-Json -Compress; [IO.File]::WriteAllText($path,($first | ConvertTo-Json -Compress)+[Environment]::NewLine+$json+[Environment]::NewLine); [IO.File]::WriteAllText((Join-Path $args[0] "captured.txt"),"captured")'
        $fixture = Get-FixtureElapsedProvider -ReadyPath (Join-Path $root 'partial.ready') -DumpReadyPath $marker
        $r = Invoke-DiagnosticFixture -script $child -prefix @('-NoProfile', '-File', $dump, $root) -fixture $fixture
        Assert-FixtureClock $fixture $r -Dump
        Assert-DiagnosticInvariant (Test-Path $marker) "Partial line suppressed capture: $($r.Captures | ConvertTo-Json -Compress)"
        Assert-DiagnosticInvariant ($r.Captures.Count -eq 1 -and $r.Captures[0].startedSeconds -lt 5 -and $r.ElapsedSeconds -lt 7) 'Capture missed unchanged deadline.'
        Assert-DiagnosticInvariant (-not (Read-DiagnosticEvent $root).Invalid) 'Completed journal invalid at final certification.'
    }
    Invoke-DiagnosticCase 'cleanup or drain failure cannot certify evidence' {
        Clear-DiagnosticJournal
        $e = @{event = 'TestCaseStart'; sequence = 1; utc = [DateTime]::UtcNow.ToString('o'); processId = 123; id = [guid]::NewGuid().ToString(); source = 'Synthetic.dll'; fullyQualifiedName = 'Synthetic.Test' }
        $e | ConvertTo-Json -Compress | Set-Content (Join-Path $root 'events-proof.jsonl')
        $run = [pscustomobject]@{TimedOut = $true; ExitCode = 1; CleanupComplete = $false; DrainComplete = $true; ReadersClosed = $true }
        $proof = Write-DiagnosticEvidence -Root $root -Project 'tests/safe/Safe.Tests.csproj' -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory $PSScriptRoot -Run $run -HangSeconds 120 -OuterSeconds 300
        Assert-DiagnosticInvariant (-not $proof.eventEvidenceComplete) 'Incomplete cleanup certified event evidence.'
        $run.CleanupComplete = $true; $run.DrainComplete = $false
        $proof = Write-DiagnosticEvidence -Root $root -Project 'tests/safe/Safe.Tests.csproj' -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory $PSScriptRoot -Run $run -HangSeconds 120 -OuterSeconds 300
        Assert-DiagnosticInvariant (-not $proof.eventEvidenceComplete) 'Incomplete drain certified event evidence.'
    }
    "RESULT passed=$passed failed=$($failed.Count)"
    if ($failed.Count) {
        throw "Regressions: $($failed -join ', ')"
    }
}
finally {
    Remove-Item $root -Recurse -Force
}
