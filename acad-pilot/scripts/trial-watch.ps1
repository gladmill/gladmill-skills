# OPTIONAL. Runs in the interactive session (logon task "AcadDevTrialWatch", see install-trial-watch.ps1): closes AutoCAD's trial
# start-up window, which otherwise blocks COM on a fresh trial install. For the first 5 minutes after acad.exe starts it looks at
# every visible top-level window of AutoCAD and the Autodesk licensing/sign-in helpers, logs new ones to <home>\out\startup-windows.log
# (title, class, process) and posts WM_CLOSE (then IDCANCEL) to those whose title looks like the trial screen. Tune -Match from
# the log if a start-up window is missed. The licensing agent's untitled window of class "webview" is closed by process and class.
# It never closes AutoCAD's main window or a drawing window (it skips AutoCAD's frame by window class and '... AutoCAD ... - [' titles,
# so verticals such as 'AutoCAD Electrical 2026 - [x]' are spared too).
# It never signs in, never enters a licence and does nothing once the window time is over. (Drawing Recovery windows are not its
# business: the blocker guard closes them, see blockers.ps1.)
param([string]$Match = '(?i)\btrial\b|days? (left|remaining)|subscribe|buy now|free trial', [int]$WindowMinutes = 5, [string]$LicClass = 'webview')
. (Join-Path $PSScriptRoot 'common.ps1')
Initialize-AcadWin   # common.ps1: the kit's shared window helper, [AcadDevWin]
$log = Join-Path $script:Out 'startup-windows.log'
$procs = '^(acad|AdSSO|AdskIdentityManager|AdskAccess.*|AdskLicensing.*|AutodeskDesktopApp|msedgewebview2)$'
$seen = @{}; $closed = @{}
while ($true) {
  $acad = Get-Process acad -ErrorAction SilentlyContinue | Sort-Object StartTime | Select-Object -First 1
  if ($acad -and ((Get-Date) - $acad.StartTime).TotalMinutes -lt $WindowMinutes) {
    $mainH = [IntPtr]$acad.MainWindowHandle
    $names = @{}; Get-Process | ForEach-Object { $names[[string]$_.Id] = $_.Name }
    foreach ($w in @([AcadDevWin]::VisibleTops($null))) {
      $name = $names[[string]$w.Pid]; if ($name -notmatch $procs) { continue }
      # never touch AutoCAD's own frame (MFC frame class; MainWindowHandle can be a WPF helper) or a drawing window
      if ($w.H -eq $mainH -or ($name -eq 'acad' -and $w.Cls -like 'AfxMDIFrame*') -or (Test-DrawingWindow $w.Title)) { continue }
      $key0 = [string]$w.H; $key = "$($w.H)|$($w.Title)"
      if (-not $seen[$key]) { $seen[$key] = 1; Add-Content $log ("{0:s} {1} class={2} title=[{3}]" -f (Get-Date), $name, $w.Cls, $w.Title) }
      $trial = ($w.Title -match $Match -and $w.Title -notmatch 'UNREGISTERED VERSION') -or ($name -eq 'AdskLicensingAgent' -and $w.Cls -eq $LicClass -and $w.Title -eq '')
      if ($trial -and -not $closed[$key0]) {
        [AcadDevWin]::Close($w.H); Start-Sleep -Milliseconds 500; [AcadDevWin]::Cancel($w.H)   # WM_CLOSE, then WM_COMMAND IDCANCEL
        $closed[$key0] = 1; Add-Content $log ("{0:s} closed [{1}] ({2})" -f (Get-Date), $w.Title, $name)
      }
    }
  } elseif (-not $acad) { $seen = @{}; $closed = @{} }
  Start-Sleep -Seconds 2
}
