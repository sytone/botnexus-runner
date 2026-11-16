<#
.SYNOPSIS
Verifies that canonical TRX parsing requires explicit caller skip policy.
.DESCRIPTION
Uses synthetic evidence only. Tests generic denial, explicit policy, failure precedence,
unknown reasons, counter arithmetic and duplicate evidence without product hosts.
.PARAMETER EvidenceRoot
Absent owned directory for fixture evidence and case results.
.EXAMPLE
./Test-RunnerSkipPolicy.ps1 -EvidenceRoot /work/skip-policy
.OUTPUTS
System.String. Per-case results and JSON counts; exits nonzero on any failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerResult.ps1')
if (Test-Path -LiteralPath $EvidenceRoot) {
    throw 'Fixture directory must be absent.'
}
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
$cases = [Collections.Generic.List[object]]::new()
foreach ($name in @('no-application-default', 'explicit-policy', 'fixture-overrides-policy', 'unknown-reason', 'impossible-arithmetic', 'duplicate-evidence')) {
    try {
        $reason = switch ($name) {
            'no-application-default' {
                'GITHUB_TOKEN environment variable not set'
            }
            'fixture-overrides-policy' {
                'Fixture init failed: synthetic deliberate skip. exit 1'
            }
            'unknown-reason' {
                'undeclared synthetic reason'
            }
            default {
                'synthetic deliberate skip'
            }
        }
        $escaped = [Security.SecurityElement]::Escape($reason)
        $executed = if ($name -eq 'impossible-arithmetic') {
            9
        }
        else {
            1
        }
        $path = Join-Path $EvidenceRoot "$name.trx"
        $xml = "<TestRun><Results><UnitTestResult testName=`"passing`" outcome=`"Passed`"/><UnitTestResult testName=`"skipped`" outcome=`"NotExecuted`"><Output><ErrorInfo><Message>$escaped</Message></ErrorInfo></Output></UnitTestResult></Results><ResultSummary><Counters total=`"2`" executed=`"$executed`" passed=`"1`" failed=`"0`" error=`"0`" timeout=`"0`" aborted=`"0`" notExecuted=`"1`" notRunnable=`"0`" inconclusive=`"0`"/></ResultSummary></TestRun>"
        [IO.File]::WriteAllText($path, $xml)
        $parameters = @{ TrxPaths = @($path) }
        if ($name -ne 'no-application-default') {
            $parameters.DeliberateSkipPatterns = @('synthetic deliberate skip')
        }
        if ($name -eq 'duplicate-evidence') {
            $parameters.TrxPaths = @($path, $path)
        }
        $result = Get-RunnerTestResult @parameters
        $expected = switch ($name) {
            'explicit-policy' {
                $null
            }
            'impossible-arithmetic' {
                'impossible-test-counters'
            }
            'duplicate-evidence' {
                'duplicate-test-evidence'
            }
            default {
                'fixture-failures'
            }
        }
        if ($result.failureReason -cne $expected -or $result.isComplete -ne ($name -eq 'explicit-policy')) {
            throw "Unexpected verdict: $($result | ConvertTo-Json -Compress)"
        }
        $cases.Add(@{ name = $name; passed = $true })
        Write-Output "PASS $name"
    }
    catch {
        $cases.Add(@{ name = $name; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${name}: $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ total = $cases.Count; passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'cases.json')
if ($failed) {
    exit 1
}
