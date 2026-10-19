# Gets AutoCAD out of a prompt by pressing Esc in its window (no COM: COM calls are rejected while AutoCAD waits at a prompt).
# Interactive session only; use run-task.ps1 from SSH.
# Posted WM_KEYDOWN messages to the main window are ignored at a command prompt, so it brings AutoCAD to the foreground and
# sends real keystrokes (SendKeys). A hidden scheduled task (remote mode) is not allowed to take the foreground, so it first
# taps Alt (Windows then lets the caller set the foreground). If AutoCAD still is not in front, it posts Esc to the control that
# has the keyboard focus in AutoCAD's thread (the command line), not to the main window.
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class K {
  [DllImport("user32")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32")] public static extern IntPtr GetFocus();
  [DllImport("user32")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
  [DllImport("user32")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr p);
  [DllImport("user32")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("user32")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("kernel32")] public static extern uint GetCurrentThreadId();
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32")] static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  // AutoCAD's frame: a visible, unowned top-level window of the process, titled "Autodesk AutoCAD ..." when there is one.
  // Process.MainWindowHandle is not reliable here: it can be an untitled WPF helper window, and Esc sent there is lost.
  public static IntPtr Frame(uint pid) {
    IntPtr best = IntPtr.Zero, any = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;   // 4 = GW_OWNER
      var t = new System.Text.StringBuilder(512); GetWindowText(h, t, 512);
      if (t.ToString().StartsWith("Autodesk AutoCAD")) { best = h; return false; }
      if (any == IntPtr.Zero && t.Length > 0) any = h;
      return true;
    }, IntPtr.Zero);
    return best != IntPtr.Zero ? best : any;
  }
}
"@
$escFile = Join-Path $script:Out 'esc.txt'
# The first acad.exe that has a frame (an exiting or windowless instance must not hide the live one).
$h = [IntPtr]::Zero
foreach ($p in @(Get-Process acad -EA SilentlyContinue | Sort-Object StartTime -Descending)) {
  $f = [K]::Frame([uint32]$p.Id); if ($f -ne [IntPtr]::Zero) { $h = $f; break }
}
if ($h -eq [IntPtr]::Zero) { "no AutoCAD window" | Set-Content $escFile; exit 1 }
if ([K]::IsIconic($h)) { [K]::ShowWindow($h, 9) | Out-Null }   # SW_RESTORE
$me = [K]::GetCurrentThreadId()

function Test-Front {
  # AutoCAD is in front when the foreground window is its frame or a window the frame owns (a dialog, a floating palette):
  # real keystrokes then reach AutoCAD. Not any window of the process: an unowned helper window can be in front too.
  $fg = [K]::GetForegroundWindow()
  return ($fg -ne [IntPtr]::Zero -and ($fg -eq $h -or [K]::GetAncestor($fg, 3) -eq $h))   # 3 = GA_ROOTOWNER
}
function Set-Front {
  # Windows only lets the foreground owner (or the process that got the last input) hand over focus. Attaching to the
  # foreground thread covers the first case, an Alt tap (key down + up, no menu opens) the second. The Alt tap goes to the
  # window in front, which is never AutoCAD here (Set-Front only runs when AutoCAD is not in front), so it cannot turn on
  # AutoCAD's ribbon KeyTips and eat an Esc.
  $fg = [K]::GetForegroundWindow()
  $t = if ($fg -ne [IntPtr]::Zero) { [K]::GetWindowThreadProcessId($fg, [IntPtr]::Zero) } else { 0 }
  $att = ($t -ne 0 -and $t -ne $me) -and [K]::AttachThreadInput($me, $t, $true)
  [K]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [K]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # VK_MENU down, up
  [K]::BringWindowToTop($h) | Out-Null
  [K]::SetForegroundWindow($h) | Out-Null
  if ($att) { [K]::AttachThreadInput($me, $t, $false) | Out-Null }
  Start-Sleep -Milliseconds 300
  return (Test-Front)
}

$front = Test-Front
if (-not $front) { $front = Set-Front }
if (-not $front) { $front = Set-Front }
if ($front) {
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}{ESC}')
  "esc via sendkeys to $h (foreground: True)" | Set-Content $escFile
  exit 0
}
# Fallback: post Esc to AutoCAD's focused control (attach to AutoCAD's thread to read its focus).
$at = [K]::GetWindowThreadProcessId($h, [IntPtr]::Zero)
$target = $h
if ([K]::AttachThreadInput($me, $at, $true)) {
  $f = [K]::GetFocus(); if ($f -ne [IntPtr]::Zero) { $target = $f }
  [K]::AttachThreadInput($me, $at, $false) | Out-Null
}
foreach ($i in 1..2) {   # key down + up only: the message loop's TranslateMessage makes the WM_CHAR
  [K]::PostMessage($target, 0x0100, [IntPtr]0x1B, [IntPtr]0x00010001) | Out-Null   # WM_KEYDOWN
  [K]::PostMessage($target, 0x0101, [IntPtr]0x1B, [IntPtr]0xC0010001) | Out-Null   # WM_KEYUP
}
"esc via posted to $target (foreground: False; AutoCAD could not be brought to the front, check with a query or shot)" | Set-Content $escFile
exit 2
