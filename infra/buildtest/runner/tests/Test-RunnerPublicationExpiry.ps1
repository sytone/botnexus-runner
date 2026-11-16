<#
.SYNOPSIS
Requires expired direct publication callers to fail and still dispose native resources.
.DESCRIPTION
Executes the exact positive publication fixture finally block with a real owned child
and the original lifecycle clock expired. No model replaces native launch or proof.
.PARAMETER ScratchRoot
Isolated writable fixture directory.
.EXAMPLE
./Test-RunnerPublicationExpiry.ps1 -ScratchRoot /tmp/publication-expiry
.OUTPUTS
System.String. Actual native failure and disposal proof.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot '../Import-RunnerDiagnostic.ps1')
. (Join-Path $PSScriptRoot 'Test-DiagnosticFixtureClock.ps1')
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Test-RunnerDiagnosticPublication.ps1'), [ref]$tokens, [ref]$parseErrors)
$node = $ast.Find({ param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $null -ne $n.Finally -and $n.Finally.Extent.Text -match 'Publication descendants survived cleanup' }, $true)
$body = $node.Finally.Extent.Text
$assertion = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Assert-DiagnosticInvariant' }, $true)
. ([scriptblock]::Create($assertion.Extent.Text))
$publicationClock = [Diagnostics.Stopwatch]::StartNew()
$owner = New-DiagnosticOwnedProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', '[Threading.ManualResetEvent]::new($false).WaitOne() | Out-Null') -Root $ScratchRoot -Token 'expired-publication' -RunClock $publicationClock -DeadlineSeconds 1
$handle = $owner.Process.SafeHandle
$result = Join-Path $ScratchRoot 'result'
Write-Verbose "Exact finally block publication marker: $result"
$failure = ''
try {
    # Expire the original ten-second lifecycle, not a reset stop/proof clock.
    [Threading.Thread]::Sleep([int][Math]::Max(0, (10.1 - $publicationClock.Elapsed.TotalSeconds) * 1000))
    try {
        . ([scriptblock]::Create($body.Substring(1, $body.Length - 2)))
    }
    catch {
        $failure = $_.Exception.Message
    }
    if (-not $failure -or $failure -notmatch 'deadline|certified') {
        throw "Expired direct caller did not preserve native proof failure: $failure"
    }
    if (-not $handle.IsClosed) {
        throw 'Expired direct caller bypassed process disposal'
    }
    "PASS expired original publication lifecycle failed and disposed: $failure"
}
finally {
    # Test owns this handle even when the baseline fails its disposal assertion.
    $owner.Process.Dispose()
    if ($null -ne $owner.Job) {
        $owner.Job.Dispose()
    }
}
