# Quits AutoCAD.
#   (default)        quits only if no drawing has unsaved changes; prints REFUSED and leaves AutoCAD running otherwise.
#   -DiscardChanges  closes every drawing without saving, quits, ends the process if it is still there.
#   -Force           ends the process at once (AutoCAD is hung); unsaved work is lost.
param([switch]$DiscardChanges, [switch]$Force)
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not (Get-Process acad -EA SilentlyContinue)) { 'acad not running'; exit 0 }
function Wait-AcadGone([int]$Sec) {
  for ($i = 0; $i -lt $Sec -and (Get-Process acad -EA SilentlyContinue); $i++) { Start-Sleep 1 }
  return -not (Get-Process acad -EA SilentlyContinue)
}
function Stop-AcadNow([string]$Done) {
  # Stop-Process returns before the process is gone; report only once acad.exe has really exited.
  Stop-Process -Name acad -Force
  if (Wait-AcadGone 30) { $Done; exit 0 } else { 'acad still running 30s after Stop-Process'; exit 1 }
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
$out = & (Join-Path $PSScriptRoot 'run-in-session.ps1') -Staged -HasQuery -WaitSec 0 -NoShot | Out-String
$line = ($out -split "`r?`n" | Where-Object { $_ -match 'quit sent|REFUSED|ERROR|TIMEOUT' } | Select-Object -First 1)
if ($line) { $line.Trim() }
if ($line -notmatch 'quit sent') {
  'acad left running. Save or close the drawings, re-run with -DiscardChanges (test drawings, user agreed), or -Force if it is hung.'
  exit 1
}
if (Wait-AcadGone 15) { 'acad closed' }
elseif ($DiscardChanges) { Stop-AcadNow 'acad process ended' }
else { 'acad still running after quit; check for a dialog (shot), or use -Force'; exit 1 }
