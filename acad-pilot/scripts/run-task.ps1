# Runs one of the session-only scripts (esc.ps1, shot.ps1, wincancel.ps1, ...) where a desktop exists: directly when you are in
# an interactive session, as a one-shot interactive scheduled task from SSH. Task arguments cannot contain spaces
# (for wincancel's -Title use the file <home>\title.txt, which this script writes from -Title).
#   run-task.ps1 esc.ps1        run-task.ps1 shot.ps1        run-task.ps1 wincancel.ps1 -Title "Some Dialog"
param([Parameter(Mandatory)][string]$Script, [string]$Title = '', [int]$TimeoutSec = 60)
. (Join-Path $PSScriptRoot 'common.ps1')
if ($Title) { Set-Content (Join-Path $script:Home_ 'title.txt') $Title -NoNewline -Encoding UTF8 }
Remove-Item (Join-Path $script:Out 'done.txt') -EA SilentlyContinue
Invoke-InSession -Script (Join-Path $PSScriptRoot $Script) -TaskName 'AcadDevRun' -TimeoutSec $TimeoutSec
