<#
.SYNOPSIS
Loads local cooperative target ownership for runner mutations.
.DESCRIPTION
Shares an exclusive local reservation between run and deployment commands. This
is not provider atomicity or a distributed lock. A trusted single operator must
exclude other writers through completion and UNKNOWN investigation. Crashed
reservations fail closed and are never stolen automatically.
.EXAMPLE
. ./Import-RunnerTargetJournal.ps1
Loads helpers without creating files or changing the environment.
.OUTPUTS
None. Defines journal helpers.
#>
[CmdletBinding()]
param()

function Assert-RunnerJournalPath {
    <#
    .SYNOPSIS
    Checks an existing private local journal node.
    .DESCRIPTION
    Rejects observed links, special nodes, shared permissions and hard-linked
    files on Linux. Windows requires a protected ACL owned by the current user.
    These are observed checks, not a filesystem sandbox against a hostile owner.
    .PARAMETER Path
    Existing journal path.
    .PARAMETER Directory
    Requires an owner-only directory instead of a regular single-link file.
    .EXAMPLE
    Assert-RunnerJournalPath -Path /private/journal.json
    .OUTPUTS
    None. Throws on unsafe observed metadata.
    #>
    [CmdletBinding()]
    param([string]$Path, [switch]$Directory)
    $null = Assert-ObservedPath -Path $Path -Directory:$Directory
    if ($IsLinux) {
        $shape = (Invoke-PrivateCommand -Executable stat -Argument @('-c', '%F:%h:%a:%U', '--', $Path) -LimitSeconds 4).Trim().Split(':')
        $kind = if ($Directory) {
            'directory'
        }
        else {
            'regular file'
        }
        if ($shape.Count -ne 4 -or $shape[0] -cne $kind -or (-not $Directory -and $shape[1] -cne '1') -or $shape[2] -cne $(if ($Directory) {
                    '700'
                }
                else {
                    '600'
                }) -or $shape[3] -cne [Environment]::UserName) {
            throw 'Unsafe private journal metadata.'
        }
    }
    elseif ($IsWindows) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $item.FullName
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        if (-not $acl.AreAccessRulesProtected -or $acl.GetOwner([Security.Principal.SecurityIdentifier]) -ne $sid) {
            throw 'Unsafe private journal owner.'
        }
        foreach ($rule in $acl.Access) {
            if ($rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]) -ne $sid -or $rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) {
                throw 'Unsafe private journal access.'
            }
        }
    }
    else {
        throw 'Unsupported local journal filesystem.'
    }
}

function Set-RunnerJournalAccess {
    <#
    .SYNOPSIS
    Restricts one newly owned journal node to the current operator.
    .DESCRIPTION
    Applies owner-only permissions without changing any provider access policy.
    .PARAMETER Path
    Newly created owned path.
    .PARAMETER Directory
    Applies directory traversal and inheritance permissions.
    .EXAMPLE
    Set-RunnerJournalAccess -Path /private/journal -Directory
    .OUTPUTS
    None. Throws if private permissions cannot be established.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Path, [switch]$Directory)
    if (-not $PSCmdlet.ShouldProcess('new private journal node', 'Restrict access to current operator')) {
        throw 'Private journal access was not established.'
    }
    if ($IsLinux) {
        $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite
        if ($Directory) {
            $mode = $mode -bor [IO.UnixFileMode]::UserExecute
        }
        [IO.File]::SetUnixFileMode($Path, $mode)
    }
    elseif ($IsWindows) {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = if ($Directory) {
            [Security.AccessControl.DirectorySecurity]::new()
        }
        else {
            [Security.AccessControl.FileSecurity]::new()
        }
        $acl.SetOwner($sid)
        $acl.SetAccessRuleProtection($true, $false)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    else {
        throw 'Unsupported local journal filesystem.'
    }
}

function Enter-RunnerTargetReservation {
    <#
    .SYNOPSIS
    Exclusively reserves one canonical local target for a mutation or reconciliation.
    .DESCRIPTION
    Uses CreateNew and an owned handle. Existing reservations, including crashed
    reservations, deny rather than being removed or stolen. Call only after the
    command's ShouldProcess boundary. Never calls a provider.
    .PARAMETER Resource
    Explicit resource identity; case-folded for the canonical key.
    .EXAMPLE
    $reservation = Enter-RunnerTargetReservation -Resource $configuration.resourceId
    .OUTPUTS
    System.Collections.IDictionary. Owned handle and canonical journal paths.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Resource)
    $root = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData, [Environment+SpecialFolderOption]::DoNotVerify)) 'BotNexus/runner-operations'
    if (Test-Path -LiteralPath $root) {
        Assert-RunnerJournalPath -Path $root -Directory
    }
    else {
        $parent = [IO.Path]::GetDirectoryName($root)
        if (Test-Path -LiteralPath $parent) {
            $null = Assert-ObservedPath -Path $parent -Directory
        }
        [void][IO.Directory]::CreateDirectory($root)
        Set-RunnerJournalAccess -Path $root -Directory
        Assert-RunnerJournalPath -Path $root -Directory
    }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Resource.ToLowerInvariant()))).ToLowerInvariant()
    $path = Join-Path $root ($key + '.reservation')
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        Set-RunnerJournalAccess -Path $path
        $bytes = [Text.Encoding]::UTF8.GetBytes([guid]::NewGuid().ToString('N'))
        $stream.Write($bytes)
        $stream.Flush($true)
        return @{ Root = $root; Key = $key; Path = $path; Stream = $stream; RunPath = (Join-Path $root ($key + '.json')); DeploymentPath = (Join-Path $root ($key + '.deployment.json')) }
    }
    catch {
        $stream.Dispose()
        # Preserve failed acquisition for explicit investigation, never steal it.
        throw
    }
}

function Exit-RunnerTargetReservation {
    <#
    .SYNOPSIS
    Releases only this invocation's successfully acquired local reservation.
    .DESCRIPTION
    Durable UNKNOWN journals are not removed. Handle disposal does not establish
    remote completion or end the operator's exclusion obligation.
    .PARAMETER Reservation
    Object returned by Enter-RunnerTargetReservation.
    .EXAMPLE
    Exit-RunnerTargetReservation -Reservation $reservation
    .OUTPUTS
    None. Throws if owned reservation cleanup is uncertain.
    #>
    [CmdletBinding()]
    param([Collections.IDictionary]$Reservation)
    $Reservation.Stream.Dispose()
    Remove-Item -LiteralPath $Reservation.Path -Force -ErrorAction Stop
}

function Write-RunnerJournalRecord {
    <#
    .SYNOPSIS
    Flushes a bounded private record under held target ownership.
    .DESCRIPTION
    Creates exclusively or replaces bytes in the known record. Torn writes remain
    fail-closed JSON. Never deletes a record or copies over an unknown path.
    .PARAMETER Path
    External private journal or receipt path.
    .PARAMETER Record
    Bounded private operation object.
    .PARAMETER Create
    Requires a previously absent file.
    .EXAMPLE
    Write-RunnerJournalRecord -Path $path -Record $record -Create
    .OUTPUTS
    None. Throws on unsafe path, access failure or incomplete persistence.
    #>
    [CmdletBinding()]
    param([string]$Path, [Collections.IDictionary]$Record, [switch]$Create)
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Record | ConvertTo-Json -Depth 20 -Compress))
    if ($bytes.Length -gt 4096) {
        throw 'Private journal record exceeds bound.'
    }
    $null = Assert-ObservedPath -Path ([IO.Path]::GetDirectoryName($Path)) -Directory
    if (-not $Create) {
        Assert-RunnerJournalPath -Path $Path
    }
    $mode = if ($Create) {
        [IO.FileMode]::CreateNew
    }
    else {
        [IO.FileMode]::Open
    }
    $stream = [IO.File]::Open($Path, $mode, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if ($Create) {
            Set-RunnerJournalAccess -Path $Path
        }
        $stream.SetLength(0)
        $stream.Write($bytes)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}
