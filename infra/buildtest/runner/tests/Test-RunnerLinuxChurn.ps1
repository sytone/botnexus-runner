<#
.SYNOPSIS
Checks bounded native Linux churn and explicit failure-path safety cleanup.
.DESCRIPTION
Runs 32-child synthetic bursts in an isolated Linux PID namespace. Uses the production
membership helper and one original clock per case. Final safety cleanup is separately
recorded and must reach zero live members, including an intentional assertion failure.
.PARAMETER ScratchRoot
New isolated directory for observations.
.EXAMPLE
./Test-RunnerLinuxChurn.ps1 -ScratchRoot /tmp/churn
.OUTPUTS
System.String. Actual native case observations and failure cleanup proof.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$ScratchRoot)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $IsLinux) {
    throw 'Native Linux required.'
}
New-Item -ItemType Directory -Path $ScratchRoot -ErrorAction Stop | Out-Null
$containmentSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../DiagnosticContainment.cs') -Raw
$controlSource = @'
using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;
using System.Threading;
using System.Text.Json;
public static class NativeChurnControl
{
    public static string Run(string root)
    {
        var observations=new List<object>();
        var previous=Environment.GetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT");
        try
        {
            foreach(var name in new[]{"bounded-32-child-churn","injected-failure-finally-zero"})
            {
                var dir=Path.Combine(root,name);Directory.CreateDirectory(dir);
                Environment.SetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT",dir);
                Process owner=null;var clock=Stopwatch.StartNew();var samples=new List<int>();
                string failure=null;string cleanupError=null;bool expiredUnknown=false;
                bool safetyReached=false;bool rootExited=false;int[] finalMembers=null;
                try
                {
                    var ready=Path.Combine(dir,"ready");
                    var start=new ProcessStartInfo("setsid"){UseShellExecute=false};
                    start.ArgumentList.Add("bash");start.ArgumentList.Add("-c");
                    start.ArgumentList.Add("touch '"+ready+"'; for i in {1..32}; do (sleep 0.02) & done; wait; sleep 30");
                    owner=Process.Start(start);
                    while(!File.Exists(ready) && clock.Elapsed.TotalSeconds<3) Thread.Sleep(1);
                    if(!File.Exists(ready) || !DiagnosticContainment.IsSessionLeader(owner.Id)) throw new Exception("Churn actor readiness/session failed.");
                    for(var n=0;n<3;n++) samples.Add(DiagnosticContainment.RegisteredMemberIds(owner.Id,clock,3).Length);
                    try { DiagnosticContainment.RegisteredMemberIds(owner.Id,clock,-1); }
                    catch(AggregateException) { expiredUnknown=true; }
                    if(!expiredUnknown) throw new Exception("Expired observation certified cleanup.");
                    if(name=="injected-failure-finally-zero") throw new Exception("Intentional fixture failure before original zero proof.");
                    DiagnosticContainment.KillGroup(owner.Id,clock,5);
                    if(!owner.WaitForExit(2000)) throw new Exception("Original cleanup left root alive.");
                    int[] ids;
                    do
                    {
                        ids=DiagnosticContainment.RegisteredMemberIds(owner.Id,clock,6);
                        if(ids.Length==0) break;
                        Thread.Sleep(5);
                    } while(clock.Elapsed.TotalSeconds<6);
                    if(ids.Length!=0) throw new Exception("Original cleanup left live members: "+string.Join(",",ids));
                }
                catch(Exception error) { failure=error.ToString(); }
                finally
                {
                    safetyReached=true;
                    if(owner!=null)
                    {
                        // Separate fixed fixture safety allowance, never original proof.
                        var safetyDeadline=clock.Elapsed.TotalSeconds+3;
                        try
                        {
                            DiagnosticContainment.KillGroup(owner.Id,clock,safetyDeadline);
                            rootExited=owner.WaitForExit(1000);
                            do
                            {
                                finalMembers=DiagnosticContainment.RegisteredMemberIds(owner.Id,clock,safetyDeadline);
                                if(finalMembers.Length==0) break;
                                Thread.Sleep(5);
                            } while(clock.Elapsed.TotalSeconds<safetyDeadline);
                            if(!rootExited || finalMembers.Length!=0) throw new Exception("Safety cleanup did not establish zero live members.");
                        }
                        catch(Exception error) { cleanupError=error.ToString(); }
                        finally { owner.Dispose(); }
                    }
                }
                var expectedFailure=name=="injected-failure-finally-zero";
                var passed=cleanupError==null && rootExited && finalMembers!=null && finalMembers.Length==0 &&
                    (expectedFailure ? failure!=null && failure.Contains("Intentional fixture failure") : failure==null);
                observations.Add(new{name,passed,samples,expiredUnknown,originalError=failure,safetyReached,
                    safetyCleanup=new{originalBudgetProof=false,rootExited,finalMembers,error=cleanupError},seconds=clock.Elapsed.TotalSeconds});
                Console.WriteLine((passed ? "PASS " : "FAIL ")+name);
            }
        }
        finally { Environment.SetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT",previous); }
        return JsonSerializer.Serialize(observations);
    }
}
'@
# Compile both types in one assembly; separate Add-Type invocations do not
# automatically reference dynamically compiled assemblies on PowerShell 7.5.
$controlBody = $controlSource -replace '(?m)^using [^;]+;\r?\n', ''
Add-Type -TypeDefinition ($containmentSource + [Environment]::NewLine + $controlBody)
$observations = [NativeChurnControl]::Run($ScratchRoot) | ConvertFrom-Json
$json = ConvertTo-Json -InputObject @($observations) -Depth 8
$json | Tee-Object -FilePath (Join-Path $ScratchRoot 'cases.json')
if (@($observations | Where-Object { -not $_.passed }).Count) {
    exit 1
}
