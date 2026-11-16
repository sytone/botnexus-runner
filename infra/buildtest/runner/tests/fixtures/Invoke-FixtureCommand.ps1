<#
.SYNOPSIS
Writes literal argument evidence for a synthetic project.
.DESCRIPTION
Used only by runner contract fixtures. Can coordinate two bounded children, fail, or leave
an owned descendant running so the existing ownership helper must clean it up.
.PARAMETER Value
Literal value written without interpolation. Parallel peers use Value.result.txt;
other modes use result.txt.
.PARAMETER Mode
Synthetic behavior to exercise.
.PARAMETER Peer
Peer marker required before a parallel fixture may finish.
.EXAMPLE
./Invoke-FixtureCommand.ps1 -Value 'literal ; $value with spaces'
.OUTPUTS
System.String. Synthetic completion message.
#>
[CmdletBinding()]
param(
    [string]$Value = 'fixture',
    [ValidateSet('write', 'parallel', 'orphan', 'dependent', 'environment')][string]$Mode = 'write',
    [string]$Peer = ''
)
$ErrorActionPreference = 'Stop'
if ($Mode -eq 'parallel') {
    [IO.File]::WriteAllText("$Value.ready", 'ready')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists("$Peer.ready")) {
        if ($clock.Elapsed.TotalSeconds -gt 6) {
            throw 'Parallel sibling did not start within bounded handshake.'
        }
        Start-Sleep -Milliseconds 10
    }
    [IO.File]::WriteAllText("$Value.complete", 'complete')
}
elseif ($Mode -eq 'dependent') {
    if (-not [IO.File]::Exists('debug.complete') -or -not [IO.File]::Exists('release.complete')) {
        throw 'Dependency started before prerequisites completed.'
    }
}
elseif ($Mode -eq 'orphan') {
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute = $false
    foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')) {
        [void]$info.ArgumentList.Add($argument)
    }
    $child = [Diagnostics.Process]::Start($info)
    try {
        [IO.File]::WriteAllText('descendant.json', (@{ processId = $child.Id
                    startUtc = $child.StartTime.ToUniversalTime().ToString('o')
                } | ConvertTo-Json))
    }
    finally {
        $child.Dispose()
    }
}
elseif ($Mode -eq 'environment') {
    if ([Environment]::GetEnvironmentVariable('RUNNER_FIXTURE_SECRET')) {
        throw 'Secret-bearing parent variable leaked into project child.'
    }
}
# Parallel peers own disjoint result files; only the dependent writes result.txt.
$resultPath = if ($Mode -eq 'parallel') {
    "$Value.result.txt"
}
else {
    'result.txt'
}
[IO.File]::WriteAllText($resultPath, $Value)
Write-Output 'layout completed'
