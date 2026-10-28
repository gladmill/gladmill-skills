# Query: closes every open drawing, but only if none has unsaved changes. Prints REFUSED otherwise.
# To throw away changes in test drawings you created, use q-discardall.ps1 (and only after the user agreed).
# SDI mode (SDI non-zero): closing the only drawing quits AutoCAD, so the drawing is replaced by a blank one instead.
$dirty = @($acad.Documents | Where-Object { -not $_.Saved } | ForEach-Object { $_.Name })
if ($dirty.Count) { "REFUSED: unsaved changes in: $($dirty -join ', ')"; return }
if (Get-AcadSdi $acad) {
  $old = $acad.ActiveDocument.Name
  [void]$acad.ActiveDocument.New('')
  "SDI mode: AutoCAD keeps one drawing; replaced $old with a blank drawing"
} else {
  foreach ($d in @($acad.Documents)) { $d.Close($false) }
}
"open documents: $($acad.Documents.Count)"
