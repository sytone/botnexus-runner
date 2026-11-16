# Private maintenance target profile, version 1

This is the reader contract, not an operational command guide. The infrastructure, registry-build and existing image-update commands consume this profile.
First creation, validation and updates are documented in `infrastructure.md`. Never put a real profile, approval, receipt or journal in Git.

`Import-RunnerMaintenanceProfile.ps1` loads only the shared private I/O helpers.
`Read-RunnerMaintenanceProfile` requires explicit `Path`, `ExpectedSha256`,
`Operation`, `SourceRoot`, `PrivateRoot` and `ExpectedCommit`. It does not read an
environment selector, discover a target, sign in, modify the environment or write
per-operation configuration files. Keep its returned object private; do not print
or serialize it to public logs. Errors have one fixed message without private data.

## Schema

The file must be a regular, observed non-linked local file, 1–4096 bytes of strict
UTF-8 JSON. Its exact bytes must match the supplied lowercase SHA256. Unknown and
duplicate keys (including nested and case-colliding keys), nulls, wrong types and
unknown operations fail closed. Version must be the JSON integer `1`, not `1.0`,
`true` or a string. Every supplied value is validated, even outside the selected
operation. No credential fields, embedded URL credentials or SAS query strings.

- Required top-level keys: `schemaVersion`, `account`, `target`, `images`.
- Optional top-level key: `transport`.
- `account`: all of `tenantId`, `subscriptionId`, `accountType`, `accountName`.
  Account type is exactly `user` or `servicePrincipal`. A service principal name
  must be its explicit lowercase UUID; a user name is an explicit login/name.
- `target`: `resourceId` is always required. `managedIdentityResourceId` and
  `managedIdentityClientId` are operation-specific. The existing job and identity
  resource must use the selected subscription. Client ID is a lowercase UUID.
  Local syntax checks do not prove the client and resource identify the same
  provider object; operational provider validation must establish that.
- `images`: `buildTag` and/or `desiredImage`, as required below. A supplied build
  tag ends in `:src-<ExpectedCommit>`. Desired image is repository`@sha256:` followed
  by 64 lowercase hex characters. Neither is approval or qualification.
- `transport`: `sourceBlobUrl` and `artifactDestination` are credential-free,
  absolute HTTPS paths, without queries or fragments. They must differ.

The profile must be beneath the explicit existing `PrivateRoot`, outside
`SourceRoot`, and outside every observed ancestor containing `.git` (directory or
linked-worktree marker file). Path/ancestor checks are observed checks, not atomic
opens, an ACL policy or a filesystem sandbox. The trusted operator must keep the
private root and file stable. These checks do not inspect arbitrary historical Git
objects or certify that data was never committed elsewhere.

## In-memory projections

| Operation | Additional requirements | `configuration` result |
|---|---|---|
| `build` | `images.buildTag` | `imageTag` |
| `publish` | `images.buildTag` | `imageTag`; publisher also requires independent local-image qualification and explicit existing authfile |
| `deploy` | `images.desiredImage`, `target.managedIdentityResourceId` | Common account fields, `resourceId`, `image`, `managedIdentityResourceId` |
| `run` | `images.desiredImage`, `target.managedIdentityClientId`, both transport fields | Common account fields, `resourceId`, `managedIdentityClientId`, `sourceBlobUrl` |

Every result also contains `operation` and `profileSha256`. Run returns
`runnerImage` and `artifactDestination` as separate parameters. This matches the
existing run command's split between target configuration and execution arguments.
Build/publish do not require an already qualified desired digest. Any desired image
supplied anyway must still be immutable. Nothing is silently selected or invented.

Existing source-root/commit validation, project path/hash, approval and release
manifest, current-image provenance approval, receipt and journal inputs remain
separate caller responsibilities. Do not copy their authority into this profile.
No current-image approval is created by the reader. A shared target profile does
not waive independent image qualification or operator exclusion.

## Synthetic example only

All addresses and identities below are invented. Store real values only outside
Git in the operator-controlled private boundary.

```json
{
  "schemaVersion": 1,
  "account": {
    "tenantId": "22222222-2222-2222-2222-222222222222",
    "subscriptionId": "11111111-1111-1111-1111-111111111111",
    "accountType": "user",
    "accountName": "operator@example.invalid"
  },
  "target": {
    "resourceId": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.App/jobs/runner",
    "managedIdentityResourceId": "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/fixture/providers/Microsoft.ManagedIdentity/userAssignedIdentities/runner",
    "managedIdentityClientId": "33333333-3333-3333-3333-333333333333"
  },
  "images": {
    "buildTag": "example.azurecr.io/runner:src-cccccccccccccccccccccccccccccccccccccccc",
    "desiredImage": "example.azurecr.io/runner@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "transport": {
    "sourceBlobUrl": "https://storage.example.invalid/source/run.tar.gz",
    "artifactDestination": "https://storage.example.invalid/results/run"
  }
}
```

## Integrated existing commands

Pass `-ConfigurationPath /private/target.json -ConfigurationSha256 $profileHash
-PrivateRoot /private` as three separate named parameters to each existing command.
The hash covers the exact original profile file. No projected JSON file is created.
Build now requires the hash too. Old per-operation target schemas are rejected.

- `Invoke-RunnerImageBuild.ps1` uses the `build` projection. Source root/commit,
  native container command and original timeout remain explicit. It rechecks the
  profile immediately before native build and before emitting its receipt.
- `Update-RunnerJobImage.ps1` uses `deploy`. Desired-image approval, optional current
  image provenance approval and their hashes, state and reconciliation remain
  separate inputs. Existing pre-write and completion checks hash the profile file.
- `Invoke-RunnerRun.ps1` uses `run`. Explicit `-RunnerImage` and
  `-ArtifactDestination` must equal the profile values. Project config/path/hash,
  independent release manifest, state and reconciliation remain separate.

`-WhatIf` validates local inputs without native build/provider calls, generated
configuration files or environment changes. The profile reader never signs in or switches identity. Infrastructure provisioning
is performed explicitly by `New-RunnerInfrastructure.ps1`; existing deployment and run
still require their existing independent approvals and once-only state rules.
