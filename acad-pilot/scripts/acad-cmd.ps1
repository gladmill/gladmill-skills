# Runs in the interactive session. Sends commands to the running AutoCAD over COM, writes the command-line log delta and a
# screenshot to <home>\out, then done.txt.  Normally started by run-in-session.ps1, not by hand.
#   Commands: <home>\cmds.txt, separated by | ; the two characters \n inside a command = Enter
#   (so write paths with forward slashes: C:/new/plan.dwg; a literal | cannot be sent).  (schtasks /tr mangles
#   spaces, quotes and parentheses, so data never travels on the command line.)
#   -HasQuery: run <home>\query.ps1 first ($acad / $doc in scope; read-only COM queries; no AutoLISP)
param([int]$WaitSec = 3, [switch]$HasQuery, [switch]$NoShot)
. (Join-Path $PSScriptRoot 'common.ps1')
$out = $script:Out
$res = Join-Path $out 'result.txt'; "" | Set-Content $res
function W($s) { Add-Content $res $s }
$cmdsFile = Join-Path $script:Home_ 'cmds.txt'
$Cmds = if (Test-Path $cmdsFile) { Get-Content $cmdsFile -Raw } else { '' }
try {
  $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
  $doc = try { $acad.ActiveDocument } catch { $null }   # COM can throw when no drawing is open (Start tab)
  # Only commands need a drawing; a query (e.g. stop, close-all) must work from the Start tab with none open.
  if (-not $doc -and $Cmds) { W "no active doc, adding one"; $doc = $acad.Documents.Add(); Start-Sleep 5; $doc = try { $acad.ActiveDocument } catch { $null } }
  W "acad: $($acad.Version) doc: $($doc.Name)"
  if ($HasQuery) {
    $q = Join-Path $script:Home_ 'query.ps1'
    foreach ($l in (. $q | Out-String -Width 200) -split "`r?`n") { if ($l) { W $l } }
  }
  if ($Cmds) {
    if ($doc.GetVariable('LOGFILEMODE') -ne 1) { $doc.SetVariable('LOGFILEMODE', 1) }
    $logdir = $doc.GetVariable('LOGFILEPATH'); W "logpath: $logdir"
    foreach ($c in ($Cmds -split '\|')) {
      if ($c -eq '') { continue }
      W ">> $c"
      $doc.SendCommand(($c -replace '\\n', "`n"))
      Start-Sleep -Seconds $WaitSec
    }
    Start-Sleep -Seconds 1
    $doc.SetVariable('LOGFILEMODE', 0)   # closes the log so it is flushed
    $log = Get-ChildItem $logdir -Filter *.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    W "--- $($log.Name) (tail) ---"; Get-Content $log.FullName -Tail 40 | ForEach-Object { W $_ }
    $doc.SetVariable('LOGFILEMODE', 1)
  }
} catch { W "ERROR: $_" }
if (-not $NoShot) {
  try { Save-Screenshot (Join-Path $out 'screen.png'); W "screenshot ok" } catch { W "screenshot ERROR: $_" }
}
'done' | Set-Content (Join-Path $out 'done.txt')
