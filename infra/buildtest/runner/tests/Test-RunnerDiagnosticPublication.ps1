<#
.SYNOPSIS
Runs synthetic diagnostic contract regressions.
.DESCRIPTION
Uses isolated journals and owned PowerShell children, never product hosts or remote jobs.
.EXAMPLE
./Test-RunnerDiagnosticPublication.ps1
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
    # Execute the candidate Stop function with only its native signal binding replaced.
    # Model anchor exit independently from live membership: Kill is not completion.
    $stopSource = (Get-Command Stop-DiagnosticOwnedProcess).ScriptBlock.ToString().Replace('[DiagnosticContainment]::KillGroup($Owner.GroupId, $signalClock, $signalDeadline)', '$Owner.Job.Kill()').Replace('Get-DiagnosticOwnedMember', 'Get-DiagnosticFixtureMember')
    $stopCandidate = [scriptblock]::Create($stopSource)
    function Get-CleanupModel {
        <#
    .SYNOPSIS
    Get CleanupModel for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER liveReads
    Synthetic liveReads control or observed value for this fixture.
    .EXAMPLE
    Get-CleanupModel -liveReads $liveReads
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
        param([int]$liveReads)

        $state = @{Killed = $false; Reads = 0; LiveReads = $liveReads; AnchorExited = $true }
        $job = [pscustomobject]@{State = $state }
        $job | Add-Member ScriptMethod Kill { $this.State.Killed = $true }
        $job | Add-Member ScriptProperty Active { $this.State.Reads++; if ($this.State.Reads -le $this.State.LiveReads) {
                return 2
            }; return 0 }
        return [pscustomobject]@{Job = $job; State = $state; Process = [pscustomobject]@{HasExited = $true }; GroupId = 2147483647; Stopped = $false }
    }
    # Linux uses live /proc membership; Windows uses the job's active count. Both
    # test doubles retain members until explicitly observed exited, not anchor exit.
    function Get-DiagnosticFixtureMember {
        <#
    .SYNOPSIS
    Get DiagnosticFixtureMember for the isolated diagnostic fixture.
    .DESCRIPTION
    Exercises the production diagnostic boundary with explicit synthetic inputs.
    .PARAMETER Owner
    Synthetic Owner control or observed value for this fixture.
    .PARAMETER RunClock
    Original supervisor clock.
    .PARAMETER DeadlineSeconds
    Original absolute deadline.
    .EXAMPLE
    Get-DiagnosticFixtureMember -Owner $Owner
    .OUTPUTS
    System.Object. Synthetic fixture observation.
    #>
        param($Owner, $RunClock, $DeadlineSeconds)

        Write-Verbose "Inert original deadline: $RunClock $DeadlineSeconds"
        if ($Owner.Job.Active -gt 0) {
            return @(101, 102)
        }; return @()
    }
    Invoke-DiagnosticCase 'stop waits beyond anchor exit until every owned member exits' {
        $owner = Get-CleanupModel 2
        $originalClock = [Diagnostics.Stopwatch]::StartNew()
        & $stopCandidate -Owner $owner -WaitTimeoutMilliseconds 500 -RunClock $originalClock -DeadlineSeconds 0.5
        Assert-DiagnosticInvariant ($owner.State.Killed -and $owner.Stopped) 'Ownership kill was not sent.'
        Assert-DiagnosticInvariant ($owner.State.AnchorExited -and $owner.State.Reads -ge 3) 'Stop accepted anchor exit while descendants were still live.'
    }
    Invoke-DiagnosticCase 'stop waits for anchor exit after live membership reaches zero' {
        $owner = Get-CleanupModel 0
        $owner.State.AnchorReads = 0
        $anchor = [pscustomobject]@{State = $owner.State }
        $anchor | Add-Member ScriptProperty HasExited { $this.State.AnchorReads++; return $this.State.AnchorReads -ge 3 }
        $owner.Process = $anchor
        $originalClock = [Diagnostics.Stopwatch]::StartNew()
        & $stopCandidate -Owner $owner -WaitTimeoutMilliseconds 500 -RunClock $originalClock -DeadlineSeconds 0.5
        Assert-DiagnosticInvariant ($owner.State.AnchorReads -ge 3) 'Stop accepted empty live membership before anchor exit was observed.'
    }
    Invoke-DiagnosticCase 'stop fails boundedly while owned descendants remain live' {
        $owner = Get-CleanupModel ([int]::MaxValue)
        $watch = [Diagnostics.Stopwatch]::StartNew(); $message = ''
        try {
            & $stopCandidate -Owner $owner -WaitTimeoutMilliseconds 30 -RunClock $watch -DeadlineSeconds 0.03
        }
        catch {
            $message = $_.Exception.Message
        }
        Assert-DiagnosticInvariant ($owner.State.Killed -and $owner.Stopped) 'Ownership kill was not sent before waiting.'
        Assert-DiagnosticInvariant ($message -match 'Owned processes still live at cleanup deadline') 'Live descendants did not produce the explicit cleanup-deadline failure.'
        Assert-DiagnosticInvariant ($owner.State.Reads -gt 1 -and $watch.Elapsed.TotalMilliseconds -ge 30 -and $watch.Elapsed.TotalSeconds -lt 2) 'Cleanup did not honor its single absolute deadline.'
    }
    Invoke-DiagnosticCase 'default stop remains nonblocking for shared supervisor deadline' {
        $owner = Get-CleanupModel ([int]::MaxValue)
        & $stopCandidate -Owner $owner
        Assert-DiagnosticInvariant ($owner.State.Killed -and $owner.Stopped -and $owner.State.Reads -eq 0) 'Default stop acquired a per-owner wait.'
    }
    Remove-Item Function:Get-DiagnosticOwnedMember
    # Restore the real production membership query for all native publication cases.
    . (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
    foreach ($scenario in @(@{Name = 'success'; Code = 0 }, @{Name = 'nonzero'; Code = 23 }, @{Name = 'launch failure'; Code = 1 })) {
        Invoke-DiagnosticCase "owned completion is atomic: $($scenario.Name)" {
            $directory = Join-Path $root ([guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($directory)
            $result = Join-Path $directory 'command.result'; $configuration = Join-Path $directory 'command.json'
            $config = @{file = 'pwsh'; arguments = @('-NoProfile', '-Command', "exit $($scenario.Code)"); release = (Join-Path $directory 'release'); result = $result; identity = (Join-Path $directory 'identity'); error = (Join-Path $directory 'error') }
            if ($scenario.Name -eq 'launch failure') {
                $config.file = Join-Path $directory 'missing-executable'
            }
            $config | ConvertTo-Json | Set-Content $configuration
            [IO.File]::WriteAllText($config.release, 'go')
            # Execute the candidate wrapper, changing only its WriteAllText binding.
            # The test double exposes the create-before-write window deterministically.
            $driver = Join-Path $directory 'publication.ps1'
            Set-Content $driver '. $args[0]; [DiagnosticFixturePublication]::Result=$args[3]; $source=[IO.File]::ReadAllText($args[1]).Replace("[IO.File]::WriteAllText(","[DiagnosticFixturePublication]::WriteAllText("); & ([scriptblock]::Create($source)) -Configuration $args[2]'
            # One original lifecycle: launch cutoff1; stop waits at most5 seconds
            # within absolute cutoff10; final proof and marker waits also end at10.
            # The existing15-second marker guard can only restrict that allowance.
            $publicationClock = [Diagnostics.Stopwatch]::StartNew()
            try {
                $owner = New-DiagnosticOwnedProcess 'pwsh' @('-NoProfile', '-File', $driver, (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1'), (Join-Path $PSScriptRoot '../Invoke-DiagnosticOwnedCommand.ps1'), $configuration, $result) $directory 'publication' -RunClock $publicationClock -DeadlineSeconds 1
            }
            catch {
                Write-Output "PUBLICATION_PRIMARY_ERROR real=$($publicationClock.Elapsed.TotalSeconds) error=$($_.Exception.Message) phases=$(@(Get-DiagnosticPhaseEvidence) | ConvertTo-Json -Depth 6 -Compress)"
                throw
            }
            try {
                [DiagnosticFixtureSignal]::Wait("$result.opened", $publicationClock, 10)
                $opened = if ([IO.File]::Exists("$result.tmp")) {
                    "$result.tmp"
                }
                else {
                    $result
                }
                $visible = [IO.File]::Exists($result)
                if ($visible) {
                    $reader = [IO.StreamReader]::new([IO.FileStream]::new($result, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
                    try {
                        $partial = $reader.ReadToEnd(); "PROOF partialVisible=True bytes=$($partial.Length) legacyExitCode=$([int]$partial)"
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
                Assert-DiagnosticInvariant (-not $visible) 'Completion became visible before exit-code bytes were written.'
                Assert-DiagnosticInvariant ([IO.File]::Exists($opened) -and ([IO.FileInfo]::new($opened)).Length -eq 0) 'Handshake did not pause an empty publication file.'
                [IO.File]::WriteAllText("$result.continue", 'go')
                [DiagnosticFixtureSignal]::Wait($result, $publicationClock, 10)
                $reader = [IO.StreamReader]::new([IO.FileStream]::new($result, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)))
                try {
                    $published = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }
                Assert-DiagnosticInvariant ($published -ceq [string]$scenario.Code) 'Published exit code was lost or changed.'
                Assert-DiagnosticInvariant (-not [IO.File]::Exists($opened)) 'Publication temporary file was not renamed.'
                if ($scenario.Name -eq 'launch failure') {
                    Assert-DiagnosticInvariant ([IO.File]::Exists($config.error) -and [IO.File]::ReadAllText($config.error).Length -gt 0) 'Launch failure error was lost.'
                }
                "PROOF partialVisible=False publishedExitCode=$published"
            }
            catch {
                Write-Output "PUBLICATION_PRIMARY_ERROR real=$($publicationClock.Elapsed.TotalSeconds) error=$($_.Exception.Message) phases=$(@(Get-DiagnosticPhaseEvidence) | ConvertTo-Json -Depth 6 -Compress)"
                throw
            }
            finally {
                try {
                    [IO.File]::WriteAllText("$result.continue", 'go')
                    Stop-DiagnosticOwnedProcess $owner -WaitTimeoutMilliseconds 5000 -RunClock $publicationClock -DeadlineSeconds 10
                    Assert-DiagnosticInvariant ($owner.Process.HasExited) 'Publication containment anchor survived cleanup.'
                    Assert-DiagnosticInvariant (@(Get-DiagnosticOwnedMember $owner -RunClock $publicationClock -DeadlineSeconds 10).Count -eq 0) 'Publication descendants survived cleanup.'
                    Assert-DiagnosticInvariant ($publicationClock.Elapsed.TotalSeconds -lt 10) 'Publication cleanup certification deadline expired.'
                }
                finally {
                    try {
                        $owner.Process.Dispose()
                    }
                    finally {
                        if ($null -ne $owner.Job) {
                            $owner.Job.Dispose()
                        }
                    }
                }
            }
        }
    }
    "RESULT passed=$passed failed=$($failed.Count)"
    if ($failed.Count) {
        throw "Regressions: $($failed -join ', ')"
    }
}
finally {
    Remove-Item $root -Recurse -Force
}
