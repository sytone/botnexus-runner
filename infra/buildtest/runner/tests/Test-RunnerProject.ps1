<#
.SYNOPSIS
Tests project configuration and bounded execution using synthetic commands only.
.DESCRIPTION
Runs parser rejection and real owned-process fixtures in an explicitly supplied scratch root.
No product test host, gateway, remote job or credential is used. Exits one on any failed case.
.PARAMETER ScratchRoot
Owned directory for retained fixture logs and results. Must be outside the live product home.
.EXAMPLE
./Test-RunnerProject.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Per-case results and a final JSON count packet.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
$script:passed = 0
$script:failed = 0
$script:cases = [Collections.Generic.List[object]]::new()
$pwsh = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null

function Assert-ProjectCondition {
    <#
    .SYNOPSIS
    Fails a fixture assertion.
    .DESCRIPTION
    Throws with the actual boundary being checked when the condition is false.
    .PARAMETER Condition
    Actual boolean result.
    .PARAMETER Message
    Assertion description.
    .EXAMPLE
    Assert-ProjectCondition ($result.status -eq 'succeeded') 'Command must complete.'
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}
function Invoke-ProjectCase {
    <#
    .SYNOPSIS
    Records one independently executed fixture.
    .DESCRIPTION
    Captures failures without preventing other cases from running and retains actual counts.
    .PARAMETER Name
    Stable case identity.
    .PARAMETER Body
    Assertions to execute.
    .EXAMPLE
    Invoke-ProjectCase 'valid' { Assert-ProjectCondition $true 'Valid.' }
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:passed++
        $script:cases.Add(@{ name = $Name
                passed = $true
            })
        Write-Output "PASS $Name"
    }
    catch {
        $script:failed++
        $script:cases.Add(@{ name = $Name
                passed = $false
                error = $_.Exception.Message
            })
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
}
function Read-FixtureProject {
    <#
    .SYNOPSIS
    Writes and loads one candidate-bound configuration fixture.
    .DESCRIPTION
    Hashes the exact written bytes, then invokes the production parser with that hash.
    .PARAMETER Text
    Serialized configuration bytes expressed as UTF-8 text.
    .PARAMETER Root
    Fixture payload directory.
    .EXAMPLE
    Read-FixtureProject -Text $json -Root $fixture
    .OUTPUTS
    System.Collections.IDictionary. Validated configuration.
    #>
    [CmdletBinding()]
    param([string]$Text, [string]$Root)
    $path = Join-Path $Root 'project.json'
    [IO.File]::WriteAllText($path, $Text)
    Read-RunnerProject -Path $path -PayloadRoot $Root -ExpectedSha256 (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

$base = @{
    schemaVersion = 1
    protocolVersion = 1
    requiredCapabilities = @('process-v1')
    limits = @{ budgetSeconds = 12
        reserveSeconds = 4
        maxConcurrency = 2
        maxLogBytes = 65536
        maxArtifactBytes = 65536
        maxArtifacts = 8
    }
    steps = @(@{ id = 'build'
            executable = $pwsh
            arguments = @('-NoProfile', '-Command', 'Write-Output "argument with spaces"')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @()
        })
}
$baseText = $base | ConvertTo-Json -Depth 12
Invoke-ProjectCase 'valid-config' {
    $config = Read-FixtureProject $baseText $ScratchRoot
    Assert-ProjectCondition ($config.steps.Count -eq 1) 'Valid configuration must preserve its step.'
}
$invalidCases = [ordered]@{
    'unknown-field' = { param($c) $c.untrustedSuccess = $true }
    'unknown-step-field' = { param($c) $c.steps[0].shell = 'anything' }
    'unsupported-version' = { param($c) $c.schemaVersion = 2 }
    'unsupported-protocol' = { param($c) $c.protocolVersion = 2 }
    'unsupported-capability' = { param($c) $c.requiredCapabilities = @('secret-access') }
    'missing-executable' = { param($c) $c.steps[0].Remove('executable') }
    'string-arguments' = { param($c) $c.steps[0].arguments = 'one shell string' }
    'empty-steps' = { param($c) $c.steps = @() }
    'duplicate-step' = { param($c) $c.steps += $c.steps[0] }
    'missing-dependency' = { param($c) $c.steps[0].dependsOn = @('absent') }
    'cyclic-dependency' = { param($c) $c.steps[0].dependsOn = @('build') }
    'escaping-working-path' = { param($c) $c.steps[0].workingDirectory = '../escape' }
    'absolute-working-path' = { param($c) $c.steps[0].workingDirectory = '/outside' }
    'escaping-artifact' = { param($c) $c.steps[0].artifacts = @('../secret') }
    'windows-absolute-artifact' = { param($c) $c.steps[0].artifacts = @('C:\\outside') }
    'zero-concurrency' = { param($c) $c.limits.maxConcurrency = 0 }
    'excessive-concurrency' = { param($c) $c.limits.maxConcurrency = 9 }
    'invalid-reserve' = { param($c) $c.limits.reserveSeconds = 12 }
    'excessive-budget' = { param($c) $c.limits.budgetSeconds = 3601 }
    'excessive-log-limit' = { param($c) $c.limits.maxLogBytes = 16777217 }
    'excessive-step-count' = { param($c) $c.steps = @(1..65 | ForEach-Object { @{ id = "step$_"
                    executable = 'echo'
                    arguments = @()
                    workingDirectory = '.'
                    dependsOn = @()
                    artifacts = @()
                } }) }
}
foreach ($entry in $invalidCases.GetEnumerator()) {
    Invoke-ProjectCase $entry.Key {
        $candidate = $baseText | ConvertFrom-Json -AsHashtable
        & $entry.Value $candidate
        $rejected = $false
        try {
            $null = Read-FixtureProject ($candidate | ConvertTo-Json -Depth 12) $ScratchRoot
        }
        catch {
            $rejected = $true
        }
        Assert-ProjectCondition $rejected "Invalid input was accepted: $($entry.Key)"
    }
}
foreach ($text in @('{', ($baseText -replace '"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1'), ($baseText -replace '"id": "build"', '"id": "build", "id": "build"'))) {
    Invoke-ProjectCase ('malformed-or-duplicate-' + $script:cases.Count) {
        $rejected = $false
        try {
            $null = Read-FixtureProject $text $ScratchRoot
        }
        catch {
            $rejected = $true
        }
        Assert-ProjectCondition $rejected 'Malformed or duplicate JSON must be rejected.'
    }
}
Invoke-ProjectCase 'config-hash-mismatch' {
    $path = Join-Path $ScratchRoot 'project.json'
    [IO.File]::WriteAllText($path, $baseText)
    $rejected = $false
    try {
        $null = Read-RunnerProject -Path $path -PayloadRoot $ScratchRoot -ExpectedSha256 ('0' * 64)
    }
    catch {
        $rejected = $true
    }
    Assert-ProjectCondition $rejected 'Changed config bytes must not match another candidate hash.'
}
Invoke-ProjectCase 'oversized-config' {
    $rejected = $false
    try {
        $null = Read-FixtureProject (' ' * 262145) $ScratchRoot
    }
    catch {
        $rejected = $true
    }
    Assert-ProjectCondition $rejected 'Oversized config must be rejected before JSON parsing.'
}
foreach ($layout in @('flat', 'nested')) {
    Invoke-ProjectCase "two-layout-$layout" {
        $root = Join-Path $ScratchRoot $layout
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $relative = if ($layout -eq 'flat') {
            '.'
        }
        else {
            'source/component'
        }
        New-Item -ItemType Directory -Path (Join-Path $root $relative) -Force | Out-Null
        $candidate = Get-Content -LiteralPath (Join-Path -Path $PSScriptRoot -ChildPath "fixtures/$layout/project.json") -Raw | ConvertFrom-Json -AsHashtable
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Invoke-FixtureCommand.ps1') -Destination (Join-Path -Path $root -ChildPath $relative -AdditionalChildPath 'Invoke-FixtureCommand.ps1')
        $artifact = if ($relative -eq '.') {
            'result.txt'
        }
        else {
            "$relative/result.txt"
        }
        $candidate.steps[0].artifacts = @($artifact)
        $config = Read-FixtureProject ($candidate | ConvertTo-Json -Depth 12) $root
        $result = Invoke-RunnerProject -Project $config -PayloadRoot $root -EvidenceRoot (Join-Path $root 'evidence')
        Assert-ProjectCondition ($result.status -eq 'succeeded') "Layout did not succeed: $($result | ConvertTo-Json -Depth 8 -Compress)"
        Assert-ProjectCondition ($result.cleanupComplete -and $result.artifacts.Count -eq 1) 'Cleanup and declared artifact must be present.'
        Assert-ProjectCondition (-not $result.accepted) 'Command success is not independent test acceptance.'
        Assert-ProjectCondition ((Get-Content (Join-Path $root $artifact) -Raw) -ceq 'literal ; $value with spaces') 'Arguments were interpolated or working directory lost.'
    }
}
foreach ($scenario in @('failure', 'cancellation', 'deadline', 'log-limit')) {
    Invoke-ProjectCase "runtime-$scenario" {
        $root = Join-Path $ScratchRoot $scenario
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $candidate = $baseText | ConvertFrom-Json -AsHashtable
        $command = switch ($scenario) {
            'failure' {
                '[IO.File]::WriteAllText("partial.txt", "partial"); exit 7'
            }
            'log-limit' {
                'while ($true) { [Console]::WriteLine("x" * 1024) }'
            }
            default {
                '[IO.File]::WriteAllText("partial.txt", "partial"); Start-Sleep -Seconds 30'
            }
        }
        $candidate.steps[0].arguments = @('-NoProfile', '-Command', $command)
        $candidate.steps[0].artifacts = @('partial.txt')
        if ($scenario -eq 'deadline') {
            $candidate.limits.budgetSeconds = 7
        }
        $config = Read-FixtureProject ($candidate | ConvertTo-Json -Depth 12) $root
        $cancel = [Threading.CancellationTokenSource]::new()
        try {
            if ($scenario -eq 'cancellation') {
                $cancel.CancelAfter(2000)
            }
            $timer = [Diagnostics.Stopwatch]::StartNew()
            $result = Invoke-RunnerProject -Project $config -PayloadRoot $root -EvidenceRoot (Join-Path $root 'evidence') -CancellationToken $cancel.Token
            $expected = switch ($scenario) {
                'cancellation' {
                    'cancelled'
                }
                'deadline' {
                    'timedOut'
                }
                default {
                    'failed'
                }
            }
            Assert-ProjectCondition ($result.status -eq $expected) "Wrong $scenario status: $($result | ConvertTo-Json -Depth 8 -Compress)"
            Assert-ProjectCondition $result.cleanupComplete 'Owned process cleanup must be confirmed.'
            Assert-ProjectCondition ($timer.Elapsed.TotalSeconds -lt $candidate.limits.budgetSeconds) 'Execution consumed finalization reserve.'
            if ($scenario -eq 'failure') {
                Assert-ProjectCondition ($result.steps[0].exitCode -eq 7 -and $result.artifacts.Count -eq 1) 'Failure must preserve exit code and partial artifact.'
            }
        }
        finally {
            $cancel.Dispose()
        }
    }
}
$summary = @{ passed = $script:passed
    failed = $script:failed
    total = $script:cases.Count
    cases = $script:cases.ToArray()
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ScratchRoot 'cases.json')
$summary | ConvertTo-Json -Depth 8 -Compress
if ($script:failed -gt 0) {
    exit 1
}
