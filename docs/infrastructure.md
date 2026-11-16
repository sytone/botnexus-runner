# Create and update the runner infrastructure

This repository contains the Azure templates, container runtime, Docker build
context and maintenance commands. No BotNexus application checkout is needed.
Container job execution and application workflow integration are separate work.

## Prerequisites

- PowerShell 7.5 or later, Git, Azure CLI and Bicep.
- An existing Azure sign-in with permission for the selected subscription,
  resource group, registry, Container Apps environment, managed identity and roles.
  Commands verify the selected account; they never sign in or switch identity.
- A clean committed runner checkout. Set `$runnerRoot` to its absolute path and
  `$commit` to its exact `git rev-parse HEAD` value.
- An existing private directory outside Git for parameters, the
  [target profile](maintenance-profile-v1.md), approvals and receipts.
  Set `$privateRoot` to that absolute directory. Never commit real settings.

Choose resource names and a region explicitly. First creation includes a VNet,
NAT gateway, storage, registry, managed identity and a manual Container Apps job.
Review network ranges, provider support, roles and cost before applying templates.
Updates must keep the same resource names. Changing a name is not a safe rename.
For an existing subnet with a network security group, supply the observed resource
ID as the optional `subnetNetworkSecurityGroupId` parameter in both templates.
Review Azure what-if before applying; do not detach an existing security group.

## Private input files

The target profile selects the existing Azure account and desired resource IDs.
For the registry/build phases it needs `images.buildTag` with this form:
`<registry>.azurecr.io/runner:src-<commit>`. Each changed source commit has a new tag.

The ARM parameter file has the standard deployment-parameters shape:

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "registryName": { "value": "example" }
  }
}
```

This is synthetic, not a deployment target. The Registry phase accepts only
`registryName`. The Infrastructure phase additionally needs `operatorObjectId`,
`runnerImageRepository`, `runnerImageDigest`, `storageAccountName`, `identityName`,
`environmentName`, `jobName`, `vnetName`, `subnetName`, `natGatewayName`,
`publicIpName`, `projectConfigPath` and `projectConfigSha256`. The last two are
explicit runtime defaults; supplying them does not execute a project. The job
remains manual. No application checkout is read to provision it.

Set the Infrastructure profile's `images.desiredImage` to the immutable reference
returned by the registry build receipt. `target.managedIdentityResourceId` must
name the identity created by these exact parameters. Templates and profile must
select the same registry, subscription, resource group, job and identity.

## First creation

Use the runner checkout as the current directory. These examples use explicit
operator-selected variables, not live defaults. Hash each private file after
preparing it. Recalculate its hash if it changes.

```powershell
$common = @{
    SourceRoot = $runnerRoot
    ExpectedCommit = $commit
    ConfigurationPath = $profilePath
    ConfigurationSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash.ToLowerInvariant()
    PrivateRoot = $privateRoot
}
$registryArguments = $common.Clone()
$registryArguments += @{
    Phase = 'Registry'
    Location = $location
    ParametersPath = $registryParametersPath
    ParametersSha256 = (Get-FileHash -LiteralPath $registryParametersPath -Algorithm SHA256).Hash.ToLowerInvariant()
    StatePath = $registryReceiptPath
}
& ./scripts/repo/New-RunnerInfrastructure.ps1 @registryArguments -WhatIf
& ./scripts/repo/New-RunnerInfrastructure.ps1 @registryArguments
```

1. **Create registry.** The Registry phase creates the resource group and registry.
2. **Build and publish image.** Submit the runner Docker context to ACR:

```powershell
$buildArguments = $common.Clone()
$buildArguments.StatePath = $imageReceiptPath
& ./scripts/repo/Invoke-RunnerRegistryBuild.ps1 @buildArguments -WhatIf
& ./scripts/repo/Invoke-RunnerRegistryBuild.ps1 @buildArguments
```

The build is asynchronous. An incomplete response is not success. Keep the receipt,
then use the same command and arguments with `-Reconcile` to inspect that run.
Do not submit another build while its outcome is uncertain. The command verifies
successful ACR output and the registry digest; the private receipt's `image` field
contains the immutable reference. No local registry authfile or Podman push is used.

3. **Deploy infrastructure.** Put that digest into the private full parameters and
profile, refresh the profile hash in `$common`, then run:

```powershell
$infraArguments = $common.Clone()
$infraArguments += @{
    Phase = 'Infrastructure'
    Location = $location
    ParametersPath = $infrastructureParametersPath
    ParametersSha256 = (Get-FileHash -LiteralPath $infrastructureParametersPath -Algorithm SHA256).Hash.ToLowerInvariant()
    StatePath = $infrastructureReceiptPath
}
& ./scripts/repo/New-RunnerInfrastructure.ps1 @infraArguments -WhatIf
& ./scripts/repo/New-RunnerInfrastructure.ps1 @infraArguments -ValidateOnly
& ./scripts/repo/New-RunnerInfrastructure.ps1 @infraArguments
```

`-WhatIf` performs local checks only. `-ValidateOnly` calls Azure template validation
for an existing resource group, without deployment or receipt writes. Registry
validation also requires an already existing resource group. A successful deployment
must match its original deployment ID and expected resource outputs. The private
receipt retains outputs; public console output does not disclose target settings.

## Infrastructure updates

Review the template diff and use the Infrastructure phase with the same target
names and intended immutable image. It uses ARM Incremental mode; it does not
request deletion of resources omitted from the template. Preview locally and use
`-ValidateOnly` before applying a separately reviewed update with a new receipt.
Do not use broad infrastructure deployment for an ordinary image-only update.
Existing subnet attachment may be irreversible; never infer rollback support.

## Image updates

For a new committed runner version, select a new source-bound build tag, update
`ExpectedCommit` and the profile hash, and build/publish with a new image receipt.
The builder refuses an already existing tag rather than overwriting it.

After independent review of the image/source, select that immutable digest in the
private target profile. Use `Update-RunnerJobImage.ps1` with the common inputs,
`ApprovalPath` and a new `StatePath`. Preview with `-WhatIf`, then apply the same
arguments without it. This command updates only the existing job's image and
verifies non-image settings are preserved. A tag-based current image also needs
`CurrentImageApprovalPath` and `CurrentImageApprovalSha256` identifying its reviewed
immutable provenance. Neither operation starts a container job.

`Invoke-RunnerImageBuild.ps1` remains available for a local build check. The older
`Publish-RunnerImage.ps1` local-credential adapter is unsupported and disabled;
it is not part of this supported ACR build/publish path.

## Incomplete operations

Keep the original receipt and use `-Reconcile` for the same deployment or build.
No automatic retry, changed receipt path or deleted journal may bypass an uncertain
operation. First bootstrap can fail after creating the group but before submitting
the registry deployment. In that case, inspect the group and the recorded deployment
name through Azure's supported read-only tools. Missing build/deployment identity
remains unknown: establish whether submission happened before authorizing a new
operation. One operator owns the update through completion and readback.

## Validation and delivery

Compile `registry.bicep`, `main.bicep` and `network.bicep` with Bicep. Run exact-file
PowerShell quality and the isolated offline provisioning/build/update fixtures.
Offline tests are not a live Azure build, deployment or container job run. Review
outgoing source/history for private settings before publishing. Application tests,
workflow recovery and job execution are not prerequisites for this infrastructure
repository move. Human merge and selected-target authorization boundaries remain.
