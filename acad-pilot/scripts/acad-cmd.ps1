# Runs in the interactive session. Sends commands to the running AutoCAD over COM, writes the command-line log delta and a
# screenshot to <home>\out, then done.txt.  Normally started by run-in-session.ps1, not by hand.
#   Commands: <home>\cmds.txt, separated by | ; the two characters \n inside a command = Enter
#   (so write paths with forward slashes: C:/new/plan.dwg; a literal | cannot be sent).  (schtasks /tr mangles
#   spaces, quotes and parentheses, so data never travels on the command line.)
#   -HasQuery: run <home>\query.ps1 first ($acad / $doc in scope; read-only COM queries; no AutoLISP)
#   -RunId: the run this worker belongs to (run-in-session.ps1 writes it to out\run.txt). When run.txt no longer holds it (the
#   run was stopped as stuck, or a newer run started), the worker sends no more commands and writes nothing more.
param([int]$WaitSec = 3, [switch]$HasQuery, [switch]$NoShot, [string]$RunId = '')
. (Join-Path $PSScriptRoot 'common.ps1')
$out = $script:Out
$runFile = Join-Path $out 'run.txt'
function Current { -not $RunId -or "$(Get-Content $runFile -Raw -EA SilentlyContinue)".Trim() -eq $RunId }
function Stop-Superseded { if ($RunId) { 'stopped' | Set-Content (Join-Path $out "stopped-$RunId.txt") }; exit 0 }
$res = Join-Path $out 'result.txt'; "" | Set-Content $res
function W($s) { if (Current) { Add-Content $res $s } }
$cmdsFile = Join-Path $script:Home_ 'cmds.txt'
$Cmds = if (Test-Path $cmdsFile) { Get-Content $cmdsFile -Raw } else { '' }
try {
  # Attach to AutoCAD's COM. The attach fails with MK_E_UNAVAILABLE when AutoCAD isn't running or hasn't registered yet, or is
  # rejected while a modal window is open. Retry a few times; before the last tries let the blocker guard deal with what it is
  # allowed to (the allowlist, and the built-in rule that closes AutoCAD's Drawing Recovery window), and say in words what is in the way.
  if (-not (Get-Process acad -ErrorAction SilentlyContinue)) { throw "AutoCAD is not running: start it first (start-acad.ps1 | acad-dev.sh start)." }
  $rec = @(Close-RecoveryWindows)   # up front, as before: a Drawing Recovery window must not cost the retry window below
  if ($rec) { W "guard: closed $($rec -join ', ') (built-in Drawing Recovery rule)"; Start-Sleep -Seconds 1 }
  $acad = $null; $guarded = $false
  for ($try = 0; $try -lt 3 -and -not $acad; $try++) {
    try { $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application') }
    catch {
      if ("$($_.Exception.Message)" -notmatch 'MK_E_UNAVAILABLE|0x800401E3|RPC_E_CALL_REJECTED|0x80010001|rejected|unavailable') { throw }
      if ($try -eq 2) { break }   # last try: no point waiting again
      if (-not $guarded -and (Test-BlockerAutoAction) -and (Current)) {
        $guarded = $true; $g = Get-BlockerReport -Apply -NoShot
        if ($g.Applied -gt 0) { W "guard: $($g.Applied) window(s) dealt with (allowlist / Drawing Recovery rule)" }
      }
      Start-Sleep -Seconds 2
    }
  }
  if (-not $acad) {
    $g = Get-BlockerReport -NoShot -TimeoutSec 40
    throw "AutoCAD is not answering COM. $(if ($g.Blocked) { $g.Text } else { 'A modal dialog may be open (a licence/sign-in window, or a command waiting at a prompt): see the screenshot in out\screen.png (acad-dev.sh screen), dismiss it, and retry.' })"
  }
  $doc = try { $acad.ActiveDocument } catch { $null }   # COM can throw when no drawing is open (Start tab)
  if (-not $doc -and (Test-BlockerAutoAction) -and (Current)) {
    # no drawing: AutoCAD's Drawing Recovery window (after a crash) can leave ActiveDocument null; let the guard close it
    $g = Get-BlockerReport -Apply -NoShot
    if ($g.Applied -gt 0) { W "guard: $($g.Applied) window(s) dealt with (allowlist / Drawing Recovery rule)"; Start-Sleep -Seconds 1; $doc = try { $acad.ActiveDocument } catch { $null } }
  }
  # Only commands need a drawing; a query (e.g. stop, close-all) must work from the Start tab with none open.
  if (-not $doc -and $Cmds) { W "no active doc, adding one"; $doc = $acad.Documents.Add(); Start-Sleep 5; $doc = try { $acad.ActiveDocument } catch { $null } }
  W "acad: $($acad.Version) doc: $($doc.Name)"
  # From here on (the query and the commands), calls AutoCAD rejects as busy are retried (common.ps1).
  $why = Register-ComRetry; if ($why) { W $why }
  if ($HasQuery) {
    $q = Join-Path $script:Home_ 'query.ps1'
    try { $qout = . $q | Out-String -Width 200 }
    catch {
      # still rejected after the retry window: say what is in the way. A query is not repeated on its own (it may not be safe to).
      if (Test-ComRejected $_) {
        $g = Get-BlockerReport -Apply:((Test-BlockerAutoAction) -and (Current)) -TimeoutSec 40
        $script:BlockerReported = $true
        if ($g.Applied -gt 0) { W 'guard: an allowlisted window was dealt with; the query was not repeated (it may not be safe to repeat): run it again' }
        W $g.Text
      }
      throw
    }
    foreach ($l in $qout -split "`r?`n") { if ($l) { W $l } }
  }
  if ($Cmds) {
    Invoke-Guarded { if ($doc.GetVariable('LOGFILEMODE') -ne 1) { $doc.SetVariable('LOGFILEMODE', 1) } } 'LOGFILEMODE' { Current }
    $logdir = Invoke-Guarded { $doc.GetVariable('LOGFILEPATH') } 'LOGFILEPATH' { Current }; W "logpath: $logdir"
    # The log is named after the drawing when logging started, so take the name before a command can rename it (SAVEAS).
    $pat = '^' + [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($doc.Name)) + '_[0-9a-f]+\.log$'
    $prog = Join-Path $out 'progress.txt'; $n = 0
    foreach ($c in ($Cmds -split '\|')) {
      if ($c -eq '') { continue }
      if (-not (Current)) { Stop-Superseded }
      W ">> $c"
      $n++; Add-Content $prog "sent $n $c"   # run-in-session.ps1 watches this to spot a command stuck at a prompt
      # a rejected SendCommand did not run, so it is safe to repeat once after the guard dealt with an allowlisted window
      $text = $c -replace '\\n', "`n"
      Invoke-Guarded { $doc.SendCommand($text) } "SendCommand $n" { Current } | Out-Null
      if (Current) { Add-Content $prog "back $n" } else { Stop-Superseded }   # stopped-<RunId>.txt promptly: run-in-session waits for it after Esc
      Start-Sleep -Seconds $WaitSec
    }
    if (-not (Current)) { Stop-Superseded }
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
} catch {
  W "ERROR: $_"
  # a COM call AutoCAD rejected anywhere else (attach, first reads): say what is in the way, unless the message already does
  if ((Test-ComRejected $_) -and "$_" -notmatch 'BLOCKED BY:' -and -not $script:BlockerReported) { try { $g = Get-BlockerReport -NoShot -TimeoutSec 40; W $g.Text } catch { } }
}
if (-not $NoShot) {
  try { Save-Screenshot (Join-Path $out 'screen.png'); W "screenshot ok" } catch { W "screenshot ERROR: $_" }
}
if (-not (Current)) { Stop-Superseded }
$(if ($RunId) { $RunId } else { 'done' }) | Set-Content (Join-Path $out 'done.txt')
