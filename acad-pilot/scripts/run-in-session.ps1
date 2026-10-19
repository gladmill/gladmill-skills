# Sends commands to AutoCAD and prints the result. Works locally (runs acad-cmd.ps1 directly) and from SSH/session 0
# (runs it as a one-shot interactive scheduled task). Result file: <home>\out\result.txt, screenshot: <home>\out\screen.png.
#   -Cmds "LINE\n0,0\n100,100\n\n|ZOOM\nE\n"   commands split by |, \n = Enter (written to <home>\cmds.txt)
#   -Query q.ps1   read-only COM query run first ($acad/$doc in scope), copied to <home>\query.ps1
#   -TimeoutSec n  give up after n s (default: commands x (WaitSec+1) + 60, at least 120)
#   -Staged        use the cmds.txt / query.ps1 already in <home> (the Mac wrapper copies them there with scp)
param([string]$Cmds = '', [int]$WaitSec = 3, [int]$TimeoutSec = 0, [string]$Query = '', [switch]$Staged, [switch]$HasQuery, [switch]$NoShot)
. (Join-Path $PSScriptRoot 'common.ps1')
$done = Join-Path $script:Out 'done.txt'; Remove-Item $done, (Join-Path $script:Out 'result.txt') -EA SilentlyContinue
if (-not $Staged) {
  Set-Content (Join-Path $script:Home_ 'cmds.txt') $Cmds -Encoding UTF8 -NoNewline
  if ($Query) { Copy-Item $Query (Join-Path $script:Home_ 'query.ps1') -Force; $HasQuery = $true }
}
# Timeout: unless given, (number of commands x WaitSec) + 60 s margin for start-up, the query, the log read and the screenshot.
if ($TimeoutSec -le 0) {
  $cf = Join-Path $script:Home_ 'cmds.txt'
  $n = if (Test-Path $cf) { @((Get-Content $cf -Raw) -split '\|' | Where-Object { $_ }).Count } else { 0 }
  $TimeoutSec = [Math]::Max(120, $n * ($WaitSec + 1) + 60)
}
$a = "-WaitSec $WaitSec" + $(if ($HasQuery) { ' -HasQuery' } else { '' }) + $(if ($NoShot) { ' -NoShot' } else { '' })
Invoke-InSession -Script (Join-Path $PSScriptRoot 'acad-cmd.ps1') -ScriptArgs $a -TaskName 'AcadDevCmd' -TimeoutSec $TimeoutSec
$ok = Test-Path $done
Get-Content (Join-Path $script:Out 'result.txt') -EA SilentlyContinue
if (-not $ok) { "TIMEOUT (no done.txt after ${TimeoutSec}s): AutoCAD may be waiting at a prompt or dialog; run esc.ps1 / shot.ps1"; exit 1 }
