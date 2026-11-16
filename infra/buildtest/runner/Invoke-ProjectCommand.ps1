<#
.SYNOPSIS
Launches one project executable with literal arguments and an explicit working directory.
.DESCRIPTION
Runs inside the existing runner ownership boundary. Inherits no secret-bearing parent
variables: only a fixed runtime allowlist is forwarded. This is not a security sandbox;
project commands are trusted candidate code and retain the runner's filesystem permissions.
.PARAMETER Specification
Absolute path to the framework-generated command specification.
.EXAMPLE
./Invoke-ProjectCommand.ps1 -Specification ./evidence/step-command.json
.OUTPUTS
System.String. Child stdout and stderr. Exits with the child exit code.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Specification)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -LiteralPath $Specification -Raw | ConvertFrom-Json -AsHashtable
$info = [Diagnostics.ProcessStartInfo]::new([string]$config.executable)
$info.UseShellExecute = $false
$info.WorkingDirectory = [string]$config.workingDirectory
$info.Environment.Clear()
foreach ($name in @('PATH', 'PATHEXT', 'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'TMPDIR', 'HOME', 'USERPROFILE', 'DOTNET_ROOT', 'DOTNET_ROOT_X64', 'ProgramFiles', 'ProgramFiles(x86)', 'PROCESSOR_ARCHITECTURE', 'LANG', 'LC_ALL', 'NUGET_PACKAGES', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_NOLOGO', 'PLAYWRIGHT_BROWSERS_PATH', 'MSBUILDDISABLENODEREUSE', 'DOTNET_CLI_HOME', 'RUNNER_OWNERSHIP_ROOT')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($null -ne $value) {
        $info.Environment[$name] = $value
    }
}
$inheritedPath = [string]$info.Environment['PATH']
$info.Environment.Remove('PATH') | Out-Null
$info.Environment['PATH'] = [IO.Path]::GetDirectoryName((Get-Process -Id $PID).Path) + [IO.Path]::PathSeparator + $inheritedPath
foreach ($argument in $config.arguments) {
    [void]$info.ArgumentList.Add([string]$argument)
}
$child = [Diagnostics.Process]::Start($info)
try {
    $child.WaitForExit()
    exit $child.ExitCode
}
finally {
    $child.Dispose()
}
