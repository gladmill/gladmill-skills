# Runs in the interactive session. Sends commands to the running AutoCAD over COM, writes the command-line log delta and a
# screenshot to <home>\out, then done.txt.  Normally started by run-in-session.ps1, not by hand.
#   Commands: <home>\cmds.txt, separated by | ; the two characters \n inside a command = Enter
#   (so write paths with forward slashes: C:/new/plan.dwg; a literal | cannot be sent).  (schtasks /tr mangles
#   spaces, quotes and parentheses, so data never travels on the command line.)
#   -HasQuery: run <home>\query.ps1 first ($acad / $doc in scope; read-only COM queries; no AutoLISP)
param([int]$WaitSec = 3, [switch]$HasQuery, [switch]$NoShot)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'clear-blockers.ps1')
$out = $script:Out
$res = Join-Path $out 'result.txt'; "" | Set-Content $res
function W($s) { Add-Content $res $s }
$cmdsFile = Join-Path $script:Home_ 'cmds.txt'
$Cmds = if (Test-Path $cmdsFile) { Get-Content $cmdsFile -Raw } else { '' }
try {
  # Attach to AutoCAD's COM. The attach fails with MK_E_UNAVAILABLE when AutoCAD isn't running or hasn't registered yet,
  # and a modal window (Drawing Recovery) can leave ActiveDocument null even when it succeeds. Close the windows we safely
  # can first, retry the attach a few times, and report failures in words (not a raw HRESULT). A screenshot is taken below.
  if (-not (Get-Process acad -ErrorAction SilentlyContinue)) { throw "AutoCAD is not running: start it first (start-acad.ps1 | acad-dev.sh start)." }
  $blk = Clear-Blockers   # proactive: Drawing Recovery does not make the attach throw, so clear it up front
  if (@($blk.closed)) { W "cleared dialog(s): $(@($blk.closed) -join ', ')"; Start-Sleep -Seconds 1 }
  $acad = $null
  for ($try = 0; $try -lt 3 -and -not $acad; $try++) {
    try { $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application') }
    catch {
      if ("$($_.Exception.Message)" -match 'MK_E_UNAVAILABLE|0x800401E3|RPC_E_CALL_REJECTED|0x80010001|rejected|unavailable') {
        if ($try -eq 2) { break }   # last try: no point clearing and waiting again
        $blk = Clear-Blockers
        if (@($blk.closed)) { W "cleared dialog(s): $(@($blk.closed) -join ', ')" }
        Start-Sleep -Seconds 2
      } else { throw }
    }
  }
  if (-not $acad) {
    $hint = if ($blk -and @($blk.manual)) { "a $(@($blk.manual) -join ', ') is open and must be dismissed by hand" }
            else { "a modal dialog is likely open (Drawing Recovery, a licence/sign-in window, or a command waiting at a prompt)" }
    throw "AutoCAD is not answering COM: $hint. See the screenshot in out\screen.png (acad-dev.sh screen), dismiss it, and retry."
  }
  $doc = try { $acad.ActiveDocument } catch { $null }   # COM can throw when no drawing is open (Start tab)
  # Only commands need a drawing; a query (e.g. stop, close-all) must work from the Start tab with none open.
  if (-not $doc -and $Cmds) { W "no active doc, adding one"; $doc = $acad.Documents.Add(); Start-Sleep 5; $doc = try { $acad.ActiveDocument } catch { $null } }
  W "acad: $($acad.Version) doc: $($doc.Name)"
  # From here on (the query and the commands), calls AutoCAD rejects as busy are retried (common.ps1). Registered only now, so
  # a blocked attach still goes to the dialog-clearing loop above and a dialog that is already up affects the reads above as before
  # instead of costing the retry wait on each.
  $why = Register-ComRetry; if ($why) { W $why }
  if ($HasQuery) {
    $q = Join-Path $script:Home_ 'query.ps1'
    foreach ($l in (. $q | Out-String -Width 200) -split "`r?`n") { if ($l) { W $l } }
  }
  if ($Cmds) {
    if ($doc.GetVariable('LOGFILEMODE') -ne 1) { $doc.SetVariable('LOGFILEMODE', 1) }
    $logdir = $doc.GetVariable('LOGFILEPATH'); W "logpath: $logdir"
    # The log is named after the drawing when logging started, so take the name before a command can rename it (SAVEAS).
    $pat = '^' + [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($doc.Name)) + '_[0-9a-f]+\.log$'
    foreach ($c in ($Cmds -split '\|')) {
      if ($c -eq '') { continue }
      W ">> $c"
      $doc.SendCommand(($c -replace '\\n', "`n"))
      Start-Sleep -Seconds $WaitSec
    }
    Start-Sleep -Seconds 1
    $doc.SetVariable('LOGFILEMODE', 0)   # closes the log so it is flushed
    # Each open drawing writes its own <drawing>_<hex>.log, so with several open the newest log can be another drawing's.
    # Take the newest log of the drawing the commands went to; fall back to the newest log and say so.
    $logs = @(Get-ChildItem $logdir -Filter *.log | Sort-Object LastWriteTime -Descending)
    $log = $logs | Where-Object { $_.Name -match $pat } | Select-Object -First 1
    if (-not $log) { $log = $logs | Select-Object -First 1; W "(no log named for $($doc.Name); showing the newest)" }
    W "--- $($log.Name) (tail) ---"; Get-Content $log.FullName -Tail 40 | ForEach-Object { W $_ }
    $doc.SetVariable('LOGFILEMODE', 1)
  }
} catch { W "ERROR: $_" }
if (-not $NoShot) {
  try { Save-Screenshot (Join-Path $out 'screen.png'); W "screenshot ok" } catch { W "screenshot ERROR: $_" }
}
'done' | Set-Content (Join-Path $out 'done.txt')
