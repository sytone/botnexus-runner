# Runner infrastructure and maintenance safety

This page describes the portable source contract, not the state of a live
subscription. Historical operator-specific migration evidence is retained
privately. No probe, deployment, rebuild or resource deletion is authorized by
this document.

## Supported infrastructure interface

Use [first-time creation and updates](../../docs/infrastructure.md).
`New-RunnerInfrastructure.ps1` provides registry bootstrap, full infrastructure
creation/update, local preview, Azure validation and original-operation
reconciliation. `Invoke-RunnerRegistryBuild.ps1` builds and publishes image updates
through ACR with the selected Azure identity. `Update-RunnerJobImage.ps1` applies
image-only changes while preserving non-image job settings. All inputs and receipts
stay private. Job execution and workflow integration are separate.

`registry.bicep` creates the registry first. After publishing the image,
`main.bicep` creates the remaining resources using the immutable digest. Supply
explicit names; keep the same names for updates. `network.bicep` retains network
prerequisites for reviewed network operations. No application checkout is required.
Broad deployment is not an ordinary image update. No fixture grants cloud authority.

## Network changes need their own safety review

- Verify the actual environment type and current provider support. A profile
  named `Consumption` is not proof that an environment is Consumption-only or
  that subnet attachment is supported. This source makes no current live claim.
- If attachment requires a request containing only the subnet configuration,
  do not combine it with main-template registry, storage, identity, tags, role or
  job changes. Network prerequisites and attachment are separate concerns.
- Preserve delegation to `Microsoft.App/environments`, NAT attachment and a
  non-internal frontend. Verify egress authorization, address ownership and any
  required service tag; topology alone does not establish access.
- Attaching a subnet may change the frontend IP. Review direct-IP consumers, DNS
  records and refresh delays. Verify current addresses rather than relying on
  historical observations.
- Subnet attachment is one-way; removing it is not a supported rollback. A
  recovery plan may require recreation and an outage. Confirm that plan first.
- Verify address-space compatibility with actual connected networks and reserved
  ranges. The templates retain `10.0.0.0/16` and subnet `10.0.0.0/23`; also avoid
  `169.254.0.0/16`, `172.30.0.0/16`, `172.31.0.0/16`, `192.0.2.0/24` and profile
  reservations `100.100.0.0/17`, `100.100.128.0/19`, `100.100.160.0/19`,
  `100.100.192.0/19`. An example range is not proof of no local overlap.
- A template does not reproduce manually created resources. Inventory and review
  ownership before a rebuild; this page supplies no probe or deletion procedure.

## Capacity and evidence stay bounded

The declared `BuildTestD8` profile is D8 with minimum zero and maximum five nodes,
not one. Each manual execution has one replica, 8 vCPU and 24 GiB. Verify regional
availability and cost separately. Keep the 1200-second platform execution allowance,
zero replica retries and per-execution parallelism/completion count of one.
Do not increase a clock to hide a failure. Do not remove a profile while a job
still selects it; changes to capacity need independent compatibility review.

A hung command or lost response does not prove that nothing changed. Preserve
UNKNOWN receipts and canonical journals, keep every other writer excluded through
terminal completion and verified readback, and reconcile read-only before any
retry. A local lock is not provider atomicity. Stop if exclusion is lost.
Successful submission, compilation or deployment is not proof of a successful run.
Retain complete test/artifact evidence, partial failures and unknown outcomes.

Independent source/privacy review, safe publication history, affected infrastructure
checks and human merge approval remain required. Application CORE, container job
execution and workflow changes are not prerequisites for this repository move. A sanitized tip
cannot clear private imported ancestors, metadata or generated assets.
