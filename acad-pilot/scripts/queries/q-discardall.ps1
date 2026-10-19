# Query: closes every open drawing WITHOUT saving, discarding unsaved changes.
# Test drawings only: never run it while the user has real work open unless they said so.
foreach ($d in @($acad.Documents)) { $d.Close($false) }
"open documents: $($acad.Documents.Count)"
