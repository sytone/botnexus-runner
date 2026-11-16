<#
.SYNOPSIS
Provides reusable deadline, process and raw TRX attribution helpers.
.DESCRIPTION
Application discovery, quarantine and acceptance policy are explicit caller responsibilities.
Importing this module starts no processes and writes no files.
.EXAMPLE
Import-Module ./RunnerTimeout.psm1
.OUTPUTS
None. Exports deadline, process and attribution functions.
#>
Set-StrictMode -Version Latest

function Get-RunnerDeadline {
    <#
    .SYNOPSIS
    Derives a positive internal deadline within the caller budget.
    .DESCRIPTION
    Derives a positive internal deadline within the caller budget. Uses explicit caller inputs and preserves existing boundary behavior.
    .PARAMETER BudgetSeconds
    Outer replica budget.
    .PARAMETER ReserveSeconds
    Time reserved for evidence finalization.
    .PARAMETER FloorSeconds
    Minimum internal deadline.
    .EXAMPLE
    Get-RunnerDeadline -BudgetSeconds $BudgetSeconds -ReserveSeconds $ReserveSeconds -FloorSeconds $FloorSeconds
    .OUTPUTS
    System.Int32. Internal deadline seconds.
    #>
    [OutputType([int])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int] $BudgetSeconds,
        [int] $ReserveSeconds = 90,
        [int] $FloorSeconds = 30
    )

    $deadline = $BudgetSeconds - $ReserveSeconds
    if ($deadline -lt $FloorSeconds) {
        return $FloorSeconds
    }
    return $deadline
}

function Get-CompletedTestAssembly {
    <#
    .SYNOPSIS
    Reads assembly attribution from complete or partial TRX text.
    .DESCRIPTION
    Reads assembly attribution from complete or partial TRX text. Uses explicit caller inputs and preserves existing boundary behavior.
    .PARAMETER TrxPaths
    Explicit result file paths.
    .EXAMPLE
    Get-CompletedTestAssembly -TrxPaths $TrxPaths
    .OUTPUTS
    System.String. Distinct observed assemblies and project names.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $TrxPaths
    )

    $assemblies = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $TrxPaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $text = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrEmpty($text)) {
            continue
        }
        foreach ($match in [regex]::Matches($text, '(?:storage|codeBase)="([^"]+)"')) {
            $value = $match.Groups[1].Value.Replace('\', '/')
            $leaf = [System.IO.Path]::GetFileNameWithoutExtension($value)
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                [void]$assemblies.Add($leaf)
            }

            # The project directory: the segment immediately before /bin/. Independent of
            # AssemblyName, so an assembly rename cannot make a project look unfinished.
            $binIndex = $value.LastIndexOf('/bin/', [StringComparison]::OrdinalIgnoreCase)
            if ($binIndex -gt 0) {
                $projectDir = $value.Substring(0, $binIndex).Split('/')[-1]
                if (-not [string]::IsNullOrWhiteSpace($projectDir)) {
                    [void]$assemblies.Add($projectDir)
                }
            }
        }
    }

    return @($assemblies | Sort-Object)
}



function Get-UnfinishedTestProject {
    <#
    .SYNOPSIS
    Computes expected project names lacking observed results.
    .DESCRIPTION
    Computes expected project names lacking observed results. Uses explicit caller inputs and preserves existing boundary behavior.
    .PARAMETER ExpectedProjects
    Caller-selected expected project names.
    .PARAMETER CompletedAssemblies
    Observed assembly or project names.
    .PARAMETER ExcludedProjects
    Explicit excluded name fragments.
    .EXAMPLE
    Get-UnfinishedTestProject -ExpectedProjects $ExpectedProjects -CompletedAssemblies $CompletedAssemblies -ExcludedProjects $ExcludedProjects
    .OUTPUTS
    System.String. Outstanding expected project names.
    #>
    [OutputType([object[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ExpectedProjects,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $CompletedAssemblies,
        [AllowEmptyCollection()][string[]] $ExcludedProjects = @()
    )

    $completed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $CompletedAssemblies) {
        if ($item) {
            [void]$completed.Add($item)
        }
    }

    return @($ExpectedProjects |
            Where-Object { $_ } |
            Where-Object { -not $completed.Contains($_) } |
            Where-Object {
                $candidate = $_
                -not ($ExcludedProjects | Where-Object { $_ -and $candidate -like "*$_*" })
            } |
            Sort-Object -Unique)
}

function Invoke-BoundedProcess {
    <#
    .SYNOPSIS
    Runs an owned native child under a hard elapsed deadline.
    .DESCRIPTION
    Runs an owned native child under a hard elapsed deadline. Uses explicit caller inputs and preserves existing boundary behavior.
    .PARAMETER FilePath
    Executable path.
    .PARAMETER ArgumentList
    Separate native arguments.
    .PARAMETER LogPath
    Owned combined output destination.
    .PARAMETER TimeoutSeconds
    Maximum child lifetime.
    .PARAMETER PollMilliseconds
    Deadline observation interval.
    .EXAMPLE
    Invoke-BoundedProcess -FilePath $FilePath -ArgumentList $ArgumentList -LogPath $LogPath -TimeoutSeconds $TimeoutSeconds -PollMilliseconds $PollMilliseconds
    .OUTPUTS
    System.Management.Automation.PSCustomObject. ExitCode, TimedOut and ElapsedSeconds.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $LogPath,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [int] $PollMilliseconds = 1000
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $stdout = "$LogPath.stdout"
    $stderr = "$LogPath.stderr"
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $ArgumentList) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stdoutStream = $null
    $stderrStream = $null
    try {
        if (-not $process.Start()) {
            throw "Could not start $FilePath."
        }
        $stdoutStream = [System.IO.File]::Create($stdout)
        $stderrStream = [System.IO.File]::Create($stderr)
        # Drain both pipes while the child runs: synchronous reads can deadlock a verbose test host.
        $stdoutCopy = $process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrCopy = $process.StandardError.BaseStream.CopyToAsync($stderrStream)

        $timedOut = $false
        while (-not $process.HasExited) {
            if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $timedOut = $true
                try {
                    $process.Kill($true)
                }
                catch {
                    Write-Verbose ('Deadline cleanup failed: ' + $_.Exception.Message)
                }
                try {
                    $process.WaitForExit(30000) | Out-Null
                }
                catch {
                    Write-Verbose ('Deadline cleanup failed: ' + $_.Exception.Message)
                }
                break
            }
            Start-Sleep -Milliseconds $PollMilliseconds
        }
        $drain = [System.Threading.Tasks.Task]::WhenAll($stdoutCopy, $stderrCopy)
        if ($timedOut) {
            # A surviving descendant may retain an inherited pipe; do not undo the deadline
            # by waiting forever for its EOF after the process tree has been killed.
            try {
                [void]$drain.Wait(30000)
            }
            catch {
                Write-Verbose ('Output drain failed: ' + $_.Exception.Message)
            }
        }
        else {
            [void]$drain.GetAwaiter().GetResult()
        }
        $exitCode = if ($timedOut) {
            1
        }
        else {
            $process.ExitCode
        }
    }
    finally {
        if ($null -ne $stdoutStream) {
            $stdoutStream.Dispose()
        }
        if ($null -ne $stderrStream) {
            $stderrStream.Dispose()
        }
        $process.Dispose()
        $stopwatch.Stop()
    }

    # Merge the drained streams into the log the rest of the runner expects. Done after the
    # fact so a timeout still leaves two readable sections rather than a half-written interleave.
    $merged = @()
    foreach ($part in @($stdout, $stderr)) {
        if (Test-Path -LiteralPath $part) {
            $merged += (Get-Content -LiteralPath $part -Raw -ErrorAction SilentlyContinue)
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        }
    }
    Set-Content -Path $LogPath -Value ($merged -join [Environment]::NewLine) -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        ExitCode = $exitCode
        TimedOut = $timedOut
        ElapsedSeconds = $stopwatch.Elapsed.TotalSeconds
    }
}

function Get-RunnerTimeoutRecord {
    <#
    .SYNOPSIS
    Creates a truthful timeout record with explicit attribution.
    .DESCRIPTION
    Creates a truthful timeout record with explicit attribution. Uses explicit caller inputs and preserves existing boundary behavior.
    .PARAMETER Phase
    Phase that exhausted the deadline.
    .PARAMETER ElapsedSeconds
    Observed elapsed time.
    .PARAMETER DeadlineSeconds
    Original execution deadline.
    .PARAMETER UnfinishedProjects
    Expected projects without terminal evidence.
    .PARAMETER CompletedAssemblies
    Assemblies observed in available results.
    .EXAMPLE
    Get-RunnerTimeoutRecord -Phase $Phase -ElapsedSeconds $ElapsedSeconds -DeadlineSeconds $DeadlineSeconds -UnfinishedProjects $UnfinishedProjects -CompletedAssemblies $CompletedAssemblies
    .OUTPUTS
    System.Collections.Specialized.OrderedDictionary. Timeout evidence.
    #>
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][double] $ElapsedSeconds,
        [Parameter(Mandatory)][int] $DeadlineSeconds,
        [AllowEmptyCollection()][string[]] $UnfinishedProjects = @(),
        [AllowEmptyCollection()][string[]] $CompletedAssemblies = @()
    )

    $unfinished = @($UnfinishedProjects)
    $attribution = if ($unfinished.Count -eq 0) {
        # Honest about not knowing. Every project having reported while the phase still
        # overran is a real, different finding (the overrun is after the tests, e.g. in
        # result aggregation), and inventing a culprit to fill the field would hide it.
        'No test project was outstanding when the deadline expired; the overrun is outside test execution.'
    }
    else {
        "Outstanding when the deadline expired: $($unfinished -join ', ')."
    }

    return [ordered]@{
        timedOut = $true
        phase = $Phase
        elapsedSeconds = [Math]::Round($ElapsedSeconds, 2)
        deadlineSeconds = $DeadlineSeconds
        unfinishedProjects = $unfinished
        completedAssemblies = @($CompletedAssemblies)
        attribution = $attribution
    }
}
