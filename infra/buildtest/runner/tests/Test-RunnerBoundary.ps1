<#
.SYNOPSIS
Exercises the actual project graph and nested diagnostic ownership boundary.
.DESCRIPTION
Synthetic native PowerShell commands only. Records real cancellation/deadline/partial
artifact observations and verifies source pipeline is supervised by the original clock.
.PARAMETER ScratchRoot
Owned isolated fixture directory.
.EXAMPLE
./Test-RunnerBoundary.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Actual per-case observations and JSON counts.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
. (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')
$script:cases = [Collections.Generic.List[object]]::new()
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
function Invoke-BoundaryCheck {
    <#
    .SYNOPSIS
    Records one execution boundary case.
    .DESCRIPTION
    Keeps actual failures visible while allowing independent controls to execute.
    .PARAMETER Name
    Stable case identity.
    .PARAMETER Body
    Assertions and fixture operation.
    .EXAMPLE
    Invoke-BoundaryCheck 'cancel' { throw 'Unexpected survivor.' }
    .OUTPUTS
    System.String. Case result.
    #>
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:cases.Add(@{ name = $Name; passed = $true })
        Write-Output "PASS $Name"
    }
    catch {
        $script:cases.Add(@{ name = $Name; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
}
Invoke-BoundaryCheck 'nested-ownership-registration-before-release' {
    $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../DiagnosticContainment.cs') -Raw
    if ($text -notmatch 'RegisterAndRelease') {
        throw 'Nested sessions are not registered before target release.'
    }
}
Invoke-BoundaryCheck 'whole-pipeline-supervised-not-setup-inline' {
    $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../Invoke-Runner.ps1') -Raw
    if ($text -notmatch 'Invoke-RunnerPipeline.ps1' -or $text -notmatch 'AbsoluteDeadlineSeconds') {
        throw 'Source extraction/git/finalization remain outside original-clock supervision.'
    }
}
foreach ($scenario in @('cancel', 'deadline', 'failure', 'success')) {
    Invoke-BoundaryCheck "graph-adapter-nested-$scenario" {
        $root = Join-Path $ScratchRoot $scenario
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'))
        $helperText = $helper.Replace("'", "''")
        $leaf = Join-Path $root 'Invoke-Leaf.ps1'
        @'
<#
.SYNOPSIS
Publishes a native leaf identity and partial evidence before its terminal action.
.DESCRIPTION
Uses atomic partial publication so the parent cancellation watcher can prove readiness.
Only synthetic failures, completion, or an owned waiting child are used.
.PARAMETER Root
Isolated evidence directory.
.PARAMETER Scenario
Synthetic success, failure, cancellation, or deadline case.
.EXAMPLE
./Invoke-Leaf.ps1 -Root /work/cancel -Scenario cancel
.OUTPUTS
None. Writes identity and partial evidence for the supervising fixture.
#>
[CmdletBinding()]
param([string]$Root, [string]$Scenario)
$ErrorActionPreference = 'Stop'
[IO.File]::WriteAllText((Join-Path $Root 'leaf.json'), (@{ processId = $PID; startUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $Root 'partial.txt.tmp'), 'partial evidence')
[IO.File]::Move((Join-Path $Root 'partial.txt.tmp'), (Join-Path $Root 'partial.txt'))
if ($Scenario -eq 'failure') {
    exit 7
}
if ($Scenario -eq 'success') {
    exit 0
}
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $leaf
        $adapter = Join-Path $root 'Invoke-Adapter.ps1'
        @"
param([string]`$Root, [string]`$Scenario)
`$ErrorActionPreference = 'Stop'
. '$helperText'
`$evidence = Join-Path `$Root 'nested'
New-Item -ItemType Directory -Path `$evidence | Out-Null
`$r = Invoke-DiagnosticProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile','-File',(Join-Path `$Root 'Invoke-Leaf.ps1'),`$Root,`$Scenario) -LogPath (Join-Path `$evidence 'child.log') -TimeoutSeconds 20 -EvidenceRoot `$evidence -CaptureReserveSeconds 4 -DumpTimeoutSeconds 1 -KillReserveSeconds 1
exit `$r.ExitCode
"@ | Set-Content -LiteralPath $adapter
        $config = @{
            schemaVersion = 1
            protocolVersion = 1
            requiredCapabilities = @('process-v1')
            limits = @{ budgetSeconds = 20; reserveSeconds = 3; maxConcurrency = 1; maxLogBytes = 65536; maxArtifactBytes = 65536; maxArtifacts = 8 }
            steps = @(@{ id = 'test'; executable = (Get-Process -Id $PID).Path; arguments = @('-NoProfile', '-File', $adapter, $root, $scenario); workingDirectory = '.'; dependsOn = @(); artifacts = @('partial.txt') })
        }
        $path = Join-Path $root 'project.json'
        $config | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $path
        $project = Read-RunnerProject -Path $path -PayloadRoot $root -ExpectedSha256 (Get-FileHash -LiteralPath $path).Hash
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $cancel = [Threading.CancellationTokenSource]::new()
        $readiness = $null
        try {
            if ($scenario -eq 'cancel') {
                $readiness = [DiagnosticFixtureCancellation]::new($root, $cancel, $clock, 9)
            }
            $result = Invoke-RunnerProject -Project $project -PayloadRoot $root -EvidenceRoot (Join-Path $root 'outer') -RunClock $clock -AbsoluteDeadlineSeconds 9 -FinalizationReserveSeconds 3 -CancellationToken $cancel.Token
            if ($scenario -eq 'cancel') {
                if (-not $readiness.Ready -or -not $cancel.IsCancellationRequested) {
                    throw "Leaf readiness not reached before original deadline: elapsed=$($clock.Elapsed.TotalSeconds) status=$($result.status)"
                }
                Write-Output "READINESS identity=True partial=True cancelledAt=$($readiness.ReadySeconds) originalDeadline=9"
            }
            $expected = switch ($scenario) {
                'cancel' {
                    'cancelled'
                }; 'deadline' {
                    'timedOut'
                }; 'failure' {
                    'failed'
                }; default {
                    'succeeded'
                }
            }
            if ($result.status -ne $expected -or -not $result.cleanupComplete) {
                throw "Wrong nested result: $($result | ConvertTo-Json -Depth 8 -Compress)"
            }
            if ($result.artifacts.Count -ne 1 -or $result.steps[0].elapsedSeconds -le 0) {
                throw 'Partial artifact or actual step timing missing.'
            }
            $identity = Get-Content (Join-Path $root 'leaf.json') -Raw | ConvertFrom-Json
            $child = Get-Process -Id $identity.processId -ErrorAction SilentlyContinue
            try {
                if ($null -ne $child -and $child.StartTime.ToUniversalTime().ToString('o') -ceq $identity.startUtc) {
                    throw 'Nested diagnostic descendant survived outer completion.'
                }
            }
            finally {
                if ($null -ne $child) {
                    $child.Dispose()
                }
            }
            if ($clock.Elapsed.TotalSeconds -ge 12) {
                throw 'Nested work extended original absolute cleanup deadline.'
            }
        }
        finally {
            if ($null -ne $readiness) {
                $readiness.Dispose()
            }
            $cancel.Dispose()
        }
    }
}
$failed = @($script:cases | Where-Object { -not $_.passed }).Count
@{ passed = $script:cases.Count - $failed; failed = $failed; total = $script:cases.Count; cases = $script:cases.ToArray() } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
