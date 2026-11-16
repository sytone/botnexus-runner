<#
.SYNOPSIS
Exercises the exact diagnostic finally block with frozen logical time and expired native clock.
.DESCRIPTION
Inert owner and pipe objects only. Executes the candidate AST block in a child with a
bounded parent guard; no process signal, product host, gateway or network call.
.PARAMETER ScratchRoot
Owned isolated evidence directory.
.PARAMETER Child
Internal child invocation for isolated exact-source model.
.EXAMPLE
./Test-RunnerCleanupClock.ps1 -ScratchRoot /tmp/cleanup-clock
.OUTPUTS
System.String. Actual bounded cleanup and final-evidence assertions.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot, [switch]$Child)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
if (-not $Child) {
    $info = [Diagnostics.ProcessStartInfo]::new('pwsh')
    $info.UseShellExecute = $false
    foreach ($arg in @('-NoProfile', '-File', $PSCommandPath, '-ScratchRoot', $ScratchRoot, '-Child')) {
        [void]$info.ArgumentList.Add($arg)
    }
    $p = [Diagnostics.Process]::Start($info)
    try {
        if (-not $p.WaitForExit(3000)) {
            $p.Kill($true); $p.WaitForExit(); throw 'Frozen logical clock prevented bounded finalization.'
        }
        if ($p.ExitCode -ne 0) {
            throw 'Cleanup child failed.'
        }
    }
    finally {
        $p.Dispose()
    }
    Write-Output 'PASS frozen logical clock cannot prevent real-deadline finalization'
    return
}
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1'), [ref]$tokens, [ref]$parseErrors)
$function = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-DiagnosticProcess' }, $true)
$node = $function.Find({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Finally.Extent.Text -match 'Ownership kill failed' }, $true)
$body = $node.Finally.Extent.Text
function Stop-DiagnosticOwnedProcess {
    <#
    .SYNOPSIS
    Counts inert signal failure.
    .DESCRIPTION
    Throws a controlled expired-budget error without native signals.
    .PARAMETER Owner
    Inert owner.
    .PARAMETER RunClock
    Original clock.
    .PARAMETER DeadlineSeconds
    Original deadline.
    .EXAMPLE
    Stop-DiagnosticOwnedProcess -Owner $owner -RunClock $clock -DeadlineSeconds 0
    .OUTPUTS
    None. Throws.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param($Owner, $RunClock, $DeadlineSeconds)
    if ($PSCmdlet.ShouldProcess("$Owner $RunClock $DeadlineSeconds", 'Model expired signal')) {
        $Owner.Signals++
        throw 'Expired original clock.'
    }
}
function Get-DiagnosticOwnedMember {
    <#
    .SYNOPSIS
    Models unprovable membership.
    .DESCRIPTION
    Always throws to require bounded failure finalization.
    .PARAMETER Owner
    Inert owner.
    .PARAMETER RunClock
    Original clock.
    .PARAMETER DeadlineSeconds
    Original deadline.
    .EXAMPLE
    Get-DiagnosticOwnedMember -Owner $owner -RunClock $clock -DeadlineSeconds 0
    .OUTPUTS
    None. Throws.
    #>
    [CmdletBinding()]
    param($Owner, $RunClock, $DeadlineSeconds)
    throw "Unknown membership: $Owner $RunClock $DeadlineSeconds"
}
$process = [pscustomobject]@{ Disposed = $false }
$process | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
$job = if ($IsWindows) {
    [pscustomobject]@{}
}
else {
    $null
}
if ($null -ne $job) {
    $job | Add-Member ScriptProperty Active { throw 'Unknown native membership' }
    $job | Add-Member ScriptMethod Dispose { }
}
$secondProcess = [pscustomobject]@{ Disposed = $false }
$secondProcess | Add-Member ScriptMethod Dispose { $this.Disposed = $true }
$owners = @(
    [pscustomobject]@{ Process = $process; Job = $job; Base = (Join-Path $ScratchRoot 'owned'); Signals = 0 }
    [pscustomobject]@{ Process = $secondProcess; Job = $null; Base = (Join-Path $ScratchRoot 'second'); Signals = 0 }
)
$dumpChildren = @(); $pipes = @(); $captures = @(); $errors = @()
$cleanupComplete = $true; $drainComplete = $true; $readersClosed = $true; $timedOut = $false
$clock = [Diagnostics.Stopwatch]::StartNew(); $TimeoutSeconds = 1
# An already-spent real deadline with deliberately frozen logical fixture time.
[Threading.Thread]::Sleep(1100)
$elapsedState = @{ Last = 0.0; Failed = $false }
$readElapsed = { throw 'Finalization must not invoke even an unfaulted fixture callback.' }
$provider = $readElapsed
Write-Verbose "Forbidden finalization callback: $provider"
$LogPath = Join-Path $ScratchRoot 'final.log'; $EvidenceRoot = $ScratchRoot
. ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
if ($cleanupComplete -or -not $process.Disposed -or -not (Test-Path (Join-Path $ScratchRoot 'absolute-captures.json'))) {
    throw 'Unprovable cleanup did not retain failure/disposal/final evidence.'
}
if (@($owners | Where-Object { $_.Signals -ne 1 -or -not $_.Process.Disposed }).Count -ne 0) {
    throw 'One failed proof prevented signaling or disposal of another known owner.'
}
@{ owners = $owners.Count; signals = @($owners.Signals); disposed = @($owners.Process.Disposed); cleanupComplete = $cleanupComplete; finalEvidence = (Test-Path (Join-Path $ScratchRoot 'absolute-captures.json')) } | ConvertTo-Json | Set-Content (Join-Path $ScratchRoot 'disposal-proof.json')
Write-Verbose "Cached logical clock $($elapsedState.Last); $dumpChildren $pipes $captures $errors $drainComplete $readersClosed $timedOut $LogPath $EvidenceRoot $TimeoutSeconds $clock $owners"
