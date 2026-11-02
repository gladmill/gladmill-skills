# Runs in the interactive session. Writes one line to <home>\out\ready.txt:
#   "ready" (AutoCAD answers over COM and is quiescent), "busy" (answers, but a command, prompt or dialog is active),
#   "none: <reason>" (not running, not registered yet, or the call was rejected).
#   -Tag t: write out\ready-<t>.txt instead (each stall check in run-in-session.ps1 uses its own file, so a late answer
#           from an earlier check that hung can never be read as the current one)
param([string]$Tag = '')
. (Join-Path $PSScriptRoot 'common.ps1')
try {
  $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
  $s = if ($acad.GetAcadState().IsQuiescent) { 'ready' } else { 'busy' }
} catch { $s = 'none: ' + $_.Exception.Message.Split("`n")[0] }
Set-Content (Join-Path $script:Out $(if ($Tag) { "ready-$Tag.txt" } else { 'ready.txt' })) $s
