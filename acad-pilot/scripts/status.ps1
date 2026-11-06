# The AutoCAD status board: what AutoCAD and the tools driving it are doing right now. Read-only. Run it FIRST when anything looks stuck.
# Reads every status file in the status folder (ACAD_STATUS_DIR, default %ProgramData%\Gladmill\acad-status): the AcadStatus add-in
# (`acad`), other tools such as Retrace, and this kit's own `run` / `ui` / `wait` (`acad-pilot`), merges them by priority and prints one
# board: an overall line, then one line per entry (source, state, age, summary; for `acad` also the pending prompt and the open dialog's
# title, texts and buttons). It also says whether acad.exe runs and, when no `acad` entry exists, that the add-in is not installed or AutoCAD
# is not running. File format: references/status-board.md.
# Files are opened for reading with FileShare ReadWrite + Delete (Read-AcadStatusFile), so a writer replacing its file is never blocked.
# Quick when the AcadStatus add-in reports (a few file reads). Without it (acad.exe runs, no `acad` entry) it also runs the blocker scan,
# which takes a few seconds (up to 45 s when AutoCAD does not answer): that is the only way to see a dialog nothing reports. -NoScan skips it.
#   status.ps1 [-Json] [-NoScan]
#   -Json     print one JSON object {overall, exitCode, acadRunning, entries[], ignored[], skipped[], notes[], scan} instead of the board
#   -NoScan   do not add the blocker scan. By default, when the overall state is blocked or busy, or acad.exe runs and no `acad` entry
#             exists, the read-only blocker scan (blockers.ps1 without -Apply, no screenshot) is added; a blocker it finds makes the
#             overall state blocked (a `blocker-scan` entry). Nothing is ever closed or pressed. It is skipped when acad.exe is not running.
# Exit codes: 0 idle / nothing, 3 running, 4 waiting-input or needs-person, 5 busy, 6 blocked, 1 error or a state this reader does not
# know, 2 setup error (the status folder cannot be read).
param([switch]$Json, [switch]$NoScan)
. (Join-Path $PSScriptRoot 'common.ps1')
. (Join-Path $PSScriptRoot 'status-board.ps1')
$dir = Get-AcadStatusDir
if (-not $dir) { 'ERROR: no status folder: set ACAD_STATUS_DIR (%ProgramData% is not set)'; exit 2 }
$skipped = @(); $notes = @(); $parsed = @()
if (-not [IO.Directory]::Exists($dir)) {
  $notes += "The status folder $dir does not exist yet: nothing has written a status (it is created by the first writer)."
} else {
  try { $files = [IO.Directory]::GetFiles($dir); [Array]::Sort($files, [StringComparer]::Ordinal) } catch { "ERROR: cannot read the status folder ${dir}: $($_.Exception.Message)"; exit 2 }
  foreach ($path in $files) {
    $name = [IO.Path]::GetFileName($path)
    if (-not (Test-AcadStatusFileName $name)) { $skipped += [pscustomobject]@{ file = $name; reason = $script:AcadStatusNameReason }; continue }   # (listed in --json only)
    $bytes = Read-AcadStatusFile $path
    if ($null -eq $bytes) { $skipped += [pscustomobject]@{ file = $name; reason = 'could not be read this round (in use?)' }; continue }
    $r = ConvertFrom-AcadStatusBytes -Bytes $bytes -FileName $name
    if ($r.Ok) { $parsed += $r.Entry } else { $skipped += [pscustomobject]@{ file = $name; reason = $r.Reason } }
  }
}
$acadRunning = [bool](Get-Process acad -ErrorAction SilentlyContinue)
$merged = Merge-AcadStatus -Entries $parsed -Now ([DateTime]::UtcNow) -IsPidAlive { param($p, $started) Test-AcadStatusPidAlive $p $started }
$result = New-AcadStatusResult -Merged $merged -AcadRunning $acadRunning -Skipped $skipped -Notes $notes
$why = Get-AcadStatusScanReason -Overall $result.overall -AcadRunning $acadRunning -HasAcadEntry $merged.HasAcadEntry
$scan = $result.scan   # (the default object: not run, not needed)
if ($why) {
  if ($NoScan) { $scan.reason = "--no-scan; it would run because $why" }
  elseif (-not $acadRunning) { $scan.reason = 'acad.exe is not running, so no window of it can be in the way' }
  else {
    $g = Get-BlockerReport -NoShot -TimeoutSec 45   # read-only: never -Apply
    $scan.ran = $true; $scan.reason = $why; $scan.blocked = [bool]$g.Blocked; $scan.windows = [int]$g.Windows; $scan.text = "$($g.Text)".Trim()
  }
}
$result = Add-AcadStatusScan -Result $result -Scan $scan
if ($Json) { $result | ConvertTo-Json -Depth 10 -Compress } else { Format-AcadStatusBoard $result }
exit $result.exitCode
