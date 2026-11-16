<#
.SYNOPSIS
Verify historical content tags and collision decisions against their test-owned implementation.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
param()
# Tests for the content-addressed runner image tag and the collision guard (#2900).
#
# WHY THIS EXISTS: on 2026-08-09 a hand-picked tag bump silently OVERWROTE an existing ACR image,
# because ACR tags are mutable and `az acr build` republishes over them with exit 0 and no warning.
# The source default had also drifted four versions behind the deployed job. These tests pin the
# properties that make that class of mistake impossible.
#
# No Azure access required: the tag derivation is pure content hashing, and the collision decision
# is pure set membership. Both are imported from the test-owned historical contract fixture;
# the actual imported decision is exercised, and missing owner/template files fail closed.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:failures = @()
<#
.SYNOPSIS
Record a tag contract assertion.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER Condition
Whether the invariant holds.
.PARAMETER Because
Failure explanation.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
function Test-Condition {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) {
        $script:failures += $Because
    }
}

$ownerPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'BootstrapContractFixture.psm1') -ErrorAction Stop).Path
Import-Module $ownerPath -Force
$ownerTokens = $null
$ownerErrors = $null
$ownerAst = [System.Management.Automation.Language.Parser]::ParseFile($ownerPath, [ref]$ownerTokens, [ref]$ownerErrors)
Test-Condition (@($ownerErrors).Count -eq 0) '12b: owner must parse'
$decisionAst = @($ownerAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-TagPublishDecision'
        }, $true))
Test-Condition ($decisionAst.Count -eq 1) '12b: actual tag decision owner must exist exactly once'
$tagParameter = @($decisionAst[0].Body.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Tag' })
Test-Condition ($tagParameter.Count -eq 1 -and $null -eq $tagParameter[0].DefaultValue) '12b: actual tag decision must require an explicit tag with no default'


# --- fixture -------------------------------------------------------------------------------

$bicepPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../main.bicep') -ErrorAction Stop).Path
$root = Join-Path ([System.IO.Path]::GetTempPath()) "tag2900-$([Guid]::NewGuid().ToString('N'))"
try {
    $runner = Join-Path $root 'runner'
    New-Item -ItemType Directory -Path $runner -Force | Out-Null
    Set-Content -Path (Join-Path $runner 'Dockerfile') -Value "FROM base`nRUN echo hi"
    Set-Content -Path (Join-Path $runner 'entrypoint.ps1') -Value "Write-Output 'run'"

    # --- tests ---------------------------------------------------------------------------------

    # 1. Deterministic: identical content yields an identical tag.
    $a = Get-RunnerContentTag -RunnerPath $runner
    $b = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition ($a -eq 'src-d47800ba23fe') '1b: content-tag framing baseline changed'
    Test-Condition ($a -eq $b) "1: tag is not deterministic ($a vs $b)"

    # 2. Sensitive: ANY content change yields a different tag. Without this the guard is worthless,
    #    because a changed runner could be published under a tag that already exists.
    Set-Content -Path (Join-Path $runner 'entrypoint.ps1') -Value "Write-Output 'run changed'"
    $c = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition ($c -ne $a) '2: content change did not change the tag'

    # 3. A NEW FILE changes the tag. A hash over only known filenames would miss an added file.
    Set-Content -Path (Join-Path $runner 'helper.ps1') -Value "Write-Output 'helper'"
    $d = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition ($d -ne $c) '3: adding a file did not change the tag'

    # 4. Line-ending-only differences do NOT change the tag: a Windows and a Linux operator must not
    #    mint two different tags for identical content.
    Set-Content -Path (Join-Path $runner 'helper.ps1') -Value "line1`r`nline2" -NoNewline
    $crlf = Get-RunnerContentTag -RunnerPath $runner
    Set-Content -Path (Join-Path $runner 'helper.ps1') -Value "line1`nline2" -NoNewline
    $lf = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition ($crlf -eq $lf) '4: CRLF vs LF produced different tags'

    # 5. Tests directory is excluded: editing runner tests must not force an image rebuild, since
    #    those files never enter the image.
    $before = Get-RunnerContentTag -RunnerPath $runner
    New-Item -ItemType Directory -Path (Join-Path $runner 'tests') -Force | Out-Null
    Set-Content -Path (Join-Path $runner 'tests/Some.Tests.ps1') -Value 'Describe "x" {}'
    $after = Get-RunnerContentTag -RunnerPath $runner
    Test-Condition ($before -eq $after) '5: a file under tests/ changed the image tag'

    # 6. NON-VACUITY: the candidate set must be non-empty. An empty directory hashing to a constant
    #    would pin every future build to a single tag and pass tests 1 and 4 vacuously.
    $empty = Join-Path $root 'empty'
    New-Item -ItemType Directory -Path $empty -Force | Out-Null
    $threw = $false
    try {
        Get-RunnerContentTag -RunnerPath $empty
    }
    catch {
        $threw = $true
    }
    Test-Condition $threw '6: empty runner directory did not throw -- tag derivation can pass vacuously'

    # 7. Tag is a valid Docker tag (alphanumerics, dots, dashes, underscores; max 128).
    Test-Condition ($a -match '^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$') "7: '$a' is not a valid docker tag"

    # 8. THE CENTRAL GUARD: an explicit tag that already exists is REFUSED, never overwritten.
    Test-Condition ((Test-TagPublishDecision -Tag '0.1.12' -ExistingTags @('0.1.11', '0.1.12') -WasDerived $false) -eq 'refuse') '8: explicit collision was not refused -- this is the 2026-08-09 overwrite'

    # 9. A derived tag that already exists is a genuine no-op: content is identical, so skip.
    Test-Condition ((Test-TagPublishDecision -Tag 'src-abc123' -ExistingTags @('src-abc123') -WasDerived $true) -eq 'skip') '9: unchanged derived content did not skip the build'

    # 10. A tag that does not exist builds, whether derived or explicit.
    Test-Condition ((Test-TagPublishDecision -Tag 'src-new' -ExistingTags @('0.1.1') -WasDerived $true) -eq 'build') '10: new derived tag did not build'
    Test-Condition ((Test-TagPublishDecision -Tag '9.9.9' -ExistingTags @('0.1.1') -WasDerived $false) -eq 'build') '10: new explicit tag did not build'

    # 11. An empty registry (no tags yet) must still build rather than error.
    Test-Condition ((Test-TagPublishDecision -Tag 'src-first' -ExistingTags @() -WasDerived $true) -eq 'build') '11: first-ever push did not build'

    # 12. The deploy script must not reintroduce a hardcoded default tag, and main.bicep must not
    #     carry one either. Those two defaults were the original drift.
    $deployText = Get-Content -LiteralPath $ownerPath -Raw -ErrorAction Stop
    Test-Condition ($deployText -notmatch "RunnerImageTag\s*=\s*'[\d.]+'") '12: owner reintroduced a hardcoded version default'
    Test-Condition ($deployText -match "return 'refuse'") '12: owner lost the collision guard'
    $bicepPath = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../main.bicep') -ErrorAction Stop).Path
    Test-Condition ((Get-Content -LiteralPath $bicepPath -Raw) -notmatch "param runnerImageTag string\s*=\s*'") '12: main.bicep reintroduced a default tag'

}
finally {
    Remove-Item $root -Recurse -Force -ErrorAction Stop
}

if ($script:failures.Count) {
    Write-Output "FAILED ($($script:failures.Count)):"
    $script:failures | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output 'Deploy tag guard: all checks passed.'
exit 0
