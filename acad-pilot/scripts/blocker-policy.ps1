# Blocker policy: pure functions (no Win32, no COM), dot-sourced by blocker-worker.ps1 and by tests/blocker-policy.tests.ps1.
#   . (Join-Path $PSScriptRoot 'blocker-policy.ps1')
# A "window" here is any object with: Title, Class, Kind (dialog | messagebox | winforms | wpf | window | licensing | foreign),
# Texts (string[]), Buttons (string[]). The allowlist file is blockers.txt in the work folder (format: scripts/README.md).
#
# The DENYLIST is built in and always wins over the allowlist. It is matched against the window's title, texts and buttons:
#   security     AutoCAD security prompts (unsigned / untrusted file, SECURELOAD, TRUSTEDPATHS, "Load once / Always load")
#   licence      licence, sign-in, login, subscription, trial, activation screens, and every window of Autodesk's licensing helpers
#   save         "save changes?" prompts (a Save / Don't save button pair, or text about saving changes)
# A denied window is only ever reported. Nothing in this file touches a window.
#
# BUILT-IN RULES (allowed without any blockers.txt, tried after the allowlist so a blockers.txt line can override them with `report`):
#   Drawing Recovery   AutoCAD's "Drawing Recovery" window, which appears when AutoCAD restarts after a crash with unsaved drawings
#                      and keeps COM from answering. Closed with WM_CLOSE (a dialog treats that as Cancel: nothing is saved, nothing is
#                      deleted; the recovered files stay on disk). Only windows of acad.exe are ever listed, so a browser or folder
#                      with that title is never touched.

$script:BlockerDeny = @(
  @{ Name = 'security prompt'; Title = '^\s*Security\b'
     Any = '(?i)\bunsigned\b|\buntrusted\b|\bSECURELOAD\b|\bTRUSTEDPATHS\b|trusted (location|path|folder)|\b(load once|always load|do not load)\b' },
  @{ Name = 'licence / sign-in / trial'
     Title = '(?i)licen[cs]|\bsign[ -]?(in|up)\b|\blog[ -]?in\b|subscri|\btrial\b|activat|autodesk account|product key|serial number|buy now|\bexpired?\b|\brenew'
     Any = '(?i)licen[cs]e|\bsign[ -]?(in|up)\b|\blog[ -]?in\b|subscri|\btrial\b|activat|autodesk account|product key|serial number|buy now|days? (left|remaining)|\bexpired?\b|\brenew' },
  @{ Name = 'save-changes prompt'; Title = '(?i)\bsave (changes|drawing)\b|unsaved'
     Any = '(?i)\bsave\b[^.]{0,60}\bchanges\b|\bchanges\b[^.]{0,60}\bsave\b|do you want to save|want to save|unsaved (changes|drawing)|discard (the )?changes|don''t save|do not save' }
)
# Kinds that are always report-only whatever the allowlist says: another program's window, the licensing helpers.
$script:BlockerReportOnlyKinds = @('licensing', 'foreign')
# Buttons the guard never presses, even in an allowlisted window (what they answer is a person's decision).
$script:BlockerDenyButton = '(?i)^\s*(save|yes|no|don''?t save|do not save|discard|trust|load|load once|always load|accept|agree|i agree|sign in|log in|activate|buy|subscribe|ok to all)\b'

$script:BlockerBuiltinRules = @(
  [pscustomobject]@{ Line = 0; Title = '^\s*Drawing Recovery'; Kind = 'any'; Class = $null; Action = 'close'; Button = $null; Name = 'built-in: Drawing Recovery window' }
)

function Test-BlockerDenied {
  # Returns the reason (string) when the window is on the built-in denylist, else $null.
  param($W)
  if ($W.Kind -eq 'licensing') { return 'licence / sign-in / trial (Autodesk licensing helper window)' }
  $title = "$($W.Title)"
  # AutoCAD's Drawing Recovery window lists unsaved drawings, so its text mentions saving: that is not a save prompt (closing it
  # saves nothing). The security and licence checks still apply to it.
  $recovery = $title -match '^\s*Drawing Recovery'
  $all = (@($W.Title) + @($W.Texts) + @($W.Buttons) | Where-Object { $_ } | ForEach-Object { "$_" }) -join "`n"
  foreach ($d in $script:BlockerDeny) {
    if ($recovery -and $d.Name -eq 'save-changes prompt') { continue }
    if ($title -match $d.Title -or $all -match $d.Any) { return $d.Name }
  }
  # a Save / Don't save style button pair is a save prompt whatever its wording
  $b = @($W.Buttons | ForEach-Object { ("$_" -replace '&', '').Trim() })
  if (-not $recovery -and ($b | Where-Object { $_ -match '^(?i)save( all)?$' }) -and ($b | Where-Object { $_ -match "^(?i)(don'?t save|do not save|discard|no)$" })) { return 'save-changes prompt' }
  return $null
}

function ConvertTo-ButtonKey([string]$Text) { return ("$Text" -replace '&', '').Trim().ToLowerInvariant() }
function Test-ButtonMatch([string]$A, [string]$B) {
  # Button labels compare with '&' (mnemonic) stripped, trimmed, case-insensitive: the same rule everywhere a button is looked up.
  return (ConvertTo-ButtonKey $A) -eq (ConvertTo-ButtonKey $B)
}

function Get-BlockingState {
  # Does this window actually block AutoCAD? A licensing / sign-in window or a message box counts only when the main frame is
  # disabled, or (licensing) it is in front of the frame or owned by it. Frame unknown (AutoCAD still starting): every kind counts as blocking.
  # Any other dialog blocks only when it is enabled and the frame is disabled.
  param([string]$Kind, [bool]$Enabled, [bool]$FrameKnown, [bool]$FrameEnabled, [bool]$InFront = $false, [bool]$Owned = $false)
  if (-not $FrameKnown) { return $true }   # AutoCAD still starting: any dialog-like window (Drawing Recovery, Component Updates, licensing...) counts
  if (-not $FrameEnabled) { return ($Kind -eq 'licensing') -or $Enabled }
  if ($Kind -eq 'licensing') { return ($InFront -or $Owned) }
  return $false
}

function Enter-BlockerLock {
  # One guard applies actions at a time: a lock file holding "pid time". A lock older than StaleSec, or whose process is gone, is
  # taken over. Waits up to WaitSec for another guard; returns $true when this one holds the lock.
  param([string]$Path, [int]$WaitSec = 10, [int]$StaleSec = 120)
  $end = (Get-Date).AddSeconds($WaitSec)
  while ($true) {
    try {
      $fs = [IO.File]::Open($Path, 'CreateNew', 'Write', 'None')
      try { $b = [Text.Encoding]::ASCII.GetBytes("$PID $([DateTime]::UtcNow.ToString('o'))"); $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
      return $true
    } catch {
      try {
        $age = ((Get-Date) - (Get-Item $Path -EA Stop).LastWriteTime).TotalSeconds
        $owner = ("$(Get-Content $Path -Raw -EA SilentlyContinue)".Trim() -split ' ')[0]
        # an empty or unreadable file is a holder that is still writing its pid: held, unless it has stayed that way for a few seconds
        $known = $owner -match '^\d+$'
        $dead = if ($known) { -not (Get-Process -Id ([int]$owner) -EA SilentlyContinue) } else { $age -gt 5 }
        if ($age -gt $StaleSec -or $dead) { Remove-Item $Path -Force -EA SilentlyContinue; continue }
      } catch { }
    }
    if ((Get-Date) -gt $end) { return $false }
    Start-Sleep -Milliseconds 250
  }
}
function Exit-BlockerLock([string]$Path) { Remove-Item $Path -Force -EA SilentlyContinue }

function ConvertFrom-BlockerPolicy {
  # Parses allowlist lines. Format, one rule per line, fields separated by " :: ":
  #     <title regex> :: <kind or class=regex> :: <close | press <button> | report>
  # kind: any | dialog | messagebox | winforms | wpf, or class=<regex> (a regex on the window class, case as written).
  # '#' starts a comment (a whole line, or after the action); blank lines are ignored. First matching rule wins.
  # Returns an object with Rules and Warnings. Never throws.
  param([string[]]$Lines)
  $rules = @(); $warn = @(); $n = 0
  foreach ($raw in @($Lines)) {
    $n++; $line = "$raw".Trim()
    if (-not $line -or $line.StartsWith('#')) { continue }
    $f = @($line -split '\s::\s+')
    if ($f.Count -ne 3) { $warn += "blockers.txt line ${n}: expected '<title regex> :: <kind> :: <action>', ignored"; continue }
    $title = $f[0].Trim(); $kindRaw = $f[1].Trim(); $kind = $kindRaw.ToLower()
    $act = ($f[2] -replace '\s+#.*$', '').Trim()
    try { [void][regex]::new($title) } catch { $warn += "blockers.txt line ${n}: bad title regex, ignored"; continue }
    $class = $null
    if ($kindRaw -match '^(?i)class=(.+)$') {
      $class = $Matches[1]   # the regex as written: only the keyword is case-insensitive (\S is not \s)
      try { [void][regex]::new($class) } catch { $warn += "blockers.txt line ${n}: bad class regex, ignored"; continue }
      $kind = 'class'
    } elseif ($kind -notin 'any', '*', 'dialog', 'messagebox', 'winforms', 'wpf') {
      $warn += "blockers.txt line ${n}: unknown kind '$kind' (any, dialog, messagebox, winforms, wpf, class=<regex>), ignored"; continue
    }
    $button = $null
    if ($act -match '^(?i)close$') { $action = 'close' }
    elseif ($act -match '^(?i)report$') { $action = 'report' }
    elseif ($act -match '^(?i)press\s+(.+)$') { $action = 'press'; $button = $Matches[1].Trim() }
    else { $warn += "blockers.txt line ${n}: unknown action '$act' (close, press <button>, report), ignored"; continue }
    $rules += [pscustomobject]@{ Line = $n; Title = $title; Kind = $(if ($kind -eq '*') { 'any' } else { $kind }); Class = $class; Action = $action; Button = $button }
  }
  [pscustomobject]@{ Rules = $rules; Warnings = $warn }
}

function Resolve-BlockerAction {
  # What the guard may do with a window: Action (report | close | press), Button, Source, Reason.
  # Order: denylist (always report) > report-only kinds > first matching allowlist rule > built-in rules > default report.
  param($W, $Rules = @())
  $deny = Test-BlockerDenied $W
  if ($deny) { return [pscustomobject]@{ Action = 'report'; Button = $null; Source = 'denylist'; Reason = "never touched: $deny" } }
  if ($W.Kind -in $script:BlockerReportOnlyKinds) { return [pscustomobject]@{ Action = 'report'; Button = $null; Source = 'default'; Reason = "$($W.Kind) window: report only" } }
  foreach ($r in @($Rules)) {
    if ("$($W.Title)" -notmatch "(?i)$($r.Title)") { continue }
    if ($r.Kind -eq 'class') { if ("$($W.Class)" -cnotmatch $r.Class) { continue } }   # the class regex is case-sensitive, as written
    elseif ($r.Kind -ne 'any') { if ($W.Kind -ne $r.Kind) { continue } }
    if ($r.Action -eq 'press') {
      # no such button in this window: the rule does not apply, later rules still may (checked before the button is judged)
      if (-not (@($W.Buttons) | Where-Object { Test-ButtonMatch $_ $r.Button })) { continue }
      # the button exists but is one a person has to choose (Save, Yes, Load, Accept ...)
      if ((ConvertTo-ButtonKey $r.Button) -match $script:BlockerDenyButton) { return [pscustomobject]@{ Action = 'report'; Button = $null; Source = 'denylist'; Reason = "never presses [$($r.Button)]: a person decides that" } }
    }
    $what = if ($r.Button) { "$($r.Action) $($r.Button)" } else { $r.Action }
    return [pscustomobject]@{ Action = $r.Action; Button = $r.Button; Source = "allowlist line $($r.Line)"; Reason = "allowlist: $what" }
  }
  foreach ($r in $script:BlockerBuiltinRules) {
    if ("$($W.Title)" -match "(?i)$($r.Title)") { return [pscustomobject]@{ Action = $r.Action; Button = $null; Source = 'built-in'; Reason = $r.Name } }
  }
  [pscustomobject]@{ Action = 'report'; Button = $null; Source = 'default'; Reason = 'no allowlist rule: report' }
}

function Get-WindowKind {
  # Kind from the window class. messagebox = a #32770 dialog without input controls (edit / combo / list).
  param([string]$Class, [bool]$HasInput = $false)
  if ($Class -eq '#32770') { if ($HasInput) { return 'dialog' } else { return 'messagebox' } }
  if ($Class -like 'adesk_dlg*') { return 'dialog' }
  if ($Class -like 'WindowsForms10.*') { return 'winforms' }
  if ($Class -like 'HwndWrapper*') { return 'wpf' }
  'window'
}

function Test-ComRejected {
  # True when an exception is AutoCAD rejecting a COM call as busy (RPC_E_CALL_REJECTED 0x80010001 / RETRYLATER 0x8001010A).
  param($ErrorRecord)
  $e = $ErrorRecord.Exception
  while ($e) {
    if ($e.HResult -eq -2147418111 -or $e.HResult -eq -2147417846) { return $true }
    $e = $e.InnerException
  }
  return ("$($ErrorRecord.Exception.Message)" -match '0x80010001|0x8001010A|RPC_E_CALL_REJECTED|rejected by (the )?callee|server is busy')
}
