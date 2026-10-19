# Screenshot only (no COM), for when AutoCAD is busy or blocked. Runs in the interactive session; use run-task.ps1 from SSH.
. (Join-Path $PSScriptRoot 'common.ps1')
Save-Screenshot (Join-Path $script:Out 'shot.png'); 'ok' | Set-Content (Join-Path $script:Out 'shot.txt')
