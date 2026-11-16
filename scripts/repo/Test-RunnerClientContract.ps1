<#
.SYNOPSIS
Checks the explicit standalone client inputs without executing candidate commands.
.DESCRIPTION
Uses temporary synthetic candidate configuration. Tests exact pins, missing inputs,
wrong hashes, traversal and mutable image rejection through the public helper.
.PARAMETER ScratchRoot
New isolated fixture directory for retained configuration and result counts.
.EXAMPLE
./Test-RunnerClientContract.ps1 -ScratchRoot /work/client-fixture
.OUTPUTS
System.String. JSON case results; exits one if a contract assertion fails.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$config = Join-Path $ScratchRoot 'explicit.json'
@{
    schemaVersion = 1
    protocolVersion = 1
    requiredCapabilities = @('process-v1')
    limits = @{ budgetSeconds = 12; reserveSeconds = 4; maxConcurrency = 1; maxLogBytes = 65536; maxArtifactBytes = 65536; maxArtifacts = 8 }
    steps = @(@{ id = 'inert'; executable = 'not-executed'; arguments = @(); workingDirectory = '.'; dependsOn = @(); artifacts = @() })
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $config
$hash = (Get-FileHash -LiteralPath $config).Hash.ToLowerInvariant()
$helper = Join-Path $PSScriptRoot 'New-RunnerClientContract.ps1'
$cases = [Collections.Generic.List[object]]::new()
foreach ($scenario in @('explicit', 'wrong-hash', 'traversal', 'missing-config', 'mutable-image', 'missing-root')) {
    try {
        $parameters = @{
            CandidateRoot = $ScratchRoot
            ProjectConfigPath = 'explicit.json'
            ProjectConfigSha256 = $hash
            RunnerImage = 'registry.example/runner@sha256:' + ('a' * 64)
            ArtifactDestination = 'https://storage.example/results/run1'
        }
        switch ($scenario) {
            'wrong-hash' {
                $parameters.ProjectConfigSha256 = '0' * 64
            }
            'traversal' {
                $parameters.ProjectConfigPath = '../explicit.json'
            }
            'missing-config' {
                $parameters.ProjectConfigPath = 'absent.json'
            }
            'mutable-image' {
                $parameters.RunnerImage = 'registry.example/runner:latest'
            }
            'missing-root' {
                $parameters.CandidateRoot = Join-Path $ScratchRoot 'absent-root'
            }
        }
        $rejected = $false
        $result = $null
        try {
            $result = & $helper @parameters | ConvertFrom-Json
        }
        catch {
            $rejected = $true
        }
        if ($scenario -eq 'explicit') {
            if ($rejected -or $result.projectConfigSha256 -cne $hash -or $result.projectConfigPath -cne 'explicit.json' -or $result.runnerImage -cne $parameters.RunnerImage -or $result.artifactDestination -cne $parameters.ArtifactDestination -or $result.accepted) {
                throw 'Explicit client identities were changed or application acceptance invented.'
            }
        }
        elseif (-not $rejected) {
            throw 'Invalid client contract was accepted.'
        }
        $cases.Add(@{ name = $scenario; passed = $true })
    }
    catch {
        $cases.Add(@{ name = $scenario; passed = $false; error = $_.Exception.Message })
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ total = $cases.Count; passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray() } | ConvertTo-Json -Depth 10 | Tee-Object -FilePath (Join-Path $ScratchRoot 'summary.json')
if ($failed) {
    exit 1
}
