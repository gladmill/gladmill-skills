# OPTIONAL, opt-in. Run ONCE, as administrator, on a Windows VM you own and use only for unattended
# AutoCAD automation. It stops Windows Update from forcing a restart or popping the "restart to
# install" prompt — the one dialog the kit cannot dismiss from the automation session, because it is
# drawn by a higher-integrity system process. Do NOT run this on a workstation someone uses for real
# work; it defers updates, which is a security trade-off you are choosing for a throwaway test box.
#
# What it changes (all under HKLM policy keys, fully reversible — delete the values to undo):
#   - Windows Update: notify before installing, never auto-restart while a user is logged on.
#   - Pauses updates for the number of days given (default 35; the max Windows accepts is 35).
# It does not touch AutoCAD. Pair it with the AcadDevTrialWatch task (install-trial-watch.ps1), which
# closes the trial window and the Drawing Recovery manager.
param([int]$PauseDays = 35)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Error 'Run this in an elevated PowerShell (Run as administrator).'; exit 1
}
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty $au NoAutoRebootWithLoggedOnUsers 1 -Type DWord   # never force a restart while logged on
Set-ItemProperty $au AUOptions 2 -Type DWord                       # 2 = notify for download and install (no auto-install)
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
New-Item -Path $ux -Force | Out-Null
$until = (Get-Date).AddDays([Math]::Min($PauseDays,35)).ToString('yyyy-MM-ddTHH:mm:ssZ')
Set-ItemProperty $ux PauseUpdatesExpiryTime $until -Type String
"hardened: no forced restart while logged on; updates paused until $until"
"to undo: remove NoAutoRebootWithLoggedOnUsers and AUOptions under $au, and PauseUpdatesExpiryTime under $ux"
