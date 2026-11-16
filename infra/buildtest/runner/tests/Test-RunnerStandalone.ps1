<#
.SYNOPSIS
Executes the fixed standalone wrapper migration inventory.
.DESCRIPTION
Runs exact source fixtures, strict exit/output and missing-harness negative controls.
This bounded inventory is not full release qualification. No application checkout,
product host, network, automatic test discovery or image mutation is used.
.PARAMETER EvidenceRoot
Absent owned destination for wrapper logs, retained evidence and actual results.
.EXAMPLE
./Test-RunnerStandalone.ps1 -EvidenceRoot /work/standalone
.OUTPUTS
System.String. Actual per-wrapper results and summary JSON; exits nonzero on failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'StandaloneTest.psm1') -Force
New-Item -ItemType Directory -Path $EvidenceRoot -ErrorAction Stop | Out-Null
$inventory = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'standalone-tests.json') -Raw | ConvertFrom-Json
if ($inventory.schemaVersion -ne 1 -or $inventory.tests.Count -ne 16 -or @($inventory.tests.path | Sort-Object -Unique).Count -ne 16) {
    throw 'Missing, duplicate or incomplete fixed test inventory.'
}
foreach ($required in @('Test-RunnerFailureSummary.ps1', 'Test-RunnerTrustedBoundary.ps1')) {
    if ($required -notin $inventory.tests.path) {
        throw "Required regression missing from inventory: $required"
    }
}
$cases = [Collections.Generic.List[object]]::new()
foreach ($control in @('nonzero', 'bad-output', 'failure-output', 'empty-proof', 'missing-harness', 'missing-fixture')) {
    try {
        $rejected = $false
        try {
            switch ($control) {
                'nonzero' {
                    Assert-StandaloneProof -ExitCode 7 -Output 'failed=0' -Proof @('failed=0')
                }
                'bad-output' {
                    Assert-StandaloneProof -ExitCode 0 -Output 'nothing proven' -Proof @('failed=0')
                }
                'failure-output' {
                    Assert-StandaloneProof -ExitCode 0 -Output "FAIL hidden error`nfailed=0" -Proof @('failed=0')
                }
                'empty-proof' {
                    Assert-StandaloneProof -ExitCode 0 -Output 'nothing proven' -Proof @()
                }
                'missing-harness' {
                    Invoke-StandaloneCase -Case $inventory.tests[0] -TestRoot $PSScriptRoot -EvidenceRoot (Join-Path $EvidenceRoot 'missing-harness') -HarnessPath (Join-Path $EvidenceRoot 'absent-pwsh')
                }
                'missing-fixture' {
                    Invoke-StandaloneCase -Case $inventory.tests[0] -TestRoot (Join-Path $EvidenceRoot 'absent-tests') -EvidenceRoot (Join-Path $EvidenceRoot 'missing-fixture')
                }
            }
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) {
            throw 'Invalid wrapper control was accepted.'
        }
        $cases.Add(@{ name = $control; passed = $true; expectedRejection = $true })
        Write-Output "PASS negative $control"
    }
    catch {
        $cases.Add(@{ name = $control; passed = $false; error = $_.Exception.Message })
    }
}
foreach ($negative in @(@{ path = 'Invoke-WrapperExit.ps1'; error = 'Child failed: exit=7' }, @{ path = 'Invoke-WrapperOutput.ps1'; error = 'Missing required proof:' })) {
    try {
        $row = [pscustomobject]@{ path = $negative.path; parameter = ''; proofs = @('failed=0'); timeoutSeconds = 60 }
        $failure = ''
        try {
            Invoke-StandaloneCase -Case $row -TestRoot (Join-Path $PSScriptRoot 'fixtures') -EvidenceRoot (Join-Path $EvidenceRoot $negative.path) | Out-Null
        }
        catch {
            $failure = $_.Exception.Message
        }
        if (-not $failure.Contains($negative.error)) {
            throw "Native negative did not reject for the required reason: $failure"
        }
        $cases.Add(@{ name = $negative.path; passed = $true; expectedRejection = $true; rejection = $failure })
        Write-Output "PASS native negative $($negative.path)"
    }
    catch {
        $cases.Add(@{ name = $negative.path; passed = $false; error = $_.Exception.Message })
    }
}
foreach ($item in $inventory.tests) {
    try {
        $observation = Invoke-StandaloneCase -Case $item -TestRoot $PSScriptRoot -EvidenceRoot (Join-Path $EvidenceRoot ([IO.Path]::GetFileNameWithoutExtension($item.path)))
        $cases.Add($observation)
        Write-Output "PASS wrapper $($item.path)"
    }
    catch {
        $cases.Add(@{ name = $item.path; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL wrapper $($item.path): $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ total = $cases.Count; passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray(); scope = $inventory.scope } | ConvertTo-Json -Depth 10 | Tee-Object -FilePath (Join-Path $EvidenceRoot 'summary.json')
if ($failed) {
    exit 1
}
