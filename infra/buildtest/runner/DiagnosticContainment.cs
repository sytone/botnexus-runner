using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.IO;
using System.Text.Json;
using System.Collections.Generic;
using System.Diagnostics;
using System.Threading;

// Small native boundary: no command-line construction or process launching here.
public sealed class DiagnosticContainment : IDisposable
{
    private static readonly List<object> phaseEvidence = new List<object>();
    [StructLayout(LayoutKind.Sequential)] private struct CpuTime { public long Seconds; public long Nanoseconds; }
    [DllImport("libc", SetLastError=true)] private static extern int clock_gettime(int kind, out CpuTime time);
    private static void MarkPhase(string phase,Stopwatch clock,double deadlineSeconds,int count=-1)
    {
        // Bounded memory and nonblocking kernel CPU clock only. No cgroup/file reads.
        try
        {
            if(phaseEvidence.Count>=256) phaseEvidence.RemoveAt(32);
            double? cpu=null;
            if(RuntimeInformation.IsOSPlatform(OSPlatform.Linux) && clock_gettime(2,out var time)==0)
                cpu=time.Seconds+time.Nanoseconds/1000000000.0;
            phaseEvidence.Add(new {phase,clockId=System.Runtime.CompilerServices.RuntimeHelpers.GetHashCode(clock),seconds=clock.Elapsed.TotalSeconds,deadline=deadlineSeconds,count,cpuSeconds=cpu});
        }
        catch { /* Observation unavailability cannot change native proof. */ }
    }
    public static object[] PhaseEvidence() => phaseEvidence.ToArray();
    private IntPtr job;
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool QueryInformationJobObject(IntPtr job, int kind, byte[] data, uint length, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("libc", SetLastError=true)] private static extern int kill(int pid, int signal);
    [DllImport("libc", SetLastError=true)] private static extern int getpgid(int pid);
    [DllImport("libc", SetLastError=true)] private static extern int getsid(int pid);
    public DiagnosticContainment() { job=CreateJobObject(IntPtr.Zero,null); if(job==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public void Assign(IntPtr process) { if(!AssignProcessToJobObject(job,process)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public bool Contains(IntPtr process) { if(!IsProcessInJob(process,job,out bool result)) throw new Win32Exception(Marshal.GetLastWin32Error()); return result; }
    public int[] MemberIds { get { byte[] data=new byte[65536]; if(!QueryInformationJobObject(job,3,data,(uint)data.Length,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error()); int count=BitConverter.ToInt32(data,4); int[] ids=new int[count]; for(int i=0;i<count;i++) ids[i]=IntPtr.Size==8 ? checked((int)BitConverter.ToInt64(data,8+i*8)) : BitConverter.ToInt32(data,8+i*4); return ids; } }
    public uint Active { get { byte[] data=new byte[48]; if(!QueryInformationJobObject(job,1,data,48,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error()); return BitConverter.ToUInt32(data,40); } }
    public void Kill() { if(!TerminateJobObject(job,1)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    private static readonly Dictionary<int,string> OwnerTokens = new Dictionary<int,string>();
    public static bool IsSessionLeader(int pid)
    {
        if (getpgid(pid)!=pid || getsid(pid)!=pid) return false;
        OwnerTokens[pid]=ReadStartToken(pid);
        return true;
    }
    private sealed class Boundary
    {
        public int Pid {get;set;}
        public string Token {get;set;}
        public int Parent {get;set;}
        public string ParentToken {get;set;}
    }
    private static string ReadStartToken(int pid)
    {
        var stat=File.ReadAllText("/proc/"+pid+"/stat");
        return stat.Substring(stat.LastIndexOf(')')+2).Split(' ',StringSplitOptions.RemoveEmptyEntries)[19];
    }
    private static string Key(int pid,string token) => pid+"-"+token;
    private static FileStream LockRegistry(string root,Stopwatch clock,double deadlineSeconds)
    {
        MarkPhase("registry.lock.before",clock,deadlineSeconds);
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned registry lock deadline exhausted before acquisition.");
        // FileStream(path) applies its own Unix sharing flock before our native
        // deadline loop. Open directly with CLOEXEC so only this protocol owns flock.
        var descriptor=open(Path.Combine(root,"registry.lock"),524354,384); // O_CLOEXEC|O_CREAT|O_RDWR, 0600
        if(descriptor<0) throw new Win32Exception(Marshal.GetLastWin32Error());
        var handle=new Microsoft.Win32.SafeHandles.SafeFileHandle(new IntPtr(descriptor),true);
        FileStream stream;
        try { stream=new FileStream(handle,FileAccess.ReadWrite); }
        catch { handle.Dispose(); throw; }
        try
        {
            // LOCK_EX | LOCK_NB: the supervisor never enters an unbounded native wait.
            while(flock(stream.SafeFileHandle.DangerousGetHandle().ToInt32(),6)!=0)
            {
                var error=Marshal.GetLastWin32Error();
                if(error!=11 && error!=4) throw new Win32Exception(error);
                if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned registry lock deadline exhausted.");
                Thread.Sleep(1);
            }
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned registry lock acquired after deadline.");
            MarkPhase("registry.lock.acquired",clock,deadlineSeconds);
            return stream;
        }
        catch { stream.Dispose(); throw; }
    }
    [DllImport("libc",SetLastError=true)] private static extern int flock(int fd,int operation);
    [DllImport("libc",SetLastError=true)] private static extern int open(string path,int flags,uint mode);
    public static void RegisterAndRelease(int pid,string release,Stopwatch clock,double deadlineSeconds)
    {
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned launch deadline exhausted.");
        var root=Environment.GetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT");
        if(string.IsNullOrEmpty(root)) { File.WriteAllText(release,"go"); return; }
        if(!Path.IsPathFullyQualified(root) || !Directory.Exists(root)) throw new InvalidOperationException("Invalid owned-boundary registry.");
        using(var admission=LockRegistry(root,clock,deadlineSeconds))
        {
            var parent=getsid(Environment.ProcessId);
            var parentToken=ReadStartToken(parent);
            var chain=ReadRegistry(root,clock,deadlineSeconds,out var invalidRegistry);
            if(invalidRegistry) throw new InvalidOperationException("Owned registry invalid; launch denied.");
            var current=Key(parent,parentToken);
            var resolved=false;
            for(var depth=0;depth<64;depth++)
            {
                if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned ancestry deadline exhausted.");
                if(File.Exists(Path.Combine(root,current+".closed"))) throw new InvalidOperationException("Owned boundary admission is closed.");
                var ancestor=chain.Find(x=>Key(x.Pid,x.Token)==current);
                if(ancestor==null) { resolved=true; break; }
                current=Key(ancestor.Parent,ancestor.ParentToken);
            }
            if(!resolved) throw new InvalidOperationException("Owned ancestry depth exceeded; launch denied.");
            var record=new Boundary {Pid=pid,Token=ReadStartToken(pid),Parent=parent,ParentToken=parentToken};
            var path=Path.Combine(root,Key(pid,record.Token)+".json");
            var temporary=path+"."+Guid.NewGuid().ToString("N")+".tmp";
            try
            {
                File.WriteAllText(temporary,JsonSerializer.Serialize(record));
                File.Move(temporary,path);
            }
            finally { if(File.Exists(temporary)) File.Delete(temporary); }
            // Same original clock and admission lock: never release after a stalled admission.
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned launch deadline exhausted before release.");
            File.WriteAllText(release,"go");
        }
    }
    private static List<Boundary> ReadRegistry(string root,Stopwatch clock,double deadlineSeconds,out bool invalid)
    {
        MarkPhase("registry.read.before",clock,deadlineSeconds);
        invalid=false;
        var records=new List<Boundary>();
        var files=0;
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; return records; }
        foreach(var path in Directory.EnumerateFiles(root,"*.json"))
        {
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds || ++files>256) { invalid=true; break; }
            try
            {
                using(var stream=File.OpenRead(path))
                {
                    if(stream.Length==0 || stream.Length>2048) { invalid=true; continue; }
                    var bytes=new byte[2049];
                    var length=0;
                    int read;
                    while(length<bytes.Length && clock.Elapsed.TotalSeconds<deadlineSeconds && (read=stream.Read(bytes,length,bytes.Length-length))>0) length+=read;
                    if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; break; }
                    if(length==0 || length>2048) { invalid=true; continue; }
                    var record=JsonSerializer.Deserialize<Boundary>(new ReadOnlySpan<byte>(bytes,0,length));
                    if(record==null || record.Pid<=0 || record.Parent<=0 || string.IsNullOrEmpty(record.Token) || string.IsNullOrEmpty(record.ParentToken)) { invalid=true; continue; }
                    records.Add(record);
                }
            }
            catch(IOException) { invalid=true; }
            catch(JsonException) { invalid=true; }
            catch(UnauthorizedAccessException) { invalid=true; }
        }
        MarkPhase("registry.read.after",clock,deadlineSeconds,files);
        return records;
    }
    private static List<Boundary> OwnedBoundaries(int pid,string root,Stopwatch clock,double deadlineSeconds,out bool invalid)
    {
        var records=ReadRegistry(root,clock,deadlineSeconds,out invalid);
        if(!OwnerTokens.TryGetValue(pid,out var token)) throw new InvalidOperationException("Missing owner generation identity.");
        var keys=new HashSet<string> {Key(pid,token)};
        var result=new List<Boundary> {new Boundary {Pid=pid,Token=token}};
        for(var depth=0;depth<64;depth++)
        {
            var changed=false;
            foreach(var record in records)
            {
                if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; return result; }
                if(keys.Contains(Key(record.Parent,record.ParentToken)) && keys.Add(Key(record.Pid,record.Token))) { result.Add(record); changed=true; }
            }
            if(!changed) return result;
        }
        invalid=true;
        return result;
    }
    private sealed class ProcessRecord
    {
        public int Pid;
        public int Group;
        public int Session;
        public string Token;
        public bool Zombie;
    }
    private sealed class MembershipSnapshot
    {
        public readonly Dictionary<int,ProcessRecord> Records=new Dictionary<int,ProcessRecord>();
        public readonly List<Exception> Errors=new List<Exception>();
    }
    private static ProcessRecord ReadProcessRecord(string path,int pid)
    {
        var stat=File.ReadAllText(path);
        if(stat.Length>4096) throw new InvalidOperationException("Process stat exceeds observation limit.");
        var fields=stat.Substring(stat.LastIndexOf(')')+2).Split(' ',StringSplitOptions.RemoveEmptyEntries);
        return new ProcessRecord {Pid=pid,Group=int.Parse(fields[2]),Session=int.Parse(fields[3]),Token=fields[19],Zombie=fields[0]=="Z"};
    }
    private static bool ConfirmProcessDisappeared(int pid,Stopwatch clock,double deadlineSeconds)
    {
        // A failed /proc read can report ESRCH as general IOException. Probe only
        // existence (signal zero), never send a signal or infer absence from a path.
        // A live/reused PID or EPERM remains unknown: no generation is inherited.
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) return false;
        var result=kill(pid,0);
        var error=Marshal.GetLastPInvokeError();
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) return false;
        return result==-1 && error==3; // ESRCH is the sole confirmed absence result.
    }
    private static MembershipSnapshot DiscoverMembers(Stopwatch clock,double deadlineSeconds)
    {
        var snapshot=new MembershipSnapshot();
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds)
        {
            snapshot.Errors.Add(new TimeoutException("Owned membership discovery deadline exhausted."));
            return snapshot;
        }
        try
        {
            var entries=0;
            using(var directories=Directory.EnumerateDirectories("/proc").GetEnumerator())
            {
                while(true)
                {
                    if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned membership discovery deadline exhausted.");
                    if(!directories.MoveNext()) break;
                    if(++entries>65536) throw new InvalidOperationException("Process observation count limit exceeded.");
                    var directory=directories.Current;
                    if(!int.TryParse(Path.GetFileName(directory),out var member)) continue;
                    try
                    {
                        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned stat-read deadline exhausted.");
                        var record=ReadProcessRecord(Path.Combine(directory,"stat"),member);
                        snapshot.Records[member]=record;
                    }
                    // Only a kernel entry that vanished is established absent. General
                    // IO/access/parse failures leave membership unknown and fail proof.
                    catch(FileNotFoundException) { }
                    catch(DirectoryNotFoundException) { }
                    catch(IOException error)
                    {
                        if(!ConfirmProcessDisappeared(member,clock,deadlineSeconds)) snapshot.Errors.Add(error);
                    }
                    catch(Exception error) { snapshot.Errors.Add(error); }
                }
            }
        }
        catch(Exception error) { snapshot.Errors.Add(error); }
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) snapshot.Errors.Add(new TimeoutException("Owned membership observation incomplete at deadline."));
        return snapshot;
    }
    private static bool IsCurrentGeneration(Boundary owner)
    {
        try { return ReadStartToken(owner.Pid)==owner.Token; }
        catch(DirectoryNotFoundException) { return true; }
        catch(FileNotFoundException) { return true; }
    }
    private static List<Boundary> GetOwners(int pid,Stopwatch clock,double deadlineSeconds,out bool invalid)
    {
        invalid=false;
        var root=Environment.GetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT");
        if(string.IsNullOrEmpty(root)) return new List<Boundary> {new Boundary {Pid=pid,Token=OwnerTokens[pid]}};
        return OwnedBoundaries(pid,root,clock,deadlineSeconds,out invalid);
    }
    public static int[] RegisteredMemberIds(int pid,Stopwatch clock,double deadlineSeconds)
    {
        MarkPhase("membership.before",clock,deadlineSeconds);
        var owners=GetOwners(pid,clock,deadlineSeconds,out var invalid);
        var snapshot=DiscoverMembers(clock,deadlineSeconds);
        var sessions=new HashSet<int>();
        foreach(var owner in owners)
        {
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; break; }
            if(snapshot.Records.TryGetValue(owner.Pid,out var anchor) && anchor.Token!=owner.Token) { invalid=true; continue; }
            // An absent anchor is permitted only with a complete snapshot. Unknown
            // reads are retained below, never silently certified as a dead anchor.
            sessions.Add(owner.Pid);
        }
        var members=new List<int>();
        foreach(var record in snapshot.Records.Values)
        {
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; break; }
            if(!record.Zombie && sessions.Contains(record.Session)) members.Add(record.Pid);
        }
        MarkPhase("membership.after",clock,deadlineSeconds,snapshot.Records.Count);
        if(invalid || snapshot.Errors.Count>0) throw new AggregateException("Owned membership unknown; cleanup cannot be certified.",snapshot.Errors);
        return members.ToArray();
    }
    private static void SignalKnownGroup(Boundary owner,int group,ProcessRecord witness,Stopwatch clock,double deadlineSeconds,List<Exception> errors)
    {
        try
        {
            if(witness!=null && clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned group signal deadline exhausted before identity read.");
            // Fixed direct identity reads only: no process enumeration in a signal.
            // A live reused anchor or reused witness must never authorize a signal.
            if(!IsCurrentGeneration(owner)) throw new InvalidOperationException("Stale owned generation; refusing reused session signal.");
            if(witness!=null)
            {
                try
                {
                    if(clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned group witness deadline exhausted.");
                    var current=ReadProcessRecord("/proc/"+witness.Pid+"/stat",witness.Pid);
                    if(current.Token!=witness.Token || current.Group!=group || current.Session!=owner.Pid) throw new InvalidOperationException("Owned group witness changed; refusing signal.");
                }
                catch(FileNotFoundException) { throw new InvalidOperationException("Owned group witness disappeared; proof incomplete."); }
                catch(DirectoryNotFoundException) { throw new InvalidOperationException("Owned group witness disappeared; proof incomplete."); }
            }
            if(witness!=null && clock.Elapsed.TotalSeconds>=deadlineSeconds) throw new TimeoutException("Owned group signal deadline exhausted after identity read.");
            if(kill(-group,9)!=0 && Marshal.GetLastWin32Error()!=3) throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        catch(Exception error) { errors.Add(error); }
    }
    public static void KillGroup(int pid,Stopwatch clock,double deadlineSeconds)
    {
        if(!OwnerTokens.TryGetValue(pid,out var token)) throw new InvalidOperationException("Missing root start identity; refusing unsafe signal.");
        var known=new Boundary {Pid=pid,Token=token};
        var owners=new List<Boundary> {known};
        var errors=new List<Exception>();
        var root=Environment.GetEnvironmentVariable("RUNNER_OWNERSHIP_ROOT");
        try
        {
            if(!string.IsNullOrEmpty(root))
            {
                // Atomic files are not an atomic registry inventory. This pre-lock
                // collection is best effort only; failed closure always fails proof.
                owners=OwnedBoundaries(pid,root,clock,deadlineSeconds,out var invalid);
                if(invalid) errors.Add(new InvalidOperationException("Owned registry incomplete before closure."));
                using(var admission=LockRegistry(root,clock,deadlineSeconds))
                {
                    File.WriteAllText(Path.Combine(root,Key(pid,token)+".closed"),"closed");
                    var finalOwners=OwnedBoundaries(pid,root,clock,deadlineSeconds,out invalid);
                    foreach(var owner in finalOwners)
                    {
                        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { invalid=true; break; }
                        if(!owners.Exists(x=>x.Pid==owner.Pid && x.Token==owner.Token)) owners.Add(owner);
                    }
                    if(invalid) errors.Add(new InvalidOperationException("Owned registry invalid or closure discovery expired."));
                }
            }
        }
        catch(Exception error) { errors.Add(error); }
        // Exactly one process snapshot per kill, never one full scan per owner.
        var snapshot=DiscoverMembers(clock,deadlineSeconds);
        errors.AddRange(snapshot.Errors);
        var groups=new Dictionary<int,Dictionary<int,ProcessRecord>>();
        var sessions=new HashSet<int>();
        foreach(var owner in owners) sessions.Add(owner.Pid);
        foreach(var record in snapshot.Records.Values)
        {
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { errors.Add(new TimeoutException("Owned group indexing deadline exhausted.")); break; }
            if(record.Zombie || !sessions.Contains(record.Session)) continue;
            if(!groups.TryGetValue(record.Session,out var sessionGroups)) { sessionGroups=new Dictionary<int,ProcessRecord>(); groups[record.Session]=sessionGroups; }
            sessionGroups[record.Group]=record;
        }
        foreach(var owner in owners)
        {
            // Even expired discovery/closure must attempt each already-known root
            // group. This bounded emergency path performs no additional scan and
            // never certifies cleanup. It does not discover concurrent descendants.
            if(clock.Elapsed.TotalSeconds>=deadlineSeconds) errors.Add(new TimeoutException("Owned signal deadline exhausted; root-only best effort."));
            SignalKnownGroup(owner,owner.Pid,null,clock,deadlineSeconds,errors);
            if(groups.TryGetValue(owner.Pid,out var sessionGroups))
            {
                foreach(var pair in sessionGroups)
                {
                    if(pair.Key==owner.Pid) continue;
                    if(clock.Elapsed.TotalSeconds>=deadlineSeconds) { errors.Add(new TimeoutException("Owned group signal deadline exhausted.")); break; }
                    SignalKnownGroup(owner,pair.Key,pair.Value,clock,deadlineSeconds,errors);
                }
            }
        }
        if(clock.Elapsed.TotalSeconds>=deadlineSeconds) errors.Add(new TimeoutException("Owned cleanup deadline exhausted."));
        if(errors.Count>0) throw new AggregateException("Owned cleanup could not be certified.",errors);
    }
    public void Dispose() { if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; } }
}
