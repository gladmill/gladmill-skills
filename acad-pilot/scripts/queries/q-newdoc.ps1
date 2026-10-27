# Query: opens a new drawing (default template) and makes it the active one. Run it in a call of its own:
# acad-cmd.ps1 sends later commands to the document that was active BEFORE the query ran.
# SDI mode (SDI non-zero): Documents.Add() is not available; the active drawing is replaced by a blank one instead
# (ActiveDocument.New), unless it has unsaved changes: New would block on a "Save changes?" dialog, so this refuses.
if (Get-AcadSdi $acad) {
  $d = $acad.ActiveDocument; $old = $d.Name
  if (-not $d.Saved) { "REFUSED: SDI mode: AutoCAD keeps one drawing, and $old has unsaved changes. Save it or run q-discardall.ps1."; return }
  [void]$d.New('')
  "SDI mode: replaced $old with a new drawing: " + $acad.ActiveDocument.Name
  return
}
$d = $acad.Documents.Add()
Start-Sleep 4
"new drawing: " + $acad.ActiveDocument.Name
