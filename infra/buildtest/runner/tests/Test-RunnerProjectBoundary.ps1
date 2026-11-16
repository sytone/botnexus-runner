<#
.SYNOPSIS
Exercises graph scheduling, cancellation, owned descendants and bounded evidence.
.DESCRIPTION
Uses synthetic PowerShell children only. Adds adversarial runtime controls without a
product test host or gateway. Retains actual case counts beneath the supplied scratch root.
.PARAMETER ScratchRoot
New owned fixture root for this invocation.
.EXAMPLE
./Test-RunnerProjectBoundary.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Per-case results and JSON summary. Exits one on any failed assertion.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../RunnerProject.psm1') -Force
$script:results = [Collections.Generic.List[object]]::new()
$pwsh = (Get-Process -Id $PID).Path
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null

function Assert-BoundaryCondition {
    <#
    .SYNOPSIS
    Checks one runtime boundary.
    .DESCRIPTION
    Throws a meaningful assertion message when the actual condition is false.
    .PARAMETER Condition
    Actual observation.
    .PARAMETER Message
    Required boundary description.
    .EXAMPLE
    Assert-BoundaryCondition $result.cleanupComplete 'Cleanup must complete.'
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}
function Invoke-BoundaryCase {
    <#
    .SYNOPSIS
    Records a bounded synthetic case.
    .DESCRIPTION
    Runs every case independently and retains failures in the summary.
    .PARAMETER Name
    Case identity.
    .PARAMETER Body
    Runtime assertions.
    .EXAMPLE
    Invoke-BoundaryCase 'cleanup' { Assert-BoundaryCondition $true 'Complete.' }
    .OUTPUTS
    System.String. Case result.
    #>
    [CmdletBinding()]
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:results.Add(@{ name = $Name
                passed = $true
            })
        Write-Output "PASS $Name"
    }
    catch {
        $script:results.Add(@{ name = $Name
                passed = $false
                error = $_.Exception.Message
            })
        Write-Output "FAIL ${Name}: $($_.Exception.Message)"
    }
}
function New-BoundaryProject {
    <#
    .SYNOPSIS
    Creates one disjoint synthetic project root.
    .DESCRIPTION
    Copies the checked-in fixture command and returns mutable project input for test setup.
    .PARAMETER Name
    Unique fixture directory name.
    .EXAMPLE
    New-BoundaryProject -Name parallel
    .OUTPUTS
    System.Collections.Hashtable. Fixture root and project document.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([hashtable])]
    param([string]$Name)
    $root = Join-Path $ScratchRoot $Name
    if (-not $PSCmdlet.ShouldProcess($root, 'Create isolated synthetic project')) {
        return
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/Invoke-FixtureCommand.ps1') -Destination $root
    return @{
        Root = $root
        Project = @{
            schemaVersion = 1
            protocolVersion = 1
            requiredCapabilities = @('process-v1', 'artifacts-v1')
            limits = @{ budgetSeconds = 16
                reserveSeconds = 4
                maxConcurrency = 2
                maxLogBytes = 65536
                maxArtifactBytes = 65536
                maxArtifacts = 8
            }
            steps = @(@{ id = 'build'
                    executable = $pwsh
                    arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1')
                    workingDirectory = '.'
                    dependsOn = @()
                    artifacts = @('result.txt')
                })
        }
    }
}
function Read-BoundaryProject {
    <#
    .SYNOPSIS
    Loads exact serialized fixture bytes.
    .DESCRIPTION
    Writes the setup document and invokes production parsing with the observed SHA-256.
    .PARAMETER Fixture
    Synthetic project setup returned by New-BoundaryProject.
    .EXAMPLE
    Read-BoundaryProject -Fixture $fixture
    .OUTPUTS
    System.Collections.IDictionary. Validated project configuration.
    #>
    [CmdletBinding()]
    param([hashtable]$Fixture)
    $path = Join-Path $Fixture.Root 'project.json'
    $Fixture.Project | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding utf8NoBOM
    Read-RunnerProject -Path $path -PayloadRoot $Fixture.Root -ExpectedSha256 (Get-FileHash -LiteralPath $path).Hash
}

Invoke-BoundaryCase 'parallel-prerequisites' {
    $fixture = New-BoundaryProject 'parallel'
    $fixture.Project.steps = @(
        @{ id = 'debug'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1', '-Mode', 'parallel', '-Value', 'debug', '-Peer', 'release')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @('debug.complete')
        },
        @{ id = 'release'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1', '-Mode', 'parallel', '-Value', 'release', '-Peer', 'debug')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @('release.complete')
        },
        @{ id = 'test'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1', '-Mode', 'dependent')
            workingDirectory = '.'
            dependsOn = @('debug', 'release')
            artifacts = @('result.txt')
        }
    )
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'succeeded' -and $result.steps.Count -eq 3) "Parallel graph failed: $($result | ConvertTo-Json -Depth 8 -Compress)"
    Assert-BoundaryCondition ($result.artifacts.Count -eq 3 -and $result.cleanupComplete) 'All prerequisite evidence and cleanup must be present.'
    foreach ($peer in @('debug', 'release')) {
        Assert-BoundaryCondition ([IO.File]::ReadAllText((Join-Path $fixture.Root "$peer.result.txt")) -ceq $peer) 'Parallel output did not retain its own literal value.'
    }
    $debug = $result.steps | Where-Object id -EQ 'debug'
    $release = $result.steps | Where-Object id -EQ 'release'
    Assert-BoundaryCondition ($debug.startedSeconds -lt ($release.startedSeconds + $release.elapsedSeconds) -and $release.startedSeconds -lt ($debug.startedSeconds + $debug.elapsedSeconds)) 'Parallel peers were serialized.'
    Assert-BoundaryCondition ([IO.File]::ReadAllText((Join-Path $fixture.Root 'result.txt')) -ceq 'fixture') 'Dependent result was overwritten by a parallel peer.'

}
Invoke-BoundaryCase 'missing-declared-artifact' {
    $fixture = New-BoundaryProject 'missing-artifact'
    $fixture.Project.steps[0].artifacts = @('missing.trx')
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'failed') 'A successful command cannot hide its missing declared artifact.'
}
Invoke-BoundaryCase 'hidden-completion-artifact' {
    $fixture = New-BoundaryProject 'hidden-completion'
    $fixture.Project.steps[0].artifacts = @('.runner-project-completion.json')
    $fixture.Project.steps[0].arguments = @('-NoProfile', '-Command', '[IO.File]::WriteAllText(".runner-project-completion.json", "{}")')
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'succeeded' -and $result.artifacts.Count -eq 1) 'Existing hidden completion artifact was lost during inventory.'
}
Invoke-BoundaryCase 'artifact-byte-limit' {
    $fixture = New-BoundaryProject 'artifact-limit'
    $fixture.Project.limits.maxArtifactBytes = 1
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'failed' -and $result.artifacts.Count -eq 0) 'Oversized artifacts must not be accepted or inventoried.'
}
Invoke-BoundaryCase 'cancel-before-launch' {
    $fixture = New-BoundaryProject 'cancel-before'
    $config = Read-BoundaryProject $fixture
    $cancel = [Threading.CancellationTokenSource]::new()
    try {
        $cancel.Cancel()
        $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence') -CancellationToken $cancel.Token
        Assert-BoundaryCondition ($result.status -eq 'cancelled' -and $result.steps[0].status -eq 'notStarted' -and $result.cleanupComplete) 'Pre-cancelled invocation launched work or lost cleanup proof.'
        Assert-BoundaryCondition (-not (Test-Path (Join-Path $fixture.Root 'result.txt'))) 'Pre-cancelled command wrote output.'
    }
    finally {
        $cancel.Dispose()
    }
}
Invoke-BoundaryCase 'owned-descendant-after-command-exit' {
    $fixture = New-BoundaryProject 'orphan'
    $fixture.Project.steps[0].arguments += @('-Mode', 'orphan')
    $fixture.Project.steps[0].artifacts += 'descendant.json'
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'succeeded' -and $result.cleanupComplete) 'Ownership cleanup failed after launcher exit.'
    $identity = Get-Content (Join-Path $fixture.Root 'descendant.json') -Raw | ConvertFrom-Json
    $survivor = Get-Process -Id $identity.processId -ErrorAction SilentlyContinue
    try {
        $same = $null -ne $survivor -and $survivor.StartTime.ToUniversalTime().ToString('o') -eq $identity.startUtc
        Assert-BoundaryCondition (-not $same) 'Owned descendant survived command completion.'
    }
    finally {
        if ($null -ne $survivor) {
            $survivor.Dispose()
        }
    }
}
Invoke-BoundaryCase 'environment-not-inherited' {
    $fixture = New-BoundaryProject 'environment'
    $fixture.Project.steps[0].arguments += @('-Mode', 'environment')
    $config = Read-BoundaryProject $fixture
    $prior = [Environment]::GetEnvironmentVariable('RUNNER_FIXTURE_SECRET')
    try {
        [Environment]::SetEnvironmentVariable('RUNNER_FIXTURE_SECRET', 'synthetic-no-credential')
        $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
        Assert-BoundaryCondition ($result.status -eq 'succeeded') 'Parent variable leaked to project command.'
    }
    finally {
        [Environment]::SetEnvironmentVariable('RUNNER_FIXTURE_SECRET', $prior)
    }
}
Invoke-BoundaryCase 'failed-prerequisite-stops-sibling-and-dependent' {
    $fixture = New-BoundaryProject 'failure-graph'
    $fixture.Project.steps = @(
        @{ id = 'fail'
            executable = $pwsh
            arguments = @('-NoProfile', '-Command', 'exit 9')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @()
        },
        @{ id = 'slow'
            executable = $pwsh
            arguments = @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @()
        },
        @{ id = 'dependent'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1')
            workingDirectory = '.'
            dependsOn = @('fail')
            artifacts = @()
        }
    )
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'failed' -and $result.cleanupComplete) 'Failed graph lost cleanup proof.'
    Assert-BoundaryCondition (@($result.steps | Where-Object { $_.id -eq 'dependent' -and $_.status -eq 'notStarted' }).Count -eq 1) 'Failed prerequisite allowed dependent launch.'
    Assert-BoundaryCondition (-not (Test-Path (Join-Path $fixture.Root 'result.txt'))) 'Dependent command wrote output after prerequisite failure.'
}
Invoke-BoundaryCase 'mutated-config-reloaded' {
    $fixture = New-BoundaryProject 'mutated'
    $config = Read-BoundaryProject $fixture
    $config.limits.maxConcurrency = 999
    $config.steps[0].arguments = @('-NoProfile', '-Command', 'exit 99')
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'succeeded') 'Mutable parsed object bypassed validated candidate bytes.'
}
Invoke-BoundaryCase 'changed-config-before-execution' {
    $fixture = New-BoundaryProject 'changed'
    $config = Read-BoundaryProject $fixture
    Add-Content -LiteralPath (Join-Path $fixture.Root 'project.json') -Value ' '
    $rejected = $false
    try {
        $null = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    }
    catch {
        $rejected = $true
    }
    Assert-BoundaryCondition $rejected 'Changed candidate configuration executed.'
    Assert-BoundaryCondition (-not (Test-Path (Join-Path $fixture.Root 'evidence'))) 'Invalid config created runtime evidence before validation.'
}
Invoke-BoundaryCase 'depth-bound' {
    $fixture = New-BoundaryProject 'depth'
    $text = ('{"nested":' * 18) + '1' + ('}' * 18)
    $path = Join-Path $fixture.Root 'project.json'
    [IO.File]::WriteAllText($path, $text)
    $rejected = $false
    try {
        $null = Read-RunnerProject -Path $path -PayloadRoot $fixture.Root -ExpectedSha256 (Get-FileHash -LiteralPath $path).Hash
    }
    catch {
        $rejected = $true
    }
    Assert-BoundaryCondition $rejected 'Excessive JSON depth accepted.'
}
Invoke-BoundaryCase 'missing-executable-cleanup' {
    $fixture = New-BoundaryProject 'launch-failure'
    $fixture.Project.steps[0].executable = 'runner-fixture-command-that-does-not-exist'
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'failed' -and $result.cleanupComplete) 'Launch failure lost failure status or cleanup proof.'
}
Invoke-BoundaryCase 'concurrency-one-prevents-overlap' {
    $fixture = New-BoundaryProject 'serial'
    $fixture.Project.limits.maxConcurrency = 1
    $fixture.Project.steps = @(
        @{ id = 'first'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1', '-Mode', 'parallel', '-Value', 'debug', '-Peer', 'release')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @()
        },
        @{ id = 'second'
            executable = $pwsh
            arguments = @('-NoProfile', '-File', './Invoke-FixtureCommand.ps1', '-Value', 'second')
            workingDirectory = '.'
            dependsOn = @()
            artifacts = @()
        }
    )
    $config = Read-BoundaryProject $fixture
    $result = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence')
    Assert-BoundaryCondition ($result.status -eq 'failed' -and $result.cleanupComplete) 'Serial cap allowed the handshake fixture to succeed.'
    Assert-BoundaryCondition (@($result.steps | Where-Object { $_.id -eq 'second' -and $_.status -eq 'notStarted' }).Count -eq 1) 'Concurrency limit launched sibling before first failed.'
}
Invoke-BoundaryCase 'two-node-cycle' {
    $fixture = New-BoundaryProject 'cycle'
    $fixture.Project.steps[0].dependsOn = @('other')
    $fixture.Project.steps += @{ id = 'other'
        executable = $pwsh
        arguments = @()
        workingDirectory = '.'
        dependsOn = @('build')
        artifacts = @()
    }
    $rejected = $false
    try {
        $null = Read-BoundaryProject $fixture
    }
    catch {
        $rejected = $true
    }
    Assert-BoundaryCondition $rejected 'Multi-node cycle accepted.'
}
Invoke-BoundaryCase 'artifact-declaration-count-limit' {
    $fixture = New-BoundaryProject 'artifact-count'
    $fixture.Project.limits.maxArtifacts = 1
    $fixture.Project.steps[0].artifacts = @('one.txt', 'two.txt')
    $rejected = $false
    try {
        $null = Read-BoundaryProject $fixture
    }
    catch {
        $rejected = $true
    }
    Assert-BoundaryCondition $rejected 'Artifact declarations exceed the trusted/configured count.'
}
Invoke-BoundaryCase 'preview-preserves-files-and-environment' {
    $fixture = New-BoundaryProject 'preview'
    $config = Read-BoundaryProject $fixture
    $before = (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'project.json')).Hash
    $environment = [Environment]::GetEnvironmentVariable('RUNNER_FIXTURE_SECRET')
    $null = Invoke-RunnerProject -Project $config -PayloadRoot $fixture.Root -EvidenceRoot (Join-Path $fixture.Root 'evidence') -WhatIf
    Assert-BoundaryCondition (-not (Test-Path (Join-Path $fixture.Root 'evidence'))) 'Preview created an evidence directory.'
    Assert-BoundaryCondition (-not (Test-Path (Join-Path $fixture.Root 'result.txt'))) 'Preview launched project code.'
    Assert-BoundaryCondition ($before -ceq (Get-FileHash -LiteralPath (Join-Path $fixture.Root 'project.json')).Hash) 'Preview changed candidate bytes.'
    Assert-BoundaryCondition ($environment -ceq [Environment]::GetEnvironmentVariable('RUNNER_FIXTURE_SECRET')) 'Preview changed environment state.'
}
$failed = @($script:results | Where-Object { -not $_.passed }).Count
$summary = @{ passed = $script:results.Count - $failed
    failed = $failed
    total = $script:results.Count
    cases = $script:results.ToArray()
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ScratchRoot 'cases.json')
$summary | ConvertTo-Json -Depth 8 -Compress
if ($failed -gt 0) {
    exit 1
}
