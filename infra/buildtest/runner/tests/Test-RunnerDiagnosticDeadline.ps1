<#
.SYNOPSIS
Runs synthetic diagnostic contract regressions.
.DESCRIPTION
Uses isolated journals and owned PowerShell children, never product hosts or remote jobs.
.EXAMPLE
./Test-RunnerDiagnosticDeadline.ps1
.OUTPUTS
System.String. Actual case counts and process cleanup proof.
#>
[CmdletBinding()]
param()
# Safe regression harness: JSON fixtures and synthetic pwsh processes only.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
Import-Module (Join-Path $PSScriptRoot '../RunnerTimeout.psm1') -Force
. (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('deadline4777-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$failed = @(); $passed = 0
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
    .PARAMETER condition
    Synthetic condition control or observed value for this fixture.
    .PARAMETER message
    Synthetic message control or observed value for this fixture.
    .EXAMPLE
    Assert-DiagnosticInvariant -condition $condition -message $message
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param([bool]$condition, [string]$message)

    if (-not $condition) {
        throw $message
    }
}
$id = [guid]::NewGuid().ToString()
function Get-DiagnosticEvent {
    <#
    .SYNOPSIS
    New DiagnosticEvent for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER kind
    Synthetic kind control or observed value for this fixture.
    .PARAMETER sequence
    Synthetic sequence control or observed value for this fixture.
    .PARAMETER source
    Synthetic source control or observed value for this fixture.
    .EXAMPLE
    Get-DiagnosticEvent -kind $kind -sequence $sequence -source $source
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param([string]$kind, [int]$sequence, [string]$source = 'Example.dll')

    return [ordered]@{event = $kind; id = $id; sequence = $sequence; utc = [DateTime]::UtcNow.ToString('o'); fullyQualifiedName = 'Example.Test'; displayName = 'Example'; source = $source; processId = 123 }
}
function Get-DiagnosticEvidence {
    <#
    .SYNOPSIS
    Get DiagnosticEvidence for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .EXAMPLE
    Get-DiagnosticEvidence
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>

    Write-DiagnosticEvidence -Root $root -Project 'tests/safe/Safe.Tests.csproj' -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory $PSScriptRoot -Run ([pscustomobject]@{TimedOut = $true; ExitCode = 1 }) -HangSeconds 120 -OuterSeconds 300
}
function Write-DiagnosticJournal {
    <#
    .SYNOPSIS
    Write DiagnosticJournal for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER records
    Synthetic records control or observed value for this fixture.
    .PARAMETER name
    Synthetic name control or observed value for this fixture.
    .EXAMPLE
    Write-DiagnosticJournal -records $records -name $name
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
    param($records, [string]$name = 'events-a.jsonl')

    @($records | ForEach-Object { $_ | ConvertTo-Json -Compress }) | Set-Content (Join-Path $root $name)
}
try {
    Invoke-DiagnosticCase 'shutdown timeout requires stack evidence' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 1), (Get-DiagnosticEvent 'TestCaseEnd' 2)); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).hangEvidenceComplete) 'Shutdown timeout certified without dump.' }
    Invoke-DiagnosticCase 'duplicate end is invalid' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 1), (Get-DiagnosticEvent 'TestCaseEnd' 2), (Get-DiagnosticEvent 'TestCaseEnd' 3)); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).eventEvidenceComplete) 'Duplicate end certified.' }
    Invoke-DiagnosticCase 'end cannot pair across journals' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 1)); Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseEnd' 1)) 'events-b.jsonl'; Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).eventEvidenceComplete) 'Cross-journal end certified.'; Remove-Item (Join-Path $root 'events-b.jsonl') }
    Invoke-DiagnosticCase 'source is part of identity' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 1), (Get-DiagnosticEvent -kind 'TestCaseEnd' -sequence 2 -source 'Other.dll')); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).eventEvidenceComplete) 'Different assembly paired.' }
    Invoke-DiagnosticCase 'timestamp must be UTC' { $e = Get-DiagnosticEvent 'TestCaseStart' 1; $e.utc = 'not-a-timestamp'; Write-DiagnosticJournal @($e); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).eventEvidenceComplete) 'Invalid timestamp certified.' }
    Invoke-DiagnosticCase 'sequence must be monotonic' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 2), (Get-DiagnosticEvent 'TestCaseEnd' 1)); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).eventEvidenceComplete) 'Reversed sequence certified.' }
    Invoke-DiagnosticCase 'dump presence is not stack proof' { Write-DiagnosticJournal @((Get-DiagnosticEvent 'TestCaseStart' 1)); [IO.File]::WriteAllBytes((Join-Path $root 'empty.dmp'), [byte[]]@(1, 2, 3)); Assert-DiagnosticInvariant (-not (Get-DiagnosticEvidence).hangEvidenceComplete) 'Corrupt dump certified.' }
    Invoke-DiagnosticCase 'verified must be boolean' { $proof = [pscustomobject]@{version = 1; verified = 'true'; digest = 'exact'; runId = 'run' }; $r = [pscustomobject]@{mode = 'diagnostic'; runId = 'run'; sourceSnapshot = $proof }; $rejected = $false; try {
            Assert-DiagnosticSourceProof $r $r 'exact' 'run'
        }
        catch {
            $rejected = $true
        }; Assert-DiagnosticInvariant $rejected 'String verified accepted.' }
    Invoke-DiagnosticCase 'valid native thread stack container is recognized, truncation rejected' {
        $path = Join-Path $root 'native.dmp'; $w = [IO.BinaryWriter]::new([IO.File]::Create($path))
        try {
            $w.Write([byte[]]::new(104)); $w.BaseStream.Position = 0; $w.Write([uint32]0x504d444d); $w.BaseStream.Position = 8; $w.Write([uint32]1); $w.Write([uint32]32); $w.BaseStream.Position = 32; $w.Write([uint32]3); $w.Write([uint32]52); $w.Write([uint32]44); $w.Write([uint32]1); $w.BaseStream.Position = 80; $w.Write([uint32]8); $w.Write([uint32]96)
        }
        finally {
            $w.Dispose()
        }
        Assert-DiagnosticInvariant (Test-DiagnosticStackDump $path) 'Valid thread/stack container rejected.'
        $s = [IO.File]::OpenWrite($path); $s.SetLength(100); $s.Dispose(); Assert-DiagnosticInvariant (-not (Test-DiagnosticStackDump $path)) 'Truncated stack accepted.'; Remove-Item $path
    }
    Invoke-DiagnosticCase 'absolute watchdog captures ended-test shutdown before unchanged deadline' {
        Get-ChildItem $root -Filter 'events-*.jsonl' | Remove-Item
        $child = Join-Path $root 'child.ps1'; $dump = Join-Path $root 'dump.ps1'; $marker = Join-Path $root 'capture.json'
        Set-Content $child '$path=Join-Path $args[0] "events-host.jsonl"; $e=@{event="TestHostLaunched";sequence=1;utc=[DateTime]::UtcNow.ToString("o");processId=$PID;testHostProcessId=$PID;testHostStartUtc=(Get-Process -Id $PID).StartTime.ToUniversalTime().ToString("o");testHostStartToken=if($IsLinux){$stat=[IO.File]::ReadAllText("/proc/$PID/stat");$stat.Substring($stat.LastIndexOf([char]41)+2).Split([char]32,[StringSplitOptions]::RemoveEmptyEntries)[19]}else{(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()}}; $e | ConvertTo-Json -Compress | Set-Content $path; $id=[guid]::NewGuid().ToString(); foreach ($kind in @("TestCaseStart","TestCaseEnd")) { $e.sequence++; $e.event=$kind; $e.utc=[DateTime]::UtcNow.ToString("o"); $e.id=$id; $e.source="Synthetic.dll"; $e.fullyQualifiedName="Synthetic.Ended"; $e | ConvertTo-Json -Compress | Add-Content $path }; [IO.File]::WriteAllText((Join-Path $args[0] "host.ready"),"ready"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
        Set-Content $dump '[IO.File]::WriteAllText($args[0],($args | Select-Object -Skip 1 | ConvertTo-Json -Compress)); [Console]::WriteLine("synthetic capture");'
        $fixture = Get-FixtureElapsedProvider -ReadyPath (Join-Path $root 'host.ready') -DumpReadyPath $marker
        $run = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $child, $root) -LogPath (Join-Path $root 'child.log') -TimeoutSeconds 6 -EvidenceRoot $root -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -DumpFilePath 'pwsh' -DumpArgumentPrefix @('-NoProfile', '-File', $dump, $marker) -ElapsedSecondsProvider $fixture.Provider
        Assert-FixtureClock $fixture $run -Dump
        Assert-DiagnosticInvariant ($run.TimedOut -and $run.ElapsedSeconds -lt 7) 'Outer deadline increased.'
        Assert-DiagnosticInvariant (Test-Path $marker) "No absolute capture attempt: $($run.Captures | ConvertTo-Json -Compress)"
        $actual = @(Get-Content $marker -Raw | ConvertFrom-Json); $hostEvent = Get-Content (Join-Path $root 'events-host.jsonl') | Select-Object -First 1 | ConvertFrom-Json
        Assert-DiagnosticInvariant ($actual[0] -eq '--normal' -and $actual[1] -eq '--name' -and $actual[-1] -eq $hostEvent.testHostProcessId.ToString()) 'Wrong dump options or PID.'
        Assert-DiagnosticInvariant ($run.Captures.Count -eq 1 -and $run.Captures[0].startedSeconds -lt 5) 'Capture too late/unrecorded.'
        Assert-DiagnosticInvariant (-not (Get-Process -Id $hostEvent.testHostProcessId -ErrorAction SilentlyContinue)) 'Synthetic child survived.'
        Assert-DiagnosticInvariant (Test-Path (Join-Path $root 'events-host.jsonl')) 'Journal lost at kill.'
    }
    Invoke-DiagnosticCase 'dump subprocess hang is bounded and failure recorded' {
        $child = Join-Path $root 'child.ps1'; $dump = Join-Path $root 'dump.ps1'
        Get-ChildItem $root -Filter 'events-*.jsonl' | Remove-Item
        Remove-Item (Join-Path $root 'host.ready')
        $blockedMarker = Join-Path $root 'blocked.ready'
        $fixture = Get-FixtureElapsedProvider -ReadyPath (Join-Path $root 'host.ready') -DumpReadyPath $blockedMarker -BlockedDump
        Set-Content $dump '[IO.File]::WriteAllText($args[0],[string]$PID); [Console]::WriteLine("dump blocked"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
        $run = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $child, $root) -LogPath (Join-Path $root 'blocked.log') -TimeoutSeconds 6 -EvidenceRoot $root -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -DumpFilePath 'pwsh' -DumpArgumentPrefix @('-NoProfile', '-File', $dump, $blockedMarker) -ElapsedSecondsProvider $fixture.Provider
        Assert-FixtureClock $fixture $run -Dump -Blocked
        $blockedId = [int](Get-Content $blockedMarker); Assert-DiagnosticInvariant (-not (Get-DiagnosticFixtureLiveProcess $blockedId)) 'Blocked dump process survived.'
        Assert-DiagnosticInvariant ($run.TimedOut -and $run.ElapsedSeconds -lt 7 -and $run.Captures.Count -eq 1 -and $run.Captures[0].timedOut -and $run.Captures[0].exitCode -eq 1) 'Dump child escaped bound or failure hidden.'
        Assert-DiagnosticInvariant (-not (Test-DiagnosticStackDump $run.Captures[0].dumpPath)) 'Failed dump certified.'
    }
    Invoke-DiagnosticCase 'missing dump executable is recorded without losing deadline or journal' {
        $child = Join-Path $root 'child.ps1'
        Get-ChildItem $root -Filter 'events-*.jsonl' | Remove-Item
        Remove-Item (Join-Path $root 'host.ready')
        $fixture = Get-FixtureElapsedProvider -ReadyPath (Join-Path $root 'host.ready') -MissingDump
        $run = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $child, $root) -LogPath (Join-Path $root 'missing.log') -TimeoutSeconds 6 -EvidenceRoot $root -CaptureReserveSeconds 3 -DumpTimeoutSeconds 1 -KillReserveSeconds 1 -PollMilliseconds 50 -DumpFilePath (Join-Path $root 'missing-executable') -ElapsedSecondsProvider $fixture.Provider
        Assert-FixtureClock $fixture $run
        Assert-DiagnosticInvariant ($run.TimedOut -and $run.ElapsedSeconds -lt 7 -and $run.Captures.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($run.Captures[0].error)) 'Missing executable failure hidden.'
        Assert-DiagnosticInvariant (Test-Path (Join-Path $root 'events-host.jsonl')) 'Journal lost on capture failure.'
    }
    "RESULT passed=$passed failed=$($failed.Count)"
    if ($failed.Count) {
        throw "Regressions: $($failed -join ', ')"
    }
}
finally {
    Remove-Item $root -Recurse -Force
}
