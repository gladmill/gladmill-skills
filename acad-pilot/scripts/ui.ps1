# Drives AutoCAD's UI: ribbon clicks, commands that open dialogs, DCL dialogs, message boxes. Runs ui-run.ps1 in the interactive
# session (directly when you are in it, as a one-shot scheduled task from SSH) and prints its step-by-step result.
#   ui.ps1 -Steps 'command KITDIALOG','dialog Kit Sample Dialog','set Name=Alpha','press OK','alert','press OK','idle'
#   ui.ps1 -File my-steps.txt          one step per line, # comments
#   -StepTimeoutSec n   how long a step waits for its dialog, button or state (default 20)
#   -TimeoutSec n       give up on the whole run after n s (default: the steps' own waits + 60, at least 120)
#   -Staged             use the <home>\ui.txt already there (the Mac wrapper copies it with scp)
# Steps: see ui-run.ps1. Exit 0 when every step passed, 1 when one failed (the result says which and why, lists the open dialogs
# and leaves out\ui-fail.png), 2 for bad input or a setup error (no step ran), 3 when a newer ui run replaced this one, 4 on a timeout,
# 6 on a timeout with a window in AutoCAD's way (the output ends with the "BLOCKED BY: ..." report; a failed step lists the same).
# Status board: while it runs it keeps its line in the shared status folder (status.ps1; ACAD_STATUS=0 turns that off) and it ends it as
# `stopped` with the result.
param([string[]]$Steps = @(), [string]$File = '', [int]$StepTimeoutSec = 20, [int]$TimeoutSec = 0, [switch]$Staged)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'status-board.ps1')   # (the status line: see Start-AcadStatus in common.ps1)
$uiFile = Join-Path $script:Home_ 'ui.txt'
if (-not $Staged) {
  if ($File -and -not (Test-Path $File)) { "no steps file $File"; exit 2 }
  $lines = if ($File) { Get-Content $File -Encoding UTF8 } else { $Steps }
  Set-Content $uiFile $lines -Encoding UTF8
}
$stepLines = @(Get-Content $uiFile -Encoding UTF8 -EA SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
if ($stepLines.Count -eq 0) { 'no steps given'; exit 2 }
# Status board line (common.ps1): running now; the waits below refresh it, every exit below ends it (`stopped` + result), except being
# replaced by a newer run.
# The steps go into the file (readable by every local user) as verbs and targets only (Get-AcadStatusUiSteps): never what `set` / `type` /
# `keys` put into a field, nor an `expect` pattern, and a failure is described by its step number and that sanitised step, never by ui-run's
# own FAIL text. ACAD_STATUS_DETAIL=0 leaves the step text out altogether.
$safeSteps = @(Get-AcadStatusUiSteps $stepLines)
$cmdText = Get-AcadStatusText (Get-AcadStatusCmdText $safeSteps)
Start-AcadStatus -Script 'ui' -Summary (Join-AcadStatusSummary "ui: $($stepLines.Count) step(s)" $cmdText) -Detail $(if ($cmdText) { @{ cmds = $cmdText } } else { @{} })
if ($TimeoutSec -le 0) {
  # what the steps may wait for: each step its timeout (timeout <s> changes it for the ones after), idle <s> and sleep <ms> their own,
  # plus a few seconds for the fixed waits (ribbon search, a dialog settling); then 60 s for start-up and the end
  $per = [Math]::Max(1, $StepTimeoutSec); $budget = 60
  foreach ($l in $stepLines) {
    $verb, $arg = $l -split '\s+', 2
    switch ($verb.ToLower()) {
      'timeout' { if ($arg -match '^\d+$') { $per = [Math]::Max(1, [int]$arg) } }
      'idle' { $budget += $(if ($arg -match '^\d+$') { [int]$arg } else { $per }) + 5 }
      'sleep' { if ($arg -match '^\d+$') { $budget += [Math]::Ceiling([int]$arg / 1000) } }
      default { $budget += $per + 5 }
    }
  }
  $TimeoutSec = [Math]::Max(120, $budget)
}
$RunId = [guid]::NewGuid().ToString('N')
$runFile = Join-Path $script:Out 'ui-run.txt'
Set-Content $runFile $RunId
function Mine { "$(Get-Content $runFile -Raw -EA SilentlyContinue)".Trim() -eq $RunId }
$done = Join-Path $script:Out 'ui-done.txt'; $res = Join-Path $script:Out 'ui-result.txt'
Remove-Item $done, $res, (Join-Path $script:Out 'ui-fail.png') -EA SilentlyContinue
$worker = Join-Path $PSScriptRoot 'ui-run.ps1'
try {
  if (Test-Interactive) {
    # in the session already: run the worker as a process of its own, so the timeout holds here too
    $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$worker`"", '-RunId', $RunId, '-StepTimeoutSec', $StepTimeoutSec) -WindowStyle Hidden -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while (-not $p.WaitForExit(1000)) {
      if ((Get-Date) -ge $deadline) { try { $p.Kill() } catch { }; break }
      Update-AcadStatusHeartbeat
    }
  } else {
    Invoke-InSession -Script $worker -ScriptArgs "-RunId $RunId -StepTimeoutSec $StepTimeoutSec" -TaskName 'AcadDevUi' -TimeoutSec $TimeoutSec |
      Where-Object { $_ -notlike 'TIMEOUT waiting for the task*' }
  }
} catch { Set-AcadStatusError 'ui: the run could not start' $_; "ERROR: the ui run could not start: $($_.Exception.Message)"; exit 2 }
$d = "$(Get-Content $done -Raw -EA SilentlyContinue)".Trim()
if ($d -like "$RunId *") {
  $code = [int]($d -split ' ')[1]
  $resLines = @(Get-Content $res -Encoding UTF8 -EA SilentlyContinue)
  $resLines
  if ($code -eq 3) { Stop-AcadStatus 'idle' 'ui: replaced by a newer ui run' }
  else {
    $u = Get-AcadStatusUiResult -Code $code -ResultLines $resLines -SafeSteps $safeSteps -NoStepText:(-not (Test-AcadStatusDetail))   # (a failed step ends with the BLOCKED BY report when a window is in the way)
    Stop-AcadStatus $u.State $u.Summary
  }
  exit $code
}
if (-not (Mine)) { Stop-AcadStatus 'idle' 'ui: replaced by a newer ui run'; 'SUPERSEDED: a newer ui run started, so this one stopped; its result is that run''s'; exit 3 }
Set-Content $runFile "timeout $RunId"   # a worker still running sends and writes nothing more
Get-Content $res -Encoding UTF8 -EA SilentlyContinue
"TIMEOUT: the ui run did not finish within ${TimeoutSec}s (a step may be waiting on AutoCAD); shot shows the screen"
$g = Get-BlockerReport   # report only: ui steps wait for windows on purpose, so nothing is closed here
$g.Text
if ($g.Blocked) { Stop-AcadStatus 'blocked' "ui: $(Get-AcadStatusBlockedLine $g.Text)"; exit 6 }
Stop-AcadStatus 'error' "ui: TIMEOUT after ${TimeoutSec}s (a step may be waiting on AutoCAD)"
exit 4
