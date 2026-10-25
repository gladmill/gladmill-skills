# Starts AutoCAD in the interactive session and waits until it is ready (wait-acad.ps1). Works locally and from SSH.
#   -Exe      acad.exe (default: ACAD_DEV_EXE, else found in the registry: newest of 2024-2026)
#   -Product  /product switch (default: ACAD_DEV_PRODUCT; empty = none). Use ACAD if a vertical (e.g. Electrical) starts instead.
#   -Trust    folders to add to TRUSTEDPATHS once AutoCAD is ready, ';'-separated (default: ACAD_DEV_TRUSTED; empty = none).
#             End a folder with \... to include its subfolders. Plugins loaded from there skip the unsigned-file dialog.
param([string]$Exe = '', [string]$Product = $env:ACAD_DEV_PRODUCT, [string]$Trust = $env:ACAD_DEV_TRUSTED, [int]$TimeoutSec = 240)
. (Join-Path $PSScriptRoot 'common.ps1')
if (Get-Process acad -EA SilentlyContinue) { 'acad already running' }
else {
  if (-not $Exe) { $Exe = Find-Acad }
  if (-not $Exe) { 'acad.exe not found: set ACAD_DEV_EXE'; exit 1 }
  $sw = if ($Product) { " /product $Product" } else { '' }
  if (Test-Interactive) {
    if ($sw) { Start-Process $Exe -ArgumentList $sw.Trim() } else { Start-Process $Exe }
  } else {
    # a hidden cmd whose `start` shows AutoCAD normally (starting AutoCAD through run-hidden.vbs would hide it)
    $cmd = Join-Path $script:Home_ 'start-acad.cmd'
    Set-Content $cmd "@echo off`r`nstart `"`" `"$Exe`"$sw" -Encoding ASCII
    Invoke-InSession -Command "cmd /c $cmd" -TaskName 'AcadDevStart' -TimeoutSec 20 | Out-Null
  }
  $deadline = (Get-Date).AddMinutes(1)
  while (-not (Get-Process acad -EA 0) -and (Get-Date) -lt $deadline) { Start-Sleep 1 }
  if (-not (Get-Process acad -EA 0)) { 'acad did not start'; exit 1 }
  "acad pid $((Get-Process acad | Select-Object -First 1).Id) up ($Exe)"
}
& (Join-Path $PSScriptRoot 'wait-acad.ps1') -TimeoutSec $TimeoutSec
$rc = $LASTEXITCODE
if ($rc -eq 0 -and $Trust) {
  # task arguments can't carry the paths (spaces, quotes), so they go through a file
  Set-Content (Join-Path $script:Home_ 'trust.txt') ($Trust -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $r = Join-Path $script:Out 'trust.txt'; Remove-Item $r -EA SilentlyContinue
  Invoke-InSession -Script (Join-Path $PSScriptRoot 'trust-paths.ps1') -TaskName 'AcadDevTrust' -TimeoutSec 30 | Out-Null
  $msg = if (Test-Path $r) { (Get-Content $r -Raw).Trim() } else { 'trusted paths: FAILED no result' }
  $msg
  if ($msg -like '*FAILED*') { $rc = 1 }
}
exit $rc
