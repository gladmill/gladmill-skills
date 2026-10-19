# OPTIONAL one-time setup: runs trial-watch.ps1 at every logon (interactive session) and starts it now.
# Undo: schtasks /delete /tn AcadDevTrialWatch /f, then stop the trial-watch powershell (schtasks /end stops only the run-hidden.vbs wrapper).
. (Join-Path $PSScriptRoot 'common.ps1')
if ($PSScriptRoot -match '\s') { throw 'The scripts folder must not contain spaces' }
$tr = "wscript //B //Nologo $PSScriptRoot\run-hidden.vbs powershell -NoProfile -ExecutionPolicy Bypass -File $PSScriptRoot\trial-watch.ps1"
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '(?<!install-)trial-watch\.ps1' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
schtasks /create /tn AcadDevTrialWatch /tr $tr /sc onlogon /it /f /rl limited 2>$null | Out-Null
schtasks /run /tn AcadDevTrialWatch | Out-Null
schtasks /query /tn AcadDevTrialWatch /fo list | Select-String 'TaskName|Status'
