<#
.SYNOPSIS
Creates the explicit application-to-runner input contract without launching a job.
.DESCRIPTION
Validates the candidate root and exact project configuration with the standalone parser.
Returns independent candidate, project, immutable image and artifact identities. Does not
select application modes, infer test acceptance, authenticate, upload or execute commands.
.PARAMETER CandidateRoot
Existing exact candidate directory owned by the application.
.PARAMETER ProjectConfigPath
Literal candidate-relative project configuration path.
.PARAMETER ProjectConfigSha256
Trusted SHA-256 of the exact configuration bytes.
.PARAMETER RunnerImage
Explicit registry image reference pinned by sha256 digest.
.PARAMETER ArtifactDestination
Explicit application-owned artifact destination, excluding credentials.
.EXAMPLE
./New-RunnerClientContract.ps1 -CandidateRoot /candidate -ProjectConfigPath ci/project.json -ProjectConfigSha256 $hash -RunnerImage $image -ArtifactDestination https://storage.example/results/run1
.OUTPUTS
System.String. JSON input contract; no application acceptance is asserted.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateRoot,
    [Parameter(Mandatory)][string]$ProjectConfigPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ProjectConfigSha256,
    [Parameter(Mandatory)][ValidatePattern('^[^\s@]+@sha256:[a-f0-9]{64}$')][string]$RunnerImage,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ArtifactDestination
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Get-Item -LiteralPath $CandidateRoot -Force -ErrorAction Stop).FullName
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw 'Candidate root must be a directory.'
}
Import-Module (Join-Path $PSScriptRoot '../../infra/buildtest/runner/RunnerProject.psm1') -Force
$config = Read-RunnerProject -Path (Join-Path $root $ProjectConfigPath) -PayloadRoot $root -ExpectedSha256 $ProjectConfigSha256
@{
    protocolVersion = 1
    candidateRoot = $root
    projectConfigPath = $ProjectConfigPath
    projectConfigSha256 = $config['_configSha256']
    runnerImage = $RunnerImage
    artifactDestination = $ArtifactDestination
    accepted = $false
} | ConvertTo-Json -Depth 4
