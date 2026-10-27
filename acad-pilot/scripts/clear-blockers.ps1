# Clears or reports the dialogs that block AutoCAD's COM automation.
#
# A modal window of AutoCAD's can keep it from answering COM, and an unattended run then dies with a raw
# HRESULT. The kit closes the ones it safely can and names the ones it cannot.
#
# Auto-closed: AutoCAD's "Drawing Recovery" windows, which appear when AutoCAD restarts after a crash with
# unsaved drawings. Only windows of acad.exe itself whose title starts "Drawing Recovery" are closed, with
# WM_CLOSE (a dialog treats it as Cancel); a browser or folder with that title is never touched.
# Trial / sign-in start-up windows are handled by trial-watch.ps1.
# Reported but NOT touched: a Windows Update "restart to install" prompt (another process; it cannot be
# dismissed from this session, see harden-automation-vm.ps1 for a VM you own) and anything that could lose
# work (a "Save changes?" prompt is left alone).
#
# Dot-source for the Clear-Blockers function, or run directly to clear once and print a summary.

Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class CB {
  public delegate bool P(IntPtr h, IntPtr l);
  [DllImport("user32")] public static extern bool EnumWindows(P p, IntPtr l);
  [DllImport("user32")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", EntryPoint="PostMessageW")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static List<string[]> All() { var l = new List<string[]>(); EnumWindows((h, x) => { if (IsWindowVisible(h)) { var t = new StringBuilder(512); GetWindowText(h, t, 512); uint pid; GetWindowThreadProcessId(h, out pid); l.Add(new[] { h.ToString(), pid.ToString(), t.ToString() }); } return true; }, IntPtr.Zero); return l; }
}
"@

function Clear-Blockers {
  # -CloseTitles: titles (regex, start-anchored) of acad.exe windows to close with WM_CLOSE. Default: Drawing Recovery.
  param([string[]]$CloseTitles = @('Drawing Recovery'))
  $closed = @(); $manual = @()
  $names = @{}; Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $names[[string]$_.Id] = $_.Name }
  foreach ($w in [CB]::All()) {
    $title = $w[2]; $proc = $names[$w[1]]
    if ($proc -eq 'acad' -and $title -and ($CloseTitles | Where-Object { $title -match "^$_" })) {
      [CB]::PostMessage([IntPtr][long]$w[0], 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null   # WM_CLOSE
      $closed += $title
    }
    elseif ($proc -match '^(MusNotification|MusNotificationUx|MoNotificationUx)$') {
      $manual += 'Windows Update restart prompt'
    }
  }
  [pscustomobject]@{ closed = @($closed | Select-Object -Unique); manual = @($manual | Select-Object -Unique) }
}

if ($MyInvocation.InvocationName -ne '.') {
  $r = Clear-Blockers
  "closed: $(@($r.closed) -join ', ')"
  "manual: $(@($r.manual) -join ', ')"
}
