<#
.SYNOPSIS
Verifies the four guide examples bind the real command parameter definitions.
.DESCRIPTION
Offline synthetic test only. Copies each real ParamBlock AST into an in-memory
non-operational stub, executes the complete guide example, and compares actual
PSBoundParameters with explicit synthetic selections. Does not import or execute
operational command bodies, read profiles or call any native tool. Writes only the
explicit test output file. Private operational values must never be supplied.
.PARAMETER SourceRoot
Synthetic runner source fixture containing the guide and four command definitions.
.PARAMETER OutputPath
Owned fixture JSON artifact receiving actual bound synthetic parameter values.
.EXAMPLE
./Test-RunnerMaintenanceBinding.ps1 -SourceRoot /work/source -OutputPath /work/binding.json
Checks guide binding offline using non-operational scriptblock stubs.
.OUTPUTS
None. Writes synthetic binding proof or throws a fixed failure.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$stubNames = @()
try {
    $guide = [IO.File]::ReadAllText((Join-Path $SourceRoot 'docs/runner-maintenance.md'))
    $blocks = [regex]::Matches($guide, '(?s)```powershell\r?\n(.*?)```')
    if ($blocks.Count -ne 5) {
        throw 'Unexpected example count.'
    }
    $names = @('Invoke-RunnerImageBuild.ps1', 'Publish-RunnerImage.ps1', 'Update-RunnerJobImage.ps1', 'Invoke-RunnerRun.ps1')
    $script:bindingProof = [Collections.Generic.List[object]]::new()
    $script:expectedBinding = @{
        SourceRoot = '/synthetic/source'
        ExpectedCommit = ('c' * 40)
        ConfigurationPath = '/synthetic/private/target.json'
        ConfigurationSha256 = ('a' * 64)
        PrivateRoot = '/synthetic/private'
        ContainerCommand = '/synthetic/podman'
        ProviderCommand = '/synthetic/az'
        ApprovalSha256 = ('d' * 64)
        QualificationEvidencePath = '/synthetic/private/evidence.json'
        RegistryAuthFile = '/synthetic/private/auth.json'
        RegistryAuthFileSha256 = ('e' * 64)
        ProjectConfigPath = 'ci/project.json'
        ProjectConfigSha256 = ('f' * 64)
        RunnerImage = ('example.azurecr.io/runner@sha256:' + ('b' * 64))
        ArtifactDestination = 'https://storage.example.invalid/results/run'
        ReleaseManifestPath = '/synthetic/private/release.json'
    }
    $assignments = @'
$sourceRoot='/synthetic/source'
$commit='cccccccccccccccccccccccccccccccccccccccc'
$privateTargetProfile='/synthetic/private/target.json'
$profileHash='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$privateRoot='/synthetic/private'
$podman='/synthetic/podman'
$azureCli='/synthetic/az'
$independentPublishApproval='/synthetic/private/publish-approval.json'
$publishApprovalHash='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
$publishEvidence='/synthetic/private/evidence.json'
$existingPodmanAuthFile='/synthetic/private/auth.json'
$authFileHash='eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
$newPublishReceipt='/synthetic/private/publish-receipt.json'
$independentDesiredImageApproval='/synthetic/private/deploy-approval.json'
$newDeploymentReceipt='/synthetic/private/deploy-receipt.json'
$projectRelativePath='ci/project.json'
$projectHash='ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
$sameProfileImmutableImage='example.azurecr.io/runner@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
$sameProfileArtifactDestination='https://storage.example.invalid/results/run'
$independentQualifiedRelease='/synthetic/private/release.json'
$newRunReceipt='/synthetic/private/run-receipt.json'
'@
    for ($index = 0; $index -lt $names.Count; $index++) {
        $name = $names[$index]
        $script:expectedBinding.ApprovalPath = if ($index -eq 1) {
            '/synthetic/private/publish-approval.json'
        }
        else {
            '/synthetic/private/deploy-approval.json'
        }
        $script:expectedBinding.StatePath = switch ($index) {
            1 {
                '/synthetic/private/publish-receipt.json'
            }
            2 {
                '/synthetic/private/deploy-receipt.json'
            }
            3 {
                '/synthetic/private/run-receipt.json'
            }
            default {
                ''
            }
        }
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot ('scripts/repo/' + $name)), [ref]$tokens, [ref]$errors)
        if ($errors.Count -ne 0) {
            throw 'Invalid real parameter source.'
        }
        $parameters = $ast.ParamBlock.Extent.Text
        $stubName = 'Test-GuideBinding' + $index
        $stubNames += $stubName
        $stubText = '[CmdletBinding(SupportsShouldProcess)]' + "`n" + $parameters + @'

$bound=@{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -eq 'WhatIf') {
        if (-not $PSBoundParameters[$key]) { throw 'Preview missing.' }
        $bound[$key]=[bool]$PSBoundParameters[$key]
    } else {
        if (-not $script:expectedBinding.ContainsKey($key) -or $PSBoundParameters[$key] -cne $script:expectedBinding[$key]) { throw 'Actual bound value mismatch.' }
        $bound[$key]=$PSBoundParameters[$key]
    }
}
foreach ($required in @('SourceRoot','ExpectedCommit','ConfigurationPath','ConfigurationSha256','PrivateRoot','WhatIf')) {
    if (-not $bound.ContainsKey($required)) { throw 'Required named selection absent.' }
}
$script:bindingProof.Add(@{bound=$bound})
'@
        $stub = [scriptblock]::Create($stubText)
        Set-Item -Path ('Function:' + $stubName) -Value $stub
        $example = $blocks[$index + 1].Groups[1].Value
        $example = $example.Replace('./scripts/repo/' + $name, $stubName)
        $complete = $assignments + "`n" + $blocks[0].Groups[1].Value + "`n" + $example
        & ([scriptblock]::Create($complete))
    }
    if ($script:bindingProof.Count -ne 4) {
        throw 'Binding proof incomplete.'
    }
    if ($PSCmdlet.ShouldProcess('owned synthetic proof artifact', 'Write guide binding result')) {
        [IO.File]::WriteAllText($OutputPath, ($script:bindingProof.ToArray() | ConvertTo-Json -Depth 20))
    }
}
catch {
    throw [InvalidOperationException]::new('Synthetic maintenance guide binding failed.')
}
finally {
    foreach ($name in $stubNames) {
        Remove-Item -Path ('Function:' + $name) -ErrorAction SilentlyContinue
    }
    Remove-Variable -Name bindingProof, expectedBinding -Scope Script -ErrorAction SilentlyContinue
}
