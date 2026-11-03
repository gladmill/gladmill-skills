# Gets AutoCAD out of a prompt by pressing Esc in its window (no COM: COM calls are rejected while AutoCAD waits at a prompt).
# Interactive session only; use run-task.ps1 from SSH.
# Posted WM_KEYDOWN messages to the main window are ignored at a command prompt, so it brings AutoCAD to the foreground and
# sends real keystrokes (SendKeys). A hidden scheduled task (remote mode) is not allowed to take the foreground, so it first
# taps Alt (Windows then lets the caller set the foreground). If AutoCAD still is not in front, it posts Esc to the control that
# has the keyboard focus in AutoCAD's thread (the command line), not to the main window.
. (Join-Path $PSScriptRoot 'common.ps1')
Add-Type -AssemblyName System.Windows.Forms
Initialize-AcadWin   # common.ps1: AutoCAD's frame lookup and window classes come from the shared [AcadDevWin]
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
}
"@
$escFile = Join-Path $script:Out 'esc.txt'
# The first acad.exe that has a frame (an exiting or windowless instance must not hide the live one).
$h = [IntPtr]::Zero
foreach ($p in @(Get-Process acad -EA SilentlyContinue | Sort-Object StartTime -Descending)) {
  $f = [AcadDevWin]::FrameOrBest([uint32]$p.Id); if ($f -ne [IntPtr]::Zero) { $h = $f; break }
}
if ($h -eq [IntPtr]::Zero) { "no AutoCAD window" | Set-Content $escFile; exit 1 }
if ([K]::IsIconic($h)) { [K]::ShowWindow($h, 9) | Out-Null }   # SW_RESTORE
$me = [K]::GetCurrentThreadId()

function Test-Front {
  # AutoCAD is in front when the foreground window is its frame, or a dialog (#32770) the frame owns: real keystrokes then
  # reach the command line or the dialog. Not a floating palette the frame owns (External References, Properties...): Esc
  # sent there stays in the palette and the command line keeps waiting (seen 2026-10-17). Not any window of the process
  # either: an unowned helper window can be in front too.
  $fg = [K]::GetForegroundWindow()
  if ($fg -eq [IntPtr]::Zero) { return $false }
  if ($fg -eq $h) { return $true }
  return ([K]::GetAncestor($fg, 3) -eq $h -and [AcadDevWin]::Cls($fg) -eq '#32770')   # 3 = GA_ROOTOWNER
}
function Set-Front {
  # Windows only lets the foreground owner (or the process that got the last input) hand over focus. Attaching to the
  # foreground thread covers the first case, an Alt tap (key down + up, no menu opens) the second. The Alt tap goes to the
  # window in front, which is never AutoCAD's here (skipped when one of AutoCAD's palettes is in front), so it cannot turn on
  # AutoCAD's ribbon KeyTips and eat an Esc.
  $fg = [K]::GetForegroundWindow()
  $t = if ($fg -ne [IntPtr]::Zero) { [K]::GetWindowThreadProcessId($fg, [IntPtr]::Zero) } else { 0 }
  $att = ($t -ne 0 -and $t -ne $me) -and [K]::AttachThreadInput($me, $t, $true)
  # A palette of AutoCAD's own in front: AutoCAD's process already owns the foreground, so no Alt tap (it could reach AutoCAD)
  $ours = $fg -ne [IntPtr]::Zero -and [K]::GetAncestor($fg, 3) -eq $h
  if (-not $ours) { [K]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [K]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) }   # VK_MENU down, up
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
