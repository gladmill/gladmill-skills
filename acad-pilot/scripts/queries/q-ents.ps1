# Query: model space objects by type, plus input-related system variables and the open drawings.
$ms = $doc.ModelSpace
"ModelSpace count: $($ms.Count)"
$types = @{}; for ($i = 0; $i -lt $ms.Count; $i++) { $n = $ms.Item($i).ObjectName; $types[$n] = 1 + $types[$n] }
$types.GetEnumerator() | ForEach-Object { "  $($_.Key): $($_.Value)" }
foreach ($v in 'DYNMODE','OSMODE','AUTOSNAP','CMDNAMES','TABMODE','PICKFIRST') { "$v = $($doc.GetVariable($v))" }
"Documents: " + ((@($acad.Documents) | ForEach-Object { $_.Name }) -join ', ')
