# Quits AutoCAD.
#   (default)        quits only if no drawing has unsaved changes; prints REFUSED and leaves AutoCAD running otherwise.
#   -DiscardChanges  closes every drawing without saving, quits, ends the process if it is still there.
#   -Force           ends the process at once (AutoCAD is hung); unsaved work is lost.
param([switch]$DiscardChanges, [switch]$Force)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'status-board.ps1')   # (the status line: see Start-AcadStatus in common.ps1; run-in-session.ps1 writes its states as "stop: ...")
if (-not (Get-Process acad -EA SilentlyContinue)) { 'acad not running'; exit 0 }
Start-AcadStatus -Script 'stop' -Summary 'stop: quitting AutoCAD'
function Exit-Stop([string]$Result, [string]$Summary, [int]$Code) { Stop-AcadStatus $Result "stop: $Summary"; exit $Code }
function Wait-AcadGone([int]$Sec) {
  for ($i = 0; $i -lt $Sec -and (Get-Process acad -EA SilentlyContinue); $i++) { Start-Sleep 1; Update-AcadStatusHeartbeat }
  return -not (Get-Process acad -EA SilentlyContinue)
}
function Stop-AcadNow([string]$Done) {
  # Stop-Process returns before the process is gone; report only once acad.exe has really exited.
  Write-AcadStatus 'running' 'stop: ending the AutoCAD process'
  Stop-Process -Name acad -Force
  if (Wait-AcadGone 30) { $Done; Exit-Stop 'idle' $Done 0 } else { 'acad still running 30s after Stop-Process'; Exit-Stop 'error' 'acad still running 30 s after Stop-Process' 1 }
}
if ($Force) { Stop-AcadNow 'acad process ended (forced)' }
$q = Join-Path $script:Home_ 'q-quit.ps1'
if ($DiscardChanges) {
  Set-Content $q 'foreach ($d in @($acad.Documents)) { $d.Close($false) }; $acad.Quit(); "quit sent"' -Encoding UTF8
} else {
  Set-Content $q '$dirty = @($acad.Documents | Where-Object { -not $_.Saved } | ForEach-Object { $_.Name }); if ($dirty.Count) { "REFUSED: unsaved changes in: $($dirty -join '', '')" } else { $acad.Quit(); "quit sent" }' -Encoding UTF8
}
Set-Content (Join-Path $script:Home_ 'cmds.txt') '' -NoNewline
Copy-Item $q (Join-Path $script:Home_ 'query.ps1') -Force
$out = & (Join-Path $PSScriptRoot 'run-in-session.ps1') -Staged -HasQuery -WaitSec 0 -NoShot -StatusScript stop | Out-String
$line = ($out -split "`r?`n" | Where-Object { $_ -match 'quit sent|REFUSED|ERROR|TIMEOUT|BLOCKED BY' } | Select-Object -First 1)
if ($line) { $line.Trim() }
if ($line -notmatch 'quit sent') {
  'acad left running. Save or close the drawings, re-run with -DiscardChanges (test drawings, user agreed), or -Force if it is hung.'
  if ($line -match 'BLOCKED BY') { Exit-Stop 'blocked' (Get-AcadStatusBlockedLine $line) 1 } else { Exit-Stop 'error' 'AutoCAD was left running (unsaved changes, or no answer)' 1 }
}
Write-AcadStatus 'running' 'stop: waiting for AutoCAD to exit'   # (a new summary: the nested run's lines are over, the old "quitting AutoCAD" would be written back)
if (Wait-AcadGone 15) { 'acad closed'; Exit-Stop 'idle' 'acad closed' 0 }
elseif ($DiscardChanges) { Stop-AcadNow 'acad process ended' }
else { 'acad still running after quit; check for a dialog (shot), or use -Force'; Exit-Stop 'error' 'acad still running after quit (a dialog may be open)' 1 }
