# Waits until AutoCAD answers over COM and is quiescent; prints "ready after Ns" (exit 0). On timeout it looks for what blocks AutoCAD
# (blockers.ps1): exit 6 with a "BLOCKED BY: ..." report when a window does, else exit 1 with the last state.
# Works from SSH (polls through a one-shot task: window titles/handles can't be read from session 0) and from an interactive session.
# The wait is always finite (a TimeoutSec of 0 or less means 240, at most 3600). While waiting, a window the allowlist names
# (<home>\blockers.txt) is dealt with after 20 s and then every 60 s (ACAD_DEV_BLOCKER_ACTIONS=0 turns that off); the wait then
# gets one more window of up to 60 s.
# Status board: while it waits it keeps its line in the shared status folder (status.ps1; ACAD_STATUS=0 turns that off) and it ends it as
# `stopped` with the result. -StatusScript s: for a script that calls this one in its own process (start-acad.ps1): the label of the status
# line ("start: ...") and the caller writes the final line.
param([int]$TimeoutSec = 240, [int]$EverySec = 2, [string]$StatusScript = '')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'status-board.ps1')   # (the status line: see Start-AcadStatus in common.ps1)
if ($TimeoutSec -le 0) { $TimeoutSec = 240 }
if ($TimeoutSec -gt 3600) { $TimeoutSec = 3600 }
if ($EverySec -lt 1) { $EverySec = 2 }
$t0 = Get-Date; $state = 'none: not checked'; $nextGuard = 20; $extended = $false; $limit = $TimeoutSec
$nested = [bool]$StatusScript; $sl = if ($StatusScript) { $StatusScript } else { 'wait' }
Start-AcadStatus -Script $sl -Nested:$nested -Summary "${sl}: waiting for AutoCAD to answer over COM (up to ${TimeoutSec}s)"
function Invoke-WaitGuard {
  # deals with allowlisted windows; the first time one was dealt with, the wait gets up to 60 s more
  $g = Get-BlockerReport -Apply -NoShot
  if ($g.Applied -gt 0) {
    $script:guardMsg = "guard: $($g.Applied) allowlisted window(s) dealt with; waiting again"
    if (-not $script:extended) { $script:extended = $true; $script:limit = [Math]::Max($script:limit, ((Get-Date) - $script:t0).TotalSeconds + 60) }
    return $true
  }
  return $false
}
$again = $true
while ($again) {
  $again = $false
  while (((Get-Date) - $t0).TotalSeconds -lt $limit) {
    $state = Get-AcadState -TimeoutSec 30
    if ($state -eq 'ready') { $m = "ready after $([int]((Get-Date) - $t0).TotalSeconds)s"; Stop-AcadStatus 'idle' "${sl}: $m"; $m; exit 0 }
    Update-AcadStatusHeartbeat
    if ((Test-BlockerAutoAction) -and ((Get-Date) - $t0).TotalSeconds -ge $nextGuard -and (Get-Process acad -EA SilentlyContinue)) {
      $nextGuard = ((Get-Date) - $t0).TotalSeconds + 60
      if (Invoke-WaitGuard) { $script:guardMsg }
    }
    for ($i = 0; $i -lt $EverySec; $i++) { Start-Sleep -Seconds 1; Update-AcadStatusHeartbeat }   # (in 1 s steps: a long -EverySec must not let the status line go stale)
  }
  # out of time: a window the allowlist names may still be the cause (a short wait never reached the 20 s check)
  if (-not $extended -and (Test-BlockerAutoAction) -and (Get-Process acad -EA SilentlyContinue)) { if (Invoke-WaitGuard) { $script:guardMsg; $again = $true } }
}
$g = if (Get-Process acad -EA SilentlyContinue) { Get-BlockerReport } else { $null }
"timeout after $([int]((Get-Date) - $t0).TotalSeconds)s: $state"
if ($g -and $g.Blocked) { Stop-AcadStatus 'blocked' "${sl}: $(Get-AcadStatusBlockedLine $g.Text)"; $g.Text; exit 6 }
Stop-AcadStatus 'error' "${sl}: timeout after $([int]((Get-Date) - $t0).TotalSeconds)s: $state"
if ($g -and $g.Windows -gt 0) { $g.Text }
exit 1
