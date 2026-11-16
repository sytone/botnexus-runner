<#
.SYNOPSIS
Loads the private maintenance target profile reader without operational effects.
.DESCRIPTION
Defines a read-only projection helper using the existing bounded private JSON and
observed-path rules. Does not import a build, deployment, run or publishing command.
No environment discovery, authentication, target default or generated config files.
.EXAMPLE
. ./Import-RunnerMaintenanceProfile.ps1
Loads the reader only; no profile is read until explicitly requested.
.OUTPUTS
None. Defines private helper functions.
#>
[CmdletBinding()]
param()
. (Join-Path $PSScriptRoot 'Import-RunnerOperation.ps1')

function Read-RunnerMaintenanceProfile {
    <#
    .SYNOPSIS
    Reads one hash-pinned private target profile and projects an operation in memory.
    .DESCRIPTION
    Validates schema version 1 and explicit common identity/target fields. Every
    supplied section and value is checked, even if not selected by this operation.
    Uses the canonical 4096-byte strict UTF8 and nested-duplicate JSON reader.
    Requires an absolute profile beneath an explicit private directory and outside
    the source and all observed Git ancestors. Observed paths are not atomic opens
    or an ACL sandbox; the trusted operator must keep directories and inputs stable.
    Approval, qualification, project inputs, receipts and journals remain separate.
    Returns private data only to the caller, never safe for public logging. Every
    failure is replaced by a fixed exception without private values or inner errors.
    Build and publish project a source-bound tag, not image qualification. Deploy
    and run require a desired immutable digest; this reader does not approve it.
    .PARAMETER Path
    Absolute existing external private profile JSON, at most 4096 bytes.
    .PARAMETER ExpectedSha256
    Lowercase SHA256 of the exact profile bytes selected by the operator.
    .PARAMETER Operation
    Exact operation build, publish, deploy or run. No default or fallback.
    .PARAMETER SourceRoot
    Existing absolute source directory excluded from profile storage. Source
    cleanliness and exact commit validation remain operational caller obligations.
    .PARAMETER PrivateRoot
    Existing absolute operator-selected private directory containing the profile.
    Does not create directories or grant filesystem permissions.
    .PARAMETER ExpectedCommit
    Exact lowercase source commit binding any supplied buildTag suffix.
    .EXAMPLE
    $private = Read-RunnerMaintenanceProfile -Path /private/target.json -ExpectedSha256 $hash -Operation deploy -SourceRoot /source -PrivateRoot /private -ExpectedCommit $commit
    Keeps the projection in memory for a separately authorized deployment caller.
    .OUTPUTS
    System.Collections.IDictionary. Private profile hash, operation and configuration
    projection. Run also returns runnerImage and artifactDestination. No public receipt.
    #>
    [CmdletBinding()]
    [OutputType([Collections.IDictionary], [hashtable])]
    param(
        [string]$Path,
        [string]$ExpectedSha256,
        [string]$Operation,
        [string]$SourceRoot,
        [string]$PrivateRoot,
        [string]$ExpectedCommit
    )
    try {
        if ($Operation -cnotin @('build', 'publish', 'deploy', 'run') -or
            $ExpectedSha256 -cnotmatch '^[0-9a-f]{64}$' -or $ExpectedCommit -cnotmatch '^[0-9a-f]{40}$') {
            throw 'Invalid explicit selection.'
        }
        foreach ($inputPath in @($Path, $SourceRoot, $PrivateRoot)) {
            if ([string]::IsNullOrWhiteSpace($inputPath) -or -not [IO.Path]::IsPathFullyQualified($inputPath) -or
                $inputPath.Contains('::') -or $inputPath -match '^[\\/]{2}|[\x00-\x1f]' -or
                ($IsWindows -and $inputPath.Substring(2).Contains(':'))) {
                throw 'Invalid local path.'
            }
        }
        $source = (Assert-ObservedPath -Path $SourceRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $private = (Assert-ObservedPath -Path $PrivateRoot -Directory).TrimEnd([IO.Path]::DirectorySeparatorChar)
        $file = Assert-ObservedPath -Path $Path
        $comparison = if ($IsWindows) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        if (-not $file.StartsWith($private + [IO.Path]::DirectorySeparatorChar, $comparison) -or
            $file.StartsWith($source + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Private boundary conflict.'
        }
        $ancestor = [IO.Path]::GetDirectoryName($file)
        while ($ancestor) {
            if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
                throw 'Profile belongs to a Git work area.'
            }
            $parent = [IO.Directory]::GetParent($ancestor)
            $ancestor = if ($null -eq $parent) {
                $null
            }
            else {
                $parent.FullName
            }
        }
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
            throw 'Profile hash conflict.'
        }
        $document = Read-RunnerPrivateObject -Path $file
        # Recheck the bytes after the bounded canonical reader. No file writes.
        if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -cne $ExpectedSha256) {
            throw 'Profile changed during read.'
        }
        $sections = @{
            account = @('tenantId', 'subscriptionId', 'accountType', 'accountName')
            target = @('resourceId', 'managedIdentityResourceId', 'managedIdentityClientId')
            images = @('buildTag', 'desiredImage')
            transport = @('sourceBlobUrl', 'artifactDestination')
        }
        foreach ($key in $document.Keys) {
            if ($key -cnotin @('schemaVersion', 'account', 'target', 'images', 'transport')) {
                throw 'Unknown profile field.'
            }
        }
        if ($document.schemaVersion -isnot [long] -or $document.schemaVersion -ne 1) {
            throw 'Unsupported profile version.'
        }
        foreach ($required in @('account', 'target', 'images')) {
            if (-not $document.Contains($required)) {
                throw 'Missing profile section.'
            }
        }
        foreach ($section in $sections.Keys) {
            if (-not $document.Contains($section)) {
                continue
            }
            if ($document[$section] -isnot [Collections.IDictionary]) {
                throw 'Invalid profile section.'
            }
            foreach ($key in $document[$section].Keys) {
                $value = $document[$section][$key]
                if ($key -cnotin $sections[$section] -or $value -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($value) -or $value.Length -gt 1024 -or
                    $value -cne $value.Trim() -or $value -match '[\x00-\x20\x7f]') {
                    throw 'Invalid profile value.'
                }
            }
        }
        $common = @{}
        foreach ($key in $sections.account) {
            if (-not $document.account.Contains($key)) {
                throw 'Missing account field.'
            }
            $common[$key] = $document.account[$key]
        }
        $common.resourceId = $document.target.resourceId
        Assert-RunnerAccountBinding -Configuration $common
        $uuid = '[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}'
        if ($common.resourceId -cnotmatch ('^/subscriptions/' + $uuid + '/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.App/jobs/[a-z][a-z0-9-]{0,62}$')) {
            throw 'Invalid explicit job.'
        }
        if ($document.target.Contains('managedIdentityResourceId')) {
            $identityPrefix = '/subscriptions/' + $common.subscriptionId + '/resourceGroups/'
            if (-not $document.target.managedIdentityResourceId.StartsWith($identityPrefix, [StringComparison]::Ordinal) -or
                $document.target.managedIdentityResourceId -cnotmatch ('^/subscriptions/' + $uuid + '/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft.ManagedIdentity/userAssignedIdentities/[A-Za-z0-9_-]+$')) {
                throw 'Identity subscription or resource conflict.'
            }
        }
        if ($document.target.Contains('managedIdentityClientId') -and $document.target.managedIdentityClientId -cnotmatch ('^' + $uuid + '$')) {
            throw 'Invalid identity client.'
        }
        if ($document.images.Contains('buildTag') -and ($document.images.buildTag.Length -gt 512 -or
                $document.images.buildTag -cnotmatch ('^[a-z0-9][a-z0-9./_-]*:src-' + $ExpectedCommit + '$'))) {
            throw 'Invalid source-bound build tag.'
        }
        if ($document.images.Contains('desiredImage') -and ($document.images.desiredImage.Length -gt 512 -or
                $document.images.desiredImage -cnotmatch '^[a-z0-9][a-z0-9./_-]*@sha256:[a-f0-9]{64}$')) {
            throw 'Invalid desired immutable image.'
        }
        if ($document.Contains('transport')) {
            foreach ($key in $document.transport.Keys) {
                $uri = [uri]$document.transport[$key]
                if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -eq '/') {
                    throw 'Invalid credential-free transport.'
                }
            }
            if ($document.transport.Contains('sourceBlobUrl') -and $document.transport.Contains('artifactDestination') -and
                $document.transport.sourceBlobUrl -ceq $document.transport.artifactDestination) {
                throw 'Conflicting transport destinations.'
            }
        }
        $configuration = @{}
        $result = @{ operation = $Operation; profileSha256 = $ExpectedSha256; configuration = $configuration }
        if ($Operation -cin @('build', 'publish')) {
            if (-not $document.images.Contains('buildTag')) {
                throw 'Missing build tag.'
            }
            $configuration.imageTag = $document.images.buildTag
        }
        else {
            if (-not $document.images.Contains('desiredImage')) {
                throw 'Missing desired image.'
            }
            foreach ($key in $common.Keys) {
                $configuration[$key] = $common[$key]
            }
            if ($Operation -ceq 'deploy') {
                if (-not $document.target.Contains('managedIdentityResourceId')) {
                    throw 'Missing deployment identity.'
                }
                $configuration.image = $document.images.desiredImage
                $configuration.managedIdentityResourceId = $document.target.managedIdentityResourceId
            }
            else {
                if (-not $document.target.Contains('managedIdentityClientId') -or -not $document.Contains('transport') -or
                    -not $document.transport.Contains('sourceBlobUrl') -or -not $document.transport.Contains('artifactDestination')) {
                    throw 'Missing run transport or identity.'
                }
                $configuration.managedIdentityClientId = $document.target.managedIdentityClientId
                $configuration.sourceBlobUrl = $document.transport.sourceBlobUrl
                $result.runnerImage = $document.images.desiredImage
                $result.artifactDestination = $document.transport.artifactDestination
            }
        }
        return $result
    }
    catch {
        throw [InvalidOperationException]::new('Runner maintenance profile validation failed.')
    }
}
