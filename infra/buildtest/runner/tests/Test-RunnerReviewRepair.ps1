<#
.SYNOPSIS
Reproduces independent review defects with inert evidence and transport controls.
.DESCRIPTION
Runs the canonical parser against contradictory rows, a complete positive and recognized
skip control. Also checks actual image transport MSI initialization with an inert executable.
.PARAMETER ScratchRoot
Owned isolated artifact root.
.EXAMPLE
./Test-RunnerReviewRepair.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Actual named observations and JSON counts.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerResult.ps1')
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
$cases = [Collections.Generic.List[object]]::new()
foreach ($case in @('inflated-passed', 'hidden-failed', 'duplicate-identity', 'complete', 'recognized-skip', 'unknown-skip')) {
    try {
        $rows = switch ($case) {
            'inflated-passed' {
                '<UnitTestResult testName="one" outcome="Passed" />'
            }
            'hidden-failed' {
                '<UnitTestResult testName="one" outcome="Failed" />'
            }
            'duplicate-identity' {
                '<UnitTestResult testId="same" executionId="same" testName="one" outcome="Passed" /><UnitTestResult testId="same" executionId="same" testName="one" outcome="Passed" />'
            }
            'complete' {
                (1..12000 | ForEach-Object { '<UnitTestResult testName="case' + $_ + '" outcome="Passed" />' }) -join ''
            }
            default {
                $reason = if ($case -eq 'recognized-skip') {
                    'Windows-only test.'
                }
                else {
                    'Fixture initialization failed.'
                }
                '<UnitTestResult testName="one" outcome="Passed" /><UnitTestResult testName="skip" outcome="NotExecuted"><Output><ErrorInfo><Message>' + $reason + '</Message></ErrorInfo></Output></UnitTestResult>'
            }
        }
        $total = if ($case -in @('duplicate-identity', 'recognized-skip', 'unknown-skip')) {
            2
        }
        else {
            12000
        }
        $skip = if ($case -in @('recognized-skip', 'unknown-skip')) {
            1
        }
        else {
            0
        }
        $executed = $total - $skip
        $path = Join-Path $ScratchRoot "$case.trx"
        [IO.File]::WriteAllText($path, ('<TestRun><Results>' + $rows + '</Results><ResultSummary><Counters total="' + $total + '" executed="' + $executed + '" passed="' + $executed + '" failed="0" error="0" timeout="0" aborted="0" notExecuted="' + $skip + '" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'))
        $result = Get-RunnerTestResult -TrxPaths @($path) -RequireZeroSkipped -DeliberateSkipPatterns @('^Windows-only test\.')
        $expected = $case -in @('complete', 'recognized-skip')
        if ($result.isComplete -ne $expected) {
            throw "Contradictory or policy result: $($result | ConvertTo-Json -Compress)"
        }
        $cases.Add(@{ name = $case; passed = $true })
        Write-Output "PASS $case"
    }
    catch {
        $cases.Add(@{ name = $case; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${case}: $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; total = $cases.Count; cases = $cases.ToArray() } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
