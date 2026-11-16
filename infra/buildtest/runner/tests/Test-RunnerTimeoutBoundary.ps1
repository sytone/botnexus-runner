<#
.SYNOPSIS
Verifies reusable timeout helpers without application discovery or product hosts.
.DESCRIPTION
Runs on Windows and Linux using partial TRX and inert native PowerShell children. Covers deadlines,
attribution, unknown attribution, exit propagation, timeout and argument boundaries.
.PARAMETER EvidenceRoot
Absent owned destination for observations and native child logs.
.EXAMPLE
./Test-RunnerTimeoutBoundary.ps1 -EvidenceRoot /work/timeout
.OUTPUTS
System.String. Per-case results and JSON counts; exits nonzero on any failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerTimeout.psm1') -Force
if (Test-Path -LiteralPath $EvidenceRoot) {
    throw 'Fixture destination must be absent.'
}
New-Item -ItemType Directory -Path $EvidenceRoot | Out-Null
$cases = [Collections.Generic.List[object]]::new()
foreach ($name in @('deadline-reserve', 'partial-attribution', 'unfinished-set', 'timeout-record', 'child-success', 'child-failure', 'child-timeout', 'argument-boundary', 'no-application-policy')) {
    try {
        switch ($name) {
            'deadline-reserve' {
                if ((Get-RunnerDeadline -BudgetSeconds 1200) -ne 1110 -or (Get-RunnerDeadline -BudgetSeconds 10) -ne 30 -or (Get-RunnerDeadline -BudgetSeconds 1200 -ReserveSeconds 300) -ne 900 -or (Get-RunnerDeadline -BudgetSeconds 2400) -eq (Get-RunnerDeadline -BudgetSeconds 1200)) {
                    throw 'Internal reserve, floor or budget sensitivity changed.'
                }
            }
            'partial-attribution' {
                $path = Join-Path $EvidenceRoot 'partial.trx'
                Set-Content -LiteralPath $path -Value '<TestRun><UnitTest storage="/work/tests/project.name/bin/debug/renamed.dll" /><UnitTe'
                $found = @(Get-CompletedTestAssembly -TrxPaths @($path))
                if ($found.Count -ne 2 -or $found -notcontains 'project.name' -or $found -notcontains 'renamed' -or @(Get-CompletedTestAssembly -TrxPaths @()).Count -ne 0 -or @(Get-CompletedTestAssembly -TrxPaths @('/absent.trx')).Count -ne 0) {
                    throw 'Partial or renamed assembly attribution changed.'
                }
            }
            'unfinished-set' {
                $missing = @(Get-UnfinishedTestProject -ExpectedProjects @('One', 'Two', 'Ignored') -CompletedAssemblies @('one') -ExcludedProjects @('Ignored'))
                if ($missing.Count -ne 1 -or $missing[0] -cne 'Two' -or @(Get-UnfinishedTestProject -ExpectedProjects @('One') -CompletedAssemblies @('one')).Count -ne 0) {
                    throw 'Set difference, exclusion or case handling changed.'
                }
            }
            'timeout-record' {
                $record = Get-RunnerTimeoutRecord -Phase test -ElapsedSeconds 1110.4 -DeadlineSeconds 1110 -UnfinishedProjects @('Two') -CompletedAssemblies @('One')
                $unknown = Get-RunnerTimeoutRecord -Phase test -ElapsedSeconds 1110 -DeadlineSeconds 1110
                if (-not $record.timedOut -or $record.deadlineSeconds -ne 1110 -or $record.attribution -notmatch 'Two' -or $unknown.attribution -notmatch 'No test project was outstanding' -or @($unknown.unfinishedProjects).Count -ne 0) {
                    throw 'Timeout record lost explicit or unknown attribution.'
                }
            }
            'child-success' {
                $log = Join-Path $EvidenceRoot 'success.log'
                $result = Invoke-BoundedProcess -FilePath pwsh -ArgumentList @('-NoProfile', '-Command', 'Write-Output inert-success; exit 0') -LogPath $log -TimeoutSeconds 10 -PollMilliseconds 50
                if ($result.ExitCode -ne 0 -or $result.TimedOut -or (Get-Content -LiteralPath $log -Raw) -notmatch 'inert-success') {
                    throw 'Successful child exit or log was lost.'
                }
            }
            'child-failure' {
                $result = Invoke-BoundedProcess -FilePath pwsh -ArgumentList @('-NoProfile', '-Command', 'exit 7') -LogPath (Join-Path $EvidenceRoot 'failure.log') -TimeoutSeconds 10 -PollMilliseconds 50
                if ($result.ExitCode -ne 7 -or $result.TimedOut) {
                    throw 'Nonzero child exit was confused with timeout.'
                }
            }
            'child-timeout' {
                $result = Invoke-BoundedProcess -FilePath pwsh -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') -LogPath (Join-Path $EvidenceRoot 'timeout.log') -TimeoutSeconds 1 -PollMilliseconds 50
                if ($result.ExitCode -eq 0 -or -not $result.TimedOut -or $result.ElapsedSeconds -gt 10) {
                    throw 'Child timeout was not bounded or reported.'
                }
            }
            'argument-boundary' {
                $log = Join-Path $EvidenceRoot 'arguments.log'
                foreach ($payload in @('literal with spaces', 'literal with spaces; "quotes" $dollar café 漢字')) {
                    $result = Invoke-BoundedProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixtures/Write-NativeArgument.ps1'), $payload) -LogPath $log -TimeoutSeconds 10 -PollMilliseconds 50
                    $frame = Get-Content -LiteralPath $log -Raw | ConvertFrom-Json
                    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($frame.utf8))
                    if ($result.ExitCode -ne 0 -or $result.TimedOut -or $frame.count -ne 1 -or $decoded -cne $payload) {
                        throw 'Native arguments were split or interpolated.'
                    }
                }
            }
            'no-application-policy' {
                $module = Get-Module RunnerTimeout
                if ($module.ExportedFunctions.Keys -contains 'Get-ExpectedTestProjects' -or $module.ExportedFunctions.Keys -contains 'Get-ExpectedTestProject' -or $module.ExportedFunctions.Keys -contains 'Get-ExpectedProjectsForMode') {
                    throw 'Application discovery leaked into generic exports.'
                }
            }
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
