<#
.SYNOPSIS
Exercises native Linux admission and cleanup consistency boundaries.
.DESCRIPTION
Requires Linux, setsid, bash and flock. Uses synthetic owned processes only. Each case
retains incomplete-cleanup errors and checks actual root termination. This fixture must
be executed in a separately authorized Linux environment; Windows compilation is not proof.
.PARAMETER ScratchRoot
New owned directory for process and registry fixtures.
.EXAMPLE
./Test-RunnerLinuxConsistency.ps1 -ScratchRoot /tmp/runner-consistency
.OUTPUTS
System.String. Actual native case observations; exits nonzero on any failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Assert-LinuxCleanupObservation {
    <#
    .SYNOPSIS
    Checks emergency and in-budget cleanup observations without conflating them.
    .DESCRIPTION
    Expired cleanup must report incomplete proof and a terminated known root, but may
    leave unregistered non-root groups. Normal cleanup must leave no observed members.
    Duration is measured from the operation start, never a negative absolute deadline.
    .PARAMETER Emergency
    True only for cleanup invoked with an already-expired original deadline.
    .PARAMETER SignalError
    Actual error from the original cleanup operation.
    .PARAMETER RootExited
    Observed termination of the known root after its signal attempt.
    .PARAMETER Members
    Fresh observation of possible surviving members; observation is not cleanup success.
    .PARAMETER OperationSeconds
    Actual duration of the original stop call.
    .PARAMETER OriginalAllowanceSeconds
    Remaining original budget at the stop call, clamped to zero.
    .EXAMPLE
    Assert-LinuxCleanupObservation -Emergency $true -SignalError 'root-only best effort' -RootExited $true -Members @(202) -OperationSeconds 0.1 -OriginalAllowanceSeconds 0
    .OUTPUTS
    None. Throws when the selected cleanup contract is violated.
    #>
    [CmdletBinding()]
    param([bool]$Emergency, [AllowNull()][string]$SignalError, [bool]$RootExited,
        [AllowEmptyCollection()][int[]]$Members, [double]$OperationSeconds,
        [double]$OriginalAllowanceSeconds)
    if ($OperationSeconds -gt ([Math]::Max([double]0, $OriginalAllowanceSeconds) + 2)) {
        throw 'Kill exceeded original operation-duration tolerance.'
    }
    if (-not $RootExited) {
        throw 'Known root was not terminated after its signal attempt.'
    }
    if ($Emergency) {
        if (-not $SignalError -or $SignalError -notmatch 'root-only best effort' -or
            $SignalError -notmatch 'membership discovery deadline exhausted') {
            throw 'Expired cleanup did not report no-discovery root-only incomplete proof.'
        }
        # Members are retained in the case record, not asserted absent. A later
        # fixture-owned kill is a separate operation and cannot redeem this proof.
        Write-Verbose "Emergency non-root survivors observed: $($Members -join ',')"
    }
    elseif ($Members.Count -ne 0) {
        throw "Owned members survived in-budget cleanup: $Members"
    }
}
if (-not $IsLinux) {
    throw 'Native Linux required; no qualification was performed.'
}
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
Add-Type -Path (Join-Path $PSScriptRoot '../DiagnosticContainment.cs')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConsistencyNative {
    [DllImport("libc",SetLastError=true)] public static extern int flock(int fd,int operation);
}
'@
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$previousRegistry = $env:RUNNER_OWNERSHIP_ROOT
$cases = [Collections.Generic.List[object]]::new()
try {
    foreach ($case in @('held-lock-launch', 'held-lock-kill', 'malformed-registry', 'overflow-registry', 'partial-unpublished-record', 'stale-generation', 'session-multiple-groups', 'dead-anchor-redirected-member', 'expired-verification', 'expired-kill', 'unreadable-stat-proof')) {
        $owner = $null
        $held = $null
        $originalToken = $null
        $tokens = $null
        $observation = @{ name = $case; passed = $false; originalCleanup = $null; fixtureCleanup = $null }
        $root = Join-Path $ScratchRoot $case
        New-Item -ItemType Directory -Path $root | Out-Null
        $registry = Join-Path $root 'registry'
        New-Item -ItemType Directory -Path $registry | Out-Null
        $env:RUNNER_OWNERSHIP_ROOT = $registry
        $clock = [Diagnostics.Stopwatch]::StartNew()
        try {
            if ($case -eq 'held-lock-launch') {
                $held = [IO.File]::Open((Join-Path $registry 'registry.lock'), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
                if ([ConsistencyNative]::flock($held.SafeFileHandle.DangerousGetHandle().ToInt32(), 6) -ne 0) {
                    throw 'Fixture lock acquisition failed.'
                }
                $deadline = $clock.Elapsed.TotalSeconds + 2
                $rejected = $false
                $launchError = ''
                try {
                    $owner = New-DiagnosticOwnedProcess -FilePath bash -ArgumentList @('-c', "touch '$root/released'") -Root $root -Token launch -RunClock $clock -DeadlineSeconds $deadline
                }
                catch {
                    $rejected = $true
                    $launchError = $_.Exception.Message
                }
                if ($launchError -notmatch 'registry lock deadline') {
                    throw "Admission did not reach held lock: $launchError"
                }
                if (-not $rejected -or (Test-Path (Join-Path $root 'released')) -or $clock.Elapsed.TotalSeconds -gt ($deadline + 2)) {
                    throw 'Held admission lock released target or exceeded original clock.'
                }
            }
            else {
                $command = 'while :; do sleep 60; done'
                if ($case -in @('session-multiple-groups', 'dead-anchor-redirected-member', 'expired-verification', 'expired-kill', 'unreadable-stat-proof')) {
                    # bash monitor mode creates a second group in the same session.
                    # Redirected pipes ensure pipe closure cannot masquerade as membership.
                    $command = 'set -m; sleep 60 >/dev/null 2>&1 & echo $! > "' + $root + '/member"; wait'
                }
                $owner = New-DiagnosticOwnedProcess -FilePath bash -ArgumentList @('-c', $command) -Root $root -Token owner -RunClock $clock -DeadlineSeconds 5
                if ($case -in @('session-multiple-groups', 'dead-anchor-redirected-member', 'expired-verification', 'expired-kill', 'unreadable-stat-proof')) {
                    while (-not (Test-Path (Join-Path $root 'member')) -and $clock.Elapsed.TotalSeconds -lt 5) {
                        Start-Sleep -Milliseconds 5
                    }
                    if (-not (Test-Path (Join-Path $root 'member'))) {
                        throw 'Second-group readiness was not reached.'
                    }
                    $memberId = [int][IO.File]::ReadAllText((Join-Path $root 'member'))
                    $stat = [IO.File]::ReadAllText("/proc/$memberId/stat")
                    $fields = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
                    if ([int]$fields[3] -ne $owner.GroupId -or [int]$fields[2] -eq $owner.GroupId) {
                        throw 'Fixture did not establish a separate group in the owned session.'
                    }
                    if ($case -eq 'dead-anchor-redirected-member') {
                        $owner.Process.Kill()
                        $owner.Process.WaitForExit(1000) | Out-Null
                    }
                }
                switch ($case) {
                    'held-lock-kill' {
                        $held = [IO.File]::Open((Join-Path $registry 'registry.lock'), 'OpenOrCreate', 'ReadWrite', 'ReadWrite')
                        if ([ConsistencyNative]::flock($held.SafeFileHandle.DangerousGetHandle().ToInt32(), 6) -ne 0) {
                            throw 'Fixture lock acquisition failed.'
                        }
                    }
                    'malformed-registry' {
                        [IO.File]::WriteAllText((Join-Path $registry 'broken.json'), '{')
                    }
                    'overflow-registry' {
                        1..257 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $registry "$_.json"), 'null') }
                    }
                    'partial-unpublished-record' {
                        [IO.File]::WriteAllText((Join-Path $registry 'pending.json.random.tmp'), '{')
                    }
                    'stale-generation' {
                        # Change only the retained identity through reflection, modelling PID
                        # reuse without killing an unrelated real operating-system process.
                        $field = [DiagnosticContainment].GetField('OwnerTokens', [Reflection.BindingFlags]'Static,NonPublic')
                        $tokens = $field.GetValue($null)
                        $originalToken = $tokens[$owner.GroupId]
                        $tokens[$owner.GroupId] = 'not-the-live-generation'
                    }
                }
                if ($case -eq 'expired-verification') {
                    $proofError = $null
                    try {
                        $null = [DiagnosticContainment]::RegisteredMemberIds($owner.GroupId, $clock, -1)
                    }
                    catch {
                        $proofError = $_.Exception.Message
                    }
                    if ($proofError -notmatch 'membership unknown') {
                        throw 'Expired native observation certified membership.'
                    }
                }
                if ($case -eq 'unreadable-stat-proof') {
                    # Production parser, persistent real filesystem access error. Opening
                    # a directory as stat must be classified unknown, not disappeared.
                    $method = [DiagnosticContainment].GetMethod('ReadProcessRecord', [Reflection.BindingFlags]'Static,NonPublic')
                    $accessError = $null
                    try {
                        $null = $method.Invoke($null, @('/proc', [int]$PID))
                    }
                    catch {
                        $accessError = $_.Exception.InnerException
                    }
                    if ($null -eq $accessError -or $accessError -is [IO.FileNotFoundException] -or $accessError -is [IO.DirectoryNotFoundException]) {
                        throw 'Persistent unreadability was classified disappeared.'
                    }
                }
                $deadline = if ($case -eq 'expired-kill') {
                    -1
                }
                else {
                    $clock.Elapsed.TotalSeconds + 0.2
                }
                $signalError = $null
                $operationStartedSeconds = $clock.Elapsed.TotalSeconds
                $originalAllowanceSeconds = [Math]::Max([double]0, [double]($deadline - $operationStartedSeconds))
                $operationClock = [Diagnostics.Stopwatch]::StartNew()
                try {
                    Stop-DiagnosticOwnedProcess -Owner $owner -RunClock $clock -DeadlineSeconds $deadline
                }
                catch {
                    $signalError = $_.Exception.Message
                }
                $operationClock.Stop()
                $observation.originalCleanup = @{ deadlineSeconds = $deadline; startedSeconds = $operationStartedSeconds; durationSeconds = $operationClock.Elapsed.TotalSeconds; remainingAllowanceSeconds = $originalAllowanceSeconds; error = $signalError; emergency = ($case -eq 'expired-kill'); membersAfter = @() }
                if ($operationClock.Elapsed.TotalSeconds -gt ($originalAllowanceSeconds + 2)) {
                    throw 'Kill exceeded original operation-duration tolerance.'
                }
                if ($case -eq 'stale-generation') {
                    if (-not $signalError -or $owner.Process.HasExited) {
                        throw 'Stale live generation was signalled or certified.'
                    }
                    $tokens[$owner.GroupId] = $originalToken
                }
                else {
                    if ($case -in @('held-lock-kill', 'malformed-registry', 'overflow-registry', 'expired-kill') -and -not $signalError) {
                        throw 'Incomplete cleanup was not explicit.'
                    }
                    if (-not $owner.Process.WaitForExit(2000)) {
                        throw 'Known root was not terminated.'
                    }
                    if ($case -in @('partial-unpublished-record', 'session-multiple-groups', 'dead-anchor-redirected-member', 'expired-verification', 'expired-kill', 'unreadable-stat-proof')) {
                        $members = @([DiagnosticContainment]::RegisteredMemberIds($owner.GroupId, $clock, $clock.Elapsed.TotalSeconds + 2))
                        $observation.originalCleanup.membersAfter = @($members)
                        Assert-LinuxCleanupObservation -Emergency ($case -eq 'expired-kill') -SignalError $signalError -RootExited $owner.Process.HasExited -Members $members -OperationSeconds $operationClock.Elapsed.TotalSeconds -OriginalAllowanceSeconds $originalAllowanceSeconds
                    }
                }
            }
            $observation.passed = $true
        }
        catch {
            $observation.error = $_.Exception.Message
        }
        finally {
            try {
                if ($null -ne $held) {
                    $held.Dispose()
                }
                if ($null -ne $owner) {
                    if ($null -ne $tokens -and $null -ne $originalToken) {
                        $tokens[$owner.GroupId] = $originalToken
                    }
                    # This NEW allowance is fixture-owned safety cleanup only. Never
                    # attribute its result to the original (possibly expired) operation.
                    $fixtureCleanupStarted = $clock.Elapsed.TotalSeconds
                    try {
                        [DiagnosticContainment]::KillGroup($owner.GroupId, $clock, $clock.Elapsed.TotalSeconds + 1)
                    }
                    catch {
                        Write-Warning $_.Exception.Message
                    }
                    if (-not $owner.Process.WaitForExit(2000)) {
                        throw 'Fixture final cleanup left its known root alive.'
                    }
                    if ($case -in @('malformed-registry', 'overflow-registry')) {
                        Get-ChildItem -LiteralPath $registry -Filter '*.json' | Remove-Item
                    }
                    # SIGKILL delivery is asynchronous. Verify the positive zero-live
                    # condition under ONE safety-cleanup deadline, not immediately after
                    # the signal, and never renew that deadline per observation.
                    $fixtureVerificationDeadline = $clock.Elapsed.TotalSeconds + 2
                    $verificationSamples = [Collections.Generic.List[object]]::new()
                    do {
                        $remaining = @([DiagnosticContainment]::RegisteredMemberIds($owner.GroupId, $clock, $fixtureVerificationDeadline))
                        $verificationSamples.Add(@{ seconds = $clock.Elapsed.TotalSeconds; members = @($remaining) })
                        if ($remaining.Count -eq 0) {
                            break
                        }
                        Start-Sleep -Milliseconds 5
                    } while ($clock.Elapsed.TotalSeconds -lt $fixtureVerificationDeadline)
                    if ($remaining.Count) {
                        throw "Fixture final cleanup left owned members: $remaining"
                    }
                    $observation.fixtureCleanup = @{ startedSeconds = $fixtureCleanupStarted; originalBudgetProof = $false; verificationDeadlineSeconds = $fixtureVerificationDeadline; verificationSamples = $verificationSamples.ToArray(); remainingMembers = @($remaining); rootExited = $owner.Process.HasExited }
                }
            }
            catch {
                $observation.passed = $false
                $observation.fixtureCleanupError = $_.Exception.Message
            }
            finally {
                if ($null -ne $owner) {
                    $owner.Process.Dispose()
                }
            }
        }
        $cases.Add($observation)
        if ($observation.passed) {
            Write-Output "PASS $case"
        }
        else {
            Write-Output "FAIL ${case}: $($observation | ConvertTo-Json -Compress -Depth 6)"
        }
    }
}
finally {
    $env:RUNNER_OWNERSHIP_ROOT = $previousRegistry
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() } | ConvertTo-Json -Depth 6 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
