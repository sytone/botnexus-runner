<#
.SYNOPSIS
Loads or tests the runner evidence contract.
.DESCRIPTION
Uses explicit caller-owned paths and bounded synthetic fixtures. Does not launch product hosts.
.EXAMPLE
./Import-RunnerResult.ps1
.OUTPUTS
System.Object. Contract observations or fixture results.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest

# Phrasings that name a build or process failure. These are checked BEFORE the allow-list so a
# crash message can never be waved through by happening to contain an allow-listed substring.
$script:ProcessFailurePattern = 'exit \d+|exit code|Exception|Fixture (failed|init|initialization)|One or more errors occurred|could not be (created|constructed)|Class fixture|Collection fixture'

function Test-DeliberateSkipReason {
    <#
    .SYNOPSIS
    Test DeliberateSkipReason for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER DeliberateSkipPatterns
    Caller-owned regex patterns for acceptable skips. Empty by default; failures always deny.
    .PARAMETER Reason
    Explicit Reason input for this operation.
    .EXAMPLE
    Test-DeliberateSkipReason -Reason $Reason
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [string] $Reason,
        [AllowEmptyCollection()][string[]] $DeliberateSkipPatterns = @()
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return $false
    }
    if ($Reason -match $script:ProcessFailurePattern) {
        return $false
    }
    foreach ($pattern in $DeliberateSkipPatterns) {
        if ($Reason -match $pattern) {
            return $true
        }
    }
    return $false
}

function Get-RunnerTestResult {
    <#
    .SYNOPSIS
    Get RunnerTestResult for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER DeliberateSkipPatterns
    Explicit caller-owned acceptable skip regex patterns; no application defaults.
    .PARAMETER TrxPaths
    Explicit TrxPaths input for this operation.
    .PARAMETER RequireZeroSkipped
    Explicit RequireZeroSkipped input for this operation.
    .PARAMETER MinimumTotal
    Explicit MinimumTotal input for this operation.
    .EXAMPLE
    Get-RunnerTestResult -TrxPaths $TrxPaths -RequireZeroSkipped $RequireZeroSkipped -MinimumTotal $MinimumTotal
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $TrxPaths,

        [switch] $RequireZeroSkipped,

        # A collapsed run is indistinguishable from a green one if only the pass/fail ratio is
        # checked: one passing test satisfies "0 failed" exactly as well as 12,765 do. The caller
        # knows how big the suite it asked for should be, so it supplies the floor.
        [int] $MinimumTotal = 0,

        [AllowEmptyCollection()][string[]] $DeliberateSkipPatterns = @()
    )

    if ($RequireZeroSkipped) {
        Write-Verbose 'Skip acceptance uses only explicit caller patterns; unexplained skips fail closed.'
    }
    $summary = [ordered]@{
        total = 0
        executed = 0
        passed = 0
        failed = 0
        skipped = 0
        fixtureFailures = 0
        isComplete = $false
        failureReason = $null
    }

    if ($TrxPaths.Count -eq 0) {
        $summary.failureReason = 'missing-test-results'
        return [pscustomobject]$summary
    }

    $impossibleCounters = $false
    $unverifiable = $false
    $reasonedSkips = 0

    $pathComparer = if ($IsWindows) {
        [StringComparer]::OrdinalIgnoreCase
    }
    else {
        [StringComparer]::Ordinal
    }
    $evidencePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
    $evidenceContent = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $evidenceIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $TrxPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $summary.failureReason = 'missing-test-results'
            return [pscustomobject]$summary
        }

        $canonicalPath = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).ProviderPath)
        $content = [IO.File]::ReadAllBytes($canonicalPath)
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($content))
        if (-not $evidencePaths.Add($canonicalPath) -or -not $evidenceContent.Add($digest)) {
            $summary.failureReason = 'duplicate-test-evidence'
            return [pscustomobject]$summary
        }
        $trx = [xml]::new()
        $xmlStream = [IO.MemoryStream]::new($content, $false)
        try {
            $trx.Load($xmlStream)
        }
        finally {
            $xmlStream.Dispose()
        }
        $runIdentity = $trx.TestRun.GetAttribute('id')
        $counters = $trx.TestRun.ResultSummary.Counters
        if ($null -eq $counters) {
            $summary.failureReason = 'invalid-test-results'
            return [pscustomobject]$summary
        }

        $fileTotal = [int]$counters.total
        $fileExecuted = [int]$counters.executed

        # Arithmetically impossible: a run cannot execute more tests than it contains. Accepting
        # it lets a forged counter block inflate `executed` past `total` and satisfy every
        # downstream check by construction.
        if ($fileExecuted -gt $fileTotal) {
            $impossibleCounters = $true
        }

        $summary.total += $fileTotal
        $summary.executed += $fileExecuted
        $summary.passed += [int]$counters.passed
        $summary.failed += [int]$counters.failed + [int]$counters.error + [int]$counters.timeout + [int]$counters.aborted
        $summary.skipped += [int]$counters.notExecuted + [int]$counters.notRunnable + [int]$counters.inconclusive

        # Counters are the file's own claim about itself. Corroborate them against the rows:
        # 160 of the 2,214 real TRX files carry no Results node, so a counter block asserting
        # work that left no trace is a shape that occurs in practice, not just in theory.
        # Zero rows with zero executed is honest (an empty project emits exactly that), so the
        # guard fires only when a file claims to have RUN something it cannot show.
        $resultsNode = $trx.TestRun.PSObject.Properties['Results']
        $rows = @()
        if ($resultsNode -and $trx.TestRun.Results) {
            $rows = @($trx.TestRun.Results.UnitTestResult) | Where-Object { $_ }
        }
        if ($fileExecuted -gt 0 -and $rows.Count -eq 0) {
            $unverifiable = $true
        }

        # Counters are not evidence unless every row agrees, including identities/outcomes.
        $rowPassed = 0
        $rowFailed = 0
        $rowSkipped = 0
        $identities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $rows) {
            $assemblyIdentity = $row.GetAttribute('storage')
            $testIdentity = $row.GetAttribute('testId')
            $executionIdentity = $row.GetAttribute('executionId')
            $dataIdentity = $row.GetAttribute('dataRowInfo')
            $identityParts = if ($testIdentity -or $executionIdentity) {
                @($assemblyIdentity, $testIdentity, $executionIdentity, $dataIdentity)
            }
            else {
                @($assemblyIdentity, $row.GetAttribute('testName'), $row.GetAttribute('testType'), $dataIdentity)
            }
            $identity = $identityParts | ConvertTo-Json -Compress
            if (-not ($identityParts | Where-Object { $_ })) {
                $unverifiable = $true
            }
            # Evidence identity is semantic, not XML serialization. With no explicit
            # execution/run ID, the same assembly/type/name/data row cannot prove a
            # second execution. Comments, root labels and row/attribute order add none.
            $semanticTest = if ($testIdentity -or $executionIdentity) {
                @($testIdentity, $executionIdentity)
            }
            else {
                @($row.GetAttribute('testName'))
            }
            $globalIdentity = @($runIdentity, $assemblyIdentity, $row.GetAttribute('testType'),
                $semanticTest, $dataIdentity) | ConvertTo-Json -Compress -Depth 4
            if ($globalIdentity -and -not $evidenceIdentities.Add($globalIdentity)) {
                $unverifiable = $true
            }
            if (-not $identity -or -not $identities.Add($identity)) {
                $unverifiable = $true
            }
            switch ($row.GetAttribute('outcome')) {
                'Passed' {
                    $rowPassed++
                }
                'Failed' {
                    $rowFailed++
                }
                'Error' {
                    $rowFailed++
                }
                'Timeout' {
                    $rowFailed++
                }
                'Aborted' {
                    $rowFailed++
                }
                'NotExecuted' {
                    $rowSkipped++
                }
                'NotRunnable' {
                    $rowSkipped++
                }
                'Inconclusive' {
                    $rowSkipped++
                }
                default {
                    $unverifiable = $true
                }
            }
        }
        if ($rowPassed -ne [int]$counters.passed -or $rowFailed -ne ([int]$counters.failed + [int]$counters.error + [int]$counters.timeout + [int]$counters.aborted) -or
            ($rowPassed + $rowFailed) -ne $fileExecuted -or $rows.Count -ne $fileTotal) {
            $unverifiable = $true
        }
        foreach ($unit in $rows) {
            if ($unit.GetAttribute('outcome') -ne 'NotExecuted') {
                continue
            }
            $reason = $unit.Output.ErrorInfo.Message
            if (Test-DeliberateSkipReason -Reason $reason -DeliberateSkipPatterns $DeliberateSkipPatterns) {
                $reasonedSkips++
            }
            else {
                $summary.fixtureFailures++
            }
        }
    }

    # A TRX summary can under-report its own skips: on 2026-08-06 the E2E project emitted
    # notExecuted=0 while the file carried 265 results with outcome="NotExecuted", so the
    # gate reported failed=0/skipped=0 and exited 0 having actually run 15 of 280 tests.
    # total vs executed is the only counter pair that exposes that, so it is authoritative:
    # a test that was neither executed nor deliberately skipped has NOT been validated, and
    # certifying it green is worse than reporting a failure.
    $unaccounted = $summary.total - $summary.executed - $summary.skipped
    if ($unaccounted -gt 0) {
        $summary.skipped += $unaccounted
    }

    # Skips that no result row explained: the TRX asserted them in its counters but never
    # said why. Unexplained is not the same as acceptable.
    $unexplained = $summary.skipped - $reasonedSkips - $summary.fixtureFailures
    if ($unexplained -gt 0) {
        $summary.fixtureFailures += $unexplained
    }

    if ($summary.total -eq 0 -or $summary.executed -eq 0) {
        $summary.failureReason = 'no-tests-executed'
    }
    elseif ($impossibleCounters) {
        $summary.failureReason = 'impossible-test-counters'
    }
    elseif ($summary.failed -gt 0) {
        $summary.failureReason = 'test-failures'
    }
    elseif ($summary.fixtureFailures -gt 0) {
        $summary.failureReason = 'fixture-failures'
    }
    elseif ($unverifiable) {
        $summary.failureReason = 'unverifiable-test-results'
    }
    elseif ($MinimumTotal -gt 0 -and $summary.total -lt $MinimumTotal) {
        $summary.failureReason = 'below-minimum-total'
    }
    else {
        $summary.isComplete = $true
    }

    [pscustomobject]$summary
}
