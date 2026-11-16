<#
.SYNOPSIS
Publishes one independently qualified local runner image with a once-only fence.
.DESCRIPTION
Consumes the single private maintenance profile and separate hash-pinned independent
qualification. Never builds, qualifies, signs in, switches identity or provisions.
WhatIf checks local files and schemas only: zero native calls, files or environment
changes. It does NOT prove Git cleanliness, local image state or registry readiness.
Actual execution currently denies before any native command or journal because
installed Windows client/server/connection and effective helper selection have not
been independently qualified. No parameter, environment flag or approval boolean
can enable that path. The retained once-only machinery requires a future reviewed
adapter, not caller attestation. Preview proves local structure only.
The trusted operator must exclude every other writer through readback and UNKNOWN
investigation. Local reservation is not registry atomicity; stop if exclusion is lost.
.PARAMETER SourceRoot
Exact clean local runner checkout. WhatIf does not invoke Git to verify cleanliness.
.PARAMETER ExpectedCommit
Exact lowercase source commit independently qualified for this image.
.PARAMETER ConfigurationPath
One strict external private version1 maintenance profile with publish buildTag.
.PARAMETER ConfigurationSha256
Exact SHA256 of profile bytes, not its in-memory projection.
.PARAMETER PrivateRoot
Explicit existing private directory containing profile, approval, evidence, authfile
and receipt. Must be outside the source and Git; keep all paths stable.
.PARAMETER ApprovalPath
Independent external qualification JSON with exactly approved, revoked, sourceCommit,
imageTag, localImageId, manifestDigest, runtimeManifestSha256 and evidenceSha256.
Approval must bind the local image ID, intended registry manifest digest, source and
runtime closure to independently retained qualification evidence. This command
consumes approval; it does not issue it or treat author fixtures as real authority.
.PARAMETER ApprovalSha256
Exact lowercase SHA256 of independently selected approval bytes.
.PARAMETER QualificationEvidencePath
Separate regular private qualification evidence file whose exact hash is approved.
Evidence is opaque here; independent review must establish its meaning and authority.
.PARAMETER RegistryAuthFile
Explicit existing operator-managed Podman registry authfile. Never created or printed.
Only one canonical host auths.auth entry is supported; no helpers, tokens or aliases.
No login or automatic credential provisioning. Qualify authfile behavior on the
actual Podman client before live use. Explicit authfile alone does not exclude helpers.
.PARAMETER RegistryAuthFileSha256
Exact authfile byte hash. It binds selection without exposing credential contents.
.PARAMETER StatePath
New private receipt or original receipt for Reconcile. Canonical tag-keyed journal
owns replay protection; alternate receipt paths cannot bypass retained UNKNOWN.
.PARAMETER ContainerCommand
Supported Podman executable; tests substitute an inert synthetic tool.
.PARAMETER ProviderCommand
Supported existing Azure CLI executable for pinned account and registry metadata.
.PARAMETER TimeoutSeconds
Original shared native operation allowance, including cleanup and readback. No retry.
.PARAMETER Reconcile
Read-only registry reconciliation of the original journal/receipt. Never pushes.
.EXAMPLE
./Publish-RunnerImage.ps1 -SourceRoot /source -ExpectedCommit $commit -ConfigurationPath /private/target.json -ConfigurationSha256 $hash -PrivateRoot /private -ApprovalPath /private/qualified.json -ApprovalSha256 $approvalHash -QualificationEvidencePath /private/evidence.json -RegistryAuthFile /private/auth.json -RegistryAuthFileSha256 $authHash -StatePath /private/publish.json -WhatIf
Validates local selections only without native calls or mutation; not readiness proof.
.OUTPUTS
System.String. Redacted published JSON, tests null and accepted false after exact
readback. Fixed validation or UNKNOWN error otherwise; durable fences are retained.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$ExpectedCommit,
    [Parameter(Mandatory)][string]$ConfigurationPath,
    [Parameter(Mandatory)][string]$ConfigurationSha256,
    [Parameter(Mandatory)][string]$PrivateRoot,
    [Parameter(Mandatory)][string]$ApprovalPath,
    [Parameter(Mandatory)][string]$ApprovalSha256,
    [Parameter(Mandatory)][string]$QualificationEvidencePath,
    [Parameter(Mandatory)][string]$RegistryAuthFile,
    [Parameter(Mandatory)][string]$RegistryAuthFileSha256,
    [Parameter(Mandatory)][string]$StatePath,
    [string]$ContainerCommand = 'podman',
    [string]$ProviderCommand = 'az',
    [ValidateRange(4, 600)][int]$TimeoutSeconds = 120,
    [switch]$Reconcile
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-RunnerPublishInput {
    <#
    .SYNOPSIS
    Rechecks selected private input bytes without exposing their contents.
    .DESCRIPTION
    Uses existing observed-path checks and SHA256. No native calls or writes.
    .PARAMETER Path
    Existing private regular file.
    .PARAMETER Hash
    Exact operator-selected lowercase SHA256.
    .EXAMPLE
    Assert-RunnerPublishInput -Path $approvalFile -Hash $ApprovalSha256
    .OUTPUTS
    None. Throws on changed or malformed selection.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$Hash)
    $null = Assert-ObservedPath -Path $Path
    if ($Hash -cnotmatch '^[0-9a-f]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Hash) {
        throw 'Publish input changed.'
    }
}

function Assert-RunnerPublishAuth {
    <#
    .SYNOPSIS
    Checks the narrow file-only credential contract without exposing credentials.
    .DESCRIPTION
    Reuses bounded strict UTF8 duplicate-safe JSON parsing and observed paths.
    Requires one exact host entry and canonical base64 username:password. Checks
    existing private owner-only metadata without native commands or ACL changes.
    Hash-before/after detects observed drift, not an atomic native credential
    snapshot. Trusted filesystem/operator and external writer exclusion remain
    prerequisites; transient replacement between observations can escape detection.
    .PARAMETER Path
    Existing operator-managed private regular single-link credential file.
    .PARAMETER Hash
    Original selected lowercase SHA256 of exact file bytes.
    .PARAMETER HostName
    Exact lowercase host from the selected fully qualified image tag.
    .PARAMETER PrivateDirectory
    Existing owner-only private boundary; ancestors inside it must be protected.
    .EXAMPLE
    Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
    .OUTPUTS
    None. Fixed redacted terminating error on unsupported input or assurance.
    #>
    [CmdletBinding()]
    param([string]$Path, [string]$Hash, [string]$HostName, [string]$PrivateDirectory)
    try {
        Assert-RunnerPublishInput -Path $Path -Hash $Hash
        $node = $Path
        while ($node) {
            $item = Get-Item -LiteralPath $node -Force -ErrorAction Stop
            if ($IsLinux) {
                $mode = [IO.File]::GetUnixFileMode($node)
                $allowed = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
                if ($item.PSIsContainer) {
                    $allowed = $allowed -bor [IO.UnixFileMode]::UserExecute
                }
                if ($mode -ne $allowed -or $item.User -cne [Environment]::UserName -or
                    (-not $item.PSIsContainer -and $item.UnixStat.HardlinkCount -ne 1)) {
                    throw 'Unsafe private credential metadata.'
                }
            }
            elseif ($IsWindows) {
                # Reuse the existing Windows owner/protected-ACL observer. Its
                # Windows branch performs managed metadata reads, not native I/O.
                Assert-RunnerJournalPath -Path $node -Directory:$item.PSIsContainer
                # Windows hard-link count assurance is not supplied by that helper.
                # Deny rather than claim a regular path proves single-link identity.
                throw 'Private credential link assurance unavailable.'
            }
            else {
                throw 'Unsupported credential filesystem assurance.'
            }
            if ($node -ceq $PrivateDirectory) {
                break
            }
            $node = [IO.Path]::GetDirectoryName($node)
        }
        if (-not $node) {
            throw 'Private credential boundary missing.'
        }
        $authDocument = Read-RunnerPrivateObject -Path $Path
        if ($authDocument.Count -ne 1 -or @($authDocument.Keys)[0] -cne 'auths' -or
            $authDocument.auths -isnot [Collections.IDictionary] -or $authDocument.auths.Count -ne 1 -or
            @($authDocument.auths.Keys)[0] -cne $HostName) {
            throw 'Unsupported credential schema.'
        }
        $entry = $authDocument.auths[$HostName]
        if ($entry -isnot [Collections.IDictionary] -or $entry.Count -ne 1 -or @($entry.Keys)[0] -cne 'auth' -or
            $entry.auth -isnot [string] -or $entry.auth -cnotmatch '^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$' -or
            [string]::IsNullOrEmpty($entry.auth)) {
            throw 'Unsupported credential encoding.'
        }
        $decoded = [Convert]::FromBase64String($entry.auth)
        if ([Convert]::ToBase64String($decoded) -cne $entry.auth) {
            throw 'Noncanonical credential encoding.'
        }
        $credential = [Text.UTF8Encoding]::new($false, $true).GetString($decoded)
        $colon = $credential.IndexOf(':')
        if ($colon -le 0 -or $colon -ge ($credential.Length - 1)) {
            throw 'Credential components missing.'
        }
        $userName = $credential.Substring(0, $colon)
        $password = $credential.Substring($colon + 1)
        if ($userName -cnotmatch '^[!-9;-~]+$' -or [string]::IsNullOrWhiteSpace($password)) {
            throw 'Unsupported credential components.'
        }
        foreach ($character in $credential.ToCharArray()) {
            if ([char]::IsControl($character)) {
                throw 'Unsupported credential character.'
            }
        }
        Assert-RunnerPublishInput -Path $Path -Hash $Hash
    }
    catch {
        throw 'Runner publish credential validation failed.'
    }
    finally {
        if ($null -ne (Get-Variable -Name decoded -ErrorAction SilentlyContinue)) {
            [Array]::Clear($decoded, 0, $decoded.Length)
        }
        $credential = $null
        $password = $null
        $userName = $null
        $authDocument = $null
    }
}

function Assert-RunnerPublishNativeSelection {
    <#
    .SYNOPSIS
    Denies unqualified native credential selection before any native side effect.
    .DESCRIPTION
    Exact installed Windows client/server/connection, effective configuration and
    owned-process environment evidence is absent. Explicit authfile suppresses
    default file search but does not suppress independent global/per-file helpers.
    No caller-controlled approval or test switch can qualify this prerequisite.
    Readback account identity is not proof of the push credential subject or scope.
    .EXAMPLE
    Assert-RunnerPublishNativeSelection
    .OUTPUTS
    None. Always throws until a separately reviewed qualified adapter replaces it.
    #>
    [CmdletBinding()]
    param()
    throw 'Runner publish native credential selection is not qualified.'
}

function Invoke-RunnerPublishRead {
    <#
    .SYNOPSIS
    Reads one bounded private native object under the original operation clock.
    .DESCRIPTION
    Reuses owned process containment and strict duplicate-safe object parsing.
    .PARAMETER Executable
    Explicit native executable, never shell text.
    .PARAMETER Argument
    Literal read-only native argument array.
    .EXAMPLE
    $account = Invoke-RunnerPublishRead -Executable $ProviderCommand -Argument @('account', 'show', '--output', 'json')
    .OUTPUTS
    System.Collections.IDictionary. Private bounded object, never public output.
    #>
    [CmdletBinding()]
    [OutputType([Collections.IDictionary])]
    param([string]$Executable, [string[]]$Argument)
    $text = Invoke-PrivateCommand -Executable $Executable -Argument $Argument -LimitSeconds $TimeoutSeconds -RunClock $clock -Owned -Capture
    return ConvertFrom-RunnerPrivateJson -Text $text
}

function Assert-RunnerPublishedImage {
    <#
    .SYNOPSIS
    Requires exact registry tag and immutable manifest readback.
    .DESCRIPTION
    CLI extracts tag attributes with name=tag and manifest attributes without name.
    Registry/repository/subscription are bound by literal queries. Repeats tag lookup
    after digest readback; unknown or conflicting data fails without a push retry.
    .EXAMPLE
    Assert-RunnerPublishedImage
    .OUTPUTS
    None. Throws unless current tag and manifest agree with independent qualification.
    #>
    [CmdletBinding()]
    param()
    foreach ($query in @("${repository}:$tag", "${repository}@$digest", "${repository}:$tag")) {
        $metadata = Invoke-RunnerPublishRead -Executable $ProviderCommand -Argument @('acr', 'manifest', 'show-metadata', '--registry', $registry, '--name', $query, '--subscription', $accountConfiguration.subscriptionId, '--only-show-errors', '--output', 'json')
        if ($metadata.digest -isnot [string] -or $metadata.digest -cne $digest) {
            throw 'Published immutable identity conflicts.'
        }
        if ($query -ceq "${repository}:$tag") {
            if ($metadata.name -isnot [string] -or $metadata.name -cne $tag) {
                throw 'Published tag identity conflicts.'
            }
        }
        else {
            if ($metadata.tags -isnot [array] -or $metadata.tags.Count -lt 1 -or $metadata.tags.Count -gt 1024) {
                throw 'Published manifest tag evidence missing.'
            }
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($alias in $metadata.tags) {
                if ($alias -isnot [string] -or $alias -cnotmatch '^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$' -or -not $seen.Add($alias)) {
                    throw 'Published manifest tags malformed.'
                }
            }
            if (-not $seen.Contains($tag)) {
                throw 'Published manifest tag mismatch.'
            }
        }
    }
}

$attempted = $false
$reservation = $null
try {
    . (Join-Path $PSScriptRoot 'Import-RunnerMaintenanceProfile.ps1')
    . (Join-Path $PSScriptRoot 'Import-RunnerTargetJournal.ps1')
    $root = Assert-ObservedPath -Path $SourceRoot -Directory
    $private = (Assert-ObservedPath -Path $PrivateRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $selection = Read-RunnerMaintenanceProfile -Path $ConfigurationPath -ExpectedSha256 $ConfigurationSha256 -Operation publish -SourceRoot $root -PrivateRoot $private -ExpectedCommit $ExpectedCommit
    $imageTag = $selection.configuration.imageTag
    if ($imageTag -cnotmatch '^(?<registry>[a-z0-9]+(?:-[a-z0-9]+)*)\.azurecr\.io/(?<repository>[a-z0-9]+(?:[._/-][a-z0-9]+)*):(?<tag>src-[0-9a-f]{40})$') {
        throw 'Unsupported explicit registry.'
    }
    $registry = $Matches.registry
    $authHost = $registry + '.azurecr.io'
    $repository = $Matches.repository
    $tag = $Matches.tag
    $profileFile = Assert-ObservedPath -Path $ConfigurationPath
    $approvalFile = Assert-ObservedPath -Path $ApprovalPath
    $evidenceFile = Assert-ObservedPath -Path $QualificationEvidencePath
    $authFile = Assert-ObservedPath -Path $RegistryAuthFile
    $stateFile = [IO.Path]::GetFullPath($StatePath)
    $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($stateFile)) -Directory
    $paths = @($profileFile, $approvalFile, $evidenceFile, $authFile, $stateFile)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else {
        [StringComparison]::Ordinal
    }
    $pathComparer = if ($IsWindows) {
        [StringComparer]::OrdinalIgnoreCase
    }
    else {
        [StringComparer]::Ordinal
    }
    $uniquePaths = [Collections.Generic.HashSet[string]]::new($pathComparer)
    foreach ($path in $paths) {
        if (-not $uniquePaths.Add($path)) {
            throw 'Conflicting private artifacts.'
        }
        if (-not $path.StartsWith($private + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            $path.StartsWith($root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Private artifact boundary conflict.'
        }
        if (Test-Path -LiteralPath $path) {
            $null = Assert-ObservedPath -Path $path
        }
        $ancestor = [IO.Path]::GetDirectoryName($path)
        while ($ancestor) {
            $null = Assert-ObservedPath -Path $ancestor -Directory
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
                throw 'Private artifact belongs to a Git work area.'
            }
            $parent = [IO.Directory]::GetParent($ancestor)
            $ancestor = if ($null -eq $parent) {
                $null
            }
            else {
                $parent.FullName
            }
        }
    }
    Assert-RunnerPublishInput -Path $approvalFile -Hash $ApprovalSha256
    Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
    $approval = Read-RunnerPrivateObject -Path $approvalFile
    if ((($approval.Keys | Sort-Object) -join ',') -cne 'approved,evidenceSha256,imageTag,localImageId,manifestDigest,revoked,runtimeManifestSha256,sourceCommit' -or
        $approval.approved -isnot [bool] -or -not $approval.approved -or $approval.revoked -isnot [bool] -or $approval.revoked) {
        throw 'Independent qualification missing or revoked.'
    }
    foreach ($field in @('sourceCommit', 'imageTag', 'localImageId', 'manifestDigest', 'runtimeManifestSha256', 'evidenceSha256')) {
        if ($approval[$field] -isnot [string]) {
            throw 'Invalid qualification type.'
        }
    }
    $runtimeHash = (Get-FileHash -LiteralPath (Join-Path $root 'infra/buildtest/runner/image-runtime.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($approval.sourceCommit -cne $ExpectedCommit -or $approval.imageTag -cne $imageTag -or $approval.localImageId -cnotmatch '^[0-9a-f]{64}$' -or
        $approval.manifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$' -or $approval.runtimeManifestSha256 -cne $runtimeHash) {
        throw 'Qualified image or source mismatch.'
    }
    Assert-RunnerPublishInput -Path $evidenceFile -Hash $approval.evidenceSha256
    $digest = $approval.manifestDigest
    # The canonical reader already checked every account field. Reuse its private
    # deploy-independent account section from the same exact profile, never a temp config.
    $document = Read-RunnerPrivateObject -Path $profileFile
    $accountConfiguration = $document.account
    $accountConfiguration.resourceId = $document.target.resourceId
    Assert-RunnerAccountBinding -Configuration $accountConfiguration
    if (-not $Reconcile -and (Test-Path -LiteralPath $stateFile)) {
        throw 'Existing receipt requires reconciliation.'
    }
    if (-not $PSCmdlet.ShouldProcess('independently qualified runner image', 'Push once or reconcile exact immutable registry readback')) {
        return
    }
    Assert-RunnerPublishNativeSelection
    $clock = [Diagnostics.Stopwatch]::StartNew()
    . (Join-Path $root 'infra/buildtest/runner/Import-RunnerDiagnostic.ps1')
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    $observedAccount = Invoke-RunnerPublishRead -Executable $ProviderCommand -Argument @('account', 'show', '--output', 'json', '--only-show-errors')
    Assert-RunnerAccountBinding -Configuration $accountConfiguration -Account $observedAccount
    $reservation = Enter-RunnerTargetReservation -Resource ('publish:' + $imageTag)
    $journal = Join-Path $reservation.Root ($reservation.Key + '.publish.json')
    # No native-selection fingerprint is available: the unconditional guard above
    # forbids production creation. A future adapter must bind its reviewed policy.
    $binding = @{
        authContractVersion = 1
        authFilePath = $authFile
        authFileSha256 = $RegistryAuthFileSha256
        authRegistryHost = $authHost
        authRegistryKey = $authHost
        sourceCommit = $ExpectedCommit
        configurationSha256 = $ConfigurationSha256
        approvalSha256 = $ApprovalSha256
        evidenceSha256 = $approval.evidenceSha256
        localImageId = $approval.localImageId
        imageTag = $imageTag
        digest = $digest
        status = 'attempted-unknown'
    }
    if ($Reconcile) {
        Assert-RunnerJournalPath -Path $journal
        Assert-RunnerJournalPath -Path $stateFile
        $prior = Read-RunnerPrivateObject -Path $journal
        $receipt = Read-RunnerPrivateObject -Path $stateFile
        foreach ($key in $binding.Keys) {
            if (-not $prior.Contains($key) -or -not $receipt.Contains($key)) {
                throw 'Original publish binding missing.'
            }
            if ($key -ceq 'authContractVersion') {
                if ($prior[$key] -isnot [long] -or $receipt[$key] -isnot [long]) {
                    throw 'Original publish contract version malformed.'
                }
            }
            elseif ($prior[$key] -isnot [string] -or $receipt[$key] -isnot [string]) {
                throw 'Original publish binding type conflict.'
            }
            if ($key -cne 'status' -and ($prior[$key] -cne $binding[$key] -or $receipt[$key] -cne $prior[$key])) {
                throw 'Publish receipt binding conflict.'
            }
        }
        if ($prior.status -cnotin @('attempted-unknown', 'completed-reconciled') -or $receipt.status -cne $prior.status) {
            throw 'Publish status conflict.'
        }
        $attempted = $true
    }
    else {
        if (Test-Path -LiteralPath $journal) {
            throw 'Canonical publish fence exists.'
        }
        $local = Invoke-RunnerPublishRead -Executable $ContainerCommand -Argument @('image', 'inspect', '--format', '{{json .}}', $approval.localImageId)
        if ($local.Id -cne $approval.localImageId -or $local.Digest -cne $digest -or $local.Config.Labels.'org.opencontainers.image.revision' -cne $ExpectedCommit) {
            throw 'Qualified local image identity or revision conflicts.'
        }
    }
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    $null = Read-RunnerMaintenanceProfile -Path $profileFile -ExpectedSha256 $ConfigurationSha256 -Operation publish -SourceRoot $root -PrivateRoot $private -ExpectedCommit $ExpectedCommit
    Assert-RunnerPublishInput -Path $approvalFile -Hash $ApprovalSha256
    Assert-RunnerPublishInput -Path $evidenceFile -Hash $approval.evidenceSha256
    Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
    if ($clock.Elapsed.TotalSeconds -ge ($TimeoutSeconds - 2)) {
        throw 'Original publish allowance exhausted.'
    }
    if (-not $Reconcile) {
        Write-RunnerJournalRecord -Path $journal -Record $binding -Create
        $attempted = $true
        Write-RunnerJournalRecord -Path $stateFile -Record $binding -Create
        Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
        Invoke-PrivateCommand -Executable $ContainerCommand -Argument @('push', '--retry=0', '--tls-verify=true', '--authfile', $authFile, $approval.localImageId, ('docker://' + $imageTag)) -LimitSeconds $TimeoutSeconds -RunClock $clock -Owned | Out-Null
    }
    Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
    Assert-RunnerPublishedImage
    Assert-RunnerPublishAuth -Path $authFile -Hash $RegistryAuthFileSha256 -HostName $authHost -PrivateDirectory $private
    Assert-RunnerOperationSource -Root $root -Commit $ExpectedCommit
    Assert-RunnerPublishInput -Path $profileFile -Hash $ConfigurationSha256
    Assert-RunnerPublishInput -Path $approvalFile -Hash $ApprovalSha256
    Assert-RunnerPublishInput -Path $evidenceFile -Hash $approval.evidenceSha256
    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
        throw 'Original publish allowance exhausted.'
    }
    $binding.status = 'completed-reconciled'
    Write-RunnerJournalRecord -Path $journal -Record $binding
    Write-RunnerJournalRecord -Path $stateFile -Record $binding
}
catch {
    $message = if ($attempted) {
        'Runner image publish outcome is unknown. Preserve private state and reconcile; never repeat the push.'
    }
    else {
        'Runner image publish validation failed. No push was attempted.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}
finally {
    if ($null -ne $reservation) {
        try {
            Exit-RunnerTargetReservation -Reservation $reservation
        }
        catch {
            [Console]::Error.WriteLine('Runner publish reservation cleanup is unknown. Preserve private state.'); exit 1
        }
    }
}
@{ status = 'published'; sourceCommit = $ExpectedCommit; runtimeManifestSha256 = $runtimeHash; tests = $null; accepted = $false } | ConvertTo-Json -Compress
