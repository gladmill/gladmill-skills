# Runs in the interactive session: posts IDCANCEL to every visible top-level window whose title equals the text in <home>\title.txt
# (written by run-task.ps1 -Title), lists the visible windows, takes a screenshot. A WPF dialog ignores IDCANCEL: use -Close (WM_CLOSE).
param([string]$Title = '', [switch]$Close)
. (Join-Path $PSScriptRoot 'common.ps1')
$out = $script:Out; $res = Join-Path $out 'result.txt'; "" | Set-Content $res
if (-not $Title) { $tf = Join-Path $script:Home_ 'title.txt'; if (Test-Path $tf) { $Title = (Get-Content $tf -Raw).Trim() } }
$cf = Join-Path $script:Home_ 'closeflag.txt'; if (Test-Path $cf) { $Close = $true; Remove-Item $cf }
Initialize-AcadWin   # common.ps1: the kit's shared window helper, [AcadDevWin]
$hits = New-Object System.Collections.Generic.List[string]
foreach ($w in [AcadDevWin]::VisibleTops($null)) {
  if (-not $w.Title) { continue }
  $hits.Add($w.Title)
  if ($Title.Length -gt 0 -and $w.Title -ceq $Title) { if ($Close) { [AcadDevWin]::Close($w.H) } else { [AcadDevWin]::Cancel($w.H) }; $hits.Add('  ^ posted') }
}
$hits | ForEach-Object { Add-Content $res $_ }
Start-Sleep 3
Save-Screenshot (Join-Path $out 'screen.png')
'done' | Set-Content (Join-Path $out 'done.txt')
