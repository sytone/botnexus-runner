<#
.SYNOPSIS
Verify offline asynchronous ARM submission and polling.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
param()
# Tests for asynchronous deployment submission and bounded polling (#3118).
#
# WHY THIS EXISTS: a synchronous `az deployment group create` against the buildtest subscription
# hung indefinitely having submitted NOTHING - no deployment record, no resource. That made an
# unattended BCDR rebuild impossible. `--no-wait` plus explicit polling is the only submission
# path observed to work, so these tests pin it: if `--no-wait` is ever dropped from the deploy
# test-owned contract fixture, test 1 fails.
#
# No Azure access required. The invocation checks are AST analysis of the actual test-owned fixture file, and
# the polling behaviour is exercised against an explicit synthetic command.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:failures = @()
<#
.SYNOPSIS
Record an offline contract assertion.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER Condition
Whether the contract holds.
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

$global:LASTEXITCODE = 0
$scriptPath = (Resolve-Path (Join-Path $PSScriptRoot 'BootstrapContractFixture.psm1')).Path
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

# 0. The script must parse. Everything below is vacuous otherwise.
Test-Condition (-not $parseErrors -or $parseErrors.Count -eq 0) "0: deploy script has parse errors: $($parseErrors -join '; ')"

<#
.SYNOPSIS
Find exact injected ARM command invocations.
.DESCRIPTION
Offline historical bootstrap contract only. Never imports or executes the operational bootstrap. Native responses are synthetic and must not escape diagnostics.
.PARAMETER Ast
Parsed owner syntax tree.
.PARAMETER Words
Required literal command words.
.EXAMPLE
Get-Content -LiteralPath ./BootstrapContractFixture.psm1
Reads the inert contract source without invoking a deployment.
.OUTPUTS
Contract result or terminating failure.
#>
function Get-AzCommandAst {
    param([Parameter(Mandatory)]$Ast, [Parameter(Mandatory)][string[]]$Words)

    $expectedWords = $Words
    $Ast.FindAll({
            param($n)
            if ($n -isnot [System.Management.Automation.Language.CommandAst]) {
                return $false
            }
            $e = $n.CommandElements
            if ($e.Count -lt $expectedWords.Count) {
                return $false
            }
            for ($i = 0; $i -lt $expectedWords.Count; $i++) {
                if ("$($e[$i].Extent.Text)" -ne $expectedWords[$i]) {
                    return $false
                }
            }
            return $true
        }, $true)
}

$creates = @(Get-AzCommandAst -Ast $ast -Words @('$Command', 'deployment', 'group', 'create'))

# --- clause 5 non-vacuity: there must actually BE a deployment submission to inspect -----------
Test-Condition ($creates.Count -eq 1) '5: no az deployment group create invocation found -- the assertion below would pass vacuously'

# --- clause 1: EVERY deployment submission passes --no-wait ------------------------------------
foreach ($c in $creates) {
    $argText = @($c.CommandElements | ForEach-Object { "$($_.Extent.Text)" })
    Test-Condition ($argText -contains '--no-wait') "1: an 'az deployment group create' invocation at line $($c.Extent.StartLineNumber) is missing --no-wait -- this is the hang from #3118"
}

# --- clause 2/4: the script polls provisioningState and bounds the wait -------------------------
$shows = @(Get-AzCommandAst -Ast $ast -Words @('$Command', 'deployment', 'group', 'show'))
Test-Condition ($shows.Count -ge 1) '2: no az deployment group show invocation -- nothing polls for terminal state'
Test-Condition (@($shows | Where-Object { $_.CommandElements.Extent.Text -contains 'properties.provisioningState' }).Count -ge 1) '2: nothing queries properties.provisioningState'
Test-Condition (@($shows | Where-Object { $_.CommandElements.Extent.Text -contains 'properties.error' }).Count -ge 1) '3: nothing queries properties.error -- ARM failure detail would not be surfaced'

# --- behavioural: exercise the historical polling contract against injected synthetic responses ----------------------
#
# The function is extracted from the script's own AST rather than copy-pasted, so the behaviour
# tested belongs to the test-owned historical contract, not a supported provisioning launcher.
# A rename or deletion fails test 6 rather than silently
# testing a stale duplicate.
$fnAst = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-BuildTestDeployment'
    }, $true)
Test-Condition ($null -ne $fnAst) '6: Invoke-BuildTestDeployment not found in the deploy script'

if ($fnAst) {
    $harness = {
        param($FunctionText, $Mode)

        Set-StrictMode -Version Latest
        $SubscriptionId = 'sub-test'
        $ResourceGroup = 'rg-test'
        $script:seenArgs = @()
        $script:showCalls = 0

        $command = {
            $all = @($args | ForEach-Object { "$_" })
            $script:seenArgs += , $all
            $global:LASTEXITCODE = 0
            Write-Information 'PRIVATE_INFORMATION_SENTINEL' -InformationAction Continue
            Write-Warning 'PRIVATE_WARNING_SENTINEL'
            Write-Verbose 'PRIVATE_VERBOSE_SENTINEL' -Verbose
            Write-Debug 'PRIVATE_DEBUG_SENTINEL' -Debug
            if ($all -contains 'create') {
                if ($Mode -eq 'submitfail') {
                    $global:LASTEXITCODE = 23
                    return 'PRIVATE_PROVIDER_SENTINEL'
                }
                return
            }
            $script:showCalls++
            if ($all -contains 'properties.error') {
                if ($Mode -eq 'errornative') {
                    $global:LASTEXITCODE = 17
                    return 'PRIVATE_PROVIDER_SENTINEL'
                }
                if ($Mode -eq 'errormissing') {
                    return $null
                }
                if ($Mode -eq 'errorthrow') {
                    throw 'PRIVATE_PROVIDER_SENTINEL'
                }
                return '{"code":"BadRequest","message":"boom PRIVATE_PROVIDER_SENTINEL"}'
            }
            switch ($Mode) {
                'succeed' {
                    return 'Succeeded'
                }
                'canceled' {
                    return 'Canceled'
                }
                'errornative' {
                    return 'Failed'
                }
                'errormissing' {
                    return 'Failed'
                }
                'errorthrow' {
                    return 'Failed'
                }
                'statethrow' {
                    throw 'PRIVATE_PROVIDER_SENTINEL'
                }
                'untrustedstate' {
                    return 'PRIVATE_PROVIDER_SENTINEL'
                }
                'fail' {
                    return 'Failed'
                }
                'running' {
                    return 'Running'
                }
                'missing' {
                    return $null
                }
                'native' {
                    $global:LASTEXITCODE = 19
                    return 'PRIVATE_PROVIDER_SENTINEL'
                }
            }
        }

        . ([scriptblock]::Create($FunctionText))

        $timeout = if ($Mode -in @('running', 'missing', 'native', 'untrustedstate')) {
            0
        }
        else {
            5
        }
        $result = [pscustomobject]@{ Threw = $null; Args = $null; Streams = @() }
        $previousExitCode = $global:LASTEXITCODE
        try {
            $result.Streams = @(Invoke-BuildTestDeployment -Command $command -SubscriptionId $SubscriptionId -ResourceGroup $ResourceGroup -DeploymentName 'd1' -TemplateFile 't.bicep' -Parameters @('a=1') -TimeoutMinutes $timeout -PollSeconds 1 *>&1)
        }
        catch {
            $result.Threw = "$_"
        }
        finally {
            $global:LASTEXITCODE = $previousExitCode
        }
        $result.Args = $script:seenArgs
        return $result
    }

    $fnText = $fnAst.Extent.Text
    $missingCommandFailed = $false
    try {
        . ([scriptblock]::Create($fnText))
        Invoke-BuildTestDeployment -Command $null -SubscriptionId 's' -ResourceGroup 'g' -DeploymentName 'd' -TemplateFile 't' -Parameters @()
    }
    catch {
        $missingCommandFailed = $true
    }
    Test-Condition $missingCommandFailed '6b: absent injected command did not fail closed'

    # 6. Happy path: succeeds, and the submission carried --no-wait at RUNTIME, not just in source.
    $ok = & $harness $fnText 'succeed'
    Test-Condition (($ok.Streams -join '') -notmatch 'PRIVATE_[A-Z_]+_SENTINEL') '6: success leaked a native stream'
    Test-Condition ($null -eq $ok.Threw) "6: a Succeeded deployment threw: $($ok.Threw)"
    $createArgs = @($ok.Args | Where-Object { $_ -contains 'create' })
    Test-Condition ($createArgs.Count -eq 1) '6: expected exactly one create invocation'
    Test-Condition ($createArgs[0] -contains '--no-wait') '6: the runtime create invocation did not include --no-wait'

    # 7. A Failed deployment throws a bounded state and detail-availability diagnostic; raw ARM detail is deliberately withheld.
    $bad = & $harness $fnText 'fail'
    Test-Condition ($null -ne $bad.Threw) '7: a Failed deployment did not throw'
    Test-Condition ($bad.Threw.Length -lt 256) '7: failure diagnostic is unbounded'
    Test-Condition (($bad.Streams -join '') -notmatch 'PRIVATE_[A-Z_]+_SENTINEL') '7: failure leaked a native stream'
    Test-Condition ($bad.Threw -match "Failed") '7: the failure message does not name the terminal state'
    Test-Condition ($bad.Threw -match 'ARM error detail: available' -and $bad.Threw -notmatch 'BadRequest|boom|PRIVATE_PROVIDER_SENTINEL') "7: the failure message lacks safe ARM detail availability or discloses raw detail: $($bad.Threw)"

    # 8. A non-terminal state does not loop forever: the bounded timeout throws (clause 4).
    $stuck = & $harness $fnText 'running'
    Test-Condition ($null -ne $stuck.Threw) '8: a never-terminal deployment did not throw -- polling is unbounded'
    Test-Condition ($stuck.Threw -match 'did not reach a terminal state') "8: timeout message is not the bounded-wait message: $($stuck.Threw)"
    Test-Condition ($stuck.Threw -match "Running") '8: the timeout message does not report the last observed state'
}

foreach ($mode in @('missing', 'native', 'submitfail', 'statethrow', 'untrustedstate', 'canceled', 'errornative', 'errormissing', 'errorthrow')) {
    $negative = & $harness $fnText $mode
    Test-Condition ($null -ne $negative.Threw) "$mode must fail closed"
    Test-Condition (($negative.Threw + ($negative.Streams -join '')) -notmatch 'PRIVATE_[A-Z_]+_SENTINEL') "$mode leaked native detail"
    Test-Condition ($negative.Threw.Length -lt 256) "$mode diagnostic is unbounded"
    $expectedDiagnostic = switch ($mode) {
        'submitfail' {
            'ARM submission failed'
        }
        'native' {
            'ARM state query failed'
        }
        'statethrow' {
            'ARM state query failed'
        }
        'errornative' {
            'ARM error query failed'
        }
        'errorthrow' {
            'ARM error query failed'
        }
        'canceled' {
            'Canceled'
        }
        'errormissing' {
            'ARM error detail: unavailable'
        }
        default {
            'did not reach a terminal state'
        }
    }
    Test-Condition ($negative.Threw -match $expectedDiagnostic) "$mode diagnostic lost the useful failure category"
    Test-Condition (@($negative.Args | Where-Object { $_ -contains 'create' }).Count -eq 1) "$mode retried submission"
}

if ($script:failures.Count) {
    Write-Output "FAILED ($($script:failures.Count)):"
    $script:failures | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output 'Deploy async submission + polling: all checks passed.'
exit 0
