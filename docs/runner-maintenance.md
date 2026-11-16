# Runner infrastructure maintenance

Use the supported [infrastructure creation and update guide](infrastructure.md).
It covers registry bootstrap, ACR image build/publication, template validation,
infrastructure deployment and image-only updates. Keep all target settings outside
Git in the [private target profile](maintenance-profile-v1.md).

Container job execution is separate and deferred until the infrastructure move is
complete. Existing execution code and tests are preserved, not declared qualified
by this documentation or the offline infrastructure checks.

`Publish-RunnerImage.ps1` is the old disabled local-credential adapter, not the
supported publication route. `Invoke-RunnerRegistryBuild.ps1` uses Azure's build
service and verifies its output against the registry digest. No Podman credential
selection is part of that route.
