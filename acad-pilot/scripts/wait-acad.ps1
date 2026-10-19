# Waits until AutoCAD answers over COM and is quiescent; prints "ready after Ns" (exit 0) or the last state on timeout (exit 1).
# Works from SSH (polls through a one-shot task: window titles/handles can't be read from session 0) and from an interactive session.
param([int]$TimeoutSec = 240, [int]$EverySec = 2)
. (Join-Path $PSScriptRoot 'common.ps1')
$f = Join-Path $script:Out 'ready.txt'
$ready = Join-Path $PSScriptRoot 'acad-ready.ps1'
$t0 = Get-Date; $state = 'none: not checked'
while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
  Remove-Item $f -EA SilentlyContinue
  Invoke-InSession -Script $ready -TaskName 'AcadDevReady' -TimeoutSec 30 | Out-Null
  if (Test-Path $f) { $state = (Get-Content $f -Raw).Trim() }
  if ($state -eq 'ready') { "ready after $([int]((Get-Date) - $t0).TotalSeconds)s"; exit 0 }
  Start-Sleep $EverySec
}
"timeout after ${TimeoutSec}s: $state"; exit 1
