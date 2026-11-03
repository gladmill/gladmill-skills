# Shared helpers, dot-sourced by the other scripts:  . (Join-Path $PSScriptRoot 'common.ps1')
# Work folder: $env:ACAD_DEV_HOME, default %USERPROFILE%\acad-dev. Output goes to <home>\out.
# In remote mode set ACAD_DEV_HOME as a USER environment variable (setx) so scheduled tasks see it too.
$script:Home_ = if ($env:ACAD_DEV_HOME) { $env:ACAD_DEV_HOME } else { Join-Path $env:USERPROFILE 'acad-dev' }
$script:Out = Join-Path $script:Home_ 'out'
New-Item -ItemType Directory -Force $script:Out | Out-Null

function Test-Interactive {
  # Session 0 (services, SSH) has no desktop. Any other session (console, RDP) is interactive.
  # ACAD_DEV_FORCE_TASK=1 forces the scheduled-task path (for testing).
  if ($env:ACAD_DEV_FORCE_TASK -eq '1') { return $false }
  return ([Diagnostics.Process]::GetCurrentProcess().SessionId -ne 0)
}

function Find-Acad {
  # acad.exe: $env:ACAD_DEV_EXE, else the newest 2024-2026 install found in the registry, else Program Files.
  if ($env:ACAD_DEV_EXE -and (Test-Path $env:ACAD_DEV_EXE)) { return $env:ACAD_DEV_EXE }
  $found = @()
  foreach ($rel in 'R24.3', 'R25.0', 'R25.1') {   # 2024, 2025, 2026
    $root = "HKLM:\SOFTWARE\Autodesk\AutoCAD\$rel"
    if (-not (Test-Path $root)) { continue }
    foreach ($k in Get-ChildItem $root -EA SilentlyContinue) {
      $loc = (Get-ItemProperty $k.PSPath -EA SilentlyContinue).AcadLocation
      if ($loc -and (Test-Path (Join-Path $loc 'acad.exe'))) { $found += [pscustomobject]@{ Rel = $rel; Exe = (Join-Path $loc 'acad.exe') } }
    }
  }
  if ($found) { return ($found | Sort-Object Rel | Select-Object -Last 1).Exe }
  foreach ($y in 2026, 2025, 2024) {
    $p = "C:\Program Files\Autodesk\AutoCAD $y\acad.exe"; if (Test-Path $p) { return $p }
  }
  return $null
}

function Invoke-InSession {
  # Runs "powershell -File <script> <args>" in the interactive session and waits for it.
  #  - interactive caller: runs it directly.
  #  - session 0 (SSH): one-shot scheduled task with /it, started, polled until it stops, deleted.
  # Task arguments must not contain spaces or quotes (schtasks /tr mangles them); pass data through files in <home>.
  param([string]$Script = '', [string]$ScriptArgs = '', [string]$Command = '', [string]$TaskName = 'AcadDevTask', [int]$TimeoutSec = 120,
        [scriptblock]$OnPoll = $null)
  # -Command: a raw command line instead of a powershell script (task mode only; no spaces/quotes in it)
  # -OnPoll: called about every 0.5 s while it runs; returning $true stops waiting (task mode: the task keeps running; interactive: the worker is ended)
  if ((Test-Interactive) -and $Script) {
    # A process of its own with its output in files, so the timeout (and -OnPoll) hold here too: a worker stuck in a COM call
    # that waits for a dialog is ended after $TimeoutSec instead of hanging this script for ever. -OnPoll returning $true is the
    # stall path: the worker is ended too (task mode leaves it running), $script:WorkerKilled says so, and the exit code is left alone.
    $killed = $false; $entryCode = $global:LASTEXITCODE   # per call: a nested Invoke-InSession (from -OnPoll) must not change this call's result
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"") + @($ScriptArgs -split ' ' | Where-Object { $_ })
    $tag = [guid]::NewGuid().ToString('N'); $so = Join-Path $script:Out "iis-$tag.out"; $se = Join-Path $script:Out "iis-$tag.err"
    $psExe = if ($env:ACAD_DEV_PS_EXE) { $env:ACAD_DEV_PS_EXE } else { 'powershell' }   # ACAD_DEV_PS_EXE: for tests only
    $sp = @{ FilePath = $psExe; ArgumentList = $a; PassThru = $true; RedirectStandardOutput = $so; RedirectStandardError = $se }
    if ($IsWindows -ne $false) { $sp.WindowStyle = 'Hidden' }   # ($IsWindows is $null in Windows PowerShell 5.1)
    $p = Start-Process @sp
    $null = $p.Handle   # keep the process handle open: without it ExitCode can read empty once the process has ended
    $deadline = (Get-Date).AddSeconds($TimeoutSec); $timedOut = $false; $stoppedWaiting = $false
    while (-not $p.HasExited) {
      if ((Get-Date) -gt $deadline) { $timedOut = $true; break }
      if ($OnPoll -and (& $OnPoll)) { $stoppedWaiting = $true; break }
      Start-Sleep -Milliseconds 300
    }
    if ($timedOut -or $stoppedWaiting) {
      $killed = $true
      if (Get-Command taskkill -EA SilentlyContinue) { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null } else { Stop-Process -Id $p.Id -Force -EA SilentlyContinue }
      [void]$p.WaitForExit(5000)   # its files are not read or removed while it still holds them
    }
    $enc = try { [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) } catch { [Text.Encoding]::Default }
    foreach ($f in $so, $se) {
      if (Test-Path $f) { $t = try { $fs = New-Object IO.FileStream($f, 'Open', 'Read', 'ReadWrite'); try { (New-Object IO.StreamReader($fs, $enc)).ReadToEnd() } finally { $fs.Dispose() } } catch { '' }; if ($t) { $t -split "`r?`n" | Where-Object { $_ -ne '' } }; Remove-Item $f -Force -EA SilentlyContinue }
    }
    if ($timedOut) { 'TIMEOUT waiting for the task' }
    $script:WorkerKilled = $killed
    $global:LASTEXITCODE = $(if ($killed) { $entryCode } else { $p.ExitCode })   # the child's own code, exactly; left alone when it was ended
    return
  }
  if ("$Script$($script:Home_)" -match '\s') { throw "Remote mode: the scripts folder and ACAD_DEV_HOME must not contain spaces ($Script, $($script:Home_))" }
  $vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
  $tr = if ($Command) { "wscript //B //Nologo $vbs $Command" } else { "wscript //B //Nologo $vbs powershell -NoProfile -ExecutionPolicy Bypass -File $Script $ScriptArgs".Trim() }
  $created = schtasks /create /tn $TaskName /tr $tr /sc once /st 00:00 /it /f /rl limited 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "schtasks /create failed ($LASTEXITCODE) for ${TaskName}: $($created.Trim())" }
  try {
    $ran = schtasks /run /tn $TaskName 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "schtasks /run failed ($LASTEXITCODE) for ${TaskName}: $($ran.Trim())" }
    Start-Sleep -Seconds 1
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
      # finished = not Running AND it has actually run (a fresh task reports result 267011 "has not run yet" until then)
      $t = Get-ScheduledTask -TaskName $TaskName -EA SilentlyContinue
      $i = Get-ScheduledTaskInfo -TaskName $TaskName -EA SilentlyContinue
      if ($t -and $i -and $t.State -ne 'Running' -and $i.LastTaskResult -ne 267011 -and $i.LastRunTime.Year -gt 2000) { break }
      if ((Get-Date) -gt $deadline) { 'TIMEOUT waiting for the task'; break }
      if ($OnPoll -and (& $OnPoll)) { break }
      Start-Sleep -Milliseconds 500
    }
  } finally {
    schtasks /delete /tn $TaskName /f 2>$null | Out-Null
    $global:LASTEXITCODE = 0   # schtasks' code is not the caller's result: a script that ends here must not exit with it
  }
}

function Get-AcadState {
  # One readiness probe (acad-ready.ps1) in the interactive session: 'ready', 'busy' (answers COM, not quiescent: a command,
  # prompt or dialog is active), 'none: <reason>', or 'none: no answer' when the probe got no reply within TimeoutSec (AutoCAD
  # computing; that probe process may still answer later, into its own file). -Tag: a file per probe, see acad-ready.ps1.
  param([int]$TimeoutSec = 30, [string]$Tag = '')
  $f = Join-Path $script:Out $(if ($Tag) { "ready-$Tag.txt" } else { 'ready.txt' })
  Remove-Item $f -EA SilentlyContinue
  $a = if ($Tag) { "-Tag $Tag" } else { '' }
  Invoke-InSession -Script (Join-Path $PSScriptRoot 'acad-ready.ps1') -ScriptArgs $a -TaskName 'AcadDevReady' -TimeoutSec $TimeoutSec | Out-Null
  if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { 'none: no answer' }
}

function Initialize-AcadWin {
  # Loads the kit's one Win32 window helper, [AcadDevWin] (EnumWindows, window classes / titles / texts, AutoCAD's main frame, WM_CLOSE /
  # IDCANCEL / BM_CLICK). Every script that looks at windows uses this one, not a copy of its own. Compiled once per process, on first use.
  # Window KIND (dialog, messagebox, winforms, wpf) is decided by Get-WindowKind in blocker-policy.ps1, not here.
  if ('AcadDevWin' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class AcadDevWindow { public IntPtr H; public uint Pid; public IntPtr Owner; public string Cls = ""; public string Title = ""; public bool Visible, Enabled, Topmost, Cloaked; public int L, T, R, B, Z; }
public class AcadDevKid { public IntPtr H; public string Cls = ""; public string Text = ""; public int Style; public bool Visible; }
public static class AcadDevWin {
  delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EP f, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EP f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW", CharSet = CharSet.Unicode)] static extern IntPtr SMT(IntPtr h, uint m, IntPtr w, StringBuilder l, uint f, uint t, out IntPtr r);
  [DllImport("user32.dll", EntryPoint = "SendMessageTimeoutW")] static extern IntPtr SMT0(IntPtr h, uint m, IntPtr w, IntPtr l, uint f, uint t, out IntPtr r);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int n);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  public static bool IsVisible(IntPtr h) { return IsWindowVisible(h); }
  public static bool IsEnabled(IntPtr h) { return IsWindowEnabled(h); }
  public static bool Exists(IntPtr h) { return IsWindow(h); }
  public static string Cls(IntPtr h) { var s = new StringBuilder(256); GetClassName(h, s, 256); return s.ToString(); }
  public static string Caption(IntPtr h) { var s = new StringBuilder(512); GetWindowText(h, s, 512); return s.ToString(); }
  // a control's text, also across processes; times out instead of hanging on a busy owner
  public static string Text(IntPtr h) {
    IntPtr r; IntPtr n = SMT0(h, 0x000E, IntPtr.Zero, IntPtr.Zero, 2, 1500, out r);
    if (n == IntPtr.Zero || r.ToInt32() <= 0) return "";
    var b = new StringBuilder(r.ToInt32() + 2); IntPtr r2; SMT(h, 0x000D, new IntPtr(r.ToInt32() + 1), b, 2, 1500, out r2); return b.ToString();
  }
  // all top-level windows (visible or not), front to back (EnumWindows order is the z-order)
  public static List<AcadDevWindow> Tops() {
    var l = new List<AcadDevWindow>(); int z = 0;
    EnumWindows(delegate (IntPtr h, IntPtr x) {
      var w = new AcadDevWindow(); w.H = h; GetWindowThreadProcessId(h, out w.Pid); w.Owner = GetWindow(h, 4); w.Cls = Cls(h); w.Title = Caption(h);
      w.Visible = IsWindowVisible(h); w.Enabled = IsWindowEnabled(h); w.Topmost = (GetWindowLong(h, -20) & 8) != 0;
      int c = 0; try { DwmGetWindowAttribute(h, 14, out c, 4); } catch (Exception) { } w.Cloaked = c != 0;
      RECT r; GetWindowRect(h, out r); w.L = r.L; w.T = r.T; w.R = r.R; w.B = r.B; w.Z = z++; l.Add(w); return true; }, IntPtr.Zero);
    return l;
  }
  // handles of one process's top-level windows (visible or not), front to back; cheaper than Tops()
  public static List<IntPtr> HandlesOf(uint pid) {
    var l = new List<IntPtr>();
    EnumWindows(delegate (IntPtr h, IntPtr x) { uint p; GetWindowThreadProcessId(h, out p); if (p == pid) l.Add(h); return true; }, IntPtr.Zero);
    return l;
  }
  public static List<AcadDevKid> Kids(IntPtr p) {
    var l = new List<AcadDevKid>();
    EnumChildWindows(p, delegate (IntPtr h, IntPtr x) {
      var k = new AcadDevKid(); k.H = h; k.Cls = Cls(h); k.Style = GetWindowLong(h, -16); k.Visible = IsWindowVisible(h); k.Text = Text(h); l.Add(k); return true; }, IntPtr.Zero);
    return l;
  }
  // AutoCAD's main frame: the visible, unowned top-level window of MFC's frame class (AfxMDIFrame140u on 2024-2026) among the
  // given processes; IntPtr.Zero when there is none (still starting). Message boxes are #32770, the WPF helper is HwndWrapper.
  public static IntPtr FrameOf(uint[] pids) {
    IntPtr found = IntPtr.Zero;
    EnumWindows(delegate (IntPtr h, IntPtr x) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (Array.IndexOf(pids, p) < 0 || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;   // 4 = GW_OWNER
      if (Cls(h).StartsWith("AfxMDIFrame", StringComparison.OrdinalIgnoreCase)) { found = h; return false; }
      return true; }, IntPtr.Zero);
    return found;
  }
  // The same, with fallbacks for the keyboard driver (esc.ps1), which needs some window to aim at: a title that starts like a frame's
  // ("Autodesk AutoCAD 2026 - ...", a vertical's "AutoCAD Electrical 2026 - ..."; not "AutoCAD Message"), then any titled window.
  // Process.MainWindowHandle is not reliable here: it can be an untitled WPF helper window, and Esc sent there is lost.
  public static IntPtr FrameOrBest(uint pid) {
    IntPtr frame = FrameOf(new uint[] { pid });
    if (frame != IntPtr.Zero) return frame;
    IntPtr titled = IntPtr.Zero, any = IntPtr.Zero;
    var frameTitle = new System.Text.RegularExpressions.Regex(@"^(Autodesk )?AutoCAD\b.*\b20\d\d\b");
    EnumWindows(delegate (IntPtr h, IntPtr x) {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;
      string t = Caption(h);
      if (titled == IntPtr.Zero && frameTitle.IsMatch(t)) titled = h;
      if (any == IntPtr.Zero && t.Length > 0) any = h;
      return true; }, IntPtr.Zero);
    return titled != IntPtr.Zero ? titled : any;
  }
  public static void Close(IntPtr h) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }        // WM_CLOSE
  public static void Cancel(IntPtr h) { PostMessage(h, 0x0111, new IntPtr(2), IntPtr.Zero); }     // WM_COMMAND IDCANCEL
  public static void Click(IntPtr b) { PostMessage(b, 0x00F5, IntPtr.Zero, IntPtr.Zero); }        // BM_CLICK
}
'@
}

. (Join-Path $PSScriptRoot 'blocker-policy.ps1')   # Test-ComRejected and the allowlist / denylist functions

function Test-BlockerAutoAction {
  # The guard applies allowlisted actions on its own (stalls, timeouts, rejected COM calls) unless ACAD_DEV_BLOCKER_ACTIONS=0.
  return ("$env:ACAD_DEV_BLOCKER_ACTIONS".Trim() -ne '0')
}

function Close-RecoveryWindows {
  # Up front, before attaching: closes AutoCAD's "Drawing Recovery" windows by the guard's built-in rule (same policy, so a blockers.txt
  # `report` line or ACAD_DEV_BLOCKER_ACTIONS=0 keeps them open). A cheap title scan of acad.exe's own windows, no report, no screenshot,
  # no scheduled task; a restart after a crash that reopens a drawing must not cost the COM retry window. Returns the titles closed.
  # WM_CLOSE (a dialog treats it as Cancel: nothing is saved or deleted). Never throws.
  try {
    if (-not (Test-BlockerAutoAction)) { return @() }
    $acadPids = @(Get-Process acad -EA SilentlyContinue | ForEach-Object { [uint32]$_.Id })
    if (-not $acadPids) { return @() }
    Initialize-AcadWin
    $policyFile = if ($env:ACAD_DEV_BLOCKERS_FILE) { $env:ACAD_DEV_BLOCKERS_FILE } else { Join-Path $script:Home_ 'blockers.txt' }
    $rules = @((ConvertFrom-BlockerPolicy $(if (Test-Path $policyFile) { Get-Content $policyFile -Encoding UTF8 } else { @() })).Rules)
    $closed = @()
    foreach ($w in @([AcadDevWin]::Tops() | Where-Object { $_.Visible -and $_.Pid -in $acadPids -and $_.Title -match '^\s*Drawing Recovery' })) {
      $win = [pscustomobject]@{ Title = $w.Title; Class = $w.Cls; Kind = 'window'; Texts = @(); Buttons = @() }
      if ((Resolve-BlockerAction $win $rules).Action -eq 'close') { [AcadDevWin]::Close($w.H); $closed += $w.Title }
    }
    if ($closed) { Start-Sleep -Milliseconds 700 }
    return @($closed)
  } catch { return @() }
}

function Get-BlockerReport {
  # Looks at what is blocking AutoCAD (blocker-worker.ps1 in the interactive session) and returns Blocked (bool), Windows, Applied
  # (allowlisted actions that worked) and Text (the report, "BLOCKED BY: ..." first when something blocks). -Apply: also do what
  # the allowlist says (never for denylisted windows). Never throws; bounded by -TimeoutSec.
  param([switch]$Apply, [switch]$NoShot, [int]$TimeoutSec = 60)
  # each call has its own result file and scheduled-task name, so two guards at once never read or delete each other's
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 12); $why = ''
  $f = Join-Path $script:Out "blockers-$tag.txt"
  $al = @(); if ($Apply) { $al += '-Apply' }; if ($NoShot) { $al += '-NoShot' }; $al += "-Tag $tag"   # (not @($(if ...)): Windows PowerShell 5.1 drops the elements of such a list)
  $a = $al -join ' '
  try { Invoke-InSession -Script (Join-Path $PSScriptRoot 'blocker-worker.ps1') -ScriptArgs $a -TaskName "AcadDevBlockers$tag" -TimeoutSec $TimeoutSec | Out-Null } catch { $why = $_.Exception.Message.Split("`n")[0] }
  $text = if (Test-Path $f) { "$(Get-Content $f -Raw -Encoding UTF8)".Trim() } else { '' }
  Remove-Item $f -Force -EA SilentlyContinue
  if ($text -match '(?m)^BLOCKERS blocked=(\d) windows=(\d+) applied=(\d+)') {
    $body = ($text -split "`r?`n" | Select-Object -Skip 1) -join "`n"
    return [pscustomobject]@{ Blocked = ($Matches[1] -eq '1'); Windows = [int]$Matches[2]; Applied = [int]$Matches[3]; Text = $body }
  }
  [pscustomobject]@{ Blocked = $false; Windows = 0; Applied = 0; Text = "blocker check gave no result (the check itself timed out or failed$(if ($why) { ': ' + $why })); run blockers.ps1 or take a screenshot" }
}

function Invoke-Guarded {
  # Runs a COM operation; if AutoCAD still rejects it (after the retry window), looks for the blocking window: allowlisted
  # windows are dealt with and the operation is tried once more; otherwise throws the "BLOCKED BY: ..." report.
  # Only for operations that are safe to repeat after a rejection (a rejected call did not run).
  # -Current: returns $false once the run was stopped or replaced; then nothing is applied and nothing is resent.
  param([scriptblock]$Op, [string]$What = 'a COM call', [scriptblock]$Current = $null)
  try { return (& $Op) } catch {
    if (-not (Test-ComRejected $_)) { throw }
    $first = $_
    if ($Current -and -not (& $Current)) { throw "$What was rejected and this run is no longer current: not retried" }
    $g = Get-BlockerReport -Apply:(Test-BlockerAutoAction) -TimeoutSec 40
    $script:BlockerReported = $true   # the error below carries (or deliberately lacks) the report: callers must not add a second one
    if ($g.Applied -gt 0) {
      Start-Sleep -Seconds 1
      if ($Current -and -not (& $Current)) { throw "${What}: this run is no longer current after the guard dealt with a window: not resent" }
      try { return (& $Op) } catch {
        if (-not (Test-ComRejected $_)) { throw }
        $g = Get-BlockerReport -TimeoutSec 40
        throw "$What was still rejected after the allowlist dealt with a window.`n$($g.Text)"
      }
    }
    throw "$What was rejected by AutoCAD.`n$($g.Text)"   # also when nothing blocks: the report then shows the command line state
  }
}

function Register-ComRetry {
  # Makes this thread's COM calls retry while AutoCAD rejects them as busy (RPC_E_CALL_REJECTED, SERVERCALL_RETRYLATER),
  # instead of failing: AutoCAD Electrical rejects calls partway through a long batch and right after closing drawings. An
  # OLE message filter retries every 100 ms for up to $env:ACAD_DEV_COM_RETRY_SEC seconds (default 30, 0 = off, at most 600),
  # then the call fails as before. A call blocked by a modal dialog can take that long to fail; a call made while a command
  # waits at a prompt is not rejected, it hangs until the prompt is answered (Esc). Needs an STA thread (Windows PowerShell
  # 5.1's default). For the kit's own one-shot workers: the filter stays for the life of the process and replaces any filter
  # already on the thread. Never throws; returns '' when registered as set, else a note to log.
  $sec = 30; $note = ''
  $v = "$env:ACAD_DEV_COM_RETRY_SEC".Trim()
  if ($v) {
    if ($v -match '^\d{1,6}$' -and [int]$v -le 600) { $sec = [int]$v }
    else { $note = "ACAD_DEV_COM_RETRY_SEC='$v' ignored (whole seconds 0-600); " }
  }
  if ($sec -eq 0) { return "${note}com retry off (ACAD_DEV_COM_RETRY_SEC=0)" }
  if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return "${note}com retry off: not an STA thread" }
  try {
    if (-not ('AcadDevComRetry' -as [type])) {
      Add-Type @'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("00000016-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAcadDevMessageFilter {
  [PreserveSig] int HandleInComingCall(int callType, IntPtr caller, int tick, IntPtr info);
  [PreserveSig] int RetryRejectedCall(IntPtr callee, int elapsedMs, int rejectType);
  [PreserveSig] int MessagePending(IntPtr callee, int elapsedMs, int pendingType); }
public class AcadDevComRetry : IAcadDevMessageFilter {
  [DllImport("ole32.dll")] static extern int CoRegisterMessageFilter(IAcadDevMessageFilter f, out IAcadDevMessageFilter old);
  public static int MaxMs = 30000;
  public static int Register() { IAcadDevMessageFilter old; return CoRegisterMessageFilter(new AcadDevComRetry(), out old); }
  public int HandleInComingCall(int callType, IntPtr caller, int tick, IntPtr info) { return 0; }   // SERVERCALL_ISHANDLED
  // rejectType 2 = SERVERCALL_RETRYLATER (busy): retry in 100 ms until MaxMs; anything else (or -1) cancels the call
  public int RetryRejectedCall(IntPtr callee, int elapsedMs, int rejectType) { return (rejectType == 2 && elapsedMs < MaxMs) ? 100 : -1; }
  public int MessagePending(IntPtr callee, int elapsedMs, int pendingType) { return 2; }   // PENDINGMSG_WAITDEFPROCESS
}
'@
    }
    [AcadDevComRetry]::MaxMs = $sec * 1000
    $hr = [AcadDevComRetry]::Register()
  } catch { return "${note}com retry off: $($_.Exception.Message.Split("`n")[0])" }
  if ($hr -ne 0) { return ("${note}com retry off: CoRegisterMessageFilter returned 0x{0:X8}" -f $hr) }
  return $note.TrimEnd('; ')
}

function Get-AcadSdi {
  # AutoCAD's SDI system variable as an int: 0 = multiple drawings (MDI); non-zero = single-drawing mode (1 set by the user;
  # 2, 3 forced by a loaded app, read-only). 0 with no drawing open (ActiveDocument throws then, and that only happens in MDI).
  # Any other failure throws: guessing 0 would make the close-all queries Close() the only drawing, which quits AutoCAD in SDI.
  # In SDI mode AutoCAD always keeps exactly one drawing and Documents.Add() / Close() don't work as in MDI.
  param($Acad)
  if ($Acad.Documents.Count -eq 0) { return 0 }
  [int]$Acad.ActiveDocument.GetVariable('SDI')
}

function Save-Screenshot {
  param([string]$Path)
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
  $bmp.Save($Path); $g.Dispose(); $bmp.Dispose()
}
