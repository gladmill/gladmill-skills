# OPTIONAL, opt-in. Run ONCE, as administrator, on a Windows VM you own and use only for unattended
# AutoCAD automation. It keeps Windows Update from installing and restarting on its own, so a forced
# restart or a "restart to install" prompt doesn't interrupt an unattended run (that prompt belongs to
# another process and can't be dismissed from the automation session). Do NOT run this on a workstation
# someone uses for real work: it turns off automatic updates, a security trade-off you are choosing for
# a throwaway test box. Nothing in the kit runs it for you.
#
# What it changes (HKLM; it prints each value's previous state first, so you can put it back):
#   - Windows Update policy (...\Policies\Microsoft\Windows\WindowsUpdate\AU): AUOptions = 2 (notify before
#     download and install: no automatic installs until you remove the value) and NoAutoRebootWithLoggedOnUsers = 1.
#   - Windows Update settings (...\WindowsUpdate\UX\Settings, not a policy key): PauseUpdatesExpiryTime, a pause
#     for the number of days given (default 35, the most Windows accepts).
# Existing keys are kept as they are; only these values are set.
# It does not touch AutoCAD. Pair it with the AcadDevTrialWatch task (install-trial-watch.ps1), which
# closes the trial window and the Drawing Recovery manager.
param([int]$PauseDays = 35)
$ErrorActionPreference = 'Stop'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  'Run this in an elevated PowerShell (Run as administrator).'; exit 1
}
function Show-Old($key, $name) {
  $v = (Get-ItemProperty $key -Name $name -ErrorAction SilentlyContinue).$name
  "before: $key $name = $(if ($null -eq $v) { '(not set)' } else { $v })"
}
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
if (-not (Test-Path $au)) { New-Item -Path $au -Force | Out-Null }   # New-Item -Force on an existing key would wipe its values
Show-Old $au NoAutoRebootWithLoggedOnUsers; Show-Old $au AUOptions
Set-ItemProperty $au NoAutoRebootWithLoggedOnUsers 1 -Type DWord   # never force a restart while logged on
Set-ItemProperty $au AUOptions 2 -Type DWord                       # 2 = notify for download and install (no auto-install)
$ux = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
if (-not (Test-Path $ux)) { New-Item -Path $ux -Force | Out-Null }
Show-Old $ux PauseUpdatesExpiryTime
$until = (Get-Date).ToUniversalTime().AddDays([Math]::Min($PauseDays, 35)).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
Set-ItemProperty $ux PauseUpdatesExpiryTime $until -Type String
"hardened: no automatic installs or restarts; updates paused until $until (UTC)"
"to undo: set the values back to the 'before' lines above (remove those that were not set)"
