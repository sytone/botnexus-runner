<#
.SYNOPSIS
Verifies source-content provenance using isolated synthetic runner files.
.DESCRIPTION
Loads the named provenance owner and checks tag framing, source sensitivity, path
normalization and explicit deployed identities. No provider command is invoked.
.EXAMPLE
pwsh -NoProfile -File ./infra/buildtest/tests/Test-RunnerImageProvenance.ps1
.OUTPUTS
System.String. Assertion results; exits with code 1 when an invariant fails.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Tests for Import-RunnerImageProvenance.ps1 (#3516).
#
# The defect these pin: the Container Apps Job ran an image built from an unmerged branch for three
# days. It contained a file main does not have, threw before build or test executed, and reported
# `tests: null`. No branch could be validated and nothing said why - because nothing compared the
# deployed image against the sources.

. (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'Import-RunnerImageProvenance.ps1')

$script:failures = 0
function Test-Condition {
    <#
    .SYNOPSIS
    Records whether a provenance invariant holds.
    .DESCRIPTION
    Reports the named assertion and increments the test failure count on failure.
    .PARAMETER Condition
    Boolean result of the invariant.
    .PARAMETER Message
    Name of the invariant being checked.
    .EXAMPLE
    Test-Condition -Condition $true -Message 'source identity matches'
    .OUTPUTS
    System.String. Assertion status without changing the tested result.
    #>
    param([bool]$Condition, [string]$Message)
    if (-not $condition) {
        Write-Output "FAIL: $message"
        $script:failures++
    }
    else {
        Write-Output "pass: $message"
    }
}
function Test-Equality {
    <#
    .SYNOPSIS
    Checks equality for a named provenance invariant.
    .DESCRIPTION
    Compares expected and actual values and records the result in the test harness.
    .PARAMETER Expected
    Required value for this invariant.
    .PARAMETER Actual
    Observed result from the provenance helper.
    .PARAMETER Message
    Name of the invariant being checked.
    .EXAMPLE
    Test-Equality -Expected 'match' -Actual 'match' -Message 'matching tag'
    .OUTPUTS
    System.String. Assertion status for the equality check.
    #>
    param($Expected, $Actual, [string]$Message)
    Test-Condition -Condition ($expected -eq $actual) -Message "$message (expected '$expected', got '$actual')"
}

$root = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "runner-provenance-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root -Force | Out-Null

try {
    $runner = Join-Path -Path $root -ChildPath 'runner'
    New-Item -ItemType Directory -Path $runner -Force | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $runner -ChildPath 'entrypoint.ps1') -Value "Write-Host 'a'`n"
    Set-Content -LiteralPath (Join-Path -Path $runner -ChildPath 'Dockerfile') -Value "FROM scratch`n"

    # 1. Determinism - the whole design rests on identical content yielding an identical tag.
    $first = Get-RunnerContentTag -RunnerPath $runner
    $second = Get-RunnerContentTag -RunnerPath $runner
    Test-Equality -Expected $first -Actual $second -Message '1: the same content derives the same tag'
    Test-Condition -Condition ($first -match '^src-[0-9a-f]{12}$') -Message '2: the tag has the src-<sha12> shape'

    # 3. A content change must change the tag, or a modified runner could deploy under an old tag -
    #    which is exactly how an image and its sources drift apart.
    Set-Content -LiteralPath (Join-Path -Path $runner -ChildPath 'entrypoint.ps1') -Value "Write-Host 'b'`n"
    $changed = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition -Condition ($changed -ne $first) -Message '3: changed content derives a different tag'

    # 4. A NEW FILE must change the tag. This is the case that actually bit: the branch image added
    #    RunnerBuild.ps1, and a derivation that ignored new files would have matched anyway.
    Set-Content -LiteralPath (Join-Path -Path $runner -ChildPath 'RunnerBuild.ps1') -Value "Write-Host 'new'`n"
    $withNewFile = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition -Condition ($withNewFile -ne $changed) -Message '4: an ADDED file derives a different tag'

    # 5. Tests are excluded, matching the deploy script - they do not land in the image.
    $testsDir = Join-Path -Path $runner -ChildPath 'tests'
    New-Item -ItemType Directory -Path $testsDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path -Path $testsDir -ChildPath 'Some.Tests.ps1') -Value "Write-Host 'test'`n"
    Test-Equality -Expected $withNewFile -Actual (Get-RunnerContentTag -RunnerPath $runner) -Message '5: files under tests/ do not affect the tag'

    # 6. Line endings are not content. A Windows operator and a Linux operator must derive the same
    #    tag from the same file, or the guard cries wolf on every cross-platform checkout.
    $crlf = Join-Path -Path $root -ChildPath 'crlf'
    New-Item -ItemType Directory -Path $crlf -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path -Path $crlf -ChildPath 'entrypoint.ps1'), "Write-Host 'a'`r`n")
    [IO.File]::WriteAllText((Join-Path -Path $crlf -ChildPath 'Dockerfile'), "FROM scratch`r`n")
    $lf = Join-Path -Path $root -ChildPath 'lf'
    New-Item -ItemType Directory -Path $lf -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path -Path $lf -ChildPath 'entrypoint.ps1'), "Write-Host 'a'`n")
    [IO.File]::WriteAllText((Join-Path -Path $lf -ChildPath 'Dockerfile'), "FROM scratch`n")
    Test-Equality -Expected (Get-RunnerContentTag -RunnerPath $lf) -Actual (Get-RunnerContentTag -RunnerPath $crlf) -Message '6: CRLF and LF derive the same tag'

    # 7. An empty candidate set must throw rather than hash to a constant, which would silently match
    #    every deployment forever.
    $empty = Join-Path -Path $root -ChildPath 'empty'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $threw = $false
    try {
        Get-RunnerContentTag -RunnerPath $empty | Out-Null
    }
    catch {
        $threw = $true
    }
    Test-Condition -Condition $threw -Message '7: an empty runner directory throws rather than returning a constant'

    # 7b. A path containing '..' segments must work. The real caller passes
    #     `Join-Path $PSScriptRoot '..' '..' 'infra' 'buildtest' 'runner'`, and an unresolved prefix
    #     is LONGER than the resolved FullName values Get-ChildItem returns - so the substring threw
    #     and the caller's catch swallowed it. The guard silently reported nothing on every run until
    #     this case existed.
    $dotted = Join-Path -Path (Join-Path -Path $runner -ChildPath '..') -ChildPath 'runner'
    $dottedTag = Get-RunnerContentTag -RunnerPath $dotted
    Test-Equality -Expected (Get-RunnerContentTag -RunnerPath $runner) -Actual $dottedTag -Message "7b: a path with '..' segments derives the same tag as its resolved form"

    # 8-10. The verdict surface.
    $expected = Get-RunnerContentTag -RunnerPath $lf
    Test-Equality -Expected 'src-4ef8992145a7' -Actual $expected -Message '7c: exact path-newline-content-newline framing remains unchanged'
    Test-Equality -Expected 'match' -Actual (Test-RunnerImageSource -RunnerPath $lf -DeployedTag $expected).Verdict -Message '8: a deployed tag equal to the derived tag is a match'
    Test-Equality -Expected 'mismatch' -Actual (Test-RunnerImageSource -RunnerPath $lf -DeployedTag 'src-4eafca6de104').Verdict -Message '9: the real 2026-08-21 branch tag is reported as a mismatch'
    Test-Equality -Expected 'unknown' -Actual (Test-RunnerImageSource -RunnerPath $lf -DeployedTag $null).Verdict -Message '10: an unreadable job is unknown, NOT a mismatch - a developer without Azure credentials must not see a red check'

    # 11. ACA normalises a tag-based deployment to an immutable digest in the job template. The
    #     digest is not a runner version and must be resolved through its ACR tags before comparison.
    #     The live job currently reports sha256:bb1b... while that manifest carries the exact
    #     source-derived tag; comparing the digest text directly manufactured a mismatch warning.
    $digest = 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $digestMatch = Test-RunnerImageSource -RunnerPath $lf -DeployedTag $digest -DeployedAliases @('latest', $expected)
    Test-Equality -Expected 'match' -Actual $digestMatch.Verdict -Message '11: a digest whose manifest carries the expected source tag is a match'
    Test-Equality -Expected $digest -Actual $digestMatch.Deployed -Message '11: the immutable deployed digest remains visible in the result'

    # 12. A digest without the source tag is still a genuine mismatch. Accepting every digest would
    #     silence the guard entirely now that ACA reports digest-pinned image references.
    Test-Equality -Expected 'mismatch' -Actual (Test-RunnerImageSource -RunnerPath $lf -DeployedTag $digest -DeployedAliases @('latest', 'src-000000000000')).Verdict -Message '12: an unrelated digest manifest remains a mismatch'
}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if ($script:failures -gt 0) {
    Write-Output "$($script:failures) failure(s)"
    exit 1
}
Write-Output 'all runner-image provenance checks passed'
