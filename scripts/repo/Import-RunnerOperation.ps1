<#
.SYNOPSIS
Loads private native I/O and observed-path checks for runner operation commands.
.DESCRIPTION
Shares bounded dual-stream draining, owned process containment and read-only
raw Git source validation. Does not execute a build, provider call or deployment.
.EXAMPLE
. ./Import-RunnerOperation.ps1
Loads helpers into the caller scope without operational side effects.
.OUTPUTS
None. Defines helper functions.
#>
[CmdletBinding()]
param()
function Invoke-PrivateCommand {
    <#
    .SYNOPSIS
    Runs a native command with capped capture and continued dual-stream drain.
    .DESCRIPTION
    Git queries capture at most one MiB per stream. Build output is discarded.
    Owned builds use the existing containment engine and one clock for launch,
    execution, termination and drain. Unknown cleanup or completion fails closed.
    .PARAMETER Executable
    Native executable name or path, passed literally.
    .PARAMETER Argument
    Literal argument array, never shell text.
    .PARAMETER LimitSeconds
    Original command allowance including cleanup and stream drain.
    .PARAMETER RunClock
    Optional original running operation clock. LimitSeconds is its absolute deadline.
    .PARAMETER CancellationToken
    Optional original cancellation signal; termination and drain retain the deadline.
    .PARAMETER Capture
    Retains bounded stdout from an owned provider query. Overflow fails closed.
    .PARAMETER Owned
    Uses the existing containment boundary for the build and its descendants.
    .EXAMPLE
    Invoke-PrivateCommand -Executable git -Argument @('version') -LimitSeconds 15
    .OUTPUTS
    System.String. Bounded query output; empty build output. Fixed errors on failure.
    #>
    [CmdletBinding()]
    param([string]$Executable, [string[]]$Argument, [int]$LimitSeconds, [switch]$Owned, [switch]$Capture, [Diagnostics.Stopwatch]$RunClock, [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None)
    $clock = if ($null -ne $RunClock) {
        $RunClock
    }
    else {
        [Diagnostics.Stopwatch]::StartNew()
    }
    $process = $null
    $owner = $null
    $scratch = $null
    $pipes = @()
    $failure = $null
    $exitCode = $null
    $cleanupComplete = $true
    $captureLimit = if ($Owned -and -not $Capture) {
        0
    }
    else {
        1048576
    }
    $reserve = [Math]::Min(2.0, $LimitSeconds / 2.0)
    try {
        $CancellationToken.ThrowIfCancellationRequested()
        if (-not $clock.IsRunning -or $clock.Elapsed.TotalSeconds -ge ($LimitSeconds - $reserve)) {
            throw 'Native command allowance expired.'
        }
        if ($Owned) {
            # Resolve before creating private scratch; no failed-start path disclosure.
            $command = Get-Command -Name $Executable -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $scratch = Join-Path ([IO.Path]::GetTempPath()) ('runner-build-' + [guid]::NewGuid().ToString('N'))
            [void][IO.Directory]::CreateDirectory($scratch)
            if ($IsLinux) {
                [IO.File]::SetUnixFileMode($scratch, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute)
            }
            $owner = New-DiagnosticOwnedProcess -FilePath $command.Source -ArgumentList $Argument -Root $scratch -Token 'build' -RunClock $clock -DeadlineSeconds ($LimitSeconds - $reserve) -WarningAction SilentlyContinue -Verbose:$false
            $process = $owner.Process
        }
        else {
            $process = [Diagnostics.Process]::new()
            $process.StartInfo = [Diagnostics.ProcessStartInfo]::new()
            $process.StartInfo.FileName = $Executable
            $process.StartInfo.UseShellExecute = $false
            $process.StartInfo.RedirectStandardOutput = $true
            $process.StartInfo.RedirectStandardError = $true
            foreach ($value in $Argument) {
                $process.StartInfo.ArgumentList.Add($value)
            }
            foreach ($key in @($process.StartInfo.Environment.Keys)) {
                if ($key -like 'GIT_*') {
                    [void]$process.StartInfo.Environment.Remove($key)
                }
            }
            $process.StartInfo.Environment['GIT_OPTIONAL_LOCKS'] = '0'
            [void]$process.Start()
        }
        foreach ($reader in @($process.StandardOutput, $process.StandardError)) {
            $buffer = [byte[]]::new(8192)
            $stream = $reader.BaseStream
            $pipes += [pscustomobject]@{ Reader = $reader; Stream = $stream; Buffer = $buffer; Pending = $stream.ReadAsync($buffer, 0, $buffer.Length); Capture = [IO.MemoryStream]::new(); Done = $false; Truncated = $false }
        }
        while ($true) {
            foreach ($pipe in $pipes) {
                if (-not $pipe.Done -and $pipe.Pending.IsCompleted) {
                    $count = $pipe.Pending.GetAwaiter().GetResult()
                    if ($count -eq 0) {
                        $pipe.Done = $true
                    }
                    else {
                        $retain = [int][Math]::Min($count, $captureLimit - $pipe.Capture.Length)
                        if ($retain -gt 0) {
                            $pipe.Capture.Write($pipe.Buffer, 0, $retain)
                        }
                        if ($retain -lt $count) {
                            $pipe.Truncated = $true
                        }
                        $pipe.Pending = $pipe.Stream.ReadAsync($pipe.Buffer, 0, $pipe.Buffer.Length)
                    }
                }
            }
            if ($CancellationToken.IsCancellationRequested -or $clock.Elapsed.TotalSeconds -ge ($LimitSeconds - $reserve)) {
                $failure = 'Native command exceeded its build allowance.'
                break
            }
            if ($Owned) {
                if ($process.HasExited) {
                    $failure = 'Native command outcome is unknown.'
                    break
                }
                if ([IO.File]::Exists($owner.Result)) {
                    $exitCode = [int][IO.File]::ReadAllText($owner.Result)
                    # Even a successful root is not successful while descendants remain.
                    $members = @(Get-DiagnosticOwnedMember -Owner $owner -RunClock $clock -DeadlineSeconds $LimitSeconds -Verbose:$false)
                    if (@($members | Where-Object { $_ -ne $owner.GroupId }).Count -gt 0) {
                        $failure = 'Native command left owned descendants; build outcome is unknown.'
                    }
                    break
                }
            }
            elseif ($process.HasExited -and @($pipes | Where-Object { -not $_.Done }).Count -eq 0) {
                $exitCode = $process.ExitCode
                break
            }
            Start-Sleep -Milliseconds 1
        }
    }
    catch {
        $failure = if ($null -eq $process) {
            'Native command could not start.'
        }
        else {
            'Native command outcome is unknown.'
        }
    }
    finally {
        if ($null -ne $owner) {
            try {
                Stop-DiagnosticOwnedProcess -Owner $owner -RunClock $clock -DeadlineSeconds $LimitSeconds -WaitTimeoutMilliseconds ([int][Math]::Max(0, ($LimitSeconds - $clock.Elapsed.TotalSeconds) * 1000)) -Confirm:$false -Verbose:$false
            }
            catch {
                $cleanupComplete = $false
            }
        }
        elseif ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill($true)
                }
            }
            catch {
                $cleanupComplete = $false
            }
        }
        # Continue draining after termination, without allocating beyond fixed buffers.
        while (@($pipes | Where-Object { -not $_.Done }).Count -gt 0 -and $clock.Elapsed.TotalSeconds -lt $LimitSeconds) {
            foreach ($pipe in $pipes) {
                if (-not $pipe.Done -and $pipe.Pending.IsCompleted) {
                    try {
                        $count = $pipe.Pending.GetAwaiter().GetResult()
                        if ($count -eq 0) {
                            $pipe.Done = $true
                        }
                        else {
                            $retain = [int][Math]::Min($count, $captureLimit - $pipe.Capture.Length)
                            if ($retain -gt 0) {
                                $pipe.Capture.Write($pipe.Buffer, 0, $retain)
                            }
                            if ($retain -lt $count) {
                                $pipe.Truncated = $true
                            }
                            $pipe.Pending = $pipe.Stream.ReadAsync($pipe.Buffer, 0, $pipe.Buffer.Length)
                        }
                    }
                    catch {
                        $cleanupComplete = $false
                        $pipe.Done = $true
                    }
                }
            }
            Start-Sleep -Milliseconds 1
        }
        if (@($pipes | Where-Object { -not $_.Done }).Count -gt 0) {
            $cleanupComplete = $false
        }
        $output = if ($pipes.Count -gt 0) {
            [Text.Encoding]::UTF8.GetString($pipes[0].Capture.ToArray())
        }
        else {
            ''
        }
        $truncated = (-not $Owned -or $Capture) -and @($pipes | Where-Object Truncated).Count -gt 0
        foreach ($pipe in $pipes) {
            $pipe.Reader.Dispose()
            $pipe.Capture.Dispose()
        }
        if ($null -ne $process) {
            $process.Dispose()
        }
        if ($null -ne $owner -and $null -ne $owner.Job) {
            $owner.Job.Dispose()
        }
        if ($null -ne $scratch) {
            try {
                Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction Stop
            }
            catch {
                $cleanupComplete = $false
            }
        }
    }
    if (-not $cleanupComplete) {
        throw 'Native command cleanup or drain is unknown; build outcome is unknown.'
    }
    if ($failure) {
        throw $failure
    }
    if ($truncated) {
        throw 'Native query output exceeded its capture limit.'
    }
    if ($null -eq $exitCode) {
        throw 'Native command outcome is unknown.'
    }
    if ($exitCode -ne 0) {
        throw "Native command failed with exit code $exitCode."
    }
    return $output
}

function Assert-ObservedPath {
    <#
    .SYNOPSIS
    Rejects observed links and reparse points along an existing path.
    .DESCRIPTION
    Checks the target and each lexical ancestor through its filesystem root.
    This is an observed-path check, not a race-proof filesystem sandbox.
    .PARAMETER Path
    Existing absolute or relative filesystem path.
    .PARAMETER Directory
    Requires a directory rather than a bounded regular configuration file.
    .EXAMPLE
    Assert-ObservedPath -Path /source -Directory
    .OUTPUTS
    System.String. Full observed path, or a terminating error.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path, [switch]$Directory)
    $full = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($Directory) {
        if (-not $item.PSIsContainer) {
            throw 'Invalid source directory.'
        }
    }
    elseif ($item.PSIsContainer -or $item -isnot [IO.FileInfo] -or $item.Length -le 0 -or $item.Length -gt 4096) {
        throw 'Invalid private configuration file.'
    }
    $current = $full
    while ($current) {
        $observed = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if ($observed.LinkType -or ($observed.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Observed linked paths are not allowed.'
        }
        $parent = [IO.Directory]::GetParent($current)
        $current = if ($null -eq $parent) {
            $null
        }
        else {
            $parent.FullName
        }
    }
    return $full
}

function Assert-RunnerOperationSource {
    <#
    .SYNOPSIS
    Validates an exact clean raw-byte source checkout.
    .DESCRIPTION
    Uses read-only Git queries with optional locks disabled and rejects byte drift.
    .PARAMETER Root
    Observed source directory, already checked for linked ancestors.
    .PARAMETER Commit
    Expected full lowercase commit identity.
    .EXAMPLE
    Assert-RunnerOperationSource -Root /source -Commit $commit
    .OUTPUTS
    None. Throws on an invalid source checkout.
    #>
    [CmdletBinding()]
    param([string]$Root, [string]$Commit)
    $head = (Invoke-PrivateCommand -Executable git -Argument @('-C', $Root, 'rev-parse', 'HEAD') -LimitSeconds 15).Trim()
    if ($head -cne $Commit) {
        throw 'Source commit does not match the requested identity.'
    }
    $status = Invoke-PrivateCommand -Executable git -Argument @('-C', $Root, 'status', '--porcelain', '--untracked-files=all') -LimitSeconds 15
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Source checkout must be clean.'
    }
    # Git clean filters may hide CRLF drift. Compare every raw file to its Git blob.
    $tracked = Invoke-PrivateCommand -Executable git -Argument @('-C', $Root, 'ls-files', '-s', '-z') -LimitSeconds 15
    foreach ($entry in $tracked.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($entry -notmatch '^100(?:644|755) ([0-9a-f]{40}) 0\t(.+)$') {
            throw 'Source contains an unsupported index entry.'
        }
        $expectedBlob = $Matches[1]
        $relative = $Matches[2]
        $item = Get-Item -LiteralPath (Join-Path $Root $relative) -Force -ErrorAction Stop
        if ($item.LinkType) {
            throw 'Linked source files are not allowed.'
        }
        $actualBlob = (Invoke-PrivateCommand -Executable git -Argument @('-C', $Root, 'hash-object', '--no-filters', '--', $item.FullName) -LimitSeconds 15).Trim()
        if ($actualBlob -cne $expectedBlob) {
            throw 'Raw source bytes differ from the committed Git blob.'
        }
    }
}

function Read-RunnerPrivateObject {
    <#
    .SYNOPSIS
    Reads a bounded strict private JSON object without duplicate properties.
    .DESCRIPTION
    Rejects linked paths, invalid UTF-8, nested duplicate keys and oversized files.
    .PARAMETER Path
    Existing observed private file outside source.
    .EXAMPLE
    Read-RunnerPrivateObject -Path /private/operation.json
    .OUTPUTS
    System.Collections.IDictionary. Parsed private JSON object.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$Path)
    $observed = Assert-ObservedPath -Path $Path
    $stream = [IO.File]::OpenRead($observed)
    try {
        $bytes = [byte[]]::new(4097)
        $length = 0
        while ($length -lt $bytes.Length) {
            $count = $stream.Read($bytes, $length, $bytes.Length - $length)
            if ($count -eq 0) {
                break
            }
            $length += $count
        }
        if ($length -eq 0 -or $length -gt 4096) {
            throw 'Invalid private JSON size.'
        }
    }
    finally {
        $stream.Dispose()
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $length)
    return ConvertFrom-RunnerPrivateJson -Text $text
}

function ConvertFrom-RunnerPrivateJson {
    <#
    .SYNOPSIS
    Parses a private JSON object without duplicate keys.
    .DESCRIPTION
    Rejects duplicate keys at every depth, including case variants. Never emits
    raw JSON or provider details. Native capture and file readers enforce bounds.
    .PARAMETER Text
    Bounded private JSON text obtained from the existing capture or file reader.
    .EXAMPLE
    ConvertFrom-RunnerPrivateJson -Text '{"id":"synthetic"}'
    .OUTPUTS
    System.Collections.IDictionary. Parsed private object, or a terminating error.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([string]$Text)
    $document = [Text.Json.JsonDocument]::Parse($text)
    try {
        $queue = [Collections.Generic.Queue[Text.Json.JsonElement]]::new()
        $queue.Enqueue($document.RootElement)
        while ($queue.Count -gt 0) {
            $element = $queue.Dequeue()
            if ($element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
                $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $element.EnumerateObject()) {
                    if (-not $names.Add($property.Name)) {
                        throw 'Duplicate private JSON key.'
                    }
                    $queue.Enqueue($property.Value)
                }
            }
            elseif ($element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
                foreach ($entry in $element.EnumerateArray()) {
                    $queue.Enqueue($entry)
                }
            }
        }
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Invalid private JSON object.'
        }
    }
    finally {
        $document.Dispose()
    }
    return ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop
}


function Assert-RunnerAccountBinding {
    <#
    .SYNOPSIS
    Validates one explicitly configured existing provider account binding.
    .DESCRIPTION
    Requires an expected account type, account login/name, tenant and selected
    subscription. Checks that the explicit job target uses that subscription.
    When Account is supplied, matches the observed existing login exactly before
    any job read or mutation. This is account-login matching, not object-ID or
    token-subject verification. Never signs in, switches accounts or falls back.
    .PARAMETER Configuration
    Strict hashed private operation configuration containing the expected binding.
    .PARAMETER Account
    Optional strict parsed account-show response. Omit for local preview checks.
    .EXAMPLE
    Assert-RunnerAccountBinding -Configuration $configuration -Account $account
    .OUTPUTS
    None. Throws on missing, malformed, unsupported or mismatched identity.
    #>
    [CmdletBinding()]
    param([Collections.IDictionary]$Configuration, [Collections.IDictionary]$Account)
    foreach ($key in @('accountType', 'accountName', 'tenantId', 'subscriptionId', 'resourceId')) {
        if (-not $Configuration.Contains($key) -or $Configuration[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Configuration[$key])) {
            throw 'Invalid configured provider binding.'
        }
    }
    if ($Configuration.accountType -cnotin @('user', 'servicePrincipal') -or $Configuration.accountName.Length -gt 320 -or $Configuration.accountName -cne $Configuration.accountName.Trim() -or $Configuration.accountName -match '[\x00-\x20\x7f]') {
        throw 'Invalid configured account selection.'
    }
    foreach ($id in @($Configuration.tenantId, $Configuration.subscriptionId)) {
        if ($id -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
            throw 'Invalid configured tenant or subscription.'
        }
    }
    if ($Configuration.accountType -ceq 'servicePrincipal' -and $Configuration.accountName -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') {
        throw 'Invalid configured service principal.'
    }
    if (-not $Configuration.resourceId.StartsWith('/subscriptions/' + $Configuration.subscriptionId + '/', [StringComparison]::Ordinal)) {
        throw 'Configured target subscription mismatch.'
    }
    if ($PSBoundParameters.ContainsKey('Account')) {
        if ($null -eq $Account -or -not $Account.Contains('id') -or -not $Account.Contains('tenantId') -or -not $Account.Contains('user') -or $Account.user -isnot [Collections.IDictionary]) {
            throw 'Missing observed provider binding.'
        }
        if (-not $Account.user.Contains('type') -or -not $Account.user.Contains('name') -or $Account.id -isnot [string] -or $Account.tenantId -isnot [string] -or $Account.user.type -isnot [string] -or $Account.user.name -isnot [string] -or $Account.id -cne $Configuration.subscriptionId -or $Account.tenantId -cne $Configuration.tenantId -or $Account.user.type -cne $Configuration.accountType -or $Account.user.name -cne $Configuration.accountName) {
            throw 'Observed provider binding mismatch.'
        }
    }
}
