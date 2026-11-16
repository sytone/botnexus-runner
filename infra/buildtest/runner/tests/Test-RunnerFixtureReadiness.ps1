<#
.SYNOPSIS
Checks fixture readiness without relying on child startup timing.
.DESCRIPTION
Uses synthetic file signals and provider observations. Rejects cancellation before both
identity and partial output, unregistered descendants, and shared parallel result output.
.EXAMPLE
./Test-RunnerFixtureReadiness.ps1
.OUTPUTS
System.String. Per-case proof and actual totals; exits nonzero on failure.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('readiness-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$failed = 0
$passed = 0
try {
    try {
        $fixture = Join-Path $PSScriptRoot 'fixtures/Invoke-FixtureCommand.ps1'
        $source = [IO.File]::ReadAllText($fixture)
        if ($source -notmatch '\$resultPath' -or $source -notmatch '\$Value\.result\.txt') {
            throw 'Parallel fixture still writes the shared result.txt destination.'
        }
        $passed++
        'PASS disjoint-parallel-result'
    }
    catch {
        $failed++
        "FAIL disjoint-parallel-result: $_"
    }
    try {
        $cancel = [Threading.CancellationTokenSource]::new()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $signal = [DiagnosticFixtureCancellation]::new($root, $cancel, $clock, 9)
        try {
            $signal.Observe()
            if ($cancel.IsCancellationRequested) {
                throw 'Missing readiness cancelled the graph.'
            }
            [IO.File]::WriteAllText((Join-Path $root 'leaf.json'), '{"processId":1,"startUtc":"synthetic"}')
            $signal.Observe()
            if ($cancel.IsCancellationRequested) {
                throw 'Identity alone cancelled the graph.'
            }
            [IO.File]::WriteAllText((Join-Path $root 'partial.txt'), 'partial evidence')
            $signal.Observe()
            if (-not $cancel.IsCancellationRequested -or -not $signal.Ready) {
                throw 'Complete readiness did not cancel the original token.'
            }
            $passed++
            'PASS identity-and-partial-before-cancellation'
        }
        finally {
            $signal.Dispose()
            $cancel.Dispose()
        }
    }
    catch {
        $failed++
        "FAIL identity-and-partial-before-cancellation: $_"
    }
    try {
        $ready = Join-Path $root 'descendant.pid'
        [IO.File]::WriteAllText($ready, [string]$PID)
        $identity = Join-Path $root 'owner.identity'
        $result = Join-Path $root 'owner.result'
        $owner = @{ Identity = $identity; Result = $result; Observed = @{} }
        $fixture = Get-FixtureElapsedProvider -ReadyPath $ready -Descendant
        $seconds = & $fixture.Provider 'poll' $owner @() @()
        if ($seconds -ne 0) {
            throw 'Unregistered descendant advanced logical time.'
        }
        [IO.File]::WriteAllText($identity, 'identity')
        $owner.Observed[$PID] = @{ processId = $PID }
        $seconds = & $fixture.Provider 'poll' $owner @() @()
        if ($seconds -ne 3) {
            throw 'Registered live descendant did not establish capture readiness.'
        }
        [IO.File]::WriteAllText($result, '0')
        $seconds = & $fixture.Provider 'poll' $owner @() @()
        if ($seconds -ne 5 -or -not $fixture.State.DescendantConfirmed) {
            throw 'Launcher exit and live registered descendant did not reach logical five.'
        }
        $passed++
        'PASS registered-descendant-before-logical-deadline'
    }
    catch {
        $failed++
        "FAIL registered-descendant-before-logical-deadline: $_"
    }
    "RESULT passed=$passed failed=$failed"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
if ($failed) {
    exit 1
}
