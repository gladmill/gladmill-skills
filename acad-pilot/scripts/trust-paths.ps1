# Runs in the interactive session. Adds the folders listed in <home>\trust.txt (one per line; end one with \... to include its
# subfolders) to AutoCAD's TRUSTEDPATHS, keeping what is there. AutoCAD saves it in the profile, so it lasts across restarts.
# Writes the result to <home>\out\trust.txt. Called by start-acad.ps1 -Trust; the user picks the folders, never the agent.
. (Join-Path $PSScriptRoot 'common.ps1')
$res = Join-Path $script:Out 'trust.txt'
try {
  $want = @(Get-Content (Join-Path $script:Home_ 'trust.txt') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $acad = [Runtime.InteropServices.Marshal]::GetActiveObject('AutoCAD.Application')
  # system variables are read through a document; on the Start tab there is none (ActiveDocument throws), so open a blank one
  $doc = if ($acad.Documents.Count -gt 0) { $acad.ActiveDocument } else { $acad.Documents.Add() }
  $have = @(([string]$doc.GetVariable('TRUSTEDPATHS')) -split ';' | Where-Object { $_ })
  $add = @($want | Where-Object { $have -notcontains $_ })
  if ($add) { $doc.SetVariable('TRUSTEDPATHS', (($have + $add) -join ';')) }
  Set-Content $res ("trusted paths: added {0}; TRUSTEDPATHS = {1}" -f $add.Count, $doc.GetVariable('TRUSTEDPATHS'))
} catch { Set-Content $res ('trusted paths: FAILED ' + $_.Exception.Message.Split("`n")[0]) }
