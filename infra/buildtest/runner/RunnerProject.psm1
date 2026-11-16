Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Import-RunnerDiagnostic.ps1')

function Assert-RunnerJsonObject {
    <#
    .SYNOPSIS
    Rejects duplicate JSON property names before materialization.
    .DESCRIPTION
    Walks the depth-limited JSON document using ordinal property identities. Case variants
    are rejected too because PowerShell consumers may use case-insensitive dictionaries.
    .PARAMETER Element
    JSON element to inspect recursively.
    .EXAMPLE
    Assert-RunnerJsonObject -Element $document.RootElement
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw "Duplicate configuration property '$($property.Name)'."
            }
            Assert-RunnerJsonObject -Element $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-RunnerJsonObject -Element $item
        }
    }
}

function Resolve-RunnerProjectPath {
    <#
    .SYNOPSIS
    Resolves one literal payload-relative path without accepting links or traversal.
    .DESCRIPTION
    Rejects cross-platform rooted paths, dot-dot components, wildcards, control characters
    and existing reparse-point components. Missing artifact leaves are allowed. Commands
    remain trusted code; this check does not claim to prevent malicious filesystem races.
    .PARAMETER Root
    Absolute payload root owned by this run.
    .PARAMETER RelativePath
    Portable literal path relative to the payload root.
    .EXAMPLE
    Resolve-RunnerProjectPath -Root /payload -RelativePath src/result.trx
    .OUTPUTS
    System.String. Full path under the payload root.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ($RelativePath -match '^[\\/]|:|[\x00-\x1f*?\[\]]' -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw 'Project paths must be literal and payload-relative.'
    }
    $parts = $RelativePath.Replace('\', '/').Split('/')
    if ($parts -contains '..') {
        throw 'Project path escapes payload root.'
    }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    $current = $fullRoot
    foreach ($part in @('.') + $parts) {
        if ($part -ne '.' -and $part -ne '') {
            $current = Join-Path $current $part
        }
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Project paths cannot cross symbolic links or reparse points.'
            }
        }
    }
    return [IO.Path]::GetFullPath($current)
}

function Read-RunnerProject {
    <#
    .SYNOPSIS
    Reads a versioned project configuration bound to exact candidate bytes.
    .DESCRIPTION
    Bounds input to 256 KiB and JSON depth 16, rejects duplicate and unknown fields, validates
    the adjacent v1 schema, graph, paths and framework ceilings. ExpectedSha256 must come
    from trusted snapshot handling, not from the candidate document. No commands execute.
    .PARAMETER Path
    Configuration file within the exact payload snapshot.
    .PARAMETER PayloadRoot
    Absolute extracted candidate root.
    .PARAMETER ExpectedSha256
    Trusted SHA-256 of the configuration bytes from the candidate manifest.
    .EXAMPLE
    Read-RunnerProject -Path /payload/project.json -PayloadRoot /payload -ExpectedSha256 $manifestHash
    .OUTPUTS
    System.Collections.IDictionary. Validated configuration with framework metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedSha256
    )
    $root = [IO.Path]::GetFullPath($PayloadRoot)
    $relative = [IO.Path]::GetRelativePath($root, [IO.Path]::GetFullPath($Path))
    $resolved = Resolve-RunnerProjectPath -Root $root -RelativePath $relative
    $stream = [IO.File]::OpenRead($resolved)
    try {
        if ($stream.Length -gt 262144) {
            throw 'Project configuration exceeds 256 KiB.'
        }
        $bytes = [byte[]]::new([int]$stream.Length)
        $stream.ReadExactly($bytes)
    }
    finally {
        $stream.Dispose()
    }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if ($hash -cne $ExpectedSha256.ToUpperInvariant()) {
        throw 'Project configuration does not match candidate manifest SHA-256.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 16
    $document = [System.Text.Json.JsonDocument]::Parse($text, $options)
    try {
        Assert-RunnerJsonObject -Element $document.RootElement
    }
    finally {
        $document.Dispose()
    }
    if (-not (Test-Json -Json $text -SchemaFile (Join-Path $PSScriptRoot 'project.schema.json') -ErrorAction Stop)) {
        throw 'Invalid project configuration schema.'
    }
    $project = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 16
    if ($project.limits.reserveSeconds -ge $project.limits.budgetSeconds) {
        throw 'Finalization reserve must be smaller than the absolute budget.'
    }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $artifactCount = 0
    foreach ($step in $project.steps) {
        if (-not $ids.Add($step.id)) {
            throw "Duplicate project step '$($step.id)'."
        }
        if ([string]::IsNullOrWhiteSpace($step.executable) -or $step.executable.Contains([char]0)) {
            throw 'Project executable is invalid.'
        }
        foreach ($argument in $step.arguments) {
            if ($argument.Contains([char]0)) {
                throw 'Project argument contains NUL.'
            }
        }
        $working = Resolve-RunnerProjectPath -Root $root -RelativePath $step.workingDirectory
        if (-not (Test-Path -LiteralPath $working -PathType Container)) {
            throw 'Project working directory is missing.'
        }
        foreach ($artifact in $step.artifacts) {
            $null = Resolve-RunnerProjectPath -Root $root -RelativePath $artifact
        }
        $artifactCount += $step.artifacts.Count
    }
    if ($artifactCount -gt $project.limits.maxArtifacts) {
        throw 'Artifact declarations exceed the configured bound.'
    }
    foreach ($step in $project.steps) {
        foreach ($dependency in $step.dependsOn) {
            if (-not $ids.Contains($dependency)) {
                throw "Unknown dependency '$dependency'."
            }
        }
    }
    $ordered = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while ($ordered.Count -lt $project.steps.Count) {
        $before = $ordered.Count
        foreach ($step in $project.steps) {
            if (@($step.dependsOn | Where-Object { -not $ordered.Contains($_) }).Count -eq 0) {
                $null = $ordered.Add($step.id)
            }
        }
        if ($before -eq $ordered.Count) {
            throw 'Project dependency graph contains a cycle.'
        }
    }
    $project['_configSha256'] = $hash.ToLowerInvariant()
    $project['_payloadRoot'] = $root
    $project['_configurationPath'] = $resolved
    return $project
}

function Receive-RunnerProjectPipe {
    <#
    .SYNOPSIS
    Drains ready process bytes with a strict retained log cap.
    .DESCRIPTION
    Uses one fixed-size outstanding asynchronous read per pipe. Never waits for a live pipe.
    Returns false on overflow; no more than Limit bytes are written across the step's pipes.
    .PARAMETER Pipe
    Framework-owned pipe state.
    .PARAMETER Counter
    Shared retained-byte counter for the step.
    .PARAMETER Limit
    Maximum combined stdout and stderr log bytes.
    .EXAMPLE
    Receive-RunnerProjectPipe -Pipe $pipe -Counter $count -Limit 65536
    .OUTPUTS
    System.Boolean. False if output exceeds the configured cap.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Pipe, [Parameter(Mandatory)]$Counter, [Parameter(Mandatory)][long]$Limit)
    if ($Pipe.Done -or -not $Pipe.Read.IsCompleted) {
        return $true
    }
    $length = $Pipe.Read.GetAwaiter().GetResult()
    if ($length -eq 0) {
        $Pipe.Done = $true
        return $true
    }
    $keep = [int][Math]::Min($length, [Math]::Max(0, $Limit - $Counter.Bytes))
    if ($keep -gt 0) {
        $Pipe.Destination.Write($Pipe.Buffer, 0, $keep)
        $Counter.Bytes += $keep
    }
    if ($keep -lt $length) {
        $Pipe.Done = $true
        return $false
    }
    $Pipe.Read = $Pipe.Reader.BaseStream.ReadAsync($Pipe.Buffer, 0, $Pipe.Buffer.Length)
    return $true
}

function Invoke-RunnerProject {
    <#
    .SYNOPSIS
    Executes a validated project graph inside the existing runner process ownership boundary.
    .DESCRIPTION
    Revalidates configuration before any launch. Uses existing owned-process start, membership
    and stop helpers; schedules at most eight ready steps. One stopwatch covers launches,
    execution, cleanup and evidence. Reserve time is not available to project commands.
    Output and artifact bytes/counts are capped. Returns execution evidence, never independent
    coverage acceptance. Commands are trusted code, not sandboxed. No grants or credentials
    are added. EvidenceRoot must be a new framework-owned directory for this invocation.
    .PARAMETER Project
    Configuration returned by Read-RunnerProject. It is reloaded from trusted-bound bytes.
    .PARAMETER PayloadRoot
    Candidate payload root; must match the validated root.
    .PARAMETER EvidenceRoot
    New owned output directory for bounded logs and command specifications.
    .PARAMETER CancellationToken
    Caller-controlled cancellation; candidate input cannot redefine cancellation.
    .PARAMETER FrameworkCommand
    Trusted image-owned phase only: preserve framework transport environment instead of project filtering.
    .PARAMETER OperatorLimits
    Trusted caller ceilings. Candidate limits can reduce but never raise these fixed ceilings.
    .PARAMETER RunClock
    Existing platform stopwatch. Reused across source restore, build, tests and finalization.
    .PARAMETER AbsoluteDeadlineSeconds
    Absolute execution deadline on RunClock; never a new per-phase allowance.
    .PARAMETER FinalizationReserveSeconds
    Trusted cleanup and upload reserve inside the caller budget.
    .PARAMETER ArgumentValues
    Fixed caller values substituted only when an entire argument equals a known placeholder.
    .EXAMPLE
    Invoke-RunnerProject -Project $config -PayloadRoot /payload -EvidenceRoot /artifacts/run1
    .OUTPUTS
    System.Collections.IDictionary. Versioned execution record, cleanup proof and partial artifacts.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Project,
        [Parameter(Mandatory)][string]$PayloadRoot,
        [Parameter(Mandatory)][string]$EvidenceRoot,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [Collections.IDictionary]$OperatorLimits = @{},
        [Diagnostics.Stopwatch]$RunClock = $null,
        [double]$AbsoluteDeadlineSeconds = 3600,
        [ValidateRange(1, 300)][int]$FinalizationReserveSeconds = 1,
        [Collections.IDictionary]$ArgumentValues = @{},
        [switch]$FrameworkCommand
    )
    $clock = if ($null -eq $RunClock) {
        [Diagnostics.Stopwatch]::StartNew()
    }
    else {
        $RunClock
    }
    $startedSeconds = $clock.Elapsed.TotalSeconds
    $root = [IO.Path]::GetFullPath($PayloadRoot)
    if ($root -cne $Project['_payloadRoot']) {
        throw 'Execution payload root differs from validated configuration.'
    }
    # The caller cannot mutate the returned dictionary to bypass validation.
    $Project = Read-RunnerProject -Path $Project['_configurationPath'] -PayloadRoot $root -ExpectedSha256 $Project['_configSha256']
    if (Test-Path -LiteralPath $EvidenceRoot) {
        throw 'Evidence directory must be new and owned by this run.'
    }
    if (-not $PSCmdlet.ShouldProcess($EvidenceRoot, 'Execute trusted candidate project and retain bounded evidence')) {
        return
    }
    New-Item -ItemType Directory -Path $EvidenceRoot -ErrorAction Stop | Out-Null
    $evidence = (Get-Item -LiteralPath $EvidenceRoot).FullName
    $limits = $Project.limits
    $frameworkCaps = @{ budgetSeconds = 3600; maxConcurrency = 8; maxLogBytes = 16777216; maxArtifactBytes = 67108864; maxArtifacts = 128 }
    foreach ($key in $frameworkCaps.Keys) {
        $cap = $frameworkCaps[$key]
        if ($OperatorLimits.Contains($key)) {
            if ($OperatorLimits[$key] -le 0 -or $OperatorLimits[$key] -gt $cap) {
                throw "Invalid trusted operator cap '$key'."
            }
            $cap = $OperatorLimits[$key]
        }
        $limits[$key] = [Math]::Min($limits[$key], $cap)
    }
    $executionDeadline = [Math]::Min($AbsoluteDeadlineSeconds, $startedSeconds + $limits.budgetSeconds - [Math]::Max($limits.reserveSeconds, $FinalizationReserveSeconds))
    $cleanupDeadline = [Math]::Min($AbsoluteDeadlineSeconds + $FinalizationReserveSeconds - 1, $startedSeconds + $limits.budgetSeconds - 1)
    $running = [Collections.Generic.List[object]]::new()
    $all = [Collections.Generic.List[object]]::new()
    $records = [Collections.Generic.List[object]]::new()
    $finished = @{}
    $status = 'succeeded'
    $cleanupComplete = $true
    $errors = [Collections.Generic.List[string]]::new()
    $pwsh = (Get-Process -Id $PID).Path
    $previousRegistry = [Environment]::GetEnvironmentVariable('RUNNER_OWNERSHIP_ROOT')
    $registry = $previousRegistry
    if (-not $registry) {
        $registry = Join-Path $evidence 'ownership'
        New-Item -ItemType Directory -Path $registry | Out-Null
    }
    [Environment]::SetEnvironmentVariable('RUNNER_OWNERSHIP_ROOT', $registry)
    try {
        while ($finished.Count -lt $Project.steps.Count) {
            if ($CancellationToken.IsCancellationRequested) {
                $status = 'cancelled'
                break
            }
            if ($clock.Elapsed.TotalSeconds -ge $executionDeadline) {
                $status = 'timedOut'
                break
            }
            foreach ($child in @($running.ToArray())) {
                foreach ($pipe in $child.Pipes) {
                    if (-not (Receive-RunnerProjectPipe -Pipe $pipe -Counter $child.Counter -Limit $limits.maxLogBytes)) {
                        $status = 'failed'
                        $errors.Add("Log limit exceeded: $($child.Step.id)")
                    }
                }
                if (Test-Path -LiteralPath $child.Owner.Result) {
                    $child.Record.exitCode = [int][IO.File]::ReadAllText($child.Owner.Result)
                    $child.Record.status = if ($child.Record.exitCode -eq 0) {
                        'succeeded'
                    }
                    else {
                        'failed'
                    }
                    $child.Record.elapsedSeconds = $clock.Elapsed.TotalSeconds - $child.Record.startedSeconds
                    $finished[$child.Step.id] = $child.Record.status
                    Stop-DiagnosticOwnedProcess -Owner $child.Owner -RunClock $clock -DeadlineSeconds $cleanupDeadline
                    $null = $running.Remove($child)
                    if ($child.Record.exitCode -ne 0) {
                        $status = 'failed'
                    }
                }
                elseif ($child.Owner.Process.HasExited) {
                    $status = 'failed'
                    $errors.Add('Owned process anchor exited unexpectedly.')
                }
            }
            if ($status -ne 'succeeded') {
                break
            }
            foreach ($step in $Project.steps) {
                if ($running.Count -ge $limits.maxConcurrency) {
                    break
                }
                if ($finished.ContainsKey($step.id) -or @($running | Where-Object { $_.Step.id -eq $step.id }).Count -gt 0) {
                    continue
                }
                if (@($step.dependsOn | Where-Object { -not $finished.ContainsKey($_) -or $finished[$_] -ne 'succeeded' }).Count -gt 0) {
                    continue
                }
                if ($CancellationToken.IsCancellationRequested -or $clock.Elapsed.TotalSeconds -ge $executionDeadline) {
                    break
                }
                $working = Resolve-RunnerProjectPath -Root $root -RelativePath $step.workingDirectory
                $specification = Join-Path $evidence "$($step.id)-command.json"
                @{
                    executable = $step.executable
                    arguments = @(foreach ($argument in $step.arguments) {
                            if ($argument -ceq '{deadlineSeconds}') {
                                [string]$executionDeadline
                            }
                            elseif ($argument -ceq '{elapsedSeconds}') {
                                [string]$clock.Elapsed.TotalSeconds
                            }
                            elseif ($ArgumentValues.Contains($argument)) {
                                [string]$ArgumentValues[$argument]
                            }
                            elseif ($argument -cmatch '^\{[a-zA-Z]+\}$') {
                                throw "Unknown project argument placeholder '$argument'."
                            }
                            else {
                                $argument
                            }
                        })
                    workingDirectory = $working
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $specification -Encoding utf8NoBOM
                $launchFile = $pwsh
                $launchArguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-ProjectCommand.ps1'), '-Specification', $specification)
                if ($FrameworkCommand) {
                    $command = Get-Content -LiteralPath $specification -Raw | ConvertFrom-Json -AsHashtable
                    $launchFile = $command.executable
                    $launchArguments = @($command.arguments)
                }
                $owner = New-DiagnosticOwnedProcess -FilePath $launchFile -ArgumentList $launchArguments -Root $evidence -Token ([guid]::NewGuid().ToString('N')) -RunClock $clock -DeadlineSeconds $executionDeadline
                $record = @{
                    id = $step.id
                    status = 'running'
                    exitCode = $null
                    stdout = "$($step.id).stdout.log"
                    stderr = "$($step.id).stderr.log"
                    startedSeconds = $clock.Elapsed.TotalSeconds
                    elapsedSeconds = 0.0
                }
                $child = @{
                    Owner = $owner
                    Step = $step
                    Record = $record
                    Counter = @{ Bytes = 0L }
                    Pipes = @()
                }
                $all.Add($child)
                $running.Add($child)
                $records.Add($record)
                foreach ($pair in @(@($owner.Process.StandardOutput, $record.stdout), @($owner.Process.StandardError, $record.stderr))) {
                    $buffer = [byte[]]::new(4096)
                    $destination = [IO.File]::Create((Join-Path $evidence $pair[1]))
                    $child.Pipes += @{
                        Reader = $pair[0]
                        Destination = $destination
                        Buffer = $buffer
                        Read = $pair[0].BaseStream.ReadAsync($buffer, 0, $buffer.Length)
                        Done = $false
                    }
                }
            }
            Start-Sleep -Milliseconds 10
        }
    }
    catch {
        $status = 'failed'
        $errors.Add($_.Exception.Message)
    }
    finally {
        # Signal every boundary first. Never serially spend a fresh timeout per child.
        foreach ($child in $all) {
            try {
                Stop-DiagnosticOwnedProcess -Owner $child.Owner -RunClock $clock -DeadlineSeconds $cleanupDeadline
            }
            catch {
                $cleanupComplete = $false
                $errors.Add($_.Exception.Message)
            }
            if ($child.Record.status -eq 'running') {
                $child.Record.elapsedSeconds = $clock.Elapsed.TotalSeconds - $child.Record.startedSeconds
                $child.Record.status = $status
            }
        }
        do {
            $remaining = 0
            $pipesPending = 0
            foreach ($child in $all) {
                try {
                    $remaining += @(Get-DiagnosticOwnedMember -Owner $child.Owner -RunClock $clock -DeadlineSeconds $cleanupDeadline).Count
                }
                catch {
                    $remaining++
                    $errors.Add($_.Exception.Message)
                }
                foreach ($pipe in $child.Pipes) {
                    try {
                        if (-not (Receive-RunnerProjectPipe -Pipe $pipe -Counter $child.Counter -Limit $limits.maxLogBytes)) {
                            $status = 'failed'
                            $errors.Add("Log limit exceeded: $($child.Step.id)")
                        }
                    }
                    catch {
                        $cleanupComplete = $false
                        $pipe.Done = $true
                        $errors.Add($_.Exception.Message)
                    }
                    if (-not $pipe.Done) {
                        $pipesPending++
                    }
                }
            }
            if ($remaining -eq 0 -and $pipesPending -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 10
        } while ($clock.Elapsed.TotalSeconds -lt $cleanupDeadline)
        if ($remaining -gt 0 -or $pipesPending -gt 0) {
            $cleanupComplete = $false
            $errors.Add('Cleanup or pipe drain incomplete at shared deadline.')
        }
        foreach ($child in $all) {
            foreach ($pipe in $child.Pipes) {
                $pipe.Reader.Dispose()
                $pipe.Destination.Dispose()
            }
            $child.Owner.Process.Dispose()
            if ($null -ne $child.Owner.Job) {
                $child.Owner.Job.Dispose()
            }
            foreach ($suffix in @('.json', '.release', '.result', '.result.tmp', '.identity', '.error')) {
                Remove-Item -LiteralPath ($child.Owner.Base + $suffix) -ErrorAction SilentlyContinue
            }
        }
    }
    [Environment]::SetEnvironmentVariable('RUNNER_OWNERSHIP_ROOT', $previousRegistry)
    if (-not $cleanupComplete) {
        $status = 'failed'
    }
    $artifacts = [Collections.Generic.List[object]]::new()
    $artifactBytes = 0L
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($step in $Project.steps) {
        foreach ($relative in $step.artifacts) {
            if (-not $seen.Add($relative)) {
                continue
            }
            try {
                if ($clock.Elapsed.TotalSeconds -ge $cleanupDeadline) {
                    throw 'Artifact finalization budget exhausted.'
                }
                $path = Resolve-RunnerProjectPath -Root $root -RelativePath $relative
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    if ($finished.ContainsKey($step.id) -and $finished[$step.id] -eq 'succeeded') {
                        throw "Successful step '$($step.id)' omitted declared artifact '$relative'."
                    }
                    continue
                }
                $size = (Get-Item -LiteralPath $path -Force).Length
                if ($artifacts.Count -ge $limits.maxArtifacts -or $size -gt ($limits.maxArtifactBytes - $artifactBytes)) {
                    throw 'Artifact limit exceeded.'
                }
                $artifactBytes += $size
                $artifacts.Add(@{
                        path = $relative
                        bytes = $size
                        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
                    })
            }
            catch {
                $status = 'failed'
                $errors.Add($_.Exception.Message)
            }
        }
    }
    foreach ($step in $Project.steps) {
        if (@($records | Where-Object { $_.id -eq $step.id }).Count -eq 0) {
            $records.Add(@{
                    id = $step.id
                    status = 'notStarted'
                    exitCode = $null
                    elapsedSeconds = 0.0
                })
        }
    }
    $result = @{
        protocolVersion = 1
        configSha256 = $Project['_configSha256']
        requestedCapabilities = @($Project.requiredCapabilities)
        status = $status
        accepted = $false
        cleanupComplete = $cleanupComplete
        steps = $records.ToArray()
        artifacts = $artifacts.ToArray()
        errors = $errors.ToArray()
        elapsedSeconds = $clock.Elapsed.TotalSeconds
    }
    $result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $evidence 'execution.json') -Encoding utf8NoBOM
    return $result
}
Export-ModuleMember -Function Read-RunnerProject, Invoke-RunnerProject
