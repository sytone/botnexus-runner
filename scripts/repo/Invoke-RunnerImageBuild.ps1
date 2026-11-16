<#
.SYNOPSIS
Builds an exact clean runner checkout with the native container tool.
.DESCRIPTION
Validates the commit, raw checkout bytes, image-owned runtime closure and an
external private JSON configuration before invoking one native build command.
Discards build output using fixed-size buffers and emits only a source-bound receipt.
Does not authenticate, push, qualify, deploy or select application policy.
WhatIf performs read-only validation without invoking the container tool.
.PARAMETER SourceRoot
Exact clean Git checkout containing the runner image sources.
.PARAMETER ExpectedCommit
Full lowercase Git commit ID that must equal the checkout HEAD.
.PARAMETER ConfigurationPath
One strict versioned external private maintenance target profile. No legacy
per-operation configuration is accepted. Reader returns a private in-memory projection.
.PARAMETER PrivateRoot
Explicit existing operator-controlled directory containing the profile, outside Git.
.PARAMETER ConfigurationSha256
Exact lowercase SHA256 of the entire private profile file, not projected JSON.
.PARAMETER ContainerCommand
Native container executable. Defaults to podman. Tests may supply an inert tool.
.PARAMETER TimeoutSeconds
Maximum native build duration, including owned termination and output drain. Defaults to 600.
.EXAMPLE
./Invoke-RunnerImageBuild.ps1 -SourceRoot /source -ExpectedCommit $commit -ConfigurationPath /private/target.json -ConfigurationSha256 $hash -PrivateRoot /private -WhatIf
Validates inputs without building or changing source, environment or files.
.OUTPUTS
System.String. JSON source receipt with tests null and accepted false. No image
qualification or deployment is claimed. Exits nonzero with fixed redacted errors
on invalid input, native failure or unknown cleanup.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [string]$ContainerCommand = 'podman',
    [ValidateRange(1, 1800)][int]$TimeoutSeconds = 600
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'Import-RunnerMaintenanceProfile.ps1')

try {
    if ($ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Expected source identity must be a full lowercase commit.'
    }
    $root = (Assert-ObservedPath -Path $SourceRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $configuration = Assert-ObservedPath -Path $ConfigurationPath
    if ($configuration.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Private build configuration must be outside the source checkout.'
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    $profileSelection = Read-RunnerMaintenanceProfile -Path $configuration -ExpectedSha256 $ConfigurationSha256 -Operation build -SourceRoot $root -PrivateRoot $PrivateRoot -ExpectedCommit $ExpectedCommit
    $imageTag = $profileSelection.configuration.imageTag
    $runner = Join-Path $root 'infra/buildtest/runner'
    $manifestPath = Join-Path $runner 'image-runtime.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $dockerfile = Get-Content -LiteralPath (Join-Path $runner 'Dockerfile') -Raw
    $copied = @()
    foreach ($line in $dockerfile.Split("`n")) {
        if ($line.StartsWith('COPY ') -and $line -notmatch '--from=') {
            $parts = $line.Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries)
            if ($parts[-1] -cne '/runner/') {
                throw 'Unsupported image-owned destination.'
            }
            $copied += $parts[1..($parts.Length - 2)]
        }
    }
    $copiedNames = ($copied | Sort-Object) -join ','
    $manifestNames = ($manifest.runtimeFiles | Sort-Object) -join ','
    if ($copied.Count -eq 0 -or @($copied | Select-Object -Unique).Count -ne $copied.Count -or $copiedNames -cne $manifestNames) {
        throw 'Image-owned runtime closure differs from the Dockerfile.'
    }
    foreach ($name in $copied) {
        if ($name -cnotmatch '^[A-Za-z][A-Za-z0-9.-]+$' -or -not (Test-Path -LiteralPath (Join-Path $runner $name) -PathType Leaf)) {
            throw 'Image-owned runtime source is missing or unsafe.'
        }
    }
}
catch {
    # Never include paths, configuration bytes, native responses or inner errors.
    [Console]::Error.WriteLine('Runner build input validation failed. Check clean source identity, runtime closure and external configuration.')
    exit 1
}
if (-not $PSCmdlet.ShouldProcess('validated runner source', 'Build source-bound runner image')) {
    return
}
$arguments = @('build', '--file', (Join-Path $runner 'Dockerfile'), '--tag', $imageTag, '--label', "org.opencontainers.image.revision=$ExpectedCommit", $runner)
try {
    $null = Read-RunnerMaintenanceProfile -Path $configuration -ExpectedSha256 $ConfigurationSha256 -Operation build -SourceRoot $root -PrivateRoot $PrivateRoot -ExpectedCommit $ExpectedCommit
    . (Join-Path $runner 'Import-RunnerDiagnostic.ps1')
    Invoke-PrivateCommand -Executable $ContainerCommand -Argument $arguments -LimitSeconds $TimeoutSeconds -Owned | Out-Null
    $null = Read-RunnerMaintenanceProfile -Path $configuration -ExpectedSha256 $ConfigurationSha256 -Operation build -SourceRoot $root -PrivateRoot $PrivateRoot -ExpectedCommit $ExpectedCommit
}
catch {
    # Only errors deliberately produced by the private wrapper can cross this boundary.
    $message = $_.Exception.Message
    if ($message -cnotmatch '^Native (?:command|query) [a-zA-Z0-9 ;.-]+$') {
        $message = 'Native command outcome is unknown.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
@{
    sourceCommit = $ExpectedCommit
    runtimeManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    status = 'built-unqualified'
    tests = $null
    accepted = $false
} | ConvertTo-Json -Compress
