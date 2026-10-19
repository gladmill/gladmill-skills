# Runs in the interactive session: posts IDCANCEL to every visible top-level window whose title equals the text in <home>\title.txt
# (written by run-task.ps1 -Title), lists the visible windows, takes a screenshot. A WPF dialog ignores IDCANCEL: use -Close (WM_CLOSE).
param([string]$Title = '', [switch]$Close)
. (Join-Path $PSScriptRoot 'common.ps1')
$out = $script:Out; $res = Join-Path $out 'result.txt'; "" | Set-Content $res
if (-not $Title) { $tf = Join-Path $script:Home_ 'title.txt'; if (Test-Path $tf) { $Title = (Get-Content $tf -Raw).Trim() } }
$cf = Join-Path $script:Home_ 'closeflag.txt'; if (Test-Path $cf) { $Close = $true; Remove-Item $cf }
$msg = if ($Close) { 0x0010 } else { 0x0111 }; $wp = if ($Close) { 0 } else { 2 }
Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class WC {
 public delegate bool EP(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP f, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
 public static List<string> Hits = new List<string>();
 public static void Cancel(string t, uint msg, int wp) { EnumWindows((h,l)=>{ var s=new StringBuilder(256); GetWindowText(h,s,256);
   if (IsWindowVisible(h) && s.Length>0) { Hits.Add(s.ToString()); if (t.Length>0 && s.ToString()==t) { PostMessage(h,msg,(IntPtr)wp,IntPtr.Zero); Hits.Add("  ^ posted"); } } return true; }, IntPtr.Zero); }
}
"@
[WC]::Cancel($Title, [uint32]$msg, $wp); [WC]::Hits | ForEach-Object { Add-Content $res $_ }
Start-Sleep 3
Save-Screenshot (Join-Path $out 'screen.png')
'done' | Set-Content (Join-Path $out 'done.txt')
