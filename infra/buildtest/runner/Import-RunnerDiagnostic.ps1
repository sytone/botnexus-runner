<#
.SYNOPSIS
Loads or tests the runner evidence contract.
.DESCRIPTION
Uses explicit caller-owned paths and bounded synthetic fixtures. Does not launch product hosts.
.EXAMPLE
./Import-RunnerDiagnostic.ps1
.OUTPUTS
System.Object. Contract observations or fixture results.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest

# Memory-only phase marks: no stats reads, compilation, timers or readiness callbacks.
if (-not (Get-Variable -Name DiagnosticPhaseBuffer -Scope Script -ErrorAction SilentlyContinue)) {
    $script:DiagnosticPhaseBuffer = [Collections.Generic.List[object]]::new()
}
function Add-DiagnosticPhase {
    <#
    .SYNOPSIS
    Records a bounded observation on the caller's original clock.
    .DESCRIPTION
    Memory only. Observation errors never change deadlines or native proof.
    .PARAMETER Phase
    Fixed phase name.
    .PARAMETER RunClock
    Original running stopwatch, never restarted here.
    .PARAMETER DeadlineSeconds
    Original absolute cutoff.
    .EXAMPLE
    Add-DiagnosticPhase -Phase 'launch.entry' -RunClock $clock -DeadlineSeconds 1
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([string]$Phase, [Diagnostics.Stopwatch]$RunClock, [double]$DeadlineSeconds)
    try {
        if ($script:DiagnosticPhaseBuffer.Count -ge 256) {
            # Keep initial compilation evidence plus the latest bounded tail.
            $script:DiagnosticPhaseBuffer.RemoveAt(32)
        }
        $seconds = if ($null -eq $RunClock) {
            $null
        }
        else {
            $RunClock.Elapsed.TotalSeconds
        }
        $clockId = if ($null -eq $RunClock) {
            $null
        }
        else {
            [Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($RunClock)
        }
        $script:DiagnosticPhaseBuffer.Add([ordered]@{ phase = $Phase; clockId = $clockId; seconds = $seconds; deadline = $DeadlineSeconds })
    }
    catch {
        Write-Verbose "Phase observation unavailable: $($_.Exception.Message)"
    }
}
function Get-DiagnosticPhaseEvidence {
    <#
    .SYNOPSIS
    Returns bounded memory evidence without observing files or readiness again.
    .DESCRIPTION
    Includes already-recorded native phases when containment was loaded. CPU observations
    use a native process CPU clock only; cgroup files are not read synchronously.
    .EXAMPLE
    Get-DiagnosticPhaseEvidence
    .OUTPUTS
    System.Object. Phase observations, not proof of cleanup.
    #>
    [CmdletBinding()]
    param()
    $script:DiagnosticPhaseBuffer.ToArray()
    if ('DiagnosticContainment' -as [type]) {
        try {
            [DiagnosticContainment]::PhaseEvidence()
        }
        catch {
            Write-Verbose "Native phase evidence unavailable: $($_.Exception.Message)"
        }
    }
}

function Get-DiagnosticBoundedText {
    <#
    .SYNOPSIS
    Bounds a diagnostic string by its actual JSON-encoded character count.
    .DESCRIPTION
    Binary search keeps valid escaped JSON within a fixed field budget. No I/O or callbacks.
    .PARAMETER Text
    Already-captured diagnostic text.
    .PARAMETER Budget
    Maximum JSON-encoded field characters including quotes.
    .PARAMETER Tail
    Keeps the end rather than the beginning.
    .EXAMPLE
    Get-DiagnosticBoundedText -Text $text -Budget 4096 -Tail
    .OUTPUTS
    System.Object. Text and explicit truncation state.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Text, [ValidateRange(32, 4096)][int]$Budget, [switch]$Tail)
    $low = 0
    $high = $Text.Length
    while ($low -lt $high) {
        $length = [int][Math]::Ceiling(($low + $high) / 2.0)
        $part = if ($Tail) {
            $Text.Substring($Text.Length - $length)
        }
        else {
            $Text.Substring(0, $length)
        }
        if ((ConvertTo-Json -InputObject $part -Compress).Length -le $Budget) {
            $low = $length
        }
        else {
            $high = $length - 1
        }
    }
    $textPart = if ($Tail) {
        $Text.Substring($Text.Length - $low)
    }
    else {
        $Text.Substring(0, $low)
    }
    return [pscustomobject]@{ Text = $textPart; Truncated = ($low -lt $Text.Length) }
}
function Get-DiagnosticFailureEnvelope {
    <#
    .SYNOPSIS
    Emits error-first valid bounded JSON independently of phase-history size.
    .DESCRIPTION
    Reserves encoded budgets for error2048, output4096 and phase4096 characters.
    Uses captured values only. Truncation is metadata, never successful cleanup proof.
    .PARAMETER Run
    Captured supervisor result; no provider is invoked.
    .EXAMPLE
    Get-DiagnosticFailureEnvelope -Run $run
    .OUTPUTS
    System.String. Compact valid JSON below the existing callback/retention limits.
    #>
    [CmdletBinding()]
    param($Run)
    $errorText = Get-DiagnosticBoundedText -Text (@($Run.CleanupErrors) -join ' | ') -Budget 2048
    $outputText = Get-DiagnosticBoundedText -Text ([string]$Run.OutputTail) -Budget 4096 -Tail
    $phases = @($Run.Phases)
    $excerpt = @($phases | Select-Object -First 4) + @($phases | Select-Object -Last 4)
    $phaseText = Get-DiagnosticBoundedText -Text (ConvertTo-Json -InputObject $excerpt -Depth 6 -Compress) -Budget 4096
    $clockIds = @($excerpt | ForEach-Object { if ($null -ne $_.clockId) {
                [string]$_.clockId
            } } | Select-Object -Unique -First 8)
    $clockText = Get-DiagnosticBoundedText -Text ($clockIds -join ',') -Budget 256
    $envelope = [ordered]@{
        version = 1
        error = $errorText.Text
        exitCode = [int]$Run.ExitCode
        cleanupComplete = [bool]$Run.CleanupComplete
        drainComplete = [bool]$Run.DrainComplete
        readersClosed = [bool]$Run.ReadersClosed
        timedOut = [bool]$Run.TimedOut
        realSeconds = [double]$Run.RealElapsedSeconds
        logicalSeconds = [double]$Run.ElapsedSeconds
        providerFailed = [bool]$Run.ProviderFailed
        clockIds = $clockText.Text
        outputTail = $outputText.Text
        truncation = [ordered]@{ error = $errorText.Truncated; output = $outputText.Truncated; clocks = $clockText.Truncated; phases = ($phases.Count -gt 8 -or $phaseText.Truncated); phaseCount = $phases.Count }
        phaseExcerpt = $phaseText.Text
    }
    return ConvertTo-Json -InputObject $envelope -Depth 6 -Compress
}

# Shared sender/runner policy. No wildcard resolution, evaluation, or shell interpolation.



function Get-DiagnosticEvidenceInventory {
    <#
    .SYNOPSIS
    Get DiagnosticEvidenceInventory for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Root
    Explicit Root input for this operation.
    .EXAMPLE
    Get-DiagnosticEvidenceInventory -Root $Root
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param([string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -File -Recurse | Where-Object { $_.Name -ne 'diagnostic-evidence.json' } | ForEach-Object {
            [ordered]@{ path = [IO.Path]::GetRelativePath($Root, $_.FullName).Replace('\', '/'); bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
        })
}

function Write-DiagnosticEvidence {
    <#
    .SYNOPSIS
    Write DiagnosticEvidence for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Root
    Explicit Root input for this operation.
    .PARAMETER Project
    Explicit Project input for this operation.
    .PARAMETER SourceSnapshot
    Explicit SourceSnapshot input for this operation.
    .PARAMETER RunnerImage
    Explicit RunnerImage input for this operation.
    .PARAMETER RunnerDirectory
    Explicit RunnerDirectory input for this operation.
    .PARAMETER Run
    Explicit Run input for this operation.
    .PARAMETER HangSeconds
    Explicit HangSeconds input for this operation.
    .PARAMETER OuterSeconds
    Explicit OuterSeconds input for this operation.
    .EXAMPLE
    Write-DiagnosticEvidence -Root $Root -Project $Project -SourceSnapshot $SourceSnapshot -RunnerImage $RunnerImage -RunnerDirectory $RunnerDirectory -Run $Run -HangSeconds $HangSeconds -OuterSeconds $OuterSeconds
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param([string]$Root, [string]$Project, $SourceSnapshot, [string]$RunnerImage, [string]$RunnerDirectory, $Run, [int]$HangSeconds, [int]$OuterSeconds)
    $parsed = Read-DiagnosticEvent -Root $Root
    $events = @($parsed.Events); $invalid = $parsed.Invalid
    $starts = @($events | Where-Object event -CEQ 'TestCaseStart')
    $ends = @($events | Where-Object event -CEQ 'TestCaseEnd')
    $inflight = @($parsed.InFlight)
    $inventory = @(Get-DiagnosticEvidenceInventory $Root)
    $dumps = @($inventory | Where-Object { $_.path -match '\.(dmp|core)$' })
    $stackDumps = @($dumps | Where-Object { Test-DiagnosticStackDump (Join-Path $Root $_.path) })
    $complete = $null -ne $Run -and -not $invalid -and $starts.Count -gt 0 -and ($Run.TimedOut -or $Run.ExitCode -ne 0 -or $inflight.Count -eq 0)
    foreach ($cleanupProperty in @('CleanupComplete', 'DrainComplete', 'ReadersClosed')) {
        if ($null -ne $Run -and $null -ne $Run.PSObject.Properties[$cleanupProperty] -and $Run.$cleanupProperty -ne $true) {
            $complete = $false
        }
    }
    $needsStack = $null -ne $Run -and ($Run.TimedOut -or $inflight.Count -gt 0)
    $record = [ordered]@{
        version = 1; mode = 'diagnostic'; qualifiesForCoreReceipt = $false
        project = $Project; sourceSnapshot = $SourceSnapshot; runnerImage = $RunnerImage
        runnerFiles = @(Get-DiagnosticEvidenceInventory $RunnerDirectory)
        completedUtc = [DateTime]::UtcNow.ToString('o'); hangSeconds = $HangSeconds; outerSeconds = $OuterSeconds
        process = $Run; eventEvidenceComplete = $complete; startCount = $starts.Count; endCount = $ends.Count
        hangEvidenceComplete = $complete -and (-not $needsStack -or $stackDumps.Count -gt 0)
        stackDumpValidated = $stackDumps.Count -gt 0
        inventoryScope = 'Files present before result.json and artifact-upload timing are finalized; journals are the authoritative event sequence.'
        inFlight = $inflight; hangDumpPresent = $dumps.Count -gt 0; files = $inventory
        sensitivity = 'Private diagnostic evidence: dumps and traces may contain secrets. Do not publish raw artifacts.'
    }
    $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $Root 'diagnostic-evidence.json') -Encoding utf8NoBOM
    return $record
}

# Failed/hung diagnostic runs still need source attribution, not successful-test certification.
function Assert-DiagnosticSourceProof {
    <#
    .SYNOPSIS
    Assert DiagnosticSourceProof for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Result
    Explicit Result input for this operation.
    .PARAMETER Evidence
    Explicit Evidence input for this operation.
    .PARAMETER Digest
    Explicit Digest input for this operation.
    .PARAMETER RunId
    Explicit RunId input for this operation.
    .EXAMPLE
    Assert-DiagnosticSourceProof -Result $Result -Evidence $Evidence -Digest $Digest -RunId $RunId
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param($Result, $Evidence, [string]$Digest, [string]$RunId)
    foreach ($contract in @($Result, $Evidence)) {
        if ($null -eq $contract -or $null -eq $contract.PSObject.Properties['sourceSnapshot']) {
            throw 'Missing diagnostic exact-source proof.'
        }
        $proof = $contract.sourceSnapshot
        if ($null -eq $proof -or $proof.version -isnot [long] -and $proof.version -isnot [int] -or $proof.version -ne 1 -or $proof.verified -isnot [bool] -or $proof.verified -ne $true -or $proof.digest -isnot [string] -or $proof.digest -cne $Digest -or $proof.runId -isnot [string] -or $proof.runId -cne $RunId -or $contract.mode -cne 'diagnostic') {
            throw 'Diagnostic source proof mismatch.'
        }
    }
    if ($Result.runId -cne $RunId) {
        throw 'Diagnostic run identity mismatch.'
    }
}

# One parser for final certification and watchdog target discovery. Pair only within the
# collector journal, exact source/name/PID, and strictly increasing sequence/UTC order.
function Read-DiagnosticEvent {
    <#
    .SYNOPSIS
    Read DiagnosticEvent for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Root
    Explicit Root input for this operation.
    .PARAMETER Live
    Explicit Live input for this operation.
    .EXAMPLE
    Read-DiagnosticEvent -Root $Root -Live $Live
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param([string]$Root, [switch]$Live)
    $events = @(); $hosts = @(); $inflight = @(); $invalid = $false; $incomplete = $false
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Filter 'events-*.jsonl' -Recurse -File)) {
        $active = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        $sequence = 0L; $lastUtc = [DateTimeOffset]::MinValue; $journalPid = 0L
        # Read one immutable snapshot. Only an unterminated last line is deferred;
        # malformed complete lines remain invalid, and final certification is strict.
        $readStream = [IO.FileStream]::new($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $reader = [IO.StreamReader]::new($readStream)
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
        $lines = @($text -split '\r?\n')
        if ($text.EndsWith("`n")) {
            $lines = @($lines | Select-Object -SkipLast 1)
        }
        elseif ($Live -and $text.Length -gt 0) {
            $incomplete = $true; $lines = @($lines | Select-Object -SkipLast 1)
        }
        if ($text.Length -eq 0) {
            $lines = @()
        }
        foreach ($line in $lines) {
            try {
                $jsonOptions = @{ ErrorAction = 'Stop' }
                # PowerShell 7.6 began coercing ISO strings into DateTime by default.
                if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
                    $jsonOptions.DateKind = 'String'
                }
                $e = $line | ConvertFrom-Json @jsonOptions
                foreach ($p in @('event', 'utc', 'sequence', 'processId')) {
                    if ($null -eq $e.PSObject.Properties[$p]) {
                        throw "Missing $p"
                    }
                }
                if (($e.sequence -isnot [long] -and $e.sequence -isnot [int]) -or $e.sequence -le $sequence -or ($e.processId -isnot [long] -and $e.processId -isnot [int]) -or $e.processId -le 0) {
                    throw 'Invalid sequence/PID.'
                }
                $utc = [DateTimeOffset]::MinValue
                if ($e.utc -isnot [string] -or $e.utc -cnotmatch 'Z$' -or -not [DateTimeOffset]::TryParse($e.utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$utc) -or $utc -lt $lastUtc) {
                    throw 'Invalid UTC order.'
                }
                if ($journalPid -ne 0 -and $journalPid -ne $e.processId) {
                    throw 'Journal process changed.'
                }
                $sequence = $e.sequence; $lastUtc = $utc; $journalPid = $e.processId
                $e | Add-Member -NotePropertyName journal -NotePropertyValue ([IO.Path]::GetRelativePath($Root, $file.FullName))
                if ($e.event -ceq 'TestHostLaunched') {
                    if (($e.testHostProcessId -isnot [long] -and $e.testHostProcessId -isnot [int]) -or $e.testHostProcessId -le 0 -or $e.testHostStartUtc -isnot [string] -or $e.testHostStartUtc -cnotmatch 'Z$') {
                        throw 'Invalid testhost identity.'
                    }
                    [void][DateTimeOffset]::Parse($e.testHostStartUtc, [Globalization.CultureInfo]::InvariantCulture)
                    $hosts += $e; continue
                }
                foreach ($p in @('id', 'fullyQualifiedName', 'source')) {
                    if ($null -eq $e.PSObject.Properties[$p]) {
                        throw "Missing $p"
                    }
                }
                $guid = [guid]::Empty
                if ($e.id -isnot [string] -or -not [guid]::TryParse($e.id, [ref]$guid) -or $guid -eq [guid]::Empty -or $e.source -isnot [string] -or [string]::IsNullOrWhiteSpace($e.source) -or $e.fullyQualifiedName -isnot [string] -or [string]::IsNullOrWhiteSpace($e.fullyQualifiedName)) {
                    throw 'Invalid test identity.'
                }
                $key = @($guid.ToString(), $e.source, $e.fullyQualifiedName) | ConvertTo-Json -Compress
                if ($e.event -ceq 'TestCaseStart') {
                    if ($active.ContainsKey($key)) {
                        throw 'Duplicate active start.'
                    }; $active.Add($key, $e)
                }
                elseif ($e.event -ceq 'TestCaseEnd') {
                    if (-not $active.Remove($key)) {
                        throw 'Unpaired/duplicate end.'
                    }
                }
                else {
                    throw 'Unknown collector event.'
                }
                $events += $e
            }
            catch {
                $invalid = $true
            }
        }
        $inflight += @($active.Values)
    }
    return [pscustomobject]@{ Events = $events; Hosts = $hosts; InFlight = $inflight; Invalid = $invalid; Incomplete = $incomplete }
}

# Validate the native dump container and actual thread/stack payload, not an extension
# or magic prefix alone. createdump on Linux emits ELF core; Windows blame emits MDMP.
function Test-DiagnosticStackDump {
    <#
    .SYNOPSIS
    Test DiagnosticStackDump for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Path
    Explicit Path input for this operation.
    .EXAMPLE
    Test-DiagnosticStackDump -Path $Path
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param([string]$Path)
    $reader = $null
    try {
        $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path)); $s = $reader.BaseStream
        if ($s.Length -lt 64) {
            return $false
        }
        $magic = $reader.ReadUInt32()
        if ($magic -eq 0x464c457f) {
            if ($reader.ReadByte() -ne 2 -or $reader.ReadByte() -ne 1) {
                return $false
            }
            $s.Position = 16; if ($reader.ReadUInt16() -ne 4) {
                return $false
            }
            $s.Position = 32; $offset = $reader.ReadUInt64(); $s.Position = 54; $size = $reader.ReadUInt16(); $count = $reader.ReadUInt16()
            if ($size -lt 56 -or $count -eq 0 -or $offset + [long]$size * $count -gt $s.Length) {
                return $false
            }
            $threads = $false; $memory = $false
            for ($i = 0; $i -lt $count; $i++) {
                $s.Position = [long]$offset + $i * $size; $type = $reader.ReadUInt32(); $s.Position += 4; $data = $reader.ReadUInt64(); $s.Position += 16; $bytes = $reader.ReadUInt64()
                if ($data -gt $s.Length -or $bytes -gt $s.Length - $data) {
                    return $false
                }
                if ($type -eq 1 -and $bytes -gt 0) {
                    $memory = $true
                }
                if ($type -eq 4) {
                    $s.Position = $data; $end = $data + $bytes
                    while ($s.Position + 12 -le $end) {
                        $name = $reader.ReadUInt32(); $desc = $reader.ReadUInt32(); $note = $reader.ReadUInt32()
                        $next = $s.Position + ([long][Math]::Ceiling($name / 4.0) * 4) + ([long][Math]::Ceiling($desc / 4.0) * 4)
                        if ($next -gt $end) {
                            return $false
                        }
                        if ($note -eq 1 -and $desc -ge 112) {
                            $threads = $true
                        }
                        $s.Position = $next
                    }
                }
            }
            return $threads -and $memory
        }
        if ($magic -eq 0x504d444d) {
            $s.Position = 8; $count = $reader.ReadUInt32(); $offset = $reader.ReadUInt32()
            if ($count -eq 0 -or [long]$offset + 12L * $count -gt $s.Length) {
                return $false
            }
            for ($i = 0; $i -lt $count; $i++) {
                $s.Position = [long]$offset + 12L * $i; $type = $reader.ReadUInt32(); $bytes = $reader.ReadUInt32(); $data = $reader.ReadUInt32()
                if ([long]$data + $bytes -gt $s.Length) {
                    return $false
                }
                if ($type -eq 3 -and $bytes -ge 52) {
                    $s.Position = $data; $threads = $reader.ReadUInt32()
                    if ($threads -eq 0 -or 4L + 48L * $threads -gt $bytes) {
                        return $false
                    }
                    for ($t = 0; $t -lt $threads; $t++) {
                        $s.Position = [long]$data + 4 + 48L * $t + 32; $stack = $reader.ReadUInt32(); $rva = $reader.ReadUInt32()
                        if ($stack -gt 0 -and [long]$rva + $stack -le $s.Length) {
                            return $true
                        }
                    }
                }
            }
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

# Every command (including dump tools) owns a gated wrapper and OS containment.
function New-DiagnosticOwnedProcess {
    <#
    .SYNOPSIS
    New DiagnosticOwnedProcess for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER FilePath
    Explicit FilePath input for this operation.
    .PARAMETER ArgumentList
    Explicit ArgumentList input for this operation.
    .PARAMETER Root
    Explicit Root input for this operation.
    .PARAMETER RunClock
    Original supervisor stopwatch; shared by launch and teardown.
    .PARAMETER DeadlineSeconds
    Absolute deadline on RunClock; no new per-owner allowance.
    .PARAMETER Token
    Explicit Token input for this operation.
    .EXAMPLE
    New-DiagnosticOwnedProcess -FilePath $FilePath -ArgumentList $ArgumentList -Root $Root -Token $Token
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath, [string[]]$ArgumentList, [string]$Root, [string]$Token,
        [Diagnostics.Stopwatch]$RunClock = $null, [double]$DeadlineSeconds = 1)
    if (-not $PSCmdlet.ShouldProcess($FilePath, 'Launch owned command')) {
        return
    }

    Add-DiagnosticPhase -Phase 'launch.entry' -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds
    if (-not ('DiagnosticContainment' -as [type])) {
        Add-DiagnosticPhase -Phase 'compile.before' -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds
        try {
            Add-Type -Path (Join-Path $PSScriptRoot 'DiagnosticContainment.cs')
        }
        finally {
            Add-DiagnosticPhase -Phase 'compile.after' -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds
        }
    }
    if (-not $IsLinux -and -not $IsWindows) {
        throw 'Diagnostic containment is unsupported on this platform; command not launched.'
    }
    $launchClock = if ($null -eq $RunClock) {
        [Diagnostics.Stopwatch]::StartNew()
    }
    else {
        $RunClock
    }
    if ($launchClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        Add-DiagnosticPhase -Phase 'launch.failed' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        $phaseJson = @(Get-DiagnosticPhaseEvidence) | ConvertTo-Json -Depth 6 -Compress
        if ($phaseJson.Length -gt 8192) {
            $phaseJson = $phaseJson.Substring(0, 8192)
        }
        Write-Warning "LAUNCH_PHASE_ERROR $phaseJson"
        throw 'Owned launch deadline exhausted before wrapper start.'
    }
    $setsid = $null
    if ($IsLinux) {
        $setsid = Get-Command setsid -CommandType Application -ErrorAction Stop | Select-Object -First 1
    }
    $base = Join-Path $Root "owned-$Token"
    $config = @{file = $FilePath; arguments = @($ArgumentList); release = "$base.release"; result = "$base.result"; identity = "$base.identity"; error = "$base.error" }
    $config | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$base.json" -Encoding utf8NoBOM
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.UseShellExecute = $false; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    if ($IsLinux) {
        $info.FileName = $setsid.Source; [void]$info.ArgumentList.Add('--'); [void]$info.ArgumentList.Add($pwsh)
    }
    else {
        $info.FileName = $pwsh
    }
    foreach ($a in @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'Invoke-DiagnosticOwnedCommand.ps1'), "$base.json")) {
        [void]$info.ArgumentList.Add($a)
    }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info; $job = $null
    try {
        if ($IsWindows) {
            $job = [DiagnosticContainment]::new()
        }
        Add-DiagnosticPhase -Phase 'wrapper.before' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        if (-not $process.Start()) {
            throw 'Containment wrapper did not start.'
        }
        Add-DiagnosticPhase -Phase 'wrapper.started' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        if ($IsWindows) {
            $job.Assign($process.Handle)
        }
        else {
            while (-not [DiagnosticContainment]::IsSessionLeader($process.Id) -and -not $process.HasExited -and $launchClock.Elapsed.TotalSeconds -lt $DeadlineSeconds) {
                Start-Sleep -Milliseconds 10
            }
            if ($process.HasExited -or -not [DiagnosticContainment]::IsSessionLeader($process.Id)) {
                throw 'Linux owned session was not established; command not launched.'
            }
        }
        Add-DiagnosticPhase -Phase 'session.confirmed' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        # This is the only release boundary. No target can spawn before containment.
        if ($launchClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            throw 'Owned launch deadline exhausted before release.'
        }
        Add-DiagnosticPhase -Phase 'release.before' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        if ($IsLinux) {
            [DiagnosticContainment]::RegisterAndRelease($process.Id, $config.release, $launchClock, $DeadlineSeconds)
        }
        else {
            [IO.File]::WriteAllText($config.release, 'go')
        }
        Add-DiagnosticPhase -Phase 'release.after' -RunClock $launchClock -DeadlineSeconds $DeadlineSeconds
        return [pscustomobject]@{Process = $process; Job = $job; GroupId = $process.Id; Result = $config.result; Identity = $config.identity; ErrorPath = $config.error; Base = $base; Observed = @{}; Stopped = $false }
    }
    catch {
        if ($null -ne $job) {
            try {
                $job.Kill()
            }
            catch {
                Write-Verbose $_.Exception.Message
            }; $job.Dispose()
        }
        $launchError = $_
        try {
            if (-not $process.HasExited) {
                $process.Kill($true)
            }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
        $process.Dispose(); throw $launchError
    }
}

function Get-DiagnosticOwnedMember {
    <#
    .SYNOPSIS
    Get DiagnosticOwnedMember for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Owner
    Explicit Owner input for this operation.
    .PARAMETER RunClock
    Original supervisor clock.
    .PARAMETER DeadlineSeconds
    Absolute deadline on RunClock; no fresh scan allowance.
    .EXAMPLE
    Get-DiagnosticOwnedMember -Owner $Owner
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param($Owner, [Diagnostics.Stopwatch]$RunClock = $null, [double]$DeadlineSeconds = 0)
    Add-DiagnosticPhase -Phase 'proof.before' -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds
    if ($null -eq $RunClock) {
        throw 'Membership certification requires the original supervisor clock.'
    }
    if ($RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        throw 'Membership certification deadline expired before query.'
    }
    $members = @()
    if ($IsLinux) {
        $members = @([DiagnosticContainment]::RegisteredMemberIds($Owner.GroupId, $RunClock, $DeadlineSeconds))
    }
    else {
        # Invoke the accessor explicitly: PowerShell property access can mask a
        # throwing native getter as an empty value. Unknown membership is failure.
        $members = @($Owner.Job.get_MemberIds())
    }
    Add-DiagnosticPhase -Phase 'proof.after' -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds
    if ($RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        throw 'Membership certification deadline expired during query.'
    }
    foreach ($processId in $members) {
        if ($Owner.Observed.ContainsKey($processId)) {
            continue
        }
        $p = $null
        try {
            $p = [Diagnostics.Process]::GetProcessById($processId); $Owner.Observed[$processId] = [ordered]@{processId = $processId; startUtc = $p.StartTime.ToUniversalTime().ToString('o') }
        }
        catch {
            Write-Verbose $_.Exception.Message
        }
        finally {
            if ($null -ne $p) {
                $p.Dispose(); $p = $null
            }
        }
    }
    if ($RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
        throw 'Membership certification deadline expired during observation.'
    }
    return $members
}

function Stop-DiagnosticOwnedProcess {
    <#
    .SYNOPSIS
    Stop DiagnosticOwnedProcess for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER Owner
    Explicit Owner input for this operation.
    .PARAMETER RunClock
    Original supervisor stopwatch for bounded native admission.
    .PARAMETER DeadlineSeconds
    Absolute deadline on RunClock; default signal-only uses no lock wait.
    .PARAMETER WaitTimeoutMilliseconds
    Explicit WaitTimeoutMilliseconds input for this operation.
    .EXAMPLE
    Stop-DiagnosticOwnedProcess -Owner $Owner -WaitTimeoutMilliseconds $WaitTimeoutMilliseconds
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    [CmdletBinding(SupportsShouldProcess)]
    param($Owner, [ValidateRange(0, 2147483647)][int]$WaitTimeoutMilliseconds = 0,
        [Diagnostics.Stopwatch]$RunClock = $null, [double]$DeadlineSeconds = 0)
    if (-not $PSCmdlet.ShouldProcess([string]$Owner.GroupId, 'Terminate owned boundary')) {
        return
    }

    # Default is signal-only: the supervisor terminates every owner before waiting
    # on its shared absolute deadline. Standalone callers may opt into completion.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    # Always terminate the ownership boundary, even if the command/launcher exited.
    if ($IsLinux) {
        $signalClock = if ($null -eq $RunClock) {
            $clock
        }
        else {
            $RunClock
        }
        $signalDeadline = if ($null -eq $RunClock) {
            $WaitTimeoutMilliseconds / 1000.0
        }
        else {
            $DeadlineSeconds
        }
        [DiagnosticContainment]::KillGroup($Owner.GroupId, $signalClock, $signalDeadline)
    }
    else {
        $Owner.Job.Kill()
    }
    $Owner.Stopped = $true
    if ($WaitTimeoutMilliseconds -eq 0) {
        return
    }
    while ($true) {
        # Anchor exit alone says nothing about descendants. Query the ownership
        # boundary, not cached PIDs (which could already have been reused).
        if ($null -eq $RunClock) {
            throw 'Completion certification requires the original supervisor clock.'
        }
        $remaining = @(Get-DiagnosticOwnedMember $Owner -RunClock $RunClock -DeadlineSeconds $DeadlineSeconds).Count
        $anchorExited = $Owner.Process.HasExited
        if ($RunClock.Elapsed.TotalSeconds -ge $DeadlineSeconds) {
            if ($remaining -gt 0 -or -not $anchorExited) {
                throw 'Owned processes still live at cleanup deadline.'
            }
            throw 'Owned completion certification deadline expired.'
        }
        if ($clock.Elapsed.TotalMilliseconds -ge $WaitTimeoutMilliseconds) {
            if ($remaining -gt 0 -or -not $anchorExited) {
                throw 'Owned processes still live at cleanup deadline.'
            }
            throw 'Owned completion certification deadline expired.'
        }
        # Linux excludes zombies from live membership before the parent has
        # necessarily observed/reaped the anchor. Both completion proofs matter.
        if ($remaining -eq 0 -and $anchorExited) {
            return
        }
        $budget = $WaitTimeoutMilliseconds - $clock.Elapsed.TotalMilliseconds
        if ($null -ne $RunClock) {
            $budget = [Math]::Min($budget, ($DeadlineSeconds - $RunClock.Elapsed.TotalSeconds) * 1000)
        }
        if ($budget -le 0) {
            throw 'Owned processes still live at cleanup deadline.'
        }
        Start-Sleep -Milliseconds ([int][Math]::Min(10, [Math]::Ceiling($budget)))
    }
}

# Diagnostic-only supervisor. All starts, retries, ownership teardown and drains
# share one clock. Root exit is not completion while owned descendants remain.
function Invoke-DiagnosticProcess {
    <#
    .SYNOPSIS
    Invoke DiagnosticProcess for the runner contract.
    .DESCRIPTION
    Applies the evidence boundary to explicit run paths or synthetic observations.
    .PARAMETER FilePath
    Explicit FilePath input for this operation.
    .PARAMETER ArgumentList
    Explicit ArgumentList input for this operation.
    .PARAMETER LogPath
    Explicit LogPath input for this operation.
    .PARAMETER TimeoutSeconds
    Explicit TimeoutSeconds input for this operation.
    .PARAMETER EvidenceRoot
    Explicit EvidenceRoot input for this operation.
    .PARAMETER CaptureReserveSeconds
    Explicit CaptureReserveSeconds input for this operation.
    .PARAMETER DumpTimeoutSeconds
    Explicit DumpTimeoutSeconds input for this operation.
    .PARAMETER KillReserveSeconds
    Explicit KillReserveSeconds input for this operation.
    .PARAMETER PollMilliseconds
    Explicit PollMilliseconds input for this operation.
    .PARAMETER DumpFilePath
    Explicit DumpFilePath input for this operation.
    .PARAMETER DumpArgumentPrefix
    Explicit DumpArgumentPrefix input for this operation.
    .PARAMETER ElapsedSecondsProvider
    Explicit ElapsedSecondsProvider input for this operation.
    .EXAMPLE
    Invoke-DiagnosticProcess -FilePath $FilePath -ArgumentList $ArgumentList -LogPath $LogPath -TimeoutSeconds $TimeoutSeconds -EvidenceRoot $EvidenceRoot -CaptureReserveSeconds $CaptureReserveSeconds -DumpTimeoutSeconds $DumpTimeoutSeconds -KillReserveSeconds $KillReserveSeconds -PollMilliseconds $PollMilliseconds -DumpFilePath $DumpFilePath -DumpArgumentPrefix $DumpArgumentPrefix -ElapsedSecondsProvider $ElapsedSecondsProvider
    .OUTPUTS
    System.Object. Contract evidence or a terminating validation error.
    #>

    param([string]$FilePath, [string[]]$ArgumentList, [string]$LogPath, [int]$TimeoutSeconds,
        [string]$EvidenceRoot, [int]$CaptureReserveSeconds = 90, [int]$DumpTimeoutSeconds = 60,
        [int]$KillReserveSeconds = 5, [int]$PollMilliseconds = 100,
        [string]$DumpFilePath = '', [string[]]$DumpArgumentPrefix = @(),
        [scriptblock]$ElapsedSecondsProvider = $null)
    if ($TimeoutSeconds -le $CaptureReserveSeconds -or $CaptureReserveSeconds -le ($DumpTimeoutSeconds + $KillReserveSeconds) -or $DumpTimeoutSeconds -le 0 -or $KillReserveSeconds -le 0 -or $PollMilliseconds -le 0) {
        throw 'Insufficient absolute capture budget.'
    }
    $provider = $ElapsedSecondsProvider
    $clock = [Diagnostics.Stopwatch]::StartNew(); $captures = @(); $owners = @(); $dumpChildren = @(); $pipes = @(); $seen = @{}; $attempts = @{}; $errors = @(); $owner = $null
    # Public helper seam for synthetic fixtures only. Production callers omit it:
    # the same running Stopwatch governs every launch, capture, kill and drain.
    # Injected callbacks must be nonblocking observations. An arbitrary synchronous
    # callback cannot be interrupted here. Cache and latch even a one-shot fault:
    # teardown and return never execute user/fixture code again.
    $elapsedState = @{ Last = 0.0; Failed = $false; Marked = $null }
    $readElapsed = { param([string]$phase = 'read')
        if ($null -eq $provider) {
            $elapsedState.Last = $clock.Elapsed.TotalSeconds
        }
        elseif (-not $elapsedState.Failed) {
            try {
                $elapsedState.Last = [double](& $provider $phase $owner $dumpChildren $captures)
            }
            catch {
                $elapsedState.Failed = $true
                throw
            }
        }
        return $elapsedState.Last
    }
    $timedOut = $false; $exitCode = 1; $cleanupComplete = $true; $drainComplete = $true; $readersClosed = $true; $journalInvalid = $false
    try {
        $owner = New-DiagnosticOwnedProcess -FilePath $FilePath -ArgumentList $ArgumentList -Root $EvidenceRoot -Token ([guid]::NewGuid().ToString('N')) -RunClock $clock -DeadlineSeconds ($TimeoutSeconds - $KillReserveSeconds); $owners += $owner
        foreach ($pair in @(@($owner.Process.StandardOutput, "$LogPath.stdout"), @($owner.Process.StandardError, "$LogPath.stderr"))) {
            $destination = [IO.File]::Create($pair[1]); $pipes += [pscustomobject]@{Reader = $pair[0]; Destination = $destination; Copy = $pair[0].BaseStream.CopyToAsync($destination) }
        }
        while ($true) {
            $elapsed = & $readElapsed 'poll'
            if ($elapsedState.Marked -ne $elapsed) {
                Add-DiagnosticPhase -Phase "readiness.logical.$elapsed" -RunClock $clock -DeadlineSeconds $TimeoutSeconds
                $elapsedState.Marked = $elapsed
            }
            # Readiness callbacks may consume real time while logical time stays
            # frozen. Do not start a proof or capture with an expired original
            # allowance. Production uses this same Stopwatch for both decisions.
            if ($clock.Elapsed.TotalSeconds -ge ($TimeoutSeconds - $KillReserveSeconds)) {
                $errors += "Original execution allowance exhausted: logicalSeconds=$elapsed realSeconds=$($clock.Elapsed.TotalSeconds) killAtSeconds=$($TimeoutSeconds - $KillReserveSeconds) deadlineSeconds=$TimeoutSeconds."
                $timedOut = $true; break
            }
            $members = @(Get-DiagnosticOwnedMember $owner -RunClock $clock -DeadlineSeconds $TimeoutSeconds)
            if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                throw 'Original deadline exhausted after membership proof.'
            }
            if (Test-Path -LiteralPath $owner.Result) {
                if (@($members | Where-Object { $_ -ne $owner.GroupId }).Count -eq 0) {
                    $exitCode = [int][IO.File]::ReadAllText($owner.Result); break
                }
            }
            if ($owner.Process.HasExited) {
                $errors += 'Containment anchor exited unexpectedly.'; $cleanupComplete = $false; break
            }
            if ($elapsed -ge ($TimeoutSeconds - $KillReserveSeconds)) {
                $timedOut = $true; break
            }
            if ($elapsed -ge ($TimeoutSeconds - $CaptureReserveSeconds)) {
                try {
                    $parsed = Read-DiagnosticEvent -Root $EvidenceRoot -Live
                }
                catch {
                    $errors += "Live journal read failed: $($_.Exception.Message)"; $parsed = $null
                }
                if ($null -ne $parsed) {
                    $journalInvalid = $journalInvalid -or $parsed.Invalid
                    foreach ($hostEvent in @($parsed.Hosts)) {
                        $key = "$($hostEvent.testHostProcessId):$($hostEvent.testHostStartUtc)"
                        if ($seen.ContainsKey($key)) {
                            continue
                        }
                        # Completed corrupt lines are terminal, not transient append races.
                        if ($parsed.Invalid) {
                            $seen[$key] = $true; $captures += [ordered]@{testHostProcessId = $hostEvent.testHostProcessId; journal = $hostEvent.journal; startedSeconds = $elapsed; exitCode = $null; timedOut = $false; error = 'Collector journal validation failed (complete line).'; dumpPath = $null }; continue
                        }
                        if ($attempts.ContainsKey($key) -and $attempts[$key] -ge 3) {
                            continue
                        }
                        if (-not $attempts.ContainsKey($key)) {
                            $attempts[$key] = 0
                        }; $attempts[$key]++
                        $record = [ordered]@{testHostProcessId = $hostEvent.testHostProcessId; journal = $hostEvent.journal; startedSeconds = $elapsed; exitCode = $null; timedOut = $false; error = $null; dumpPath = $null; attempts = $attempts[$key] }
                        try {
                            $target = [Diagnostics.Process]::GetProcessById($hostEvent.testHostProcessId)
                            try {
                                [void][DateTimeOffset]::Parse($hostEvent.testHostStartUtc, [Globalization.CultureInfo]::InvariantCulture)
                                $actual = [DateTimeOffset]::new($target.StartTime.ToUniversalTime())
                                # Kernel starttime is exact across Linux observers; wall-clock
                                # StartTime is not. Never replace PID-reuse proof with tolerance.
                                $identityMatches = if ($IsLinux) {
                                    if ($null -eq $hostEvent.PSObject.Properties['testHostStartToken']) {
                                        $false
                                    }
                                    else {
                                        $stat = [IO.File]::ReadAllText("/proc/$($target.Id)/stat")
                                        $token = $stat.Substring($stat.LastIndexOf(')') + 2).Split(' ', [StringSplitOptions]::RemoveEmptyEntries)[19]
                                        $token -ceq [string]$hostEvent.testHostStartToken
                                    }
                                }
                                else {
                                    $actual.UtcDateTime.Ticks.ToString([Globalization.CultureInfo]::InvariantCulture) -ceq [string]$hostEvent.testHostStartToken
                                }
                                if (-not $identityMatches) {
                                    throw 'Testhost PID was reused.'
                                }
                                if ($members -notcontains $target.Id) {
                                    throw 'Recorded testhost is outside diagnostic containment.'
                                }
                            }
                            finally {
                                $target.Dispose()
                            }
                            $tool = $DumpFilePath
                            if (-not $tool) {
                                if (-not $IsLinux) {
                                    throw 'Absolute native capture currently requires Linux createdump.'
                                }
                                $maps = Get-Content "/proc/$($hostEvent.testHostProcessId)/maps"
                                $core = @($maps | Where-Object { $_ -match '/libcoreclr\.so$' } | Select-Object -First 1)
                                if (-not $core.Count) {
                                    throw 'Testhost runtime mapping not found.'
                                }
                                $runtime = ($core[0] -split '\s+', 6)[5]; $tool = Join-Path (Split-Path $runtime -Parent) 'createdump'
                                if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
                                    throw 'Runtime createdump is unavailable.'
                                }
                            }
                            $dumpPath = Join-Path $EvidenceRoot "absolute-$($hostEvent.testHostProcessId).dmp"; $record.dumpPath = $dumpPath
                            $dumpOwner = New-DiagnosticOwnedProcess -FilePath $tool -ArgumentList (@($DumpArgumentPrefix) + @('--normal', '--name', $dumpPath, [string]$hostEvent.testHostProcessId)) -Root $EvidenceRoot -Token ([guid]::NewGuid().ToString('N')) -RunClock $clock -DeadlineSeconds ($TimeoutSeconds - $KillReserveSeconds); $owners += $dumpOwner
                            $dumpChildren += [pscustomobject]@{Owner = $dumpOwner; Record = $record; Deadline = $TimeoutSeconds - $KillReserveSeconds; LaunchConfirmed = $false }
                            foreach ($pair in @(@($dumpOwner.Process.StandardOutput, "$dumpPath.stdout.log"), @($dumpOwner.Process.StandardError, "$dumpPath.stderr.log"))) {
                                $destination = [IO.File]::Create($pair[1]); $pipes += [pscustomobject]@{Reader = $pair[0]; Destination = $destination; Copy = $pair[0].BaseStream.CopyToAsync($destination) }
                            }
                            $seen[$key] = $true; $captures += $record
                        }
                        catch {
                            $record.error = $_.Exception.Message
                            # Failed launch may retry, bounded to three attempts on the same clock.
                            if ($attempts[$key] -ge 3) {
                                $seen[$key] = $true; $captures += $record
                            }
                        }
                    }
                }
            }
            foreach ($child in $dumpChildren) {
                if ($clock.Elapsed.TotalSeconds -ge ($TimeoutSeconds - $KillReserveSeconds)) {
                    $errors += "Original capture allowance exhausted: realSeconds=$($clock.Elapsed.TotalSeconds) deadlineSeconds=$TimeoutSeconds."
                    $timedOut = $true; break
                }
                $null = Get-DiagnosticOwnedMember $child.Owner -RunClock $clock -DeadlineSeconds $TimeoutSeconds
                if ($null -ne $child.Record.exitCode) {
                    continue
                }
                if (-not $child.LaunchConfirmed -and (Test-Path -LiteralPath $child.Owner.Identity)) {
                    $child.LaunchConfirmed = $true; $child.Deadline = [Math]::Min((& $readElapsed) + $DumpTimeoutSeconds, $TimeoutSeconds - $KillReserveSeconds)
                }
                if (Test-Path -LiteralPath $child.Owner.Result) {
                    $child.Record.exitCode = [int][IO.File]::ReadAllText($child.Owner.Result); if (Test-Path -LiteralPath $child.Owner.ErrorPath) {
                        $child.Record.error = [IO.File]::ReadAllText($child.Owner.ErrorPath)
                    }; Stop-DiagnosticOwnedProcess $child.Owner -RunClock $clock -DeadlineSeconds $TimeoutSeconds
                }
                elseif ((& $readElapsed) -ge $child.Deadline) {
                    $child.Record.timedOut = $true; $child.Record.exitCode = 1; try {
                        Stop-DiagnosticOwnedProcess $child.Owner -RunClock $clock -DeadlineSeconds $TimeoutSeconds
                    }
                    catch {
                        $child.Record.error = $_.Exception.Message; $cleanupComplete = $false
                    }
                }
            }
            Start-Sleep -Milliseconds ([int][Math]::Min($PollMilliseconds, [Math]::Max(1, ($TimeoutSeconds - $KillReserveSeconds - (& $readElapsed)) * 1000)))
        }
    }
    catch {
        # Unknown membership remains failure, including when a native scan expires
        # between the caller guard and the proof. Preserve the actual error and
        # original elapsed time instead of throwing away the structured result.
        $cleanupComplete = $false
        $timedOut = $timedOut -or $clock.Elapsed.TotalSeconds -ge $TimeoutSeconds
        $errors += "Diagnostic supervision failed at realSeconds=$($clock.Elapsed.TotalSeconds) logicalSeconds=$($elapsedState.Last) providerFailed=$($elapsedState.Failed) ownerCount=$($owners.Count): $($_.Exception.Message)"
    }
    finally {
        foreach ($child in $dumpChildren) {
            if ($null -eq $child.Record.exitCode) {
                $child.Record.timedOut = $true; $child.Record.exitCode = 1
            }
        }
        foreach ($owned in $owners) {
            try {
                Stop-DiagnosticOwnedProcess $owned -RunClock $clock -DeadlineSeconds $TimeoutSeconds
            }
            catch {
                $cleanupComplete = $false; $errors += "Ownership kill failed: $($_.Exception.Message)"
            }
        }
        # Confirm termination and pipe completion within, not after, the outer deadline.
        do {
            $remaining = 0
            foreach ($owned in $owners) {
                try {
                    $remaining += @(Get-DiagnosticOwnedMember $owned -RunClock $clock -DeadlineSeconds $TimeoutSeconds).Count
                    $anchorExited = $owned.Process.HasExited
                    if ($clock.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                        throw 'Owned completion certification deadline expired.'
                    }
                    if (-not $anchorExited) {
                        $remaining++
                    }
                }
                catch {
                    $remaining++
                    $cleanupComplete = $false
                    if ($errors -notcontains $_.Exception.Message) {
                        $errors += $_.Exception.Message
                    }
                }
            }
            if ($remaining -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 10
        } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds -and $elapsedState.Last -lt $TimeoutSeconds)
        if ($remaining -gt 0) {
            $cleanupComplete = $false; $errors += 'Owned processes remain live or cleanup certification is unknown at deadline.'
        }
        if ($pipes.Count) {
            try {
                $drainComplete = [Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($pipes | ForEach-Object Copy)).Wait([int][Math]::Max(0, ([Math]::Min($TimeoutSeconds - $elapsedState.Last, $TimeoutSeconds - $clock.Elapsed.TotalSeconds)) * 1000))
            }
            catch {
                $drainComplete = $false; $errors += "Pipe copy failed: $($_.Exception.Message)"
            }
        }
        foreach ($pipe in $pipes) {
            try {
                $pipe.Reader.Dispose()
            }
            catch {
                $readersClosed = $false; $errors += "Reader close failed: $($_.Exception.Message)"
            }
        }
        # Reader disposal cancels blocked source reads. Never claim success on a
        # false Wait result, faulted copy or a destination closed while still copying.
        foreach ($pipe in $pipes) {
            if (-not $pipe.Copy.IsCompletedSuccessfully) {
                $drainComplete = $false
            }
            try {
                $pipe.Destination.Dispose()
            }
            catch {
                $drainComplete = $false
                $errors += "Destination close failed: $($_.Exception.Message)"
            }
        }
        # Snapshot only already-observable state; never call readiness/provider
        # code from diagnostics or teardown. Child stderr is retained in LogPath.
        $phaseState = @($owners | ForEach-Object {
                try {
                    [ordered]@{ groupId = $_.GroupId; resultExists = [IO.File]::Exists($_.Result); identityExists = [IO.File]::Exists($_.Identity); errorExists = [IO.File]::Exists($_.ErrorPath); anchorExited = $_.Process.HasExited; stopped = $_.Stopped }
                }
                catch {
                    [ordered]@{ observationError = $_.Exception.Message }
                }
            })
        $finalRealSeconds = $clock.Elapsed.TotalSeconds
        foreach ($owned in $owners) {
            try {
                $owned.Process.Dispose()
            }
            catch {
                $cleanupComplete = $false
                $errors += "Process disposal failed: $($_.Exception.Message)"
            }
            if ($null -ne $owned.Job) {
                try {
                    $owned.Job.Dispose()
                }
                catch {
                    $cleanupComplete = $false
                    $errors += "Job disposal failed: $($_.Exception.Message)"
                }
            }
            foreach ($suffix in @('.json', '.release', '.result', '.result.tmp', '.identity', '.error')) {
                Remove-Item -LiteralPath ($owned.Base + $suffix) -ErrorAction SilentlyContinue
            }
        }
        $clock.Stop()
        if ($null -eq $provider) {
            $elapsedState.Last = $clock.Elapsed.TotalSeconds
        }
        $parts = @(); foreach ($part in @("$LogPath.stdout", "$LogPath.stderr")) {
            if (Test-Path $part) {
                $parts += Get-Content $part -Raw; Remove-Item $part
            }
        }; Set-Content $LogPath ($parts -join [Environment]::NewLine)
        $outputTail = ($parts -join [Environment]::NewLine)
        if ($outputTail.Length -gt 4096) {
            $outputTail = $outputTail.Substring($outputTail.Length - 4096)
        }
        [ordered]@{ realSeconds = $finalRealSeconds; logicalSeconds = $elapsedState.Last; providerFailed = $elapsedState.Failed; phases = @(Get-DiagnosticPhaseEvidence); cgroup = 'not sampled: synchronous filesystem latency is not bounded'; owners = $phaseState; errors = @($errors); outputTail = $outputTail } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $EvidenceRoot 'supervision-state.json')
        if ($timedOut -and $captures.Count -eq 0) {
            $captures += [ordered]@{testHostProcessId = $null; startedSeconds = $null; exitCode = $null; timedOut = $false; error = 'No valid TestHostLaunched target was available before the absolute deadline.'; dumpPath = $null }
        }
        ConvertTo-Json -InputObject @($captures) -Depth 6 | Set-Content (Join-Path $EvidenceRoot 'absolute-captures.json')
    }
    if (-not $cleanupComplete -or -not $drainComplete -or -not $readersClosed -or $journalInvalid) {
        $exitCode = 1
    }
    return [pscustomobject]@{Phases = @(Get-DiagnosticPhaseEvidence); OutputTail = $outputTail; RealElapsedSeconds = $finalRealSeconds; ProviderFailed = $elapsedState.Failed; PhaseState = $phaseState; ExitCode = $exitCode; TimedOut = $timedOut; ElapsedSeconds = $elapsedState.Last; Captures = @($captures); CleanupComplete = $cleanupComplete; DrainComplete = $drainComplete; ReadersClosed = $readersClosed; CleanupErrors = @($errors); OwnedProcesses = @($owners | ForEach-Object { @($_.Observed.Values) }) }
}
