<#
.SYNOPSIS
Tests diagnostic selection, containment and evidence using synthetic fixtures.
.DESCRIPTION
Runs safe pure contract and synthetic process checks, never product test hosts or Azure.
.EXAMPLE
./Test-RunnerDiagnostic.ps1
.OUTPUTS
System.String. Actual assertion count and success status.
#>
[CmdletBinding()]
param()
# Generic process/evidence only. Product collector assertions are preserved in the application migration artifact.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../../..'))
$helper = Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw 'RED #4777: Import-RunnerDiagnostic.ps1 does not exist.'
}
. $helper
Import-Module (Join-Path $PSScriptRoot '../RunnerTimeout.psm1') -Force
$count = 0
function Assert-DiagnosticCondition {
    <#
    .SYNOPSIS
    Checks one diagnostic invariant.
    .DESCRIPTION
    Throws the named reason when the observed invariant is false.
    .PARAMETER Condition
    Actual observation.
    .PARAMETER Reason
    Assertion failure explanation.
    .EXAMPLE
    Assert-DiagnosticCondition $true 'Expected complete evidence.'
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([bool]$Condition, [string]$Reason)
    if (-not $condition) {
        throw $reason
    }; $script:count++
}
function Assert-DiagnosticRejection {
    <#
    .SYNOPSIS
    Verifies a diagnostic input is rejected.
    .DESCRIPTION
    Executes the supplied pure fixture operation and requires an exception.
    .PARAMETER Body
    Rejection operation.
    .EXAMPLE
    Assert-DiagnosticRejection { Resolve-DiagnosticProject /fixture ../escape }
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([scriptblock]$Body)
    $threw = $false; try {
        & $body | Out-Null
    }
    catch {
        $threw = $true
    }; Assert-DiagnosticCondition $threw 'Expected fail-closed rejection.'
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('diagnostic4777-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    $project = 'synthetic/Example.csproj'
    $argsList = @('literal with spaces', '--filter', 'Synthetic.One&Two')
    $child = Join-Path $root 'echo.ps1'
    Set-Content -LiteralPath $child -Value '[Environment]::GetCommandLineArgs() | Select-Object -Skip 4 | ConvertTo-Json -Compress'
    $echo = Invoke-BoundedProcess -FilePath 'pwsh' -ArgumentList (@('-NoProfile', '-File', $child) + $argsList) -TimeoutSeconds 20 -LogPath (Join-Path $root 'echo.log') -PollMilliseconds 50
    Assert-DiagnosticCondition ($echo.ExitCode -eq 0 -and -not $echo.TimedOut) 'Synthetic argument child failed.'
    $actual = @(Get-Content -LiteralPath (Join-Path $root 'echo.log') -Raw | ConvertFrom-Json)
    Assert-DiagnosticCondition (($actual | ConvertTo-Json -Compress) -ceq ($argsList | ConvertTo-Json -Compress)) "Arguments were split or changed. actual=$($actual | ConvertTo-Json -Compress) expected=$($argsList | ConvertTo-Json -Compress)"
    $journalPath = Join-Path $root 'events.jsonl'
    $id = [guid]::NewGuid()
    $lines = @(
        (@{event = 'TestCaseStart'; id = $id.ToString(); sequence = 1; utc = [DateTime]::UtcNow.ToString('o'); fullyQualifiedName = 'Synthetic.Hangs'; displayName = 'quoted "case"'; source = 'Synthetic.dll'; processId = 123 } | ConvertTo-Json -Compress)
        (@{event = 'TestCaseEnd'; id = $id.ToString(); sequence = 2; utc = [DateTime]::UtcNow.ToString('o'); fullyQualifiedName = 'Synthetic.Hangs'; displayName = 'quoted "case"'; source = 'Synthetic.dll'; processId = 123 } | ConvertTo-Json -Compress)
    )
    $lines | Set-Content -LiteralPath $journalPath
    [IO.File]::WriteAllBytes((Join-Path $root 'hang.dmp'), [byte[]]@(1, 2, 3))
    $inventory = @(Get-DiagnosticEvidenceInventory -Root $root)
    Assert-DiagnosticCondition (@($inventory | Where-Object path -eq 'hang.dmp').Count -eq 1) 'Dump missing from evidence inventory.'
    Assert-DiagnosticCondition (($inventory | Where-Object path -eq 'hang.dmp').sha256.Length -eq 64) 'Evidence not content addressed.'
    $fakeRun = [pscustomobject]@{ ExitCode = 1; TimedOut = $true }
    Copy-Item -LiteralPath $journalPath -Destination (Join-Path $root 'events-fixture.jsonl')
    $evidence = Write-DiagnosticEvidence -Root $root -Project $project -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image@sha256:example' -RunnerDirectory (Join-Path $repo 'infra/buildtest/runner') -Run $fakeRun -HangSeconds 120 -OuterSeconds 300
    Assert-DiagnosticCondition ($evidence.eventEvidenceComplete -and $evidence.hangDumpPresent -and -not $evidence.qualifiesForCoreReceipt) 'Timeout evidence/dump/receipt separation lost.'
    Set-Content -LiteralPath (Join-Path $root 'events-fixture.jsonl') -Value ($lines[0])
    $evidence = Write-DiagnosticEvidence -Root $root -Project $project -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory (Join-Path $repo 'infra/buildtest/runner') -Run $fakeRun -HangSeconds 120 -OuterSeconds 300
    Assert-DiagnosticCondition ($evidence.inFlight.Count -eq 1 -and $evidence.inFlight[0].id -eq $id.ToString()) 'In-flight identity lost on timeout.'
    Remove-Item -LiteralPath (Join-Path $root 'hang.dmp')
    $missingDump = Write-DiagnosticEvidence -Root $root -Project $project -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory (Join-Path $repo 'infra/buildtest/runner') -Run $fakeRun -HangSeconds 120 -OuterSeconds 300
    Assert-DiagnosticCondition (-not $missingDump.hangEvidenceComplete) 'In-flight test without hang dump certified.'
    Set-Content -LiteralPath (Join-Path $root 'events-fixture.jsonl') -Value '{broken'
    $evidence = Write-DiagnosticEvidence -Root $root -Project $project -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory (Join-Path $repo 'infra/buildtest/runner') -Run $fakeRun -HangSeconds 120 -OuterSeconds 300
    Assert-DiagnosticCondition (-not $evidence.eventEvidenceComplete) 'Malformed evidence certified.'
    Remove-Item -LiteralPath (Join-Path $root 'events-fixture.jsonl')
    $evidence = Write-DiagnosticEvidence -Root $root -Project $project -SourceSnapshot @{digest = 'exact' } -RunnerImage 'image' -RunnerDirectory (Join-Path $repo 'infra/buildtest/runner') -Run $fakeRun -HangSeconds 120 -OuterSeconds 300
    Assert-DiagnosticCondition (-not $evidence.eventEvidenceComplete) 'Missing collector events certified.'
    $hangChild = Join-Path $root 'synthetic-hang.ps1'
    Set-Content -LiteralPath $hangChild -Value '[IO.File]::WriteAllText($args[0],"started"); [Console]::WriteLine("synthetic-hang-started"); [Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null'
    $marker = Join-Path $root 'started.txt'
    $hangLog = Join-Path $root 'hang.log'
    $hang = Invoke-BoundedProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $hangChild, $marker) -TimeoutSeconds 3 -PollMilliseconds 50 -LogPath $hangLog
    Assert-DiagnosticCondition ($hang.TimedOut -and $hang.ExitCode -eq 1 -and $hang.ElapsedSeconds -lt 10) 'Synthetic hang not bounded.'
    Assert-DiagnosticCondition ((Test-Path -LiteralPath $marker) -and (Get-Content -LiteralPath $hangLog -Raw).Contains('synthetic-hang-started')) 'Synthetic timeout lost pre-kill evidence.'
    $proof = [pscustomobject]@{ version = 1; verified = $true; digest = 'exact'; runId = 'run-4777' }
    $failedResult = [pscustomobject]@{ mode = 'diagnostic'; runId = 'run-4777'; exitCode = 1; sourceSnapshot = $proof }
    $proofEvidence = [pscustomobject]@{ mode = 'diagnostic'; sourceSnapshot = $proof }
    Assert-DiagnosticSourceProof -Result $failedResult -Evidence $proofEvidence -Digest 'exact' -RunId 'run-4777'
    Assert-DiagnosticCondition $true 'Failed diagnostic source proof should be accepted without successful-test certification.'
    Assert-DiagnosticRejection { Assert-DiagnosticSourceProof -Result $failedResult -Evidence $proofEvidence -Digest 'different' -RunId 'run-4777' }
    Assert-DiagnosticRejection { Assert-DiagnosticSourceProof -Result $failedResult -Evidence $proofEvidence -Digest 'exact' -RunId 'different' }
    $bicep = Get-Content -LiteralPath (Join-Path $repo 'infra/buildtest/main.bicep') -Raw
    Assert-DiagnosticCondition ($bicep.Contains('allowBlobPublicAccess: false') -and $bicep.Contains('allowSharedKeyAccess: false')) 'Sensitive storage privacy weakened.'
    Write-Output "RESULT passed=$count failed=0"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
