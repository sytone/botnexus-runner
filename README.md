# Standalone runner infrastructure

This repository owns the Azure infrastructure, image construction and container
runtime for an independently maintained build agent. It contains Bicep templates,
a complete Docker build context, deployment/update scripts and their tests.
Applications supply their own commands; no application checkout or runner Git pin
is required to create or update this infrastructure.

## Supported infrastructure commands

| Operation | Command |
|---|---|
| Create initial registry | `scripts/repo/New-RunnerInfrastructure.ps1 -Phase Registry` |
| Build and publish image using ACR | `scripts/repo/Invoke-RunnerRegistryBuild.ps1` |
| Validate Azure templates | `scripts/repo/New-RunnerInfrastructure.ps1 -ValidateOnly` |
| Create/update Azure infrastructure | `scripts/repo/New-RunnerInfrastructure.ps1 -Phase Infrastructure` |
| Update only the deployed image | `scripts/repo/Update-RunnerJobImage.ps1` |
| Optional local image build check | `scripts/repo/Invoke-RunnerImageBuild.ps1` |

Start with [first-time setup and updates](docs/infrastructure.md), using an external
private [target profile](docs/maintenance-profile-v1.md). Named inputs are required.
No command signs in or changes the selected identity. Preview does not prove live
readiness. Incomplete operations retain their original receipts for reconciliation.

The old local-credential `Publish-RunnerImage.ps1` adapter remains disabled. Use the
supported ACR build/publish command instead; no local registry credential is needed.

## Container runtime

The image includes the runtime and tools. Its entrypoint is
`infra/buildtest/runner/Invoke-Runner.ps1`; image inputs are declared by
`image-runtime.json` and `Dockerfile`. Preserve containment, deadline, cleanup and
failure evidence when updating runtime files. Job execution, source submission and
result acceptance are a separate stage after infrastructure extraction. Do not
rebuild infrastructure for an ordinary project run. The separate
[result-retrieval guide](docs/execution-results.md) describes retained evidence and
its limits; offline checks do not qualify a live execution target.

## Validation

Compile all three Bicep templates and run exact-file quality plus isolated offline
provisioning, ACR build and image-update checks. Tests must retain negative cases;
missing evidence or unknown outcomes are not success. Existing runtime tests stay
with the runtime source; this infrastructure delivery does not claim job execution
or application acceptance. See the [portable infrastructure guide](infra/buildtest/README-migration.md).

## Privacy and publication

Keep real names, identities, credentials, profiles, receipts and logs outside Git.
`SOURCE-PROVENANCE.json` records the original import, not release approval. Review
outgoing source and history independently before publication; a clean tip cannot
clear private ancestors. Preserve originals privately. Do not publish unsafe import
history or force-push. Human merge approval remains required.
