# OPTIONAL. Runs in the interactive session (logon task "AcadDevTrialWatch", see install-trial-watch.ps1): closes AutoCAD's trial
# start-up window, which otherwise blocks COM on a fresh trial install. For the first 5 minutes after acad.exe starts it looks at
# every visible top-level window of AutoCAD and the Autodesk licensing/sign-in helpers, logs new ones to <home>\out\startup-windows.log
# (title, class, process) and posts WM_CLOSE (then IDCANCEL) to those whose title looks like the trial screen. Tune -Match from
# the log if a start-up window is missed. The licensing agent's untitled window of class "webview" is closed by process and class.
# It never closes AutoCAD's main window or a drawing window (it skips the acad main frame and 'Autodesk AutoCAD ... - [' titles).
# It never signs in, never enters a licence and does nothing once the window time is over.
param([string]$Match = '(?i)\btrial\b|days? (left|remaining)|subscribe|buy now|free trial', [int]$WindowMinutes = 5, [string]$LicClass = 'webview')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'clear-blockers.ps1')
Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class TW {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", EntryPoint="PostMessageW")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<string[]> All() { var l = new List<string[]>(); EnumWindows((h, x) => { if (IsWindowVisible(h)) { var t = new StringBuilder(512); var c = new StringBuilder(256); GetWindowText(h, t, 512); GetClassName(h, c, 256); uint pid; GetWindowThreadProcessId(h, out pid); l.Add(new[] { h.ToString(), pid.ToString(), c.ToString(), t.ToString() }); } return true; }, IntPtr.Zero); return l; }
}
"@
$log = Join-Path $script:Out 'startup-windows.log'
$procs = '^(acad|AdSSO|AdskIdentityManager|AdskAccess.*|AdskLicensing.*|AutodeskDesktopApp|msedgewebview2)$'
$seen = @{}; $closed = @{}
while ($true) {
  # Close COM-blocking nags whenever they appear (not just in the start-up window): mainly the
  # Drawing Recovery manager after AutoCAD was killed with unsaved drawings.
  $b = Clear-Blockers; foreach ($t in @($b.closed)) { Add-Content $log ("{0:s} cleared blocker [{1}]" -f (Get-Date), $t) }
  $acad = Get-Process acad -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
  if ($acad -and ((Get-Date) - $acad.StartTime).TotalMinutes -lt $WindowMinutes) {
    $mainH = [string][long]$acad.MainWindowHandle
    $names = @{}; Get-Process | ForEach-Object { $names[[string]$_.Id] = $_.Name }
    foreach ($w in [TW]::All()) {
      $name = $names[$w[1]]; if ($name -notmatch $procs) { continue }
      if ($w[0] -eq $mainH -or $w[3] -match '^Autodesk AutoCAD.* - \[') { continue }   # never touch AutoCAD's own frame or a drawing window
      $key = "$($w[0])|$($w[3])"
      if (-not $seen[$key]) { $seen[$key] = 1; Add-Content $log ("{0:s} {1} class={2} title=[{3}]" -f (Get-Date), $name, $w[2], $w[3]) }
      $trial = ($w[3] -match $Match -and $w[3] -notmatch 'UNREGISTERED VERSION') -or ($name -eq 'AdskLicensingAgent' -and $w[2] -eq $LicClass -and $w[3] -eq '')
      if ($trial -and -not $closed[$w[0]]) {
        $h = [IntPtr][long]$w[0]
        [TW]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null          # WM_CLOSE
        Start-Sleep -Milliseconds 500
        [TW]::PostMessage($h, 0x0111, [IntPtr]2, [IntPtr]::Zero) | Out-Null                # WM_COMMAND IDCANCEL
        $closed[$w[0]] = 1; Add-Content $log ("{0:s} closed [{1}] ({2})" -f (Get-Date), $w[3], $name)
      }
    }
  } elseif (-not $acad) { $seen = @{}; $closed = @{} }
  Start-Sleep -Seconds 2
}
