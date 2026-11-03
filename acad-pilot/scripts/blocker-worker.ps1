# Runs in the interactive session (started by blockers.ps1; session 0 has no windows to look at). Lists what is blocking AutoCAD:
# its dialogs and message boxes (Win32, MFC, DCL, WinForms, WPF; modal and modeless), Autodesk licensing helper windows, other
# programs' windows in front of AutoCAD, the main frame's state and the command line state over COM (if COM answers within 8 s).
# Optionally applies the allowlist and the built-in Drawing Recovery rule (-Apply). Writes <home>\out\blockers.txt (first line: "BLOCKERS blocked=0|1 windows=N applied=K")
# and a screenshot <home>\out\blockers.png. Read-only unless -Apply; even then only allowlisted windows, never the denylist
# (blocker-policy.ps1: security prompts, licence / sign-in / trial screens, save-changes prompts).
#   -Apply   close / press a button in windows the allowlist (<home>\blockers.txt, or ACAD_DEV_BLOCKERS_FILE) names, and close Drawing Recovery windows
#   -NoShot  skip the screenshot
#   -Tag t   write out\blockers-<t>.txt instead of blockers.txt (each caller has its own result file)
param([switch]$Apply, [switch]$NoShot, [string]$Tag = '')
. (Join-Path $PSScriptRoot 'common.ps1')
$resFile = Join-Path $script:Out $(if ($Tag -match '^[0-9a-fA-F]{1,32}$') { "blockers-$Tag.txt" } else { 'blockers.txt' })
$lockFile = Join-Path $script:Out 'blockers.lock'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Initialize-AcadWin   # common.ps1: the kit's one window helper, [AcadDevWin]

$lines = New-Object System.Collections.Generic.List[string]
function L([string]$s) { $lines.Add($s) }
$policyFile = if ($env:ACAD_DEV_BLOCKERS_FILE) { $env:ACAD_DEV_BLOCKERS_FILE } else { Join-Path $script:Home_ 'blockers.txt' }
$policy = ConvertFrom-BlockerPolicy $(if (Test-Path $policyFile) { Get-Content $policyFile -Encoding UTF8 } else { @() })
$rules = @($policy.Rules)
$licProcs = '^(AdSSO|AdskIdentityManager|AdskAccess.*|AdskLicensing.*|AutodeskDesktopApp|AutodeskAccess.*)$'
# programs that are often in front of AutoCAD without blocking it (the terminal this runs from, the shell)
$ignoreForeign = '^(powershell|pwsh|WindowsTerminal|OpenConsole|conhost|cmd|explorer|wscript|ShellExperienceHost|SearchHost|SearchApp|StartMenuExperienceHost|TextInputHost|ApplicationFrameHost|LockApp|dwm|ctfmon|sihost|RuntimeBroker|claude|Code)$'

$acadProcs = @(Get-Process acad -EA SilentlyContinue)
$acadPids = @($acadProcs | ForEach-Object { [uint32]$_.Id })
$names = @{}; Get-Process | ForEach-Object { $names[[uint32]$_.Id] = $_.ProcessName }

function Get-Uia($h) {
  # texts and buttons through UI Automation (WPF, WinForms, task dialogs): one FindAll over Text and Button elements only, capped
  $texts = @(); $buttons = @()
  try {
    $AE = [System.Windows.Automation.AutomationElement]; $CT = [System.Windows.Automation.ControlType]
    $cond = New-Object System.Windows.Automation.OrCondition(
      (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Text)),
      (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, $CT::Button)))
    $root = $AE::FromHandle($h)
    foreach ($e in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
      if ($texts.Count + $buttons.Count -ge 150) { break }
      $n = "$($e.Current.Name)".Trim()
      if (-not $n -or $e.Current.IsOffscreen) { continue }
      if ($e.Current.ControlType.Id -eq $CT::Text.Id) { $texts += $n } else { $buttons += $n }
    }
  } catch { }
  [pscustomobject]@{ Texts = @($texts | Select-Object -Unique); Buttons = @($buttons | Select-Object -Unique) }
}

function Get-Blockers {
  $all = [AcadDevWin]::Tops()
  $frame = [AcadDevWin]::FrameOf($all, [uint32[]]$acadPids)   # from the same snapshot
  $out = @(); $foreign = @(); $update = @()
  foreach ($w in $all) {
    if (-not $w.Visible -or $w.Cloaked) { continue }
    $pname = $names[$w.Pid]
    $acadOwned = $w.Pid -in $acadPids
    if ($acadOwned) {
      if ($frame -and $w.H -eq $frame.H) { continue }
      if (Test-DrawingWindow $w.Title) { continue }   # a drawing window
      $isDlg = Test-DialogWindow $w.Cls $w.Title
      if (-not $isDlg -and (Test-RecoveryWindow $w.Title)) { $isDlg = $true }   # whatever its window class: the built-in rule closes it
      if (-not $isDlg) { continue }
      $texts = @(); $buttons = @(); $hasInput = $false
      $kids = if ($w.Cls -eq '#32770' -or $w.Cls -like 'adesk_dlg*') { @([AcadDevWin]::Kids($w.H)) } else { @() }
      if ($kids -and -not ($kids | Where-Object { $_.Cls -eq 'DirectUIHWND' })) {
        foreach ($k in $kids) {
          if (-not $k.Visible) { continue }
          if ([AcadDevWin]::IsInputClass($k.Cls)) { $hasInput = $true }
          elseif ($k.Cls -eq 'Static' -and $k.Text.Trim()) { $texts += $k.Text.Trim() }
          elseif ($k.Cls -eq 'Button' -and ($k.Style -band 0xF) -in 0, 1, 0xB -and $k.Text.Trim()) { $buttons += $k.Text.Trim() }
        }
      } else {
        $u = Get-Uia $w.H; $texts = $u.Texts; $buttons = $u.Buttons
      }
      $kind = Get-WindowKind $w.Cls $hasInput
      $blocking = Get-BlockingState $kind $w.Enabled ([bool]$frame) ($frame -and [AcadDevWin]::IsEnabled($frame.H)) $false $false
      $out += [pscustomobject]@{ H = $w.H; Title = $w.Title; Class = $w.Cls; Kind = $kind; Texts = $texts; Buttons = $buttons; Blocking = [bool]$blocking
        Enabled = $w.Enabled; Process = $pname; Rect = "$($w.L),$($w.T),$($w.R),$($w.B)" }
    } elseif ($pname -match $licProcs -or ($pname -eq 'msedgewebview2' -and $w.Title -match '(?i)autodesk|sign|licen')) {
      if (-not $w.Title -and $w.Cls -ne 'webview') { continue }
      $lb = Get-BlockingState 'licensing' $w.Enabled ([bool]$frame) ($frame -and [AcadDevWin]::IsEnabled($frame.H)) ($frame -and $w.Z -lt $frame.Z) ($frame -and $w.Owner -eq $frame.H)
      $out += [pscustomobject]@{ H = $w.H; Title = $w.Title; Class = $w.Cls; Kind = 'licensing'; Texts = @(); Buttons = @(); Blocking = [bool]$lb
        Enabled = $w.Enabled; Process = $pname; Rect = "$($w.L),$($w.T),$($w.R),$($w.B)" }
    } elseif ($pname -match '^(MusNotification|MusNotificationUx|MoNotificationUx)$') {
      # a Windows Update "restart to install" prompt: another process, cannot be dismissed from this session; reported, never touched
      $update += [pscustomobject]@{ Title = $w.Title; Class = $w.Cls; Process = $pname }
    } elseif ($frame -and $w.Z -lt $frame.Z -and $w.Title -and $pname -notmatch $ignoreForeign) {
      $ox = [Math]::Min($w.R, $frame.R) - [Math]::Max($w.L, $frame.L); $oy = [Math]::Min($w.B, $frame.B) - [Math]::Max($w.T, $frame.T)
      if ($ox -gt 50 -and $oy -gt 50) { $foreign += [pscustomobject]@{ Title = $w.Title; Class = $w.Cls; Process = $pname } }
    }
  }
  [pscustomobject]@{ Frame = $frame; Windows = $out; Foreign = $foreign; Update = $update }
}

function Get-ComState {
  # AutoCAD's command line state over COM, in a runspace so a call that hangs (a prompt waiting) can't hang this script
  $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.Open()
  $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({
    try {
      $a = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
      $q = try { [bool]$a.GetAcadState().IsQuiescent } catch { "unknown ($($_.Exception.Message.Split("`n")[0]))" }
      $d = try { $a.ActiveDocument } catch { $null }
      if (-not $d) { return "COM answers: quiescent=$q, no active drawing" }
      $act = try { [int]$d.GetVariable('CMDACTIVE') } catch { $null }; $nm = try { [string]$d.GetVariable('CMDNAMES') } catch { $null }
      $bits = @(); if ($null -ne $act) { foreach ($p in @(1, 'command'), @(2, 'transparent command'), @(4, 'script'), @(8, 'dialog'), @(16, 'DDE'), @(32, 'AutoLISP'), @(64, 'ObjectARX')) { if ($act -band $p[0]) { $bits += $p[1] } } }
      "COM answers: quiescent=$q; CMDACTIVE=$(if ($null -eq $act) { 'unavailable (call rejected)' } else { "$act ($(if ($bits) { $bits -join ', ' } else { 'none' }))" }); CMDNAMES=$(if ($null -eq $nm) { 'unavailable' } else { "'$nm'" }); drawing=$(try { $d.Name } catch { 'unavailable' })"
    } catch { $m = $_.Exception.Message.Split("`n")[0]; "COM: $m" }
  })
  $h = $ps.BeginInvoke()
  if ($h.AsyncWaitHandle.WaitOne(8000)) { $r = ($ps.EndInvoke($h) | Out-String).Trim(); if (-not $r) { $r = 'COM: no result' } } else { $r = 'COM: no answer within 8 s (AutoCAD is computing, or a call is waiting at a prompt or dialog)' }
  $r
}

function Invoke-Action($w, $act) {
  # returns a short note of what was done
  if ($act.Action -eq 'close') {
    [AcadDevWin]::Close($w.H); Start-Sleep -Milliseconds 700
    if ([AcadDevWin]::Exists($w.H) -and $w.Class -in '#32770') { [AcadDevWin]::Cancel($w.H); Start-Sleep -Milliseconds 700 }
  } elseif ($act.Action -eq 'press') {
    $done = $false
    if ($w.Kind -in 'dialog', 'messagebox', 'winforms') {
      foreach ($k in [AcadDevWin]::Kids($w.H)) {
        if (($k.Cls -eq 'Button' -or $k.Cls -like 'WindowsForms10.BUTTON*') -and $k.Visible -and (Test-ButtonMatch $k.Text $act.Button)) { [AcadDevWin]::Click($k.H); $done = $true; break }
      }
    }
    if (-not $done) {
      try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($w.H)
        $cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        foreach ($b in $root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $cond)) {
          if (Test-ButtonMatch $b.Current.Name $act.Button) { $b.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $done = $true; break }
        }
      } catch { }
    }
    if (-not $done) { return "could not press [$($act.Button)]" }
    Start-Sleep -Milliseconds 800
  }
  if ([AcadDevWin]::Exists($w.H) -and [AcadDevWin]::IsVisible($w.H)) { return 'sent, but the window is still open' }
  'done, window gone'
}

try {
  if (-not $acadProcs) {
    "BLOCKERS blocked=0 windows=0 applied=0", 'NO BLOCKERS: AutoCAD is not running.' | Set-Content $resFile -Encoding UTF8
    [Environment]::Exit(0)
  }
  if (-not $NoShot) { try { Save-Screenshot (Join-Path $script:Out 'blockers.png') } catch { } }
  $applied = 0; $notes = @{}; $before = $null
  $actions = @{}
  $lockNote = ''; $locked = $false
  if ($Apply) {
    # one guard at a time applies actions (lock file with pid + stale timeout); a second one waits up to 10 s, then only reports.
    # The scan is taken under the lock, so a window another guard dealt with meanwhile is not acted on twice.
    $locked = Enter-BlockerLock $lockFile 10
    if (-not $locked) { $lockNote = 'another guard is applying actions right now: this one only reports' }
  }
  try {
    $scan = Get-Blockers
    foreach ($w in $scan.Windows) { $actions[[string]$w.H] = Resolve-BlockerAction $w $rules }
    if ($locked) {
      foreach ($w in $scan.Windows) {
        $a = $actions[[string]$w.H]
        if ($a.Action -eq 'report') { continue }
        $notes[[string]$w.H] = Invoke-Action $w $a
        if ($notes[[string]$w.H] -like 'done*') { $applied++ }
      }
      if ($notes.Count) { Start-Sleep -Milliseconds 500; $before = $scan; $scan = Get-Blockers; foreach ($w in $scan.Windows) { if (-not $actions.ContainsKey([string]$w.H)) { $actions[[string]$w.H] = Resolve-BlockerAction $w $rules } } }
    }
  } finally { if ($locked) { Exit-BlockerLock $lockFile } }
  $blocking = @($scan.Windows | Where-Object { $_.Blocking })
  $com = Get-ComState
  $frameState = if (-not $scan.Frame) { 'main frame not found (AutoCAD still starting?)' } elseif ([AcadDevWin]::IsEnabled($scan.Frame.H)) { 'main frame enabled' } else { 'main frame DISABLED: a modal window is open' }
  $hdr = "BLOCKERS blocked=$(if ($blocking) { 1 } else { 0 }) windows=$($scan.Windows.Count) applied=$applied"
  L $hdr
  if ($Apply -and $notes.Count -and $before) {
    L "Actions taken (allowlist $policyFile, and the built-in Drawing Recovery rule):"
    foreach ($w in $before.Windows) { if ($notes.ContainsKey([string]$w.H)) { $a = $actions[[string]$w.H]; L ("  [{0}] {1}: {2} -> {3}" -f $w.Title, $a.Source, $a.Reason, $notes[[string]$w.H]) } }
  }
  if ($blocking) {
    L "BLOCKED BY: $($blocking.Count) window(s) in AutoCAD's way"
  } elseif ($scan.Windows.Count) {
    L 'NO BLOCKERS found, but these windows are open (not blocking AutoCAD):'
  } else {
    L 'NO BLOCKERS: no AutoCAD dialog, message box or licensing window is open.'
  }
  $i = 0
  foreach ($w in $scan.Windows) {
    $i++; $a = $actions[[string]$w.H]
    L ('  [{0}] {1}  "{2}"  class={3}  kind={4}  process={5}  enabled={6}  at {7}' -f $i, $(if ($w.Blocking) { 'MODAL/BLOCKING' } else { 'open (not blocking)' }), $w.Title, $w.Class, $w.Kind, $w.Process, $w.Enabled, $w.Rect)
    if ($w.Texts.Count) { $tx = (($w.Texts | Select-Object -First 8) -join ' | ') -replace '\s+', ' '; if ($tx.Length -gt 400) { $tx = $tx.Substring(0, 400) + '...' }; L "      text: $tx" }
    if ($w.Buttons.Count) { L "      buttons: $(($w.Buttons | ForEach-Object { "[$_]" }) -join ' ')" }
    L "      policy: $($a.Reason) ($($a.Source))"
  }
  L "  $frameState"
  L "  $com"
  if ($scan.Foreign.Count) {
    L 'Also in front of AutoCAD (other programs; they do not block COM, they can cover the ribbon):'
    foreach ($f in $scan.Foreign) { L "  `"$($f.Title)`" class=$($f.Class) process=$($f.Process)" }
  }
  if ($scan.Update.Count) {
    L '  note: a Windows Update prompt is open (another process; reported only, never touched). It cannot be dismissed from this session: close it by hand, or on a VM you own run harden-automation-vm.ps1 once.'
  }
  if ($lockNote) { L "  note: $lockNote" }
  foreach ($wn in $policy.Warnings) { L "  warning: $wn" }
  if (-not $NoShot) { L 'screenshot: out\blockers.png' }
  $lines | Set-Content $resFile -Encoding UTF8
} catch {
  "BLOCKERS blocked=0 windows=0 applied=0", "blocker check ERROR: $($_.Exception.Message)" | Set-Content $resFile -Encoding UTF8
}
[Environment]::Exit(0)
