<#
.SYNOPSIS
Exercises the complete image supervisor against synthetic setup/transfer pipelines.
.DESCRIPTION
Runs the real image entrypoint with inert native pipeline stubs. A hung extraction/git-like
operation must be killed inside the original budget and leave partial artifact/result evidence.
.PARAMETER ScratchRoot
Owned isolated output directory.
.EXAMPLE
./Test-RunnerPipelineBoundary.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Actual case results and JSON counts.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
$cases = [Collections.Generic.List[object]]::new()
foreach ($scenario in @('setup-hang', 'transfer-failure', 'complete', 'upload-hang', 'malformed-result', 'framework-exception')) {
    try {
        $fixture = Join-Path $ScratchRoot $scenario
        New-Item -ItemType Directory -Path $fixture -Force | Out-Null
        $stub = Join-Path $fixture 'Invoke-NativePipeline.ps1'
        $behavior = if ($scenario -eq 'setup-hang') {
            'Start-Sleep -Seconds 30'
        }
        elseif ($scenario -eq 'transfer-failure') {
            'exit 9'
        }
        elseif ($scenario -eq 'malformed-result') {
            "[IO.File]::WriteAllText((Join-Path `$root 'artifacts/result.json'), '{malformed'); exit 0"
        }
        else {
            'exit 0'
        }
        @"
<#
.SYNOPSIS
Runs an inert pipeline fixture.
.DESCRIPTION
Writes partial evidence and a native identity, then performs the selected fixture behavior.
.EXAMPLE
./Invoke-NativePipeline.ps1
.OUTPUTS
None.
#>
[CmdletBinding()]
param()
`$ErrorActionPreference = 'Stop'
`$root = `$env:RUNNER_WORK_ROOT
[IO.File]::WriteAllText((Join-Path `$root 'artifacts/partial.txt'), 'partial download/extraction evidence')
[IO.File]::WriteAllText((Join-Path `$root 'native.json'), (@{ processId = `$PID; startUtc = (Get-Process -Id `$PID).StartTime.ToUniversalTime().ToString('o') } | ConvertTo-Json))
$behavior
"@ | Set-Content -LiteralPath $stub
        $work = Join-Path $fixture 'run'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $supervisor = Join-Path $PSScriptRoot '../Invoke-Runner.ps1'
        if ($scenario -eq 'framework-exception') {
            $framework = Join-Path $fixture 'framework'
            New-Item -ItemType Directory -Path $framework | Out-Null
            Copy-Item -Path (Join-Path $PSScriptRoot '../*') -Destination $framework -Recurse
            $supervisor = Join-Path $framework 'Invoke-Runner.ps1'
            $source = Get-Content -LiteralPath $supervisor -Raw
            $anchor = '$exitCode = if ($execution.status'
            if ($source.Split($anchor).Count -ne 2) {
                throw 'Expected exactly one framework fault anchor.'
            }
            $source = $source.Replace($anchor, "throw 'fixture-framework-finalization-error'" + [Environment]::NewLine + $anchor)
            Set-Content -LiteralPath $supervisor -Value $source
        }
        $transfer = Join-Path $fixture 'Invoke-NativeTransfer.ps1'
        @'
<#
.SYNOPSIS
Copies inert fixture evidence without network access.
.DESCRIPTION
Records each actual transfer invocation and its native process identity, then copies files.
.PARAMETER Source
Fixture-owned source wildcard.
.PARAMETER Destination
Fixture-owned destination directory; synthetic-no-network selects the hang control.
.PARAMETER EvidenceRoot
Reserved transport evidence directory, unused by this inert child.
.PARAMETER TimeoutSeconds
Original remaining allowance, retained in the invocation record.
.PARAMETER Recursive
Matches the production transport interface.
.EXAMPLE
./Invoke-NativeTransfer.ps1 -Source /work/artifacts/* -Destination /work/saved -EvidenceRoot /work/upload -TimeoutSeconds 6 -Recursive
.OUTPUTS
None.
#>
[CmdletBinding()]
param($Source, $Destination, $EvidenceRoot, $TimeoutSeconds, [switch]$Recursive)
$ErrorActionPreference = 'Stop'
$record = @{ processId = $PID; startUtc = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); timeoutSeconds = $TimeoutSeconds; evidenceRoot = $EvidenceRoot; recursive = [bool]$Recursive }
$record | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $env:RUNNER_WORK_ROOT 'transfer-attempts.jsonl')
$record | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:RUNNER_WORK_ROOT 'upload-native.json')
if ($Destination -eq 'synthetic-no-network') {
    Start-Sleep -Seconds 30
}
else {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Copy-Item -Path $Source -Destination $Destination -Recurse:$Recursive
}
'@ | Set-Content -LiteralPath $transfer
        $previousUrl = [Environment]::GetEnvironmentVariable('ARTIFACT_BLOB_URL')
        $previousWork = [Environment]::GetEnvironmentVariable('RUNNER_WORK_ROOT')
        $previousDeadline = [Environment]::GetEnvironmentVariable('RUNNER_EXECUTION_DEADLINE_UTC')
        $previousRegistry = [Environment]::GetEnvironmentVariable('RUNNER_OWNERSHIP_ROOT')
        $destination = Join-Path $fixture 'transferred'
        try {
            $url = if ($scenario -eq 'upload-hang') {
                'synthetic-no-network'
            }
            else {
                $destination
            }
            [Environment]::SetEnvironmentVariable('ARTIFACT_BLOB_URL', $url)
            if ($scenario -in @('setup-hang', 'transfer-failure')) {
                & (Get-Process -Id $PID).Path -NoProfile -File $supervisor -WorkRoot $work -PipelineScript $stub -BudgetSeconds 12 -ReserveSeconds 4 -SkipUpload
            }
            else {
                & (Get-Process -Id $PID).Path -NoProfile -File $supervisor -WorkRoot $work -PipelineScript $stub -BudgetSeconds 12 -ReserveSeconds 4 -TransportScript $transfer
            }
            $code = $LASTEXITCODE
            if ([Environment]::GetEnvironmentVariable('RUNNER_WORK_ROOT') -cne $previousWork -or
                [Environment]::GetEnvironmentVariable('RUNNER_EXECUTION_DEADLINE_UTC') -cne $previousDeadline -or
                [Environment]::GetEnvironmentVariable('RUNNER_OWNERSHIP_ROOT') -cne $previousRegistry) {
                throw 'Supervisor did not restore parent environment.'
            }
        }
        finally {
            [Environment]::SetEnvironmentVariable('ARTIFACT_BLOB_URL', $previousUrl)
        }
        $expected = if ($scenario -eq 'complete') {
            0
        }
        else {
            1
        }
        if ($code -ne $expected) {
            throw "Wrong supervisor exit code $code for $scenario."
        }
        $execution = Get-Content (Join-Path $work 'artifacts/pipeline-execution.json') -Raw | ConvertFrom-Json
        $result = Get-Content (Join-Path $work 'artifacts/result.json') -Raw | ConvertFrom-Json
        if (-not $execution.cleanupComplete -or $clock.Elapsed.TotalSeconds -ge 12) {
            throw 'Whole setup process exceeded original platform budget or lacked cleanup proof.'
        }
        if (-not (Test-Path (Join-Path $work 'artifacts/partial.txt')) -or $null -ne $result.tests) {
            throw 'Partial finalization lost evidence or fabricated test success.'
        }
        if ($scenario -eq 'setup-hang' -and (-not $result.timeout.timedOut -or $execution.status -ne 'timedOut')) {
            throw 'Setup timeout was not represented in final artifacts.'
        }
        if ($scenario -in @('complete', 'malformed-result', 'framework-exception')) {
            $attempts = @(Get-Content -LiteralPath (Join-Path $work 'transfer-attempts.jsonl'))
            if ($attempts.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $destination 'partial.txt'))) {
                throw 'Expected exactly one actual successful transfer retaining partial evidence.'
            }
            $saved = Get-Content -LiteralPath (Join-Path $destination 'result.json') -Raw | ConvertFrom-Json
            if ($null -ne $saved.tests) {
                throw 'Transferred result fabricated test success.'
            }
            if ($scenario -ne 'complete') {
                if ($saved.exitCode -ne 1 -or -not $saved.outerFailure.error) {
                    throw 'Original outer error or failure status was lost.'
                }
                if ($scenario -eq 'framework-exception' -and $saved.outerFailure.error -notmatch 'fixture-framework-finalization-error') {
                    throw 'Deterministic framework error was replaced.'
                }
                if ($scenario -eq 'malformed-result' -and $saved.outerFailure.error -notmatch 'JSON|ConvertFrom-Json') {
                    throw 'Malformed JSON error was replaced.'
                }
            }
            $upload = Get-Content (Join-Path $work 'artifacts/upload-execution.json') -Raw | ConvertFrom-Json
            if ($upload.status -ne 'succeeded' -or -not $upload.cleanupComplete) {
                throw 'Successful inert transfer lacks cleanup proof.'
            }
        }
        if ($scenario -eq 'upload-hang') {
            $upload = Get-Content (Join-Path $work 'artifacts/upload-execution.json') -Raw | ConvertFrom-Json
            if ($upload.status -ne 'timedOut' -or -not $upload.cleanupComplete) {
                throw 'Final upload was not bounded on the original clock.'
            }
        }
        $identityPath = if ($scenario -eq 'upload-hang') {
            'upload-native.json'
        }
        else {
            'native.json'
        }
        $identities = @('native.json')
        if (Test-Path -LiteralPath (Join-Path $work 'upload-native.json')) {
            $identities += 'upload-native.json'
        }
        foreach ($identityPath in $identities) {
            $identity = Get-Content (Join-Path $work $identityPath) -Raw | ConvertFrom-Json
            $child = Get-Process -Id $identity.processId -ErrorAction SilentlyContinue
            try {
                if ($null -ne $child -and $child.StartTime.ToUniversalTime().ToString('o') -ceq $identity.startUtc) {
                    throw 'Native setup/transfer child survived finalization.'
                }
            }
            finally {
                if ($null -ne $child) {
                    $child.Dispose()
                }
            }
        }
        $cases.Add(@{ name = $scenario; passed = $true; elapsedSeconds = $clock.Elapsed.TotalSeconds })
        Write-Output "PASS $scenario"
    }
    catch {
        $cases.Add(@{ name = $scenario; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${scenario}: $($_.Exception.Message)"
    }
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; total = $cases.Count; cases = $cases.ToArray() } | ConvertTo-Json -Depth 8 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
