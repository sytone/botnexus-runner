Set-StrictMode -Version Latest
function Get-RunnerRunEvidence {
    <#
    .SYNOPSIS
    Downloads and validates exact generic execution evidence without accepting tests.
    .DESCRIPTION
    Uses one caller-owned provider read and original operation allowance per file.
    Reads only the explicit credential-free destination and declared generic artifacts.
    Rejects unknown identities, incomplete cleanup, invalid sizes and changed bytes.
    Failed or cancelled terminal executions retain truthful nonzero generic results.
    .PARAMETER Destination
    Explicit credential-free artifact destination bound to the recorded execution.
    .PARAMETER Root
    Existing caller-owned private scratch directory, removed by the caller.
    .PARAMETER Record
    Private immutable source, run, project configuration and image identities.
    .PARAMETER Project
    Validated generic project, including artifact limits and declarations.
    .PARAMETER ProjectPath
    Exact candidate-relative project configuration path.
    .PARAMETER TerminalStatus
    Observed terminal provider status, never an application acceptance decision.
    .PARAMETER ProviderRead
    Caller callback for bounded credential-safe native download on its original clock.
    .EXAMPLE
    Get-RunnerRunEvidence -Destination $destination -Root $scratch -Record $record -Project $project -ProjectPath 'ci/project.json' -TerminalStatus Succeeded -ProviderRead $reader
    .OUTPUTS
    System.String. SHA256 of verified downloaded result bytes. Throws on incomplete proof.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Destination,
        [string]$Root,
        $Record,
        $Project,
        [string]$ProjectPath,
        [ValidateSet('Succeeded', 'Failed', 'Cancelled')][string]$TerminalStatus,
        [scriptblock]$ProviderRead
    )
    $resultPath = Join-Path $Root 'result.json'
    & $ProviderRead -Argument @('storage', 'blob', 'download', '--blob-url', ($Destination.TrimEnd('/') + '/result.json'), '--file', $resultPath, '--auth-mode', 'login', '--only-show-errors', '--output', 'json') | Out-Null
    $file = Get-Item -LiteralPath $resultPath -Force -ErrorAction Stop
    if ($file.Length -gt 1048576 -or $file.Length -eq 0 -or $file.LinkType) {
        throw 'Invalid downloaded result file.'
    }
    $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($resultPath))
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
                        throw 'Duplicate result JSON key.'
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
            throw 'Invalid result object.'
        }
    }
    finally {
        $document.Dispose()
    }
    $result = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    if ($result.runId -cne $Record.runId -or $null -ne $result.tests -or $result.accepted -isnot [bool] -or $result.accepted -or $result.runnerProtocol -ne 1 -or $result.runnerImage -cne $Record.image -or $result.sourceSnapshot.verified -isnot [bool] -or -not $result.sourceSnapshot.verified -or $result.sourceSnapshot.digest -cne $Record.sourceDigest -or $result.sourceSnapshot.runId -cne $Record.runId) {
        throw 'Result immutable identity mismatch.'
    }
    if ($result.pipelineExecution.cleanupComplete -isnot [bool] -or -not $result.pipelineExecution.cleanupComplete -or $result.pipelineExecution.status -cnotin @('succeeded', 'failed', 'cancelled', 'timedOut') -or ($TerminalStatus -ceq 'Succeeded' -and $result.pipelineExecution.status -cne 'succeeded')) {
        throw 'Outer pipeline cleanup or terminal state is incomplete.'
    }
    $expectedSteps = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($step in $Project.steps) {
        [void]$expectedSteps.Add($step.id)
    }
    $observedSteps = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($step in $result.projectExecution.steps) {
        if (-not $expectedSteps.Contains($step.id) -or -not $observedSteps.Add($step.id) -or $step.status -cnotin @('succeeded', 'failed', 'cancelled', 'timedOut', 'notStarted')) {
            throw 'Invalid project step identity or state.'
        }
    }
    if (-not $observedSteps.SetEquals($expectedSteps)) {
        throw 'Incomplete project step evidence.'
    }
    $identity = [pscustomobject]@{ version = 1; path = $ProjectPath; sha256 = $Record.projectConfigSha256 }
    Import-Module (Join-Path $PSScriptRoot '../../infra/buildtest/runner/RunnerEvidence.psm1') -Force -WarningAction SilentlyContinue
    if ($TerminalStatus -ceq 'Succeeded') {
        Assert-RunnerProjectEvidence -Result $result -Identity $identity -Image $Record.image
        if ($result.exitCode -ne 0) {
            throw 'Provider success conflicts with result failure.'
        }
    }
    else {
        if ($result.exitCode -isnot [long] -and $result.exitCode -isnot [int]) {
            throw 'Missing failure exit code.'
        }
        if ($result.exitCode -eq 0 -or $result.projectExecution.status -cnotin @('failed', 'cancelled', 'timedOut') -or $result.projectExecution.cleanupComplete -isnot [bool] -or -not $result.projectExecution.cleanupComplete -or $result.projectExecution.accepted -isnot [bool] -or $result.projectExecution.accepted -or $result.projectExecution.protocolVersion -ne 1 -or $result.projectExecution.configSha256 -cne $identity.sha256 -or $result.projectConfiguration.version -ne 1 -or $result.projectConfiguration.path -cne $identity.path -or $result.projectConfiguration.sha256 -cne $identity.sha256) {
            throw 'Incomplete or inconsistent terminal failure evidence.'
        }
    }
    $expected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($step in $Project.steps) {
        foreach ($path in $step.artifacts) {
            [void]$expected.Add($path)
        }
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = 0L
    foreach ($artifact in $result.projectExecution.artifacts) {
        $path = $artifact.path
        if ($path -isnot [string] -or -not $expected.Contains($path) -or -not $seen.Add($path) -or $path.Contains('\') -or $path.Contains(':') -or $path.StartsWith('/') -or @($path.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0 -or $artifact.sha256 -cnotmatch '^[a-f0-9]{64}$' -or ($artifact.bytes -isnot [long] -and $artifact.bytes -isnot [int]) -or $artifact.bytes -lt 0) {
            throw 'Invalid artifact declaration.'
        }
        $total += $artifact.bytes
        if ($seen.Count -gt $Project.limits.maxArtifacts -or $total -gt $Project.limits.maxArtifactBytes) {
            throw 'Artifact limits exceeded.'
        }
        $local = Join-Path $Root ('project/' + $path)
        $parent = [IO.Path]::GetDirectoryName($local)
        [void][IO.Directory]::CreateDirectory($parent)
        $relative = ($path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        & $ProviderRead -Argument @('storage', 'blob', 'download', '--blob-url', ($Destination.TrimEnd('/') + '/project/' + $relative), '--file', $local, '--auth-mode', 'login', '--only-show-errors', '--output', 'json') | Out-Null
        $downloaded = Get-Item -LiteralPath $local -Force -ErrorAction Stop
        if ($downloaded.LinkType -or $downloaded.Length -ne $artifact.bytes -or (Get-FileHash -LiteralPath $local).Hash.ToLowerInvariant() -cne $artifact.sha256) {
            throw 'Downloaded artifact is missing, truncated or changed.'
        }
    }
    if (-not $seen.SetEquals($expected)) {
        throw 'Declared project artifacts are incomplete.'
    }
    (Get-FileHash -LiteralPath $resultPath).Hash.ToLowerInvariant()
}
function Get-RunnerEvidenceInventory {
    <#
    .SYNOPSIS
    Hashes regular retained evidence without following links.
    .DESCRIPTION
    Walks an owned bounded evidence tree and rejects links, case collisions and
    unexpected non-file entries. Directory entries are included for exact reuse.
    .PARAMETER Root
    Existing local evidence directory with stable ancestors checked by the caller.
    .EXAMPLE
    Get-RunnerEvidenceInventory -Root /private/run.evidence
    .OUTPUTS
    System.Collections.Generic.Dictionary. Relative paths mapped to directory or file hashes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root)
    $inventory = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $portable = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        $item = Get-Item -LiteralPath $directory -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Evidence must contain only regular directories and files.'
        }
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            $relative = [IO.Path]::GetRelativePath($Root, $entry.FullName).Replace('\', '/')
            if (-not $portable.Add($relative) -or ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Linked or case-colliding evidence is not supported.'
            }
            if ($entry.PSIsContainer) {
                $inventory.Add($relative, 'directory')
                $pending.Push($entry.FullName)
            }
            else {
                $inventory.Add($relative, (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash)
            }
        }
    }
    Write-Output -InputObject $inventory -NoEnumerate
}

function Save-RunnerRunEvidence {
    <#
    .SYNOPSIS
    Retains verified evidence at a stable run-specific private path.
    .DESCRIPTION
    Moves the complete verified staging directory on the same filesystem without
    replacement. Existing evidence is reused only when every path and byte hash
    matches. A conflict is never overwritten or removed. Callers hold the target
    reservation and check stable local ancestors; this is not an OS sandbox.
    .PARAMETER Root
    Verified staging directory, deleted by caller cleanup if not moved.
    .PARAMETER Destination
    Stable private directory derived from the recorded run identity.
    .EXAMPLE
    Save-RunnerRunEvidence -Root /private/staging -Destination /private/run.evidence
    .OUTPUTS
    System.String. Retained evidence directory. Never application acceptance.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Destination)
    $expected = Get-RunnerEvidenceInventory -Root $Root
    if (Test-Path -LiteralPath $Destination) {
        $observed = Get-RunnerEvidenceInventory -Root $Destination
        if ($observed.Count -ne $expected.Count) {
            throw 'Retained evidence conflicts with verified downloads.'
        }
        foreach ($path in $expected.Keys) {
            if (-not $observed.ContainsKey($path) -or $observed[$path] -cne $expected[$path]) {
                throw 'Retained evidence conflicts with verified downloads.'
            }
        }
    }
    elseif ($PSCmdlet.ShouldProcess('verified private run evidence', 'Retain without replacing existing files')) {
        [IO.Directory]::Move($Root, $Destination)
    }
    return $Destination
}
Export-ModuleMember -Function Get-RunnerRunEvidence, Save-RunnerRunEvidence
