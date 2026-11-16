Set-StrictMode -Version Latest

function Assert-RunnerProjectEvidence {
    <#
    .SYNOPSIS
    Requires project execution proof matching candidate config and qualified image.
    .DESCRIPTION
    Rejects old-image output, missing protocol, config mismatch, incomplete cleanup and forged
    project acceptance. Existing source/TRX acceptance remains mandatory in callers.
    .PARAMETER Result
    Downloaded result or cached receipt with the project execution fields.
    .PARAMETER Identity
    Expected tuple from the unchanged candidate snapshot.
    .PARAMETER Image
    Independently qualified immutable provider image.
    .EXAMPLE
    Assert-RunnerProjectEvidence -Result $result -Identity $identity -Image $binding.image
    .OUTPUTS
    None. Throws on missing or inconsistent evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)]$Identity, [Parameter(Mandatory)][string]$Image)
    foreach ($name in @('projectConfiguration', 'projectExecution', 'runnerProtocol', 'runnerImage')) {
        if (-not $Result.PSObject.Properties[$name]) {
            throw "Missing project protocol evidence '$name'; legacy image output cannot certify new execution."
        }
    }
    if ($Result.runnerProtocol -ne 1 -or $Result.runnerImage -cne $Image) {
        throw 'Project protocol or actual image identity mismatch.'
    }
    foreach ($name in @('version', 'path', 'sha256')) {
        if ($Result.projectConfiguration.$name -cne $Identity.$name) {
            throw 'Project configuration identity mismatch.'
        }
    }
    $execution = $Result.projectExecution
    if ($null -eq $execution -or $execution.protocolVersion -ne 1 -or $execution.configSha256 -cne $Identity.sha256 -or
        $execution.status -cne 'succeeded' -or $execution.cleanupComplete -isnot [bool] -or -not $execution.cleanupComplete -or
        $execution.accepted -isnot [bool] -or $execution.accepted -or @($execution.steps).Count -eq 0) {
        throw 'Project execution is incomplete or claims independent acceptance.'
    }
    foreach ($step in $execution.steps) {
        if ($step.status -cne 'succeeded' -or $step.exitCode -ne 0) {
            throw 'Project step did not complete successfully.'
        }
    }
}
Export-ModuleMember -Function Assert-RunnerProjectEvidence
