<#
.SYNOPSIS
Verifies isolated disposal failures using the exact diagnostic finalizer.
.DESCRIPTION
Uses inert process, job, reader and destination objects. Runs each case in a
bounded child and requires later cleanup, retained first error, negative verdict
and final evidence. No native ownership signals or product processes are used.
.PARAMETER ScratchRoot
Owned directory for observations and evidence.
.PARAMETER Child
Runs one isolated case instead of the full inventory.
.PARAMETER FailureKind
Handle whose disposal throws, or None for the normal control.
.PARAMETER Expired
Uses an already expired original clock without adding a sleep.
.EXAMPLE
./Test-RunnerDisposalFailure.ps1 -ScratchRoot /tmp/disposal
.OUTPUTS
System.String. Passing case names; throws on any failed assertion.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScratchRoot,
    [switch]$Child,
    [ValidateSet('None', 'Process', 'Job', 'Reader', 'Destination')][string]$FailureKind = 'None',
    [switch]$Expired
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
if (-not $Child) {
    $cases = @()
    foreach ($kind in @('None', 'Process', 'Job', 'Reader', 'Destination')) {
        foreach ($expiredClock in @($false, $true)) {
            $name = "$kind-expired-$expiredClock"
            $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
            $info.UseShellExecute = $false
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            foreach ($argument in @('-NoProfile', '-File', $PSCommandPath, '-ScratchRoot', (Join-Path $ScratchRoot $name), '-Child', '-FailureKind', $kind)) {
                [void]$info.ArgumentList.Add($argument)
            }
            if ($expiredClock) {
                [void]$info.ArgumentList.Add('-Expired')
            }
            $childProcess = [Diagnostics.Process]::Start($info)
            $stdout = $childProcess.StandardOutput.ReadToEndAsync()
            $stderr = $childProcess.StandardError.ReadToEndAsync()
            try {
                if (-not $childProcess.WaitForExit(3000)) {
                    $childProcess.Kill($true)
                    $childProcess.WaitForExit()
                    throw "Disposal case exceeded bounded parent guard: $name"
                }
                $stdout.GetAwaiter().GetResult() | Set-Content (Join-Path $ScratchRoot "$name.stdout.log")
                $stderr.GetAwaiter().GetResult() | Set-Content (Join-Path $ScratchRoot "$name.stderr.log")
                $cases += [ordered]@{ name = $name; passed = ($childProcess.ExitCode -eq 0); exitCode = $childProcess.ExitCode }
            }
            finally {
                $childProcess.Dispose()
            }
        }
    }
    $cases | ConvertTo-Json | Set-Content (Join-Path $ScratchRoot 'cases.json')
    $cases | ForEach-Object { Write-Output "passed=$($_.passed) $($_.name)" }
    if (@($cases | Where-Object { -not $_.passed }).Count) {
        throw 'Disposal isolation regression failed. See per-case observations.'
    }
    return
}
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'), [ref]$tokens, [ref]$parseErrors)
$function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-DiagnosticProcess' }, $true)
$node = $function.Find({ param($item) $item -is [Management.Automation.Language.TryStatementAst] -and $null -ne $item.Finally -and $item.Finally.Extent.Text -match 'Ownership kill failed' }, $true)
$body = $node.Finally.Extent.Text
function Stop-DiagnosticOwnedProcess {
    <#
    .SYNOPSIS
    Records inert ownership signals.
    .DESCRIPTION
    Records signal ordering without accessing native processes.
    .PARAMETER Owner
    Inert owner to signal.
    .PARAMETER RunClock
    Original stopwatch.
    .PARAMETER DeadlineSeconds
    Original deadline.
    .EXAMPLE
    Stop-DiagnosticOwnedProcess -Owner $owner -RunClock $clock -DeadlineSeconds 0
    .OUTPUTS
    None.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param($Owner, $RunClock, $DeadlineSeconds)
    if ($PSCmdlet.ShouldProcess("$RunClock $DeadlineSeconds", 'Record inert signal')) {
        $Owner.Signals++
    }
}
function Get-DiagnosticOwnedMember {
    <#
    .SYNOPSIS
    Models bounded ownership proof.
    .DESCRIPTION
    Checks all signals precede proof and rejects an expired original clock.
    .PARAMETER Owner
    Inert owner being queried.
    .PARAMETER RunClock
    Original stopwatch.
    .PARAMETER DeadlineSeconds
    Original deadline.
    .EXAMPLE
    Get-DiagnosticOwnedMember -Owner $owner -RunClock $clock -DeadlineSeconds 0
    .OUTPUTS
    None. Empty membership within deadline, otherwise throws.
    #>
    [CmdletBinding()]
    param($Owner, $RunClock, $DeadlineSeconds)
    if (@($owners | Where-Object Signals -NE 1).Count) {
        throw 'Ownership proof preceded all signals.'
    }
    if ($RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        throw "Expired original clock: $($Owner.Base)"
    }
}
$handles = @()
foreach ($index in 0..1) {
    foreach ($kind in @('Process', 'Job', 'Reader', 'Destination')) {
        $handle = [pscustomobject]@{ Kind = $kind; Disposed = $false; Throws = ($index -eq 0 -and $kind -eq $FailureKind); HasExited = $true }
        $handle | Add-Member ScriptMethod Dispose {
            $this.Disposed = $true
            if ($this.Throws) {
                throw "Synthetic $($this.Kind) disposal failure."
            }
        }
        $handles += $handle
    }
}
$owners = @()
$pipes = @()
foreach ($index in 0..1) {
    $offset = $index * 4
    $owners += [pscustomobject]@{ Process = $handles[$offset]; Job = $handles[$offset + 1]; Base = (Join-Path $ScratchRoot "owner-$index"); Signals = 0; GroupId = $index; Result = ''; Identity = ''; ErrorPath = ''; Stopped = $true }
    $pipes += [pscustomobject]@{ Reader = $handles[$offset + 2]; Destination = $handles[$offset + 3]; Copy = [Threading.Tasks.Task]::CompletedTask }
}
$dumpChildren = @()
$captures = @()
$errors = @('Original supervision failure.')
$cleanupComplete = $true
$drainComplete = $true
$readersClosed = $true
$timedOut = $false
$journalInvalid = $false
$exitCode = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
$TimeoutSeconds = if ($Expired) {
    0
}
else {
    30
}
$elapsedState = @{ Last = 0.0; Failed = $false }
$provider = { throw 'Finalization invoked forbidden logical-clock provider.' }
$LogPath = Join-Path $ScratchRoot 'final.log'
$EvidenceRoot = $ScratchRoot
$escapedError = ''
try {
    . ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
}
catch {
    $escapedError = $_.Exception.Message
}
$verdict = $function.Find({ param($item) $item -is [Management.Automation.Language.IfStatementAst] -and $item.Extent.Text.StartsWith('if (-not $cleanupComplete -or -not $drainComplete') }, $true)
. ([scriptblock]::Create($verdict.Extent.Text))
$observation = [ordered]@{ failureKind = $FailureKind; expired = [bool]$Expired; escapedError = $escapedError; errors = @($errors); disposed = @($handles.Disposed); signals = @($owners.Signals); cleanupComplete = $cleanupComplete; drainComplete = $drainComplete; readersClosed = $readersClosed; exitCode = $exitCode; finalEvidence = (Test-Path (Join-Path $ScratchRoot 'absolute-captures.json')); supervisionState = (Test-Path (Join-Path $ScratchRoot 'supervision-state.json')) }
$observation | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $ScratchRoot 'observation.json')
if ($escapedError -or @($handles | Where-Object { -not $_.Disposed }).Count -or @($owners | Where-Object Signals -NE 1).Count) {
    throw 'One disposal failure prevented later known-handle cleanup.'
}
if (-not $observation.finalEvidence -or -not $observation.supervisionState -or $errors[0] -ne 'Original supervision failure.') {
    throw 'Final evidence or original first error was lost.'
}
if ($FailureKind -ne 'None') {
    if (($errors -join ' ') -notmatch "Synthetic $FailureKind disposal failure" -or $exitCode -ne 1) {
        throw 'Disposal failure was not retained with a negative verdict.'
    }
    if (($FailureKind -in @('Process', 'Job') -and $cleanupComplete) -or ($FailureKind -eq 'Reader' -and $readersClosed) -or ($FailureKind -eq 'Destination' -and $drainComplete)) {
        throw 'Throwing disposal was falsely certified complete.'
    }
}
if ($Expired -and ($cleanupComplete -or $exitCode -ne 1)) {
    throw 'Expired original clock incorrectly certified cleanup.'
}
if ($FailureKind -eq 'None' -and -not $Expired -and ($exitCode -ne 0 -or -not $cleanupComplete -or -not $drainComplete -or -not $readersClosed)) {
    throw 'Normal two-owner control failed.'
}
Write-Verbose "$dumpChildren $captures $timedOut $provider $journalInvalid $LogPath $EvidenceRoot $elapsedState $pipes $clock $TimeoutSeconds"
