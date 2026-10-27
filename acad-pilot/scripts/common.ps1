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
  param([string]$Script = '', [string]$ScriptArgs = '', [string]$Command = '', [string]$TaskName = 'AcadDevTask', [int]$TimeoutSec = 120)
  # -Command: a raw command line instead of a powershell script (task mode only; no spaces/quotes in it)
  if ((Test-Interactive) -and $Script) {
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + @($ScriptArgs -split ' ' | Where-Object { $_ })
    & powershell @a
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
      Start-Sleep -Milliseconds 500
    }
  } finally {
    schtasks /delete /tn $TaskName /f 2>$null | Out-Null
    $global:LASTEXITCODE = 0   # schtasks' code is not the caller's result: a script that ends here must not exit with it
  }
}

function Register-ComRetry {
  # Makes this thread's COM calls retry while AutoCAD rejects them as busy (RPC_E_CALL_REJECTED, SERVERCALL_RETRYLATER),
  # instead of failing: AutoCAD Electrical rejects calls partway through a long batch even with a drawing open. An OLE message
  # filter retries every 100 ms for up to $env:ACAD_DEV_COM_RETRY_SEC seconds (default 30, 0 = off), then the call fails as
  # before. At a prompt or modal dialog a call therefore fails only after that wait. Needs an STA thread (Windows PowerShell
  # 5.1's default). Returns '' when registered or off, else why not.
  $sec = 30
  if ("$env:ACAD_DEV_COM_RETRY_SEC" -match '^\d+$') { $sec = [int]$env:ACAD_DEV_COM_RETRY_SEC }
  if ($sec -eq 0) { return '' }
  if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { return 'com retry off: not an STA thread' }
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
  if ($hr -ne 0) { return ('com retry off: CoRegisterMessageFilter returned 0x{0:X8}' -f $hr) }
  return ''
}

function Save-Screenshot {
  param([string]$Path)
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
  $bmp.Save($Path); $g.Dispose(); $bmp.Dispose()
}
