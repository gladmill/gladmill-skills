# Query: closes every open drawing, but only if none has unsaved changes. Prints REFUSED otherwise.
# To throw away changes in test drawings you created, use q-discardall.ps1 (and only after the user agreed).
$dirty = @($acad.Documents | Where-Object { -not $_.Saved } | ForEach-Object { $_.Name })
if ($dirty.Count) { "REFUSED: unsaved changes in: $($dirty -join ', ')"; return }
foreach ($d in @($acad.Documents)) { $d.Close($false) }
"open documents: $($acad.Documents.Count)"
