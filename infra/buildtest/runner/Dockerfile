FROM mcr.microsoft.com/dotnet/sdk:10.0 AS dotnet10
FROM mcr.microsoft.com/playwright/dotnet:v1.44.0-jammy

USER root
COPY --from=dotnet10 /usr/share/dotnet /usr/share/dotnet

# Supported general-purpose toolchain: .NET SDK 10, Playwright .NET browsers,
# Node.js 20, PowerShell, Git, archive tools, setsid and AzCopy.
# Project commands may require this toolchain, but application test policy is not
# part of the image. Network package installation is required during a real build.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl git tar gzip util-linux \
    && curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh \
    && bash /tmp/nodesource_setup.sh \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -f /tmp/nodesource_setup.sh \
    && curl -fsSL "https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb" -o /tmp/packages-microsoft-prod.deb \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && curl -fsSL "https://aka.ms/downloadazcopy-v10-linux" -o /tmp/azcopy.tar.gz \
    && tar -xzf /tmp/azcopy.tar.gz -C /tmp \
    && install -m 0755 /tmp/azcopy_linux_amd64_*/azcopy /usr/local/bin/azcopy \
    && rm -rf /tmp/azcopy* /tmp/packages-microsoft-prod.deb /var/lib/apt/lists/* \
    && mkdir -p /work /cache/nuget \
    && chmod 0777 /work /cache/nuget

COPY Invoke-Runner.ps1 Invoke-RunnerPipeline.ps1 Invoke-RunnerTransport.ps1 Import-RunnerResult.ps1 RunnerTimeout.psm1 RunnerCost.ps1 RunnerBuild.ps1 Import-RunnerDiagnostic.ps1 Invoke-DiagnosticOwnedCommand.ps1 DiagnosticContainment.cs RunnerProject.psm1 Invoke-ProjectCommand.ps1 project.schema.json /runner/
WORKDIR /work

# Fail the build when a required runtime tool is absent. This does not qualify
# an image: exact-source isolated build/run proof and immutable digest binding
# are separate release gates.
RUN setsid --version && node --version && dotnet --version && git --version && tar --version && gzip --version && azcopy --version && pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'

ENTRYPOINT ["pwsh", "-NoProfile", "-File", "/runner/Invoke-Runner.ps1"]
