# Retrieve and retain execution results

The runner-owned `scripts/repo/Invoke-RunnerRun.ps1` command submits a committed
application source snapshot and its protocol-v1 project configuration to an existing
job. It does not update the image or job definition. Application source must not
contain a runner Git pin or a copy of the runner client.

## Prerequisites

Live execution requires a clean exact source commit, the project configuration
path and its byte hash, a private target profile and its byte hash, a qualified
external runner release manifest, and an external private receipt path. The image
must match both the selected release and the existing job. Keep real inputs,
provider identities, receipts and results outside Git.

Use `-WhatIf` with the selected inputs first. Preview performs local checks, not
provider requests, authentication, deployment or application validation. An
unresolved deployment or execution journal blocks live execution. Do not clear,
replace or relocate that journal to get past the check.

## Retrieve one existing execution

Retain the original command inputs and add `-Reconcile` after the recorded execution
is terminal. This reads the same execution and downloads its evidence; it does not
start another execution or upload another source snapshot. Missing execution
identity, nonterminal status or incomplete evidence is not permission to resubmit.

Successful reconciliation retains:

| File | Location |
|---|---|
| Generic execution result | `<receipt-directory>/<run-id>.evidence/result.json` |
| Declared application artifacts | `<receipt-directory>/<run-id>.evidence/project/<artifact-path>` |
| Private evidence location | `evidencePath` in the original receipt and canonical completed audit |

Artifact paths retain their original names, including dot-prefixed files. The
command verifies source, image, project configuration, terminal state, cleanup,
required step identities and every declared artifact's byte count and SHA256.
Success, failure and cancellation all require complete declared evidence. An early
failure with missing artifacts remains unresolved; partial remote evidence must
not be called complete.

The complete verified staging directory is moved on the same filesystem without
replacement before completion is recorded. Repeated reconciliation may reuse an
existing directory only when its entire inventory and byte hashes match. Linked
paths, changed bytes, missing files or extra entries fail without overwriting the
retained directory. Keep the private directory stable; these observed filesystem
checks do not provide an atomic no-follow sandbox against a hostile local user.

The public command response includes `evidenceVerified: true` and
`evidenceRetained: true`, but excludes the private filesystem path. It still reports
`tests: null` and `accepted: false`. Read `evidencePath` from the private receipt to
inspect the files. **Provider success and verified transport are not application
test acceptance.** The application owner must check required builds and suites,
test counts, fixture failures and justified skips from the retained evidence.

## Recovery and cleanup

If retrieval fails, preserve the original receipt and operation journals. Repeat
only read-only reconciliation with the same inputs once its concrete failure is
resolved. A conflicting retained directory is not automatically deleted or repaired.
A crash after evidence retention may leave that directory before completion is
recorded; exact matching evidence can be reused on reconciliation.

Temporary failed downloads are removed. Completed evidence remains for the caller;
there is no automatic retention expiry. Remove only known-owned evidence after no
run, review, recovery or application acceptance still needs it. Never delete an
uncertain operation record to permit replay.

Offline fixtures verify retrieval behavior. They do not qualify a live release,
prove deployment, or prove that application tests have run. See
[infrastructure operations](infrastructure.md) for the separate setup stage.
