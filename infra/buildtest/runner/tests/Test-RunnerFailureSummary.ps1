<#
.SYNOPSIS
Checks actual generic pipeline failure evidence through the real supervisor.
.DESCRIPTION
Copies the current framework into owned scratch and replaces only its transport
with an inert failing fixture. Executes the real pipeline and supervisor as native
children. Preserves the original error, partial artifact, unknown tests and rejected
acceptance without application configuration, counts or source-marker extraction.
.PARAMETER ScratchRoot
Absent owned destination for copied framework and retained failure evidence.
.EXAMPLE
./Test-RunnerFailureSummary.ps1 -ScratchRoot /work/failure
.OUTPUTS
System.String. Required failure-evidence proof; throws on missing evidence.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$framework = Join-Path $ScratchRoot 'framework'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..') -Destination $framework -Recurse
@'
<#
.SYNOPSIS
Fails an inert download after preserving a partial artifact.
.DESCRIPTION
Provides the production transport signature without network or credentials.
.PARAMETER Source
Unused inert source identity.
.PARAMETER Destination
Unused owned download destination.
.PARAMETER EvidenceRoot
Reserved owned transfer evidence path.
.PARAMETER TimeoutSeconds
Remaining original execution allowance.
.EXAMPLE
./Invoke-RunnerTransport.ps1 -Source inert -Destination /work/payload -EvidenceRoot /work/transfer -TimeoutSeconds 10
.OUTPUTS
None. Throws the deliberate original transport exception.
#>
[CmdletBinding()]
param($Source, $Destination, $EvidenceRoot, $TimeoutSeconds)
$ErrorActionPreference = 'Stop'
if (-not $Source -or -not $Destination -or -not $EvidenceRoot -or [int]$TimeoutSeconds -le 0) {
    throw 'Invalid original transport allowance.'
}
[IO.File]::WriteAllText((Join-Path $env:RUNNER_WORK_ROOT 'artifacts/partial.txt'), 'partial evidence before original exception')
throw 'original synthetic download exception 5162'
'@ | Set-Content -LiteralPath (Join-Path $framework 'Invoke-RunnerTransport.ps1')
$names = @('SOURCE_BLOB_URL', 'ARTIFACT_BLOB_URL', 'PROJECT_CONFIG_PATH', 'PROJECT_CONFIG_SHA256', 'RUN_ID')
$previous = @{}
foreach ($name in $names) {
    $previous[$name] = [Environment]::GetEnvironmentVariable($name)
}
try {
    $env:SOURCE_BLOB_URL = 'inert-source'
    $env:ARTIFACT_BLOB_URL = 'inert-no-upload'
    $env:PROJECT_CONFIG_PATH = 'custom/build-plan.json'
    $env:PROJECT_CONFIG_SHA256 = 'a' * 64
    $env:RUN_ID = 'generic-failure-evidence'
    $work = Join-Path $ScratchRoot 'run'
    $output = & pwsh -NoProfile -File (Join-Path $framework 'Invoke-Runner.ps1') -WorkRoot $work -BudgetSeconds 30 -ReserveSeconds 8 -SkipUpload 2>&1
    $code = $LASTEXITCODE
    $output | Out-String | Set-Content -LiteralPath (Join-Path $ScratchRoot 'supervisor-output.log')
    $artifacts = Join-Path $work 'artifacts'
    $result = Get-Content -LiteralPath (Join-Path $artifacts 'result.json') -Raw | ConvertFrom-Json
    if ($code -eq 0 -or $result.exitCode -ne 1 -or $result.pipelineExecution.steps[0].exitCode -ne 1) {
        throw 'Failed pipeline lost native nonzero exit evidence.'
    }
    if ($result.error -cne 'original synthetic download exception 5162') {
        throw 'Original pipeline exception was replaced.'
    }
    if ((Get-Content -LiteralPath (Join-Path $artifacts 'runner-error.log') -Raw) -notmatch 'original synthetic download exception 5162') {
        throw 'Original exception log was lost.'
    }
    if ([IO.File]::ReadAllText((Join-Path $artifacts 'partial.txt')) -cne 'partial evidence before original exception') {
        throw 'Partial failure artifact was discarded.'
    }
    if ($null -ne $result.tests -or $result.accepted -isnot [bool] -or $result.accepted -or $null -ne $result.projectExecution) {
        throw 'Failure invented test counts, project execution or acceptance.'
    }
    if (-not $result.pipelineExecution.cleanupComplete -or $result.pipelineExecution.status -ne 'failed') {
        throw 'Failed supervisor did not retain owned cleanup proof.'
    }
    Write-Output 'PASS generic failure preserves original exception, nonzero exit, partial artifact, tests=null, accepted=false'
}
finally {
    foreach ($name in $names) {
        [Environment]::SetEnvironmentVariable($name, $previous[$name])
    }
}
