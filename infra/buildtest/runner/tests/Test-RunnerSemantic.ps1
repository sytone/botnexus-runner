<#
.SYNOPSIS
Checks semantic evidence copies and injected native-boundary observations.
.DESCRIPTION
Runs standalone trusted-evidence controls and compiles the actual containment source with
only filesystem/signal bindings replaced by inert controlled functions. This is executed
algorithm/error-path evidence on Windows, not native Linux qualification.
.PARAMETER ScratchRoot
Owned isolated directory for synthetic XML and observations.
.PARAMETER SourceRoot
Runner source directory; defaults to the candidate beside this fixture. A frozen baseline
can be supplied to reproduce tests-first evidence without modifying current source.
.EXAMPLE
./Test-RunnerSemantic.ps1 -ScratchRoot $scratchRoot
.OUTPUTS
System.String. Named assertion results and JSON evidence.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot, [string]$SourceRoot = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
New-Item -ItemType Directory -Path $ScratchRoot -Force | Out-Null
. (Join-Path $SourceRoot 'Import-RunnerResult.ps1')
$cases = [Collections.Generic.List[object]]::new()
$rows = @(1..1200 | ForEach-Object { '<UnitTestResult storage="same.dll" testType="unit" testName="case' + $_ + '" outcome="Passed" />' })
$tail = '</Results><ResultSummary><Counters total="1200" executed="1200" passed="1200" failed="0" error="0" timeout="0" aborted="0" notExecuted="0" notRunnable="0" inconclusive="0" /></ResultSummary></TestRun>'
foreach ($case in @('comments', 'root-label', 'row-order', 'attribute-order', 'partial-overlap', 'assemblies-positive', 'runs-positive')) {
    try {
        $paths = @(1..10 | ForEach-Object {
                $index = $_
                $path = Join-Path $ScratchRoot "$case-$index.trx"
                $head = '<TestRun><Results>'
                $body = $rows -join ''
                switch ($case) {
                    'comments' {
                        $head = "<TestRun><!-- copy$index --><Results>"
                    }
                    'root-label' {
                        $head = "<TestRun label=`"copy$index`"><Results>"
                    }
                    'row-order' {
                        $rotated = @($rows[$index..1199]) + @($rows[0..($index - 1)])
                        $body = $rotated -join ''
                    }
                    'attribute-order' {
                        $head = "<TestRun label=`"noise$index`"><Results>"
                        $body = $body.Replace('storage="same.dll" testType="unit"', 'testType="unit" storage="same.dll"')
                    }
                    'partial-overlap' {
                        $head = "<TestRun label=`"noise$index`"><Results>"
                        $body = $body.Replace('testName="case1200"', "testName=`"independent$index`"")
                    }
                    'assemblies-positive' {
                        $body = $body.Replace('same.dll', "assembly$index.dll")
                    }
                    'runs-positive' {
                        $head = "<TestRun id=`"run$index`"><Results>"
                    }
                }
                [IO.File]::WriteAllText($path, $head + $body + $tail)
                $path
            })
        $result = Get-RunnerTestResult -TrxPaths $paths -MinimumTotal 12000 -RequireZeroSkipped
        $expected = $case -in @('assemblies-positive', 'runs-positive')
        if ($result.isComplete -ne $expected) {
            throw "Semantic evidence verdict: $($result | ConvertTo-Json -Compress)"
        }
        $cases.Add(@{ name = $case; passed = $true; result = $result })
        Write-Output "PASS $case"
    }
    catch {
        $cases.Add(@{ name = $case; passed = $false; error = $_.Exception.Message })
        Write-Output "FAIL ${case}: $($_.Exception.Message)"
    }
}
# Replace external bindings, not control flow. Every observation below executes
# actual candidate membership/kill logic in an inert compiled class.
$native = Get-Content (Join-Path $SourceRoot 'DiagnosticContainment.cs') -Raw
$native = $native.Replace('DiagnosticContainment', 'SemanticContainment').Replace('File.ReadAllText(', 'SemanticFixtureIO.ReadAllText(').Replace('Directory.EnumerateDirectories(', 'SemanticFixtureIO.EnumerateDirectories(')
$signalBinding = '[DllImport("libc", SetLastError=true)] private static extern int kill(int pid, int signal);'
if (-not $native.Contains($signalBinding)) {
    throw 'Exact inert signal binding not found.'
}
$native = $native.Replace($signalBinding, 'private static int kill(int pid,int signal) => SemanticFixtureIO.Kill(pid,signal);')
$lockBinding = '[DllImport("libc",SetLastError=true)] private static extern int flock(int fd,int operation);'
if (-not $native.Contains($lockBinding)) {
    throw 'Exact inert lock binding not found.'
}
$native = $native.Replace($lockBinding, 'private static int flock(int fd,int operation) => 0;')
# The Linux raw-open binding is replaced as well; this model runs on Windows.
$openStart = $native.IndexOf('        var descriptor=open(')
$openEnd = $native.IndexOf('        try', $native.IndexOf('catch { handle.Dispose(); throw; }', $openStart))
if ($openStart -lt 0 -or $openEnd -lt $openStart) {
    throw 'Exact raw-open binding not found.'
}
$native = $native.Substring(0, $openStart) + '        var stream=new FileStream(Path.Combine(root,"registry.lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.ReadWrite);' + [Environment]::NewLine + $native.Substring($openEnd)

Add-Type -TypeDefinition ($native + @'
public static class SemanticFixtureIO
{
    public static string Mode="";
    public static int Reads;
    public static int Enumerations;
    public static int Signals;
    public static System.Diagnostics.Stopwatch Clock;
    public static int ExpirationBoundary;
    public static double Deadline;
    public static System.Collections.Generic.IEnumerable<string> EnumerateDirectories(string root)
    {
        Enumerations++;
        if(Mode=="enumeration-denied") throw new UnauthorizedAccessException("Injected process listing denial.");
        return Entries();
    }
    private static System.Collections.Generic.IEnumerable<string> Entries()
    {
        yield return "/proc/101";
        yield return "/proc/202";
        yield return "/proc/303";
        if(Mode=="large-membership")
            for(var i=304;i<70000;i++) yield return "/proc/"+i;
    }
    public static string ReadAllText(string path)
    {
        Reads++;
        path=path.Replace('\\','/');
        if(path.Contains("/202/"))
        {
            if(Mode=="access-denied") throw new UnauthorizedAccessException("Injected persistent stat denial.");
            if(Mode=="persistent-io" || Mode=="esrch-vanished" || Mode=="esrch-reused-live" || Mode=="io-probe-denied") throw new IOException("Injected stat read failure.");
            if(Mode=="disappeared") throw new FileNotFoundException("Injected vanished process.");
            if(Mode=="expires-during-scan")
            {
                // No sleep: wait only for the test clock's explicitly measured edge.
                while(Clock.Elapsed.TotalSeconds<Deadline) System.Threading.Thread.SpinWait(100);
                ExpirationBoundary=Reads;
            }
        }
        var pid=path.Contains("/101/") ? 101 : path.Contains("/202/") ? 202 : 303;
        // state, parent, group, session, seventeen fields through starttime.
        var group=(Mode=="many-owners" || Mode=="signal-error-owner" || Mode=="expires-after-root") && pid==202 ? 202 : 101;
        return pid+" (fixture) "+(Mode=="zombies" ? "Z" : "S")+" 1 "+group+" "+group+" 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 123";
    }
    public static int Kill(int pid,int signal)
    {
        if(signal==0)
        {
            if(Mode=="esrch-vanished") { System.Runtime.InteropServices.Marshal.SetLastPInvokeError(3); return -1; }
            if(Mode=="io-probe-denied") { System.Runtime.InteropServices.Marshal.SetLastPInvokeError(1); return -1; }
            return 0;
        }
        Signals++;
        if(Mode=="signal-error-owner" && pid==-101) throw new IOException("Injected root signal failure.");
        if(Mode=="expires-after-root" && Signals==1)
            while(Clock.Elapsed.TotalSeconds<Deadline) System.Threading.Thread.SpinWait(100);
        return 0;
    }
    public static void Reset(string mode) { Mode=mode; Reads=0; Enumerations=0; Signals=0; }
}
'@)
$field = [SemanticContainment].GetField('OwnerTokens', [Reflection.BindingFlags]'Static,NonPublic')
$tokens = $field.GetValue($null)
# Read the injected stat start token through the same parser, not a guessed index.
$startMethod = [SemanticContainment].GetMethod('ReadStartToken', [Reflection.BindingFlags]'Static,NonPublic')
$tokens[101] = $startMethod.Invoke($null, @([int]101))
$previousRegistry = $env:RUNNER_OWNERSHIP_ROOT
$env:RUNNER_OWNERSHIP_ROOT = $null
try {
    foreach ($case in @('access-denied', 'persistent-io', 'esrch-vanished', 'esrch-reused-live', 'io-probe-denied', 'enumeration-denied', 'disappeared', 'zombies', 'expired-verification', 'expired-kill', 'single-scan-kill', 'expires-during-scan', 'large-membership', 'access-denied-kill', 'many-owners', 'signal-error-owner', 'expires-after-root')) {
        try {
            [SemanticFixtureIO]::Reset($(if ($case -eq 'access-denied-kill') {
                        'access-denied'
                    }
                    else {
                        $case
                    }))
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $deadline = if ($case -like 'expired-*') {
                -1.0
            }
            else {
                10.0
            }
            if ($case -eq 'expires-during-scan') {
                $deadline = 0.02
            }
            [SemanticFixtureIO]::Clock = $clock
            [SemanticFixtureIO]::Deadline = $deadline
            if ($case -in @('many-owners', 'signal-error-owner', 'expires-after-root')) {
                $registry = Join-Path $ScratchRoot $case
                New-Item -ItemType Directory -Path $registry -Force | Out-Null
                @{ Pid = 202; Token = $tokens[101]; Parent = 101; ParentToken = $tokens[101] } | ConvertTo-Json | Set-Content (Join-Path $registry 'child.json')
                $env:RUNNER_OWNERSHIP_ROOT = $registry
            }
            else {
                $env:RUNNER_OWNERSHIP_ROOT = $null
            }
            $message = $null
            $members = @()
            if ($case -in @('expired-kill', 'single-scan-kill', 'access-denied-kill', 'many-owners', 'signal-error-owner', 'expires-after-root')) {
                try {
                    [SemanticContainment]::KillGroup(101, $clock, $deadline)
                }
                catch {
                    $message = $_.Exception.Message
                }
                if ([SemanticFixtureIO]::Signals -lt 1) {
                    throw 'Known root/group signal was suppressed.'
                }
                if ($case -eq 'expired-kill' -and (-not $message -or [SemanticFixtureIO]::Enumerations -ne 0)) {
                    throw 'Expired cleanup scanned processes or certified success.'
                }
                if ($case -eq 'single-scan-kill' -and [SemanticFixtureIO]::Enumerations -ne 1) {
                    throw 'Kill did not use exactly one process snapshot.'
                }
                if ($case -in @('many-owners', 'signal-error-owner', 'expires-after-root')) {
                    if ([SemanticFixtureIO]::Signals -ne 2 -or [SemanticFixtureIO]::Enumerations -ne 1) {
                        throw 'Owners were rescanned or later known-root signal suppressed.'
                    }
                    if ($case -in @('signal-error-owner', 'expires-after-root') -and -not $message) {
                        throw 'Incomplete signal proof certified success.'
                    }
                    if ($case -eq 'many-owners' -and $message) {
                        throw "Complete inert registry failed: $message"
                    }
                }
                if ($case -eq 'access-denied-kill' -and (-not $message -or [SemanticFixtureIO]::Enumerations -ne 1)) {
                    throw 'Unknown membership suppressed signals or certified cleanup.'
                }
            }
            else {
                try {
                    $overload = [SemanticContainment].GetMethod('RegisteredMemberIds', [type[]]@([int], [Diagnostics.Stopwatch], [double]))
                    $members = @(if ($null -eq $overload) {
                            [SemanticContainment]::RegisteredMemberIds(101)
                        }
                        else {
                            $overload.Invoke($null, @([int]101, $clock, $deadline))
                        })
                }
                catch {
                    $message = $_.Exception.Message
                }
                if ($case -in @('access-denied', 'persistent-io', 'esrch-reused-live', 'io-probe-denied', 'enumeration-denied', 'expired-verification', 'expires-during-scan', 'large-membership')) {
                    if (-not $message) {
                        throw "Incomplete observation was certified: members=$members"
                    }
                    if ($case -eq 'expires-during-scan' -and [SemanticFixtureIO]::Reads -ne [SemanticFixtureIO]::ExpirationBoundary) {
                        throw 'Discovery continued stat reads after original clock expired.'
                    }
                    if ($case -eq 'large-membership' -and [SemanticFixtureIO]::Reads -gt 65536) {
                        throw 'Process count bound was not enforced.'
                    }
                    if ($case -eq 'expired-verification' -and [SemanticFixtureIO]::Enumerations -ne 0) {
                        throw 'Expired verification started new process scan.'
                    }
                }
                elseif ($case -in @('disappeared', 'esrch-vanished') -and ($message -or $members.Count -ne 2)) {
                    throw 'Disappeared entry was not distinguished from persistent unreadability.'
                }
                elseif ($case -eq 'zombies' -and ($message -or $members.Count -ne 0)) {
                    throw 'Zombie-only snapshot was not accepted as terminated.'
                }
            }
            $cases.Add(@{ name = $case; passed = $true; reads = [SemanticFixtureIO]::Reads; scans = [SemanticFixtureIO]::Enumerations; signals = [SemanticFixtureIO]::Signals; error = $message })
            Write-Output "PASS $case"
        }
        catch {
            $cases.Add(@{ name = $case; passed = $false; error = $_.Exception.Message })
            Write-Output "FAIL ${case}: $($_.Exception.Message)"
        }
    }
}
finally {
    $env:RUNNER_OWNERSHIP_ROOT = $previousRegistry
}
$failed = @($cases | Where-Object { -not $_.passed }).Count
@{ passed = $cases.Count - $failed; failed = $failed; cases = $cases.ToArray(); nativeLinux = 'UNRUN; filesystem/signal injection only' } | ConvertTo-Json -Depth 7 | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if ($failed) {
    exit 1
}
