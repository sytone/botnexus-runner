<#
.SYNOPSIS
Runs one literal command inside an established containment boundary.
.DESCRIPTION
Waits for the supervisor release file before starting the native command. Publishes
an atomic completion result and stays alive so descendants remain owned until the
supervisor terminates the boundary. Output is inherited by the supervisor pipes.
.PARAMETER Configuration
Private JSON pathname created by New-DiagnosticOwnedProcess. Contains literal
arguments and owned release/result/identity/error paths. Never publish this file.
.EXAMPLE
pwsh -NoProfile -File ./Invoke-DiagnosticOwnedCommand.ps1 /private/owned-command.json
.OUTPUTS
None. Writes private ownership metadata and inherits native output streams.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Configuration)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json
while (-not [IO.File]::Exists($config.release)) {
    Start-Sleep -Milliseconds 10
}
function Publish-DiagnosticCompletion {
    <#
    .SYNOPSIS
    Publishes the native completion code atomically.
    .DESCRIPTION
    Closes the pending file before moving it to the owned completion pathname.
    Existence therefore never exposes a partially written or empty exit code.
    .PARAMETER ExitCode
    Observed native exit code, or a failure code when command startup failed.
    .EXAMPLE
    Publish-DiagnosticCompletion -ExitCode '0'
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([string]$ExitCode)
    $pending = $config.result + '.tmp'
    [IO.File]::WriteAllText($pending, $ExitCode)
    [IO.File]::Move($pending, $config.result)
}
$command = $null
try {
    $info = [Diagnostics.ProcessStartInfo]::new([string]$config.file)
    $info.UseShellExecute = $false
    foreach ($argument in $config.arguments) {
        [void]$info.ArgumentList.Add([string]$argument)
    }
    $command = [Diagnostics.Process]::Start($info)
    # Very short commands can exit before StartTime is available on Linux.
    # That does not erase their observed exit code. Never invent a start identity.
    $started = $command.StartTime
    if ($null -ne $started) {
        $identity = @{ processId = $command.Id; startUtc = $started.ToUniversalTime().ToString('o') }
        [IO.File]::WriteAllText($config.identity, ($identity | ConvertTo-Json -Compress))
    }
    elseif (-not $command.HasExited) {
        throw 'Native command start identity is unknown.'
    }
    $command.WaitForExit()
    Publish-DiagnosticCompletion -ExitCode ([string]$command.ExitCode)
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    [IO.File]::WriteAllText($config.error, $_.Exception.Message)
    Publish-DiagnosticCompletion -ExitCode '1'
}
finally {
    if ($null -ne $command) {
        $command.Dispose()
    }
}
# Anchor exit is not command completion. Keep descendants independently killable.
[Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null
