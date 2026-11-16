<#
.SYNOPSIS
Checks deadline, teardown and complete-evidence consistency regressions.
.DESCRIPTION
Uses canonical TRX parsing and an exact AST teardown model. Source contracts for Linux
are not native Linux qualification. No product test host or gateway is launched.
.PARAMETER ScratchRoot
Owned isolated synthetic evidence directory.
.EXAMPLE
./Test-RunnerConsistency.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Named assertions and JSON observations.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
. (Join-Path $PSScriptRoot '../Import-RunnerResult.ps1')
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
$cases = [Collections.Generic.List[object]]::new()
$rows = (1..1200 | ForEach-Object { '<UnitTestResult testId="test' + $_ + '" executionId="exec' + $_ + '" testName="same-name" outcome="Passed" />' }) -join ''
$document = '<TestRun id="same-run"><Results>' + $rows + '</Results><ResultSummary><Counters total="1200" executed="1200" passed="1200" failed="0" error="0" timeout="0" aborted="0" notExecuted="0" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'
$paths = @(1..10 | ForEach-Object {
        $path = Join-Path $ScratchRoot "copy$_.trx"
        [IO.File]::WriteAllText($path, $document)
        $path
    })
foreach ($case in @('copied-content', 'repeated-path', 'same-run-reformatted', 'legacy-content-reformatted', 'independent-runs', 'different-assemblies', 'data-row-identities', 'legacy-assembly-names', 'unique-12000', 'nine-approved-skips', 'membership-error-signals', 'membership-error-finalization', 'nonblocking-lock-source', 'atomic-publication-source', 'architecture-path')) {
    try {
        switch ($case) {
            'copied-content' {
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths $paths -MinimumTotal 12000
                if ($result.isComplete) {
                    throw 'Copied content inflated coverage to 12000.'
                }
            }
            'repeated-path' {
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @(@($paths[0]) * 10) -MinimumTotal 12000
                if ($result.isComplete) {
                    throw 'Repeated path inflated coverage to 12000.'
                }
            }
            'same-run-reformatted' {
                $other = Join-Path $ScratchRoot 'reformatted.trx'
                [IO.File]::WriteAllText($other, $document.Replace('><', ">`n<"))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($paths[0], $other)
                if ($result.isComplete) {
                    throw 'Same execution identities counted twice after reformatting.'
                }
            }
            'legacy-content-reformatted' {
                $legacyOriginal = Join-Path $ScratchRoot 'legacy-original.trx'
                $legacyCopy = Join-Path $ScratchRoot 'legacy-copy.trx'
                # Preserve unique legacy names; absent run IDs must not allow a copied
                # document to bypass content rejection by changing indentation alone.
                $legacyRows = (1..1200 | ForEach-Object { '<UnitTestResult testName="legacy' + $_ + '" outcome="Passed" />' }) -join ''
                $legacyDocument = $document.Replace(' id="same-run"', '').Replace($rows, $legacyRows)
                [IO.File]::WriteAllText($legacyOriginal, $legacyDocument)
                [IO.File]::WriteAllText($legacyCopy, $legacyDocument.Replace('><', ">`n<"))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($legacyOriginal, $legacyCopy)
                if ($result.isComplete) {
                    throw 'Reformatted legacy content was counted twice.'
                }
            }
            'independent-runs' {
                $independent = @(1..10 | ForEach-Object {
                        $path = Join-Path $ScratchRoot "run$_.trx"
                        [IO.File]::WriteAllText($path, $document.Replace('same-run', "run$_"))
                        $path
                    })
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths $independent -MinimumTotal 12000
                if (-not $result.isComplete) {
                    throw 'Legitimate independent runs rejected.'
                }
            }
            'different-assemblies' {
                $assembly = Join-Path $ScratchRoot 'assembly.trx'
                [IO.File]::WriteAllText($assembly, $document.Replace('testId="test', 'testId="assembly2-test').Replace('executionId="exec', 'executionId="assembly2-exec'))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($paths[0], $assembly)
                if (-not $result.isComplete) {
                    throw 'Distinct assembly/result identities rejected by test name.'
                }
            }
            'data-row-identities' {
                $data = Join-Path $ScratchRoot 'data-rows.trx'
                $dataRows = '<UnitTestResult testId="theory" executionId="parent" dataRowInfo="0" testName="same" outcome="Passed" /><UnitTestResult testId="theory" executionId="parent" dataRowInfo="1" testName="same" outcome="Passed" />'
                [IO.File]::WriteAllText($data, ('<TestRun id="data-run"><Results>' + $dataRows + '</Results><ResultSummary><Counters total="2" executed="2" passed="2" failed="0" error="0" timeout="0" aborted="0" notExecuted="0" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($data)
                if (-not $result.isComplete) {
                    throw 'Legitimate data rows with shared parent execution rejected.'
                }
            }
            'legacy-assembly-names' {
                $legacy = @(1..2 | ForEach-Object {
                        $path = Join-Path $ScratchRoot "legacy$_.trx"
                        $legacyRow = '<UnitTestResult storage="assembly' + $_ + '.dll" testName="same" outcome="Passed" />'
                        [IO.File]::WriteAllText($path, ('<TestRun id="legacy-run"><Results>' + $legacyRow + '</Results><ResultSummary><Counters total="1" executed="1" passed="1" failed="0" error="0" timeout="0" aborted="0" notExecuted="0" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'))
                        $path
                    })
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths $legacy
                if (-not $result.isComplete) {
                    throw 'Shared names across explicitly distinct assemblies rejected.'
                }
            }
            'unique-12000' {
                $unique = Join-Path $ScratchRoot 'unique.trx'
                $uniqueRows = (1..12000 | ForEach-Object { '<UnitTestResult testId="t' + $_ + '" executionId="e' + $_ + '" testName="row' + $_ + '" outcome="Passed" />' }) -join ''
                [IO.File]::WriteAllText($unique, $document.Replace('1200"', '12000"').Replace($rows.Replace('1200"', '12000"'), $uniqueRows))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($unique) -MinimumTotal 12000
                if (-not $result.isComplete) {
                    throw 'Unique 12000 positive rejected.'
                }
            }
            'nine-approved-skips' {
                $skip = Join-Path $ScratchRoot 'skip.trx'
                $skipRows = (1..11991 | ForEach-Object { '<UnitTestResult testName="pass' + $_ + '" outcome="Passed" />' }) -join ''
                $skipRows += (1..8 | ForEach-Object { '<UnitTestResult testName="credential' + $_ + '" outcome="NotExecuted"><Output><ErrorInfo><Message>SYNTHETIC credential unavailable.</Message></ErrorInfo></Output></UnitTestResult>' }) -join ''
                $skipRows += '<UnitTestResult testName="platform" outcome="NotExecuted"><Output><ErrorInfo><Message>SYNTHETIC platform unavailable.</Message></ErrorInfo></Output></UnitTestResult>'
                [IO.File]::WriteAllText($skip, ('<TestRun><Results>' + $skipRows + '</Results><ResultSummary><Counters total="12000" executed="11991" passed="11991" failed="0" error="0" timeout="0" aborted="0" notExecuted="9" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'))
                $result = Get-RunnerTestResult -DeliberateSkipPatterns @('^SYNTHETIC (credential|platform|feature|service) unavailable\.$') -TrxPaths @($skip) -MinimumTotal 12000 -RequireZeroSkipped
                if (-not $result.isComplete -or $result.skipped -ne 9) {
                    throw 'Approved nine-skip positive rejected.'
                }
            }
            'membership-error-signals' {
                $tokens = $null
                $parseErrors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'), [ref]$tokens, [ref]$parseErrors)
                $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DiagnosticProcess' }, $true)
                $loop = $function.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Condition.Extent.Text -eq '$owners' -and $node.Body.Extent.Text -match 'Ownership kill failed' }, $true)
                if ($null -eq $loop) {
                    throw 'Exact teardown loop missing.'
                }
                $model = & {
                    param($source)
                    $script:signals = 0
                    function Get-DiagnosticOwnedMember {
                        <#
                        .SYNOPSIS
                        Models invalid membership.
                        .DESCRIPTION
                        Throws without accessing processes.
                        .PARAMETER Owner
                        Inert owner.
                        .EXAMPLE
                        Get-DiagnosticOwnedMember -Owner one
                        .OUTPUTS
                        None. Throws.
                        #>
                        [CmdletBinding()]
                        param($Owner)
                        throw "Invalid registry: $Owner"
                    }
                    function Stop-DiagnosticOwnedProcess {
                        <#
                        .SYNOPSIS
                        Counts inert signal attempts.
                        .DESCRIPTION
                        Does not invoke any operating system signal.
                        .PARAMETER Owner
                        Inert owner.
                        .PARAMETER RunClock
                        Original clock.
                        .PARAMETER DeadlineSeconds
                        Original deadline.
                        .EXAMPLE
                        Stop-DiagnosticOwnedProcess -Owner one
                        .OUTPUTS
                        None. Updates count.
                        #>
                        [CmdletBinding(SupportsShouldProcess)]
                        param($Owner, $RunClock, $DeadlineSeconds)
                        if ($PSCmdlet.ShouldProcess("$Owner $RunClock $DeadlineSeconds", 'Count signal')) {
                            $script:signals++
                        }
                    }
                    $owners = @('first', 'second')
                    $cleanupComplete = $true
                    $errors = @()
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    $TimeoutSeconds = 1
                    . ([scriptblock]::Create($source))
                    @{ signals = $script:signals; complete = $cleanupComplete; errors = $errors; elapsed = $clock.Elapsed.TotalSeconds; deadline = $TimeoutSeconds; owners = $owners.Count }
                } $loop.Extent.Text
                if ($model.signals -ne 2) {
                    throw "Membership error suppressed signals: $($model.signals)/2."
                }
            }
            'membership-error-finalization' {
                $tokens = $null
                $parseErrors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'), [ref]$tokens, [ref]$parseErrors)
                $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DiagnosticProcess' }, $true)
                $tryNode = $function.Find({ param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $null -ne $node.Finally -and $node.Finally.Extent.Text -match 'Ownership kill failed' }, $true)
                if ($null -eq $tryNode) {
                    throw 'Exact finally block missing.'
                }
                $body = $tryNode.Finally.Extent.Text
                $model = & {
                    param($source, $root)
                    $script:attempts = 0
                    function Get-DiagnosticOwnedMember {
                        <#
                        .SYNOPSIS
                        Models an invalid registry.
                        .DESCRIPTION
                        Throws without inspecting native processes.
                        .PARAMETER Owner
                        Inert owner.
                        .EXAMPLE
                        Get-DiagnosticOwnedMember -Owner one
                        .OUTPUTS
                        None. Throws.
                        #>
                        [CmdletBinding()]
                        param($Owner)
                        throw "Invalid registry: $($Owner.GroupId)"
                    }
                    function Stop-DiagnosticOwnedProcess {
                        <#
                        .SYNOPSIS
                        Models isolated owner signal failure.
                        .DESCRIPTION
                        Counts all attempts and throws for the first owner only.
                        .PARAMETER Owner
                        Inert owner.
                        .PARAMETER RunClock
                        Original clock.
                        .PARAMETER DeadlineSeconds
                        Original deadline.
                        .EXAMPLE
                        Stop-DiagnosticOwnedProcess -Owner $owner
                        .OUTPUTS
                        None.
                        #>
                        [CmdletBinding(SupportsShouldProcess)]
                        param($Owner, $RunClock, $DeadlineSeconds)
                        if ($PSCmdlet.ShouldProcess("$Owner $RunClock $DeadlineSeconds", 'Count inert signal')) {
                            $script:attempts++
                            if ($script:attempts -eq 1) {
                                throw 'First signal failed.'
                            }
                        }
                    }
                    $owners = @(1..2 | ForEach-Object {
                            $process = [pscustomobject]@{ Disposed = $false }
                            $process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
                            $job = [pscustomobject]@{}
                            $job | Add-Member ScriptProperty Active { throw 'Invalid membership proof.' }
                            $job | Add-Member ScriptMethod Dispose { }
                            [pscustomobject]@{ GroupId = $_; Process = $process; Job = $job; Base = (Join-Path $root "model$_") }
                        })
                    $dumpChildren = @()
                    $pipes = @()
                    $captures = @()
                    $errors = @()
                    $cleanupComplete = $true
                    $drainComplete = $true
                    $readersClosed = $true
                    $timedOut = $false
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    $TimeoutSeconds = 1
                    # Current finally reads the latched elapsed state directly; do not
                    # replace the actual candidate teardown block or weaken its assertions.
                    $elapsedState = @{ Last = 2.0; Failed = $false; Marked = $null }
                    $provider = { 2 }
                    $readElapsed = { 2 }
                    if ($elapsedState.Last -ne (& $provider)) {
                        throw 'Teardown fixture clock state does not match its provider.'
                    }
                    $LogPath = Join-Path $root 'model-finalization.log'
                    $EvidenceRoot = $root
                    . ([scriptblock]::Create($source))
                    @{ attempts = $script:attempts; complete = $cleanupComplete; disposed = @($owners | Where-Object { $_.Process.Disposed }).Count; evidence = (Test-Path (Join-Path $root 'absolute-captures.json')); drain = $drainComplete; readers = $readersClosed; errors = $errors; timedOut = $timedOut; captures = $captures.Count; children = $dumpChildren.Count; pipes = $pipes.Count; log = (Test-Path $LogPath); elapsed = (& $readElapsed); deadline = $TimeoutSeconds; clock = $clock.IsRunning; root = $EvidenceRoot }
                } $body.Substring(1, $body.Length - 2) $ScratchRoot
                if ($model.attempts -ne 2 -or $model.complete -or $model.disposed -ne 2 -or -not $model.evidence -or -not $model.log) {
                    throw "Finalization interrupted: $($model | ConvertTo-Json -Compress)"
                }
            }
            'nonblocking-lock-source' {
                $native = Get-Content (Join-Path $PSScriptRoot '../DiagnosticContainment.cs') -Raw
                if ($native -match 'flock\([^\r\n]+,2\)' -or $native -notmatch 'Stopwatch' -or $native -notmatch 'deadlineSeconds') {
                    throw 'Native admission does not use nonblocking lock and original deadline.'
                }
            }
            'atomic-publication-source' {
                $native = Get-Content (Join-Path $PSScriptRoot '../DiagnosticContainment.cs') -Raw
                if ($native -notmatch 'File.Move\(temporary,path\)' -or $native -match 'File.WriteAllText\(path,JsonSerializer') {
                    throw 'Registry publication is not atomic.'
                }
            }
            'architecture-path' {
                $inventory = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'standalone-tests.json') -Raw | ConvertFrom-Json
                $entrypoint = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Test-RunnerStandalone.ps1') -Raw
                $required = @('Test-RunnerDiagnostic.ps1', 'Test-RunnerDiagnosticDeadline.ps1', 'Test-RunnerDiagnosticCleanup.ps1', 'Test-RunnerDiagnosticPublication.ps1', 'Test-RunnerCallbackLifecycle.ps1', 'Test-RunnerPublicationExpiry.ps1')
                foreach ($name in $required) {
                    $item = @($inventory.tests | Where-Object path -eq $name)
                    if ($item.Count -ne 1 -or $item[0].timeoutSeconds -ne 60 -or -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) {
                        throw "Standalone wrapper missing or guard changed: $name"
                    }
                }
                if ($entrypoint -notmatch 'Invoke-StandaloneCase' -or $entrypoint -notmatch 'standalone-tests.json' -or $entrypoint -notmatch 'Assert-StandaloneProof') {
                    throw 'Inventory is not wired to actual bounded execution and proof validation.'
                }
                $callback = $inventory.tests | Where-Object path -eq 'Test-RunnerCallbackLifecycle.ps1'
                $expiry = $inventory.tests | Where-Object path -eq 'Test-RunnerPublicationExpiry.ps1'
                if ($callback.proofs -notcontains 'PASS persistent=True' -or $callback.proofs -notcontains 'PASS persistent=False' -or $expiry.proofs -notcontains 'PASS expired original publication lifecycle failed and disposed:') {
                    throw 'Lifecycle output assertions lost.'
                }
            }
        }
        $cases.Add(@{ name = $case; passed = $true })
        Write-Output "PASS $case"
    }
    catch {
        $cases.Add(@{ name = $case; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${case}: $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray(); linuxNative = 'UNRUN' } | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
