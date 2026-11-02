# What is blocking AutoCAD? Lists its dialogs, message boxes and other windows in the way (title, class, kind, texts, buttons,
# modal or not), Autodesk licensing helper windows, other programs' windows in front of it, the main frame's state and the command
# line state over COM, plus a screenshot (out\blockers.png). Run it FIRST when anything stalls. Works locally and from SSH (the
# look is taken in the interactive session). Report-only unless -Apply.
#   blockers.ps1                 report
#   blockers.ps1 -Apply          also do what the allowlist (<home>\blockers.txt) says for matching windows (close / press a
#                                button), then report what is left. The built-in denylist always wins: security prompts, licence /
#                                sign-in / trial screens and save-changes prompts are never touched.
#   -NoShot                      no screenshot
#   -TimeoutSec n                give up after n s (default 60)
# Exit 0: nothing blocks AutoCAD. Exit 6: something blocks it (the report starts with "BLOCKED BY:").
param([switch]$Apply, [switch]$NoShot, [int]$TimeoutSec = 60)
. (Join-Path $PSScriptRoot 'common.ps1')
if ($TimeoutSec -le 0) { $TimeoutSec = 60 }
$r = Get-BlockerReport -Apply:$Apply -NoShot:$NoShot -TimeoutSec $TimeoutSec
$r.Text
if ($r.Blocked) { exit 6 }
exit 0
