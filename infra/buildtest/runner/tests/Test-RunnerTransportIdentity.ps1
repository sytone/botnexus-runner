<#
.SYNOPSIS
Checks managed-identity setup in the actual image transport process.
.DESCRIPTION
Executes the production transfer helper with an inert native command that records inherited
variables. No authentication or network request occurs. Parent state is restored exactly.
.PARAMETER ScratchRoot
Owned isolated output directory.
.EXAMPLE
./Test-RunnerTransportIdentity.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Actual transport environment case results.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
$names = @('AZCOPY_AUTO_LOGIN_TYPE', 'AZCOPY_MSI_CLIENT_ID', 'AZURE_CLIENT_ID')
$previous = @{}
foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
$stub = Join-Path $ScratchRoot 'Invoke-NativeTransport.ps1'
@'
@{ autoLogin=$env:AZCOPY_AUTO_LOGIN_TYPE;msiClient=$env:AZCOPY_MSI_CLIENT_ID;azureClient=$env:AZURE_CLIENT_ID } | ConvertTo-Json | Set-Content -LiteralPath $args[2]
exit 0
'@ | Set-Content -LiteralPath $stub
try {
    foreach ($selectedClient in @('synthetic-not-a-credential', '')) {
        [Environment]::SetEnvironmentVariable('AZCOPY_AUTO_LOGIN_TYPE', $null)
        [Environment]::SetEnvironmentVariable('AZCOPY_MSI_CLIENT_ID', 'stale-client')
        [Environment]::SetEnvironmentVariable('AZURE_CLIENT_ID', $selectedClient)
        $tag = if ($selectedClient) {
            'selected'
        }
        else {
            'absent'
        }
        $observation = Join-Path $ScratchRoot "$tag.json"
        & (Join-Path $PSScriptRoot '../Invoke-RunnerTransport.ps1') -Source inert -Destination $observation -EvidenceRoot (Join-Path $ScratchRoot $tag) -TimeoutSeconds 10 -NativeExecutable (Get-Process -Id $PID).Path -NativeArgumentPrefix @('-NoProfile', '-File', $stub)
        if ($LASTEXITCODE -ne 0) {
            throw 'Inert native transport failed.'
        }
        $actual = Get-Content -LiteralPath $observation -Raw | ConvertFrom-Json
        if ($actual.autoLogin -ne 'MSI' -or [string]$actual.msiClient -cne $selectedClient) {
            throw 'Actual transport did not initialize selected MSI client or clear stale client.'
        }
        Write-Output "PASS transport-$tag"
    }
}
finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
}
