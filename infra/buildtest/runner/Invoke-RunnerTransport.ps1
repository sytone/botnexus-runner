<#
.SYNOPSIS
Runs one image-owned artifact transfer under the remaining absolute platform budget.
.DESCRIPTION
Uses the existing owned-process containment helpers with an explicitly bounded transfer.
The parent supplies the remaining time from its original run stopwatch. Managed identity
variables are used only by this framework command, never added to project children.
.PARAMETER Source
Explicit approved transport source URL or framework-owned path.
.PARAMETER Destination
Explicit approved destination URL or framework-owned path.
.PARAMETER EvidenceRoot
New owned directory for transfer logs and ownership control files.
.PARAMETER TimeoutSeconds
Remaining shared-clock allowance, including cleanup. Must exceed five seconds.
.PARAMETER Recursive
Copies an artifact tree instead of a single source payload.
.PARAMETER NativeExecutable
Image-owned transfer executable; inert fixtures may select the current PowerShell executable.
.PARAMETER NativeArgumentPrefix
Literal prefix for isolated native executable fixtures; empty for real azcopy.
.EXAMPLE
./Invoke-RunnerTransport.ps1 -Source /work/artifacts -Destination $artifactUrl -EvidenceRoot /work/upload -TimeoutSeconds 60 -Recursive
.OUTPUTS
System.String. Bounded transfer status. Exits nonzero on transfer/cleanup/timeout failure.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [Parameter(Mandatory)][ValidateRange(6, 3600)][int]$TimeoutSeconds,
    [switch]$Recursive,
    [string]$NativeExecutable = 'azcopy',
    [string[]]$NativeArgumentPrefix = @()
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Run bounded framework artifact transfer')) {
    return
}
$env:AZCOPY_AUTO_LOGIN_TYPE = 'MSI'
if ($env:AZURE_CLIENT_ID) {
    $env:AZCOPY_MSI_CLIENT_ID = $env:AZURE_CLIENT_ID
}
else {
    Remove-Item Env:AZCOPY_MSI_CLIENT_ID -ErrorAction SilentlyContinue
}
. (Join-Path $PSScriptRoot 'Import-RunnerDiagnostic.ps1')
New-Item -ItemType Directory -Path $EvidenceRoot -ErrorAction Stop | Out-Null
$arguments = @($NativeArgumentPrefix) + @('copy', $Source, $Destination, '--overwrite=true')
if ($Recursive) {
    $arguments += '--recursive=true'
}
# The diagnostic supervisor is the existing shared absolute-clock process engine.
# No dump target is supplied for transport; its reserved interval remains cleanup time.
$result = Invoke-DiagnosticProcess -FilePath $NativeExecutable -ArgumentList $arguments -LogPath (Join-Path $EvidenceRoot 'transport.log') -TimeoutSeconds $TimeoutSeconds -EvidenceRoot $EvidenceRoot -CaptureReserveSeconds 4 -DumpTimeoutSeconds 1 -KillReserveSeconds 1
if ($result.ExitCode -ne 0 -or $result.TimedOut -or -not $result.CleanupComplete -or -not $result.DrainComplete) {
    exit 1
}
exit 0
