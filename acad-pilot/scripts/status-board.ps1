# Status board: pure functions (no Win32, no COM, no disk access). NOT loaded by common.ps1: the scripts that write or read the status
# dot-source it themselves, right after common.ps1 (status.ps1, run-in-session.ps1, ui.ps1, wait-acad.ps1, start-acad.ps1, stop-acad.ps1),
# so the workers do not carry it. Unit tests for this file are kept with the kit's development sources. The file format (contract v1) is
# described in references/status-board.md.
#
# One status file per writer lives in the status folder (ACAD_STATUS_DIR, default %ProgramData%\Gladmill\acad-status). A reader
# (status.ps1) parses every file the contract allows, merges them by state priority and prints one board. This kit's scripts write one
# file each, `acad-pilot-<pid>.json` (Write-AcadStatus in common.ps1). Everything here runs in Windows PowerShell 5.1 and PowerShell 7.
#
# Display priority, highest first: blocked > needs-person > waiting-input > busy > error > running > (unknown state) > idle > stopped.
# A stale entry (older than its ttlSec) counts as busy while its pid is alive, and is ignored once the pid is gone. A stale `stopped`
# entry is dropped: it says only that the writer is gone.

$script:AcadStatusFilePattern = '^[a-z0-9][a-z0-9-]{0,39}\.json$'
$script:AcadStatusSourcePattern = '^[a-z0-9][a-z0-9-]{0,39}$'
$script:AcadStatusNameReason = 'file name not allowed (only <source>.json and <source>-<instance>.json are read)'   # (a skipped file the board does not list)
$script:AcadStatusRequired = @('v', 'source', 'writer', 'pid', 'updated', 'ttlSec', 'state', 'summary')

function Test-AcadStatusFileName {
  # Readers read only files with these names (case-sensitive): <source>.json or <source>-<instance>.json. A `.tmp-` file or a
  # <source>.v2.json (a later, breaking format) does not match.
  param([string]$Name)
  return ("$Name" -cmatch $script:AcadStatusFilePattern)
}

# (-is [System.Management.Automation.PSCustomObject], not [pscustomobject]: in Windows PowerShell 5.1 that accelerator is PSObject, which every value -is.)
function Test-AcadStatusInt($Value) {
  # A JSON integer as ConvertFrom-Json gives it (Int32 / Int64). Not a string, a boolean or a fraction (Double / Decimal).
  return (($Value -is [int]) -or ($Value -is [long]))
}

function Test-AcadStatusPidStart {
  # Windows reuses process ids. A status file may carry `pidStart` (the start time of process `pid`, UTC): when the live process with that
  # pid started more than 2 s apart from it, it is another process and the writer is gone. $Recorded null (field absent) = no objection.
  param($Recorded, $Actual)
  if ($null -eq $Recorded -or $null -eq $Actual) { return $true }
  return ([Math]::Abs(($Recorded.ToUniversalTime() - $Actual.ToUniversalTime()).TotalSeconds) -le 2)
}

function Get-AcadStatusRefreshGap {
  # Seconds between a writer's refreshes: 4 (the file's ttl is 15 s). After 3 or more failed writes in a row it backs off, 2 s more per
  # further failure, at most 10 s; one good write puts it back to 4.
  param([int]$Fails)
  if ($Fails -lt 3) { return 4 }
  return [Math]::Min(10, 4 + 2 * ($Fails - 2))
}

function Get-AcadStatusRank {
  # Display priority of a state; higher first. An unknown state sits just above idle.
  param([string]$State)
  switch -CaseSensitive ($State) {
    'blocked' { return 70 }
    'needs-person' { return 60 }
    'waiting-input' { return 50 }
    'busy' { return 40 }
    'error' { return 30 }
    'running' { return 20 }
    'idle' { return 5 }
    'stopped' { return 0 }
    default { return 10 }
  }
}

function Limit-AcadStatusText {
  # One line, at most $Max characters.
  param($Text, [int]$Max = 200)
  if ($Text -is [DateTime]) { $Text = ConvertTo-AcadStatusIso $Text }   # (PowerShell 7 turns ISO-looking strings into dates)
  $t = ("$Text" -replace '\s+', ' ').Trim()
  if ($t.Length -gt $Max) { $t = $t.Substring(0, [Math]::Max(0, $Max - 3)) + '...' }
  return $t
}

function Join-AcadStatusSummary {
  # "Head: Text", or just "Head" when there is no text (a summary never ends in ': ').
  param([string]$Head, $Text)
  $t = "$Text".Trim()
  if ($t) { return "${Head}: $t" }
  return $Head
}

function Get-AcadStatusBlockedLine {
  # The first "BLOCKED BY: ..." line of a blocker report (a string or an array of lines), else $Fallback. One place for the rule the
  # scripts use for the summary of a `blocked` entry; pass -Fallback '' to ask "is there one?".
  param($Text, [string]$Fallback = "BLOCKED BY: a window in AutoCAD's way")
  $line = @(@($Text) -split "`r?`n" | Where-Object { "$_" -match '^\s*BLOCKED BY:' } | Select-Object -First 1)
  if ($line.Count -and "$($line[0])".Trim()) { return (Limit-AcadStatusText $line[0] 200) }
  return $Fallback
}

function Test-AcadStatusRemovable {
  # Housekeeping of the kit's own files (acad-pilot-<pid>.json) when a kit script starts: is this file left over? $Legacy: the old single
  # acad-pilot.json, removable as soon as it is stale. Any other file: its writer is gone ($PidAlive false) and it was last written over
  # 10 minutes ago. (The AcadStatus add-in cleans its own and Retrace's files after an hour.)
  param($Entry, [DateTime]$Now, [bool]$PidAlive, [bool]$Legacy = $false)
  $age = ($Now.ToUniversalTime() - $Entry.Updated).TotalSeconds
  if ($Legacy) { return ($age -gt $Entry.TtlSec) }
  return ((-not $PidAlive) -and $age -gt 600)
}

function Get-AcadStatusUiSteps {
  # The ui steps as they may go into a status file readable by every local user: the verb and its target, never what is typed.
  # `set <label>=<value>` -> `set <label>`; `type <text>` -> `type`; `keys <sendkeys>` -> `keys`; `expect <regex>` -> `expect` (the pattern
  # often repeats a value); `command <text>` -> `command <first word>` (what follows can be answers to its prompts, typed with \n).
  # The steps that name a target (ribbon, dialog, alert, press, click, closed, front, shot, move, idle, sleep, timeout) keep it; any other
  # verb, a misspelled `sett Password=x` too, keeps the verb only.
  param([string[]]$Steps)
  foreach ($s in @($Steps)) {
    $t = "$s".Trim()
    if (-not $t) { continue }
    $verb, $arg = $t -split '\s+', 2
    switch -CaseSensitive ($verb.ToLowerInvariant()) {
      'set' { if ("$arg" -match '^([^=]*)=') { "set $($Matches[1].Trim())" } else { 'set' } }
      'type' { 'type' }
      'keys' { 'keys' }
      'expect' { 'expect' }
      'command' { if ("$arg" -match '^\s*(\S+?)(\\n|\s|$)') { "command $($Matches[1])" } else { 'command' } }
      { $_ -in 'ribbon', 'dialog', 'alert', 'press', 'click', 'closed', 'front', 'shot', 'move', 'idle', 'sleep', 'timeout' } { $t }
      default { $verb }
    }
  }
}

function ConvertTo-AcadStatusTime {
  # A [DateTime] in UTC from what ConvertFrom-Json gives for `updated`: Windows PowerShell 5.1 leaves an ISO 8601 string as a string,
  # PowerShell 7 turns it into a [DateTime]. $null when it is neither a date nor a parsable string.
  param($Value)
  if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
  if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
  if ($Value -is [string] -and $Value.Trim()) {
    $d = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParse($Value.Trim(), [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
  }
  return $null
}

function ConvertTo-AcadStatusIso([DateTime]$Time) {
  return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-AcadStatusIsoMs([DateTime]$Time) {
  # With milliseconds, for pidStart: two scripts started in the same second are told apart.
  return $Time.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-AcadStatusAge {
  param([double]$Sec)
  $s = [int][Math]::Max(0, [Math]::Floor($Sec))
  if ($s -lt 60) { return "${s}s" }
  if ($s -lt 3600) { return ('{0}m{1:00}s' -f [Math]::Floor($s / 60), ($s % 60)) }
  return ('{0}h{1:00}m' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60))
}

function ConvertFrom-AcadStatusBytes {
  # Parses the bytes of one status file. Returns Ok (bool), Reason (why it was skipped) and Entry. Never throws.
  # UTF-8, a BOM is tolerated (the contract says none, a hand-made file may have one). A file is skipped when it is empty, not a JSON
  # object, lacks a required field, has one of the wrong type, or has a `v` that is not an integer >= 1. Unknown fields are ignored.
  param([byte[]]$Bytes, [string]$FileName = '')
  function Skip([string]$Why) { [pscustomobject]@{ Ok = $false; Reason = $Why; Entry = $null } }
  try {
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return (Skip 'empty file') }
    $from = 0
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $from = 3 }
    $text = (New-Object Text.UTF8Encoding($false)).GetString($Bytes, $from, $Bytes.Length - $from)
    $trim = $text.Trim()
    if (-not $trim) { return (Skip 'empty file') }
    if ($trim[0] -ne '{') { return (Skip 'not a JSON object') }   # (PowerShell 5.1 and 7 differ on a one-element array)
    $o = $null
    try { $o = $trim | ConvertFrom-Json -ErrorAction Stop } catch { return (Skip 'not valid JSON') }
    if ($o -isnot [System.Management.Automation.PSCustomObject]) { return (Skip 'not a JSON object') }
    foreach ($f in $script:AcadStatusRequired) {
      $p = $o.PSObject.Properties[$f]
      if (-not $p -or $null -eq $p.Value) { return (Skip "missing required field '$f'") }
    }
    # PowerShell 7 turns a string that looks like a date into a [DateTime] (Windows PowerShell 5.1 leaves it): put the text fields back
    # as ISO text before they are checked, so a file with a date-like summary or writer is not dropped. (The original spelling is lost;
    # a UTC time written with Z comes back exactly, a bare date as the UTC time of its local midnight.)
    foreach ($n in 'source', 'writer', 'state', 'summary', 'short', 'owner') {
      $q = $o.PSObject.Properties[$n]
      if ($q -and $q.Value -is [DateTime]) { $q.Value = ConvertTo-AcadStatusIso $q.Value }
    }
    if (-not (Test-AcadStatusInt $o.v) -or $o.v -lt 1) { return (Skip 'v is not an integer >= 1') }
    if ($o.source -isnot [string] -or $o.source -cnotmatch $script:AcadStatusSourcePattern) { return (Skip "field 'source' is not a source name") }
    if ($o.writer -isnot [string]) { return (Skip "field 'writer' is not a string") }
    if (-not (Test-AcadStatusInt $o.pid)) { return (Skip "field 'pid' is not an integer") }
    if (-not (Test-AcadStatusInt $o.ttlSec) -or $o.ttlSec -lt 1) { return (Skip "field 'ttlSec' is not an integer >= 1") }
    if ($o.state -isnot [string] -or -not $o.state.Trim()) { return (Skip "field 'state' is not a non-empty string") }
    if ($o.summary -isnot [string]) { return (Skip "field 'summary' is not a string") }
    $updated = ConvertTo-AcadStatusTime $o.updated
    if ($null -eq $updated) { return (Skip "field 'updated' is not a UTC ISO 8601 time") }
    $opt = { param($n) $q = $o.PSObject.Properties[$n]; if ($q -and $q.Value -is [string] -and $q.Value.Trim()) { $q.Value } else { $null } }
    $since = $null; $sp = $o.PSObject.Properties['since']; if ($sp) { $since = ConvertTo-AcadStatusTime $sp.Value }
    $pidStart = $null; $ps = $o.PSObject.Properties['pidStart']; if ($ps) { $pidStart = ConvertTo-AcadStatusTime $ps.Value }   # optional; unusable = absent
    $detail = $null; $dp = $o.PSObject.Properties['detail']; if ($dp -and $dp.Value -is [System.Management.Automation.PSCustomObject]) { $detail = $dp.Value }
    $entry = [pscustomobject]@{
      File = $FileName; Source = [string]$o.source; Writer = [string]$o.writer; Pid = [int]$o.pid; PidStart = $pidStart; Updated = $updated; TtlSec = [int]$o.ttlSec
      State = $o.state.Trim(); Summary = (Limit-AcadStatusText $o.summary 200); Short = (& $opt 'short'); Since = $since; Owner = (& $opt 'owner'); Detail = $detail
    }
    return [pscustomobject]@{ Ok = $true; Reason = ''; Entry = $entry }
  } catch { return (Skip "unreadable: $($_.Exception.Message.Split("`n")[0])") }
}

function Merge-AcadStatus {
  # Merges parsed entries at time $Now: works out which are stale, ranks them, drops what must be ignored.
  #   -IsPidAlive  scriptblock taking a pid and the entry's pidStart (or $null) and returning $true when that process is running
  #                (and, with a pidStart, is the same process: Test-AcadStatusPidAlive in common.ps1); only asked for stale entries
  # Returns Entries (highest priority first), Ignored (file, source, reason), Overall ('none' when nothing but stopped entries) and
  # HasAcadEntry (a live `acad` entry, i.e. the AcadStatus add-in reports).
  param($Entries, [DateTime]$Now, [scriptblock]$IsPidAlive)
  $shown = @(); $ignored = @()
  foreach ($e in @($Entries | Where-Object { $null -ne $_ })) {
    $age = [Math]::Max(0, ($Now.ToUniversalTime() - $e.Updated).TotalSeconds)
    $stale = $age -gt $e.TtlSec
    $state = $e.State; $alive = $null
    if ($stale) {
      if ($e.State -ceq 'stopped') { $ignored += [pscustomobject]@{ file = $e.File; source = $e.Source; reason = 'stale, state stopped (the writer is gone)' }; continue }
      $alive = [bool](& $IsPidAlive $e.Pid $e.PidStart)
      if (-not $alive) {
        $gone = if ($e.PidStart) { 'is gone (or the id was reused)' } else { 'is gone' }
        $ignored += [pscustomobject]@{ file = $e.File; source = $e.Source; reason = "stale ($(Format-AcadStatusAge $age) old), pid $($e.Pid) $gone" }; continue
      }
      $state = 'busy'   # the writer cannot refresh its file but is alive: not answering
    }
    $shown += [pscustomobject]@{
      source = $e.Source; file = $e.File; state = $state; reportedState = $e.State; stale = $stale; ageSec = [int][Math]::Floor($age); ttlSec = $e.TtlSec
      pid = $e.Pid; pidStart = $(if ($e.PidStart) { ConvertTo-AcadStatusIsoMs $e.PidStart } else { $null }); pidAlive = $alive; writer = $e.Writer; owner = $e.Owner; summary = $e.Summary; short = $e.Short
      since = $(if ($e.Since) { ConvertTo-AcadStatusIso $e.Since } else { $null }); updated = (ConvertTo-AcadStatusIso $e.Updated); detail = $e.Detail
      rank = (Get-AcadStatusRank $state)
    }
  }
  $sorted = @($shown | Sort-Object @{ Expression = { $_.rank }; Descending = $true }, @{ Expression = { $_.source } }, @{ Expression = { $_.file } })
  [pscustomobject]@{ Entries = $sorted; Ignored = $ignored; Overall = (Get-AcadStatusOverall $sorted); HasAcadEntry = (@($sorted | Where-Object { $_.source -ceq 'acad' }).Count -gt 0) }
}

function Get-AcadStatusOverall {
  # The state of the highest-ranked entry; 'none' when there is no entry or only stopped ones. Entries must be sorted.
  param($Entries)
  $live = @($Entries | Where-Object { $_.state -cne 'stopped' })
  if ($live.Count -eq 0) { return 'none' }
  return [string]$live[0].state
}

function Get-AcadStatusExitCode {
  # 0 idle / nothing, 3 running, 4 waiting-input or needs-person, 5 busy, 6 blocked, 1 error or a state this reader does not know.
  # (2, a setup error, is the reader's own.)
  param([string]$Overall)
  switch -CaseSensitive ($Overall) {
    'none' { return 0 }
    'idle' { return 0 }
    'stopped' { return 0 }
    'running' { return 3 }
    'waiting-input' { return 4 }
    'needs-person' { return 4 }
    'busy' { return 5 }
    'blocked' { return 6 }
    default { return 1 }
  }
}

function Get-AcadStatusScanReason {
  # Why the blocker scan should be added to the board, or $null when it is not needed: the status is blocked or busy, or acad.exe runs
  # and nothing reports its state (no AcadStatus add-in), so a dialog would go unseen.
  param([string]$Overall, [bool]$AcadRunning, [bool]$HasAcadEntry)
  if ($Overall -ceq 'blocked' -or $Overall -ceq 'busy') { return "the status is $Overall" }
  if ($AcadRunning -and -not $HasAcadEntry) { return 'acad.exe is running and nothing reports its state' }
  return $null
}

function New-AcadStatusResult {
  # The reader's result object (and the --json document): overall, exitCode, acadRunning, entries, ignored, skipped, notes, scan.
  param($Merged, [bool]$AcadRunning, $Skipped = @(), $Notes = @(), $Scan = $null)
  if (-not $Scan) { $Scan = [pscustomobject]@{ ran = $false; reason = 'not needed'; blocked = $false; windows = 0; text = '' } }
  $notes = @($Notes)
  if (-not $Merged.HasAcadEntry) {
    if ($AcadRunning) { $notes += 'acad.exe is running but there is no `acad` entry: the AcadStatus add-in is not installed or not loaded, so only the blocker scan can see a dialog.' }
    else { $notes += 'No `acad` entry and acad.exe is not running: AutoCAD is not running (or the AcadStatus add-in is not installed).' }
  }
  $r = [ordered]@{
    overall = [string]$Merged.Overall; exitCode = (Get-AcadStatusExitCode $Merged.Overall); acadRunning = $AcadRunning
    entries = @($Merged.Entries | ForEach-Object { $_ | Select-Object * -ExcludeProperty rank }); ignored = @($Merged.Ignored); skipped = @($Skipped); notes = $notes; scan = $Scan
  }
  return [pscustomobject]$r
}

function Add-AcadStatusScan {
  # Adds the blocker scan's outcome. A blocker it found raises the overall status to blocked, with a synthetic `blocker-scan` entry first.
  param($Result, $Scan)
  $Result.scan = $Scan
  if ($Scan.ran -and $Scan.blocked) {
    $first = Get-AcadStatusBlockedLine $Scan.text
    $e = [pscustomobject]@{
      source = 'blocker-scan'; file = $null; state = 'blocked'; reportedState = 'blocked'; stale = $false; ageSec = 0; ttlSec = 0; pid = $null; pidStart = $null; pidAlive = $null
      writer = 'acad-dev kit blockers'; owner = $null; summary = (Limit-AcadStatusText $first 200); short = $null; since = $null; updated = (ConvertTo-AcadStatusIso ([DateTime]::UtcNow)); detail = $null
    }
    $Result.entries = @($e) + @($Result.entries)
    $Result.overall = 'blocked'
    $Result.exitCode = Get-AcadStatusExitCode 'blocked'
  }
  return $Result
}

function Format-AcadStatusBoard {
  # The compact board for a person or a model: an overall line, one line per entry, notes, skipped and ignored files, the scan.
  param($Result)
  $L = New-Object Collections.Generic.List[string]
  $head = "AutoCAD status: $("$($Result.overall)".ToUpperInvariant()) (exit $($Result.exitCode)); acad.exe $(if ($Result.acadRunning) { 'is running' } else { 'is not running' })"
  $L.Add($head)
  $entries = @($Result.entries)
  if ($entries.Count -eq 0) { $L.Add('  (no status entries)') }
  foreach ($e in $entries) {
    $st = "$($e.state)"; if ($e.stale) { $st += ' (stale)' }
    if ($e.state -ceq 'stopped') {   # a writer that has ended: shown as such, with its result when it gave one (the kit's scripts do)
      $res = if ($e.detail -is [System.Management.Automation.PSCustomObject] -and $e.detail.PSObject.Properties['result']) { "$($e.detail.result)".Trim() } else { '' }
      $st = if ($res) { "ended ($(Limit-AcadStatusText $res 20))" } else { 'ended' }
    }
    $own = if ($e.owner) { "  [owner: $($e.owner)]" } else { '' }
    $L.Add(('  {0,-14} {1,-22} {2,6}  {3}{4}' -f $e.source, $st, (Format-AcadStatusAge $e.ageSec), $e.summary, $own))
    if ($e.stale) {
      $L.Add("      stale: no update for $(Format-AcadStatusAge $e.ageSec) (ttl $($e.ttlSec)s), pid $($e.pid) is running; it last reported '$($e.reportedState)'")
    }
    if ($e.source -ceq 'acad' -and $e.detail -is [System.Management.Automation.PSCustomObject]) {
      $pr = $e.detail.PSObject.Properties['prompt']
      if ($pr -and "$($pr.Value)".Trim()) { $L.Add("      prompt: $(Limit-AcadStatusText $pr.Value 200)") }
      $dp = $e.detail.PSObject.Properties['dialog']
      if ($dp -and $dp.Value -is [System.Management.Automation.PSCustomObject]) {
        $d = $dp.Value
        $title = if ($d.PSObject.Properties['title']) { "$($d.title)" } else { '' }
        $texts = @(); if ($d.PSObject.Properties['texts'] -and $null -ne $d.texts) { $texts = @($d.texts | Select-Object -First 5 | ForEach-Object { Limit-AcadStatusText $_ 200 }) }
        $btns = @(); if ($d.PSObject.Properties['buttons'] -and $null -ne $d.buttons) { $btns = @($d.buttons | Select-Object -First 8 | ForEach-Object { "[$(Limit-AcadStatusText $_ 40)]" }) }
        $open = ''
        if ($d.PSObject.Properties['since']) { $t = ConvertTo-AcadStatusTime $d.since; if ($t) { $open = ", open $(Format-AcadStatusAge (([DateTime]::UtcNow - $t).TotalSeconds))" } }
        $L.Add("      dialog: `"$(Limit-AcadStatusText $title 120)`"$open")
        if ($texts.Count) { $L.Add("        text: $($texts -join ' | ')") }
        if ($btns.Count) { $L.Add("        buttons: $($btns -join ' ')") }
      }
    }
  }
  foreach ($n in @($Result.notes)) { $L.Add("note: $n") }
  foreach ($s in @($Result.skipped | Where-Object { $_.reason -cne $script:AcadStatusNameReason })) { $L.Add("skipped: $($s.file) ($($s.reason))") }   # (names that are not read: only in --json)
  $ign = @($Result.ignored)
  if ($ign.Count -gt 3) { $L.Add("ignored: $($ign.Count) stale entries of writers that are gone ($(($ign | Select-Object -First 3 | ForEach-Object { $_.file }) -join ', '), ...; status --json lists all)") }
  else { foreach ($i in $ign) { $L.Add("ignored: $($i.file) ($($i.reason))") } }
  $sc = $Result.scan
  if ($sc -and $sc.ran) {
    $L.Add("blocker scan (read-only; ran because $($sc.reason)):")
    foreach ($t in (("$($sc.text)" -split "`r?`n") | Where-Object { $_.Trim() })) { $L.Add("  $t") }
  } elseif ($sc -and $sc.reason -and $sc.reason -ne 'not needed') {
    $L.Add("blocker scan: not run ($($sc.reason))")
  }
  return $L.ToArray()
}

function New-AcadStatusDocument {
  # The document a writer puts in its file (contract v1), as an ordered hashtable; ConvertTo-Json it. Pure: the caller gives the pid and
  # the clock and the process start time. Optional fields (pidStart, owner, since, detail) are left out when empty. summary is one line of at most 200 characters.
  param([string]$Source, [string]$Writer, [int]$ProcessId, [DateTime]$Now, [int]$TtlSec, [string]$State, [string]$Summary,
        [string]$Owner = '', $Since = $null, [hashtable]$Detail = $null, $PidStart = $null)
  $d = [ordered]@{
    v = 1; source = $Source; writer = $Writer; pid = $ProcessId; updated = (ConvertTo-AcadStatusIso $Now); ttlSec = $TtlSec
    state = $State; summary = (Limit-AcadStatusText $Summary 200)
  }
  if ($PidStart -is [DateTime]) { $d.Insert(4, 'pidStart', (ConvertTo-AcadStatusIsoMs $PidStart)) }   # right after pid
  if ($Owner -and $Owner.Trim()) { $d.owner = (Limit-AcadStatusText $Owner 80) }
  if ($Since -is [DateTime]) { $d.since = ConvertTo-AcadStatusIso $Since }
  if ($Detail -and $Detail.Count) { $d.detail = $Detail }
  return $d
}

function Get-AcadStatusCmdText {
  # `detail.cmds` of the kit's own entry: commands (or ui steps) joined with `|`. \n (Enter) becomes a space; capped at $Max characters
  # (the file is readable by every local user: only the start of what was typed goes in).
  param([string[]]$Items, [int]$Max = 120)
  $parts = @($Items | ForEach-Object { (("$_" -replace '\\n', ' ') -replace '\s+', ' ').Trim() } | Where-Object { $_ })
  return (Limit-AcadStatusText ($parts -join '|') $Max)
}

function Get-AcadStatusWorkerError {
  # The worker's own error line ("ERROR: ...", upper case) of a run's result lines, or $null. Only the worker's own lines count, those before
  # the "--- <log> (tail) ---" marker: what follows is AutoCAD's command-line log, which may say ERROR for reasons of its own.
  param($ResultLines)
  foreach ($l in @($ResultLines)) {
    if ("$l" -match '^--- .* \(tail\) ---$') { break }
    if ("$l" -clike 'ERROR:*') { return "$l" }
  }
  return $null
}

function Get-AcadStatusUiResult {
  # The status line a finished `ui` run ends with: State and Summary. Built from the exit code, the step NUMBER in ui-run's FAIL line and the
  # sanitised steps (Get-AcadStatusUiSteps), never from ui-run's own text, which repeats the raw step and the reason (typed values, what a
  # dialog contained). A failure with a BLOCKED BY report is `blocked`. $Code is ui-run's exit code (not 3: a replaced run writes nothing).
  # -NoStepText (ACAD_STATUS_DETAIL=0): the step number only.
  param([int]$Code, $ResultLines, [string[]]$SafeSteps, [switch]$NoStepText)
  $n = @($SafeSteps).Count
  if ($Code -eq 0) { return [pscustomobject]@{ State = 'idle'; Summary = "ui: PASS $n steps" } }
  $fail = 0
  $m = @(@($ResultLines) | Where-Object { "$_" -match '^FAIL (\d+)\b' } | Select-Object -First 1)
  if ($m.Count -and "$($m[0])" -match '^FAIL (\d+)\b') { $fail = [int]$Matches[1] }
  $head = if ($fail -ge 1 -and $fail -le $n) { "ui: FAIL at step $fail$(if (-not $NoStepText) { ' (' + @($SafeSteps)[$fail - 1] + ')' })" } else { "ui: FAIL (exit $Code)" }
  $blocked = Get-AcadStatusBlockedLine $ResultLines -Fallback ''
  if ($blocked) { return [pscustomobject]@{ State = 'blocked'; Summary = "$head; $blocked" } }
  return [pscustomobject]@{ State = 'error'; Summary = $head }
}
