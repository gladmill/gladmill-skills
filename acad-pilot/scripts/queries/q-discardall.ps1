# Query: closes every open drawing WITHOUT saving, discarding unsaved changes.
# Test drawings only: never run it while the user has real work open unless they said so.
# SDI mode (SDI non-zero): closing the only drawing quits AutoCAD, and New blocks on a "Save changes?" dialog for an unsaved
# drawing. So an unsaved drawing is first saved to a temp file (the original file on disk is untouched), then replaced by a blank one.
if (Get-AcadSdi $acad) {
  $d = $acad.ActiveDocument; $old = $d.Name; $tmp = $null
  if (-not $d.Saved) {
    $tmp = Join-Path $env:TEMP ("acad-dev-discard-{0}.dwg" -f [guid]::NewGuid().ToString('N'))
    $d.SaveAs($tmp)
  }
  [void]$d.New('')
  if ($tmp) { Remove-Item $tmp, ($tmp -replace '\.dwg$', '.bak') -EA SilentlyContinue }
  "SDI mode: AutoCAD keeps one drawing; replaced $old with a blank drawing" + $(if ($tmp) { ', discarding its unsaved changes' } else { ' (it had no unsaved changes)' })
} else {
  foreach ($d in @($acad.Documents)) { $d.Close($false) }
}
"open documents: $($acad.Documents.Count)"
