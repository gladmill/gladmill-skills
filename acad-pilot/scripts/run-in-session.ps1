# Sends commands to AutoCAD and prints the result. Works locally (runs acad-cmd.ps1 directly) and from SSH/session 0
# (runs it as a one-shot interactive scheduled task). Result file: <home>\out\result.txt, screenshot: <home>\out\screen.png.
#   -Cmds "LINE\n0,0\n100,100\n\n|ZOOM\nE\n"   commands split by |, \n = Enter (written to <home>\cmds.txt)
#   -Query q.ps1   read-only COM query run first ($acad/$doc in scope), copied to <home>\query.ps1
#   -TimeoutSec n  give up after n s (default: commands x (WaitSec+1) + 60, at least 120)
#   -Staged        use the cmds.txt / query.ps1 already in <home> (the Mac wrapper copies them there with scp)
#   Blocker guard: when a run is stuck or times out it looks for the window in AutoCAD's way (blockers.ps1) and prints "BLOCKED BY: ..."
#   with exit 6; a window the allowlist (<home>\blockers.txt) names is dealt with first and the command carries on.
#   -StallSec n    when one command has been running n s (default 30; 0 = off) and AutoCAD answers COM as busy
#                  twice (a prompt or dialog, or a long command that keeps its message loop running, e.g. one with a progress
#                  meter), the run stops: commands after it are not sent, it prints STUCK and exits 4. AutoCAD is left as it is.
#   -Esc           with -StallSec: also press Esc (esc.ps1). Exit 4 if that freed AutoCAD, 5 if not (check with shot)
#   Status board: while it runs it keeps its line in the shared status folder (status.ps1; ACAD_STATUS=0 turns that off) and it ends it
#   as `stopped` with the result.
#   -StatusScript s  for a script that calls this one in its own process (stop-acad.ps1): the label of the status line ("stop: ...") and the
#                  caller writes the final line.
param([string]$Cmds = '', [int]$WaitSec = 3, [int]$TimeoutSec = 0, [string]$Query = '', [switch]$Staged, [switch]$HasQuery, [switch]$NoShot,
      [int]$StallSec = 30, [switch]$Esc, [string]$StatusScript = '')
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'status-board.ps1')   # (the status line: see Start-AcadStatus in common.ps1)
$done = Join-Path $script:Out 'done.txt'; $prog = Join-Path $script:Out 'progress.txt'
# This run's id: the worker stops (sends nothing more, writes nothing more) once out\run.txt holds anything else.
$RunId = [guid]::NewGuid().ToString('N')
Set-Content (Join-Path $script:Out 'run.txt') $RunId
Remove-Item $done, $prog, (Join-Path $script:Out 'result.txt') -EA SilentlyContinue
Get-ChildItem $script:Out -Filter 'stopped-*.txt' -EA SilentlyContinue | Remove-Item -EA SilentlyContinue
Get-ChildItem $script:Out -Filter 'ready-*.txt' -EA SilentlyContinue | Remove-Item -EA SilentlyContinue
if (-not $Staged) {
  Set-Content (Join-Path $script:Home_ 'cmds.txt') $Cmds -Encoding UTF8 -NoNewline
  if ($Query) { Copy-Item $Query (Join-Path $script:Home_ 'query.ps1') -Force; $HasQuery = $true }
}
# The commands, split exactly as the worker (acad-cmd.ps1) does: on |, empty items skipped. Read once: for the timeout and the status line.
$cmdFile = Join-Path $script:Home_ 'cmds.txt'
$cmdRaw = if (Test-Path $cmdFile) { "$(Get-Content $cmdFile -Raw -Encoding UTF8)" } else { '' }
$cmdItems = @($cmdRaw -split '\|' | Where-Object { $_ })
$cmdCount = $cmdItems.Count
# Status board line (common.ps1): running now; the poll loops refresh it, every exit below ends it (`stopped` + result), and a call that throws
# ends it as `error`.
$nested = [bool]$StatusScript; $sl = if ($StatusScript) { $StatusScript } else { 'run' }
$cmdText = Get-AcadStatusText (Get-AcadStatusCmdText $cmdItems)
$statusDetail = @{ stallSec = $StallSec }; if ($cmdText) { $statusDetail.cmds = $cmdText }
$statusWhat = if ($cmdCount) { "$cmdCount command(s)" + $(if ($HasQuery) { ' + query' } else { '' }) } else { 'query only' }
Start-AcadStatus -Script $sl -Nested:$nested -Summary (Join-AcadStatusSummary "${sl}: $statusWhat" $cmdText) -Detail $statusDetail
# Timeout: unless given, (number of commands x WaitSec) + 60 s margin for start-up, the query, the log read and the screenshot.
if ($TimeoutSec -le 0) {
  $TimeoutSec = [Math]::Max(120, $cmdCount * ($WaitSec + 1) + 60)
  if ($StallSec -gt 0) { $TimeoutSec = [Math]::Max($TimeoutSec, $StallSec + 60) }   # room for the stall checks
} elseif ($StallSec -gt 0 -and $TimeoutSec -lt $StallSec + 60) {
  "NOTE: -TimeoutSec $TimeoutSec leaves no room for -StallSec $StallSec (needs about StallSec + 60): a stuck command ends as TIMEOUT"
}
$a = "-WaitSec $WaitSec -RunId $RunId" + $(if ($HasQuery) { ' -HasQuery' } else { '' }) + $(if ($NoShot) { ' -NoShot' } else { '' })
# Stall watch: a command that waits for input never returns from SendCommand, so the worker's last progress line stays
# "sent N ...". AutoCAD at a prompt or dialog still answers COM, as not quiescent ("busy"); one computing in a tight loop doesn't
# answer at all ("none: no answer"), so that isn't taken for a prompt. Two busy answers in a row are required. A long command that
# keeps its message loop running (progress meters) also answers busy: that's why Esc is opt-in (-Esc).
# One probe at a time, each with its own file: after a probe got no answer, the next waits 60 s (no pile of hung probes).
$script:stuck = $null; $script:blocked = $null; $script:notes = @(); $script:busy = 0; $script:probe = 0; $script:nextCheck = (Get-Date).AddSeconds($StallSec)
$script:nextStatus = Get-Date
$watch = {
  # progress.txt is read once per poll, and only when the status summary (every 3 s) or the stall check is due
  $doStatus = (Get-Date) -ge $script:nextStatus
  $doStall = $StallSec -gt 0 -and (Get-Date) -ge $script:nextCheck
  if (-not ($doStatus -or $doStall) -or -not (Test-Path $prog)) { return $false }
  $last = @(Get-Content $prog -EA SilentlyContinue)[-1]
  if ($doStatus) {
    # which command the run is at (only the summary changes here; the heartbeat in Invoke-InSession writes it)
    $script:nextStatus = (Get-Date).AddSeconds(3)
    if ($last -like 'sent *') { $pn, $pc = $last.Substring(5) -split ' ', 2; Set-AcadStatusSummary (Join-AcadStatusSummary "${sl}: command $pn of $cmdCount" (Get-AcadStatusText ($pc -replace '\\n', ' '))) }
  }
  if (-not $doStall) { return $false }
  if ($last -notlike 'sent *' -or ((Get-Date) - (Get-Item $prog).LastWriteTime).TotalSeconds -lt $StallSec) { $script:busy = 0; return $false }
  $script:probe++
  $state = Get-AcadState -TimeoutSec 20 -Tag "$RunId-$($script:probe)"
  $script:nextCheck = (Get-Date).AddSeconds($(if ($state -eq 'none: no answer') { 60 } else { 5 }))
  if ($state -eq 'busy') { $script:busy++ } else { $script:busy = 0 }
  if ($script:busy -ge 2) {
    # Blocker guard: what is in AutoCAD's way? A window the allowlist names is dealt with and the command carries on (nothing is
    # resent); a window it doesn't ends the run as BLOCKED, and no Esc is pressed into it.
    $g = Get-BlockerReport -Apply:(Test-BlockerAutoAction)
    if ($g.Applied -gt 0) {
      $script:notes += "guard: $($g.Applied) allowlisted window(s) dealt with while command $($last.Substring(5)) was waiting"
      $script:busy = 0; $script:nextCheck = (Get-Date).AddSeconds(5); return $false
    }
    if ($g.Blocked) { $script:blocked = $g.Text }
    $script:stuck = $last.Substring(5); return $true
  }
  return $false
}
Invoke-InSession -Script (Join-Path $PSScriptRoot 'acad-cmd.ps1') -ScriptArgs $a -TaskName 'AcadDevCmd' -TimeoutSec $TimeoutSec -OnPoll $watch
$workerKilled = $script:WorkerKilled   # local mode ends a worker that was stopped as stuck
foreach ($n in $script:notes) { $n }
if ($script:stuck) {
  Set-Content (Join-Path $script:Out 'run.txt') "stopped $RunId"   # the worker sends nothing after the stuck command
  Get-Content (Join-Path $script:Out 'result.txt') -EA SilentlyContinue
  $sn, $sc = $script:stuck -split ' ', 2
  $what = "STUCK: command $sn ($sc) has run over ${StallSec}s and AutoCAD answers as busy: a prompt or dialog waiting for input, or a long command showing progress. The run stopped there; later commands were not sent."
  if ($script:blocked) {
    # a window is in the way: no Esc (it would go into that window); the report says what it is
    Stop-AcadStatus 'blocked' "$sl ended: $(Get-AcadStatusBlockedLine $script:blocked)"
    "$what AutoCAD was left as it is."
    $script:blocked; exit 6
  }
  $stuckAt = Join-AcadStatusSummary "command $sn" (Get-AcadStatusText ($sc -replace '\\n', ' ') 60)
  if (-not $Esc) { Stop-AcadStatus 'waiting-input' "$sl ended: STUCK at $stuckAt; AutoCAD is busy (a prompt or dialog waiting for input, or a long command)"; "$what AutoCAD was left as it is: shot to look, esc to leave a prompt, wait if it is working."; exit 4 }
  Write-AcadStatus 'waiting-input' "${sl}: STUCK at $stuckAt; pressed Esc, waiting for AutoCAD to come free"   # (the waits below keep this line fresh)
  $ef = Join-Path $script:Out 'esc.txt'; Remove-Item $ef -EA SilentlyContinue
  Invoke-InSession -Script (Join-Path $PSScriptRoot 'esc.ps1') -TaskName 'AcadDevRun' -TimeoutSec 60 | Out-Null
  $how = if (Test-Path $ef) { (Get-Content $ef -Raw).Trim() } else { 'the Esc task gave no result' }
  $freed = Join-Path $script:Out "stopped-$RunId.txt"   # the worker writes it once SendCommand returns
  if ($workerKilled) {
    # local mode ended the stuck worker (it can't write the "freed" file): ask AutoCAD itself, for up to 15 s
    for ($k = 0; $k -lt 5 -and -not (Test-Path $freed); $k++) { if ((Get-AcadState -TimeoutSec 5) -eq 'ready') { 'freed' | Set-Content $freed } else { Start-Sleep -Seconds 2 } }
  }
  for ($k = 0; $k -lt 30 -and -not (Test-Path $freed); $k++) { Start-Sleep -Milliseconds 500; Update-AcadStatusHeartbeat }
  if (Test-Path $freed) { Stop-AcadStatus 'idle' "$sl ended: stopped at $stuckAt, Esc freed AutoCAD"; "$what Pressed Esc ($how); AutoCAD is free."; exit 4 }
  Stop-AcadStatus 'waiting-input' "$sl ended: STUCK at $stuckAt; Esc did not free AutoCAD (a dialog may be open)"
  "$what Pressed Esc ($how), but AutoCAD did not come free within 15 s: a dialog may be open (shot, then cancel)."; exit 5
}
$ok = (Test-Path $done) -and "$(Get-Content $done -Raw -EA SilentlyContinue)".Trim() -eq $RunId
$result = @(Get-Content (Join-Path $script:Out 'result.txt') -EA SilentlyContinue)
$result
if (-not $ok) {
  Set-Content (Join-Path $script:Out 'run.txt') "timeout $RunId"
  "TIMEOUT (no done.txt after ${TimeoutSec}s): AutoCAD may be waiting at a prompt or dialog."
  $g = Get-BlockerReport   # report only: the run is over, nothing is retried
  $g.Text
  if ($g.Blocked) { Stop-AcadStatus 'blocked' "$sl ended: $(Get-AcadStatusBlockedLine $g.Text)"; exit 6 }
  Stop-AcadStatus 'error' "$sl ended: TIMEOUT after ${TimeoutSec}s, no window in AutoCAD's way (AutoCAD may be at a prompt)"
  'The guard sees no window in AutoCAD''s way; run esc.ps1 / shot.ps1.'; exit 1
}
# the worker found a window in its way (a COM call still rejected after the retry window) and stopped there
if ($result -match '^BLOCKED BY:') { Stop-AcadStatus 'blocked' "$sl ended: $(Get-AcadStatusBlockedLine $result)"; exit 6 }
# the worker's own error (it prints "ERROR: ..." and still finishes), else done (Get-AcadStatusWorkerError: not the log tail)
$err = Get-AcadStatusWorkerError $result
if ($err) { Stop-AcadStatus 'error' (Join-AcadStatusSummary "$sl ended: error" (Get-AcadStatusText ($err -replace '^ERROR:\s*', ''))) }
else { Stop-AcadStatus 'idle' "$sl ended: $(if ($cmdCount) { "$statusWhat sent" } else { $statusWhat }), no error" }
