<#
.SYNOPSIS
Preserves the original generic timeout and attribution regressions.
.DESCRIPTION
Uses explicit caller project sets, partial TRX and inert native children. Application discovery and mode assertions live in the migration artifact.
.EXAMPLE
./Test-RunnerTimeout.ps1
.OUTPUTS
System.String. Assertion count and failure status; exits nonzero on failure.
#>
[CmdletBinding()]
param()
# Tests for the runner's self-imposed deadline and per-project attribution (#3305).
#
# WHY THIS EXISTS: `-Mode full` reached the 20-minute platform replica ceiling twice on one
# worktree and was killed by the platform, so the entrypoint's finally block never ran and the
# artifact directory was EMPTY. No result.json, no TRX, no way to name the project that was
# still executing. These tests pin the pure logic that replaces that outcome: a deadline that
# lands inside the platform budget, and attribution derived from whatever TRX exist at that
# moment.
#
# No Azure, no container, no test run required: every function under test is pure, apart from
# Invoke-BoundedProcess which is exercised against a real short-lived pwsh child.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot '../RunnerTimeout.psm1') -Force

$script:failures = @()
$script:assertions = 0
function Assert-True {
    <#
    .SYNOPSIS
    Tests one original timeout invariant.
    .DESCRIPTION
    Records explicit synthetic observations without application discovery.
    .PARAMETER Condition
    Explicit synthetic Condition input.
    .PARAMETER Because
    Explicit synthetic Because input.
    .EXAMPLE
    Assert-True -Condition $Condition -Because $Because
    .OUTPUTS
    None. Updates fixture observations.
    #>
    param([bool]$Condition, [string]$Because)
    $script:assertions++
    if (-not $Condition) {
        $script:failures += $Because
    }
}
function Assert-Equal {
    <#
    .SYNOPSIS
    Tests one original timeout invariant.
    .DESCRIPTION
    Records explicit synthetic observations without application discovery.
    .PARAMETER Expected
    Explicit synthetic Expected input.
    .PARAMETER Actual
    Explicit synthetic Actual input.
    .PARAMETER Because
    Explicit synthetic Because input.
    .EXAMPLE
    Assert-Equal -Expected $Expected -Actual $Actual -Because $Because
    .OUTPUTS
    None. Updates fixture observations.
    #>
    param($Expected, $Actual, [string]$Because)
    $script:assertions++
    if ($Expected -ne $Actual) {
        $script:failures += "$Because Expected '$Expected', got '$Actual'."
    }
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) "rt3305-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $root -Force | Out-Null

function Write-TimeoutTrx {
    <#
    .SYNOPSIS
    Tests one original timeout invariant.
    .DESCRIPTION
    Records explicit synthetic observations without application discovery.
    .PARAMETER Path
    Explicit synthetic Path input.
    .PARAMETER Assemblies
    Explicit synthetic Assemblies input.
    .EXAMPLE
    Write-TimeoutTrx -Path $Path -Assemblies $Assemblies
    .OUTPUTS
    None. Updates fixture observations.
    #>
    param([string]$Path, [string[]]$Assemblies)
    $rows = ($Assemblies | ForEach-Object {
            "    <UnitTest name=`"t`" storage=`"/work/src/tests/$_/bin/Debug/net10.0/$_.dll`" />"
        }) -join "`n"
    @"
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <TestDefinitions>
$rows
  </TestDefinitions>
</TestRun>
"@ | Set-Content -Path $Path
}

# --- Get-RunnerDeadline -------------------------------------------------------------

# 1. The deadline is strictly INSIDE the platform budget. Landing on it reproduces the defect:
#    the platform destroys the replica before the upload can complete.
$d = Get-RunnerDeadline -BudgetSeconds 1200
Assert-True -Condition ($d -lt 1200) -Because "1: deadline $d is not inside the 1200s platform budget"
Assert-Equal -Expected 1110 -Actual $d -Because '1: default reserve is not 90s.'

# 2. The reserve is honoured as given, so retuning the platform budget cannot silently change
#    how much finalisation time the runner keeps.
Assert-Equal -Expected 900 -Actual (Get-RunnerDeadline -BudgetSeconds 1200 -ReserveSeconds 300) -Because '2: explicit reserve ignored.'

# 3. NON-VACUITY / floor: an absurd budget must still yield a POSITIVE deadline. A negative
#    deadline would abort the run before a single test executed while reporting a timeout,
#    which is a worse lie than the original empty directory.
$tiny = Get-RunnerDeadline -BudgetSeconds 10
Assert-True -Condition ($tiny -gt 0) -Because "3: tiny budget produced a non-positive deadline ($tiny)"
Assert-Equal -Expected 30 -Actual $tiny -Because '3: floor is not applied.'

# 4. The deadline is SENSITIVE to the budget. A constant would pass tests 1-3 vacuously.
Assert-True -Condition ((Get-RunnerDeadline -BudgetSeconds 2400) -ne (Get-RunnerDeadline -BudgetSeconds 1200)) -Because '4: deadline does not vary with the budget -- the derivation is constant'

# --- Get-CompletedTestAssembly -----------------------------------------------------------

$results = Join-Path $root 'test-results'
New-Item -ItemType Directory -Path $results -Force | Out-Null
Write-TimeoutTrx -Path (Join-Path $results 'a.trx') -Assemblies @('BotNexus.Gateway.Tests')
Write-TimeoutTrx -Path (Join-Path $results 'b.trx') -Assemblies @('BotNexus.Architecture.Tests', 'BotNexus.Gateway.Tests')

# 5. Assemblies come from the ROWS, not the filenames. dotnet test writes every project's TRX
#    into one directory with the same prefix, so filenames carry no project identity at all.
$completed = @(Get-CompletedTestAssembly -TrxPaths @((Join-Path $results 'a.trx'), (Join-Path $results 'b.trx')))
Assert-Equal -Expected 2 -Actual $completed.Count -Because "5: expected 2 distinct assemblies, got $($completed -join ',')"
Assert-True -Condition ($completed -contains 'BotNexus.Gateway.Tests') -Because '5: gateway assembly not detected'
Assert-True -Condition ($completed -contains 'BotNexus.Architecture.Tests') -Because '5: architecture assembly not detected'

# 6. THE CENTRAL PROPERTY: a TRX TRUNCATED BY A KILL still attributes. This is the whole point
#    -- a run destroyed mid-write leaves malformed XML, and an [xml] cast would throw and
#    surrender the only evidence the run produced. Text scanning survives it.
$truncated = Join-Path $results 'partial.trx'
Set-Content -Path $truncated -Value '<TestRun><TestDefinitions><UnitTest storage="/work/tests/BotNexus.Cron.Tests/bin/BotNexus.Cron.Tests.dll" /><UnitTe'
$partial = @(Get-CompletedTestAssembly -TrxPaths @($truncated))
Assert-True -Condition ($partial -contains 'BotNexus.Cron.Tests') -Because '6: a truncated TRX yielded no attribution -- the kill path is unreadable'
$xmlThrew = $false
try {
    [xml](Get-Content -LiteralPath $truncated -Raw)
}
catch {
    $xmlThrew = $true
}
Assert-True -Condition $xmlThrew -Because '6: fixture is not actually malformed, so the truncation property is vacuous'

# 7. A missing or empty path is skipped, not fatal. Finalisation runs on the failure path and
#    must never throw there -- throwing would lose the artifacts it exists to save.
Assert-Equal -Expected 0 -Actual @(Get-CompletedTestAssembly -TrxPaths @((Join-Path $results 'nope.trx'))).Count -Because '7: missing TRX was not tolerated.'
Assert-Equal -Expected 0 -Actual @(Get-CompletedTestAssembly -TrxPaths @()).Count -Because '7: empty input was not tolerated.'

# 7b. FALSE-ACCUSATION REGRESSION, measured not imagined. A real green run
#     (20260818002247-be34bc61) emitted this exact shape: the project directory is
#     BotNexus.Agent.Core.Tests but <AssemblyName> renames the dll to BotNexus.AgentCore.Tests,
#     and the whole path is LOWERCASED. Matching on the dll basename alone reported a project
#     that had just passed 438 tests as never having run. The project DIRECTORY must therefore
#     be recorded too.
$renamed = Join-Path $results 'renamed.trx'
Set-Content -Path $renamed -Value '<TestRun><TestDefinitions><UnitTest storage="/work/src/tests/agent/botnexus.agent.core.tests/bin/debug/net10.0/botnexus.agentcore.tests.dll" /></TestDefinitions></TestRun>'
$renamedSet = @(Get-CompletedTestAssembly -TrxPaths @($renamed))
Assert-True -Condition ($renamedSet -contains 'BotNexus.Agent.Core.Tests') -Because "7b: an AssemblyName-renamed project was not attributed to its directory: $($renamedSet -join ',')"
Assert-True -Condition ($renamedSet -contains 'BotNexus.AgentCore.Tests') -Because '7b: the dll name itself was dropped'

# Explicit caller-owned expected set. Application discovery is preserved separately.
$expected = @('BotNexus.Gateway.Tests', 'BotNexus.Integration.E2E.Tests')

# --- Get-UnfinishedTestProject ------------------------------------------------------------

# 10. The projects that produced no results are named. This is the capability the empty
#     artifact directory could not provide at any price.
$unfinished = @(Get-UnfinishedTestProject -ExpectedProjects $expected -CompletedAssemblies @('BotNexus.Gateway.Tests'))
Assert-Equal -Expected 1 -Actual $unfinished.Count -Because "10: expected 1 unfinished project, got $($unfinished -join ',')"
Assert-Equal -Expected 'BotNexus.Integration.E2E.Tests' -Actual $unfinished[0] -Because '10: wrong project attributed.'

# 11. Excluded projects are NOT accused. `core` filters the browser/E2E projects out, so their
#     absence from the results is by design; reporting them would be a false attribution, and
#     a confident wrong answer is worse than none.
$coreUnfinished = @(Get-UnfinishedTestProject -ExpectedProjects $expected -CompletedAssemblies @('BotNexus.Gateway.Tests') -ExcludedProjects @('BotNexus.Integration.E2E', 'BotNexus.E2E'))
Assert-Equal -Expected 0 -Actual $coreUnfinished.Count -Because "11: an excluded project was accused: $($coreUnfinished -join ',')"

# 12. A fully reported run has nothing outstanding -- the negative case, without which 10
#     could pass by always returning a non-empty set.
Assert-Equal -Expected 0 -Actual @(Get-UnfinishedTestProject -ExpectedProjects $expected -CompletedAssemblies @('BotNexus.Gateway.Tests', 'BotNexus.Integration.E2E.Tests')).Count -Because '12: complete run reported outstanding projects.'

# 13. Matching is case-insensitive: assembly casing on a case-sensitive Linux filesystem must
#     not manufacture a phantom unfinished project.
Assert-Equal -Expected 0 -Actual @(Get-UnfinishedTestProject -ExpectedProjects @('BotNexus.Gateway.Tests') -CompletedAssemblies @('botnexus.gateway.tests')).Count -Because '13: casing produced a phantom unfinished project.'

# --- Get-RunnerTimeoutRecord ---------------------------------------------------------------

$record = Get-RunnerTimeoutRecord -Phase 'test' -ElapsedSeconds 1110.4 -DeadlineSeconds 1110 -UnfinishedProjects @('BotNexus.Integration.E2E.Tests') -CompletedAssemblies @('BotNexus.Gateway.Tests')

# 14. The record is STRUCTURED and carries the timeout flag, so the client can read the outcome
#     out of result.json instead of inferring it from an absence (#3244's shape).
Assert-Equal -Expected $true -Actual $record.timedOut -Because '14: timedOut flag not set.'
Assert-Equal -Expected 'test' -Actual $record.phase -Because '15: phase not recorded.'
Assert-Equal -Expected 1110 -Actual $record.deadlineSeconds -Because '16: deadline not recorded.'

# 17. AC2: the message NAMES the outstanding project.
Assert-True -Condition ($record.attribution -match 'BotNexus\.Integration\.E2E\.Tests') -Because "17: attribution does not name the outstanding project: $($record.attribution)"

# 18. HONESTY: when nothing was outstanding the record says so rather than inventing a culprit.
#     "Everything reported and it still overran" is a real and different finding.
$noneOutstanding = Get-RunnerTimeoutRecord -Phase 'test' -ElapsedSeconds 1110 -DeadlineSeconds 1110
Assert-True -Condition ($noneOutstanding.attribution -match 'No test project was outstanding') -Because "18: an empty outstanding set did not produce an explicit statement: $($noneOutstanding.attribution)"
Assert-Equal -Expected 0 -Actual @($noneOutstanding.unfinishedProjects).Count -Because '18: empty set was not preserved.'

# --- Invoke-BoundedProcess -----------------------------------------------------------------

$pwshPath = (Get-Process -Id $PID).Path

# 19. A process that finishes inside its deadline is NOT reported as timed out, and its exit
#     code is passed through. Without this the bound would fail every run closed.
$log = Join-Path $root 'fast.log'
$fast = Invoke-BoundedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Write-Output hello-3305; exit 0') -LogPath $log -TimeoutSeconds 60 -PollMilliseconds 100
Assert-Equal -Expected $false -Actual $fast.TimedOut -Because '19: a fast process was reported as timed out.'
Assert-Equal -Expected 0 -Actual $fast.ExitCode -Because '19: exit code not passed through.'
Assert-True -Condition ((Get-Content -LiteralPath $log -Raw) -match 'hello-3305') -Because '19: child output was not captured to the log'

# 20. A NON-ZERO exit is passed through as-is and is not confused with a timeout. A genuine
#     test failure and a hang must remain distinguishable -- conflating them is the defect.
$failLog = Join-Path $root 'fail.log'
$failed = Invoke-BoundedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'exit 7') -LogPath $failLog -TimeoutSeconds 60 -PollMilliseconds 100
Assert-Equal -Expected 7 -Actual $failed.ExitCode -Because '20: non-zero exit code not passed through.'
Assert-Equal -Expected $false -Actual $failed.TimedOut -Because '20: a failing process was misreported as timed out.'

# 21. THE MECHANISM: a process that overruns is KILLED and reported as timed out, and control
#     RETURNS to the caller -- which is what makes the finalise-and-upload path reachable at
#     all. The platform kill it replaces never returns control to anything.
$hangLog = Join-Path $root 'hang.log'
$hang = Invoke-BoundedProcess -FilePath $pwshPath -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -LogPath $hangLog -TimeoutSeconds 3 -PollMilliseconds 100
Assert-Equal -Expected $true -Actual $hang.TimedOut -Because '21: an overrunning process was not reported as timed out.'
Assert-True -Condition ($hang.ElapsedSeconds -lt 60) -Because "21: the bound did not actually cut the run short ($($hang.ElapsedSeconds)s)"
Assert-True -Condition ($hang.ElapsedSeconds -ge 3) -Because "21: returned before the deadline could have expired ($($hang.ElapsedSeconds)s)"

# 22. The real child process must receive a collector value containing spaces as ONE token.
#     PowerShell's -File binder splits --collect:<value> itself, so use a probe token without
#     the option prefix to isolate the process-launch boundary (the actual runner uses dotnet).
#     Start-Process's string-array API flattens unquoted tokens on Windows.
$probePath = Join-Path $root 'argv-probe.ps1'
Set-Content -LiteralPath $probePath -Value '$args | ConvertTo-Json -Compress' -Encoding utf8
$argvLog = Join-Path $root 'argv.log'
$filter = 'FullyQualifiedName!~BotNexus.Integration.E2E&FullyQualifiedName!~BotNexus.E2E'
$argvParameters = @{ FilePath = $pwshPath; ArgumentList = @('-NoProfile', '-File', $probePath, 'collector:XPlat Code Coverage', '--filter', $filter); LogPath = $argvLog; TimeoutSeconds = 60; PollMilliseconds = 100 }
$argvRun = Invoke-BoundedProcess @argvParameters
Assert-Equal -Expected 0 -Actual $argvRun.ExitCode -Because '22: argv probe did not exit successfully.'
try {
    $observedArguments = @(Get-Content -LiteralPath $argvLog -Raw | ConvertFrom-Json)
    Assert-Equal -Expected 3 -Actual $observedArguments.Count -Because '22: collector or filter was split into multiple arguments.'
    if ($observedArguments.Count -ge 3) {
        Assert-Equal -Expected 'collector:XPlat Code Coverage' -Actual $observedArguments[0] -Because '22: collector name did not survive as one argument.'
        Assert-Equal -Expected '--filter' -Actual $observedArguments[1] -Because '22: filter switch was lost.'
        Assert-Equal -Expected $filter -Actual $observedArguments[2] -Because '22: filter value changed at the child boundary.'
    }
}
catch {
    $script:failures += "22: argv probe did not emit parseable JSON: $($_.Exception.Message)"
}

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failures.Count) {
    Write-Output "FAILED ($($script:failures.Count)):"
    $script:failures | ForEach-Object { Write-Output "  $_" }
    exit 1
}
Write-Output "RESULT passed=$script:assertions failed=0"
exit 0
