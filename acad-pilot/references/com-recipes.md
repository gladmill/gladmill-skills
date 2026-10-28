# COM query recipes

A query is a `.ps1` file; `$acad` (AutoCAD.Application) and `$doc` (active document) are in scope. Whatever it prints
goes into the result. Run: `run-in-session.ps1 -Query file.ps1` (local) or `acad-dev.sh query file.ps1` (remote).
Queries must not wait for input and must not type AutoLISP.

## Basics
```powershell
"AutoCAD $($acad.Version) / $($acad.Name)"          # 25.1 = 2026, 25.0 = 2025, 24.3 = 2024
"Drawing: $($doc.FullName)  saved: $($doc.Saved)"
"Documents: " + ((@($acad.Documents) | % Name) -join ', ')
$s = $acad.GetAcadState(); "quiescent: $($s.IsQuiescent)"
"CMDNAMES = $($doc.GetVariable('CMDNAMES'))"       # empty = no command running
```

## Count model-space entities by type
```powershell
$ms = $doc.ModelSpace; "count: $($ms.Count)"
$t = @{}; for ($i = 0; $i -lt $ms.Count; $i++) { $n = $ms.Item($i).ObjectName; $t[$n] = 1 + $t[$n] }
$t.GetEnumerator() | % { "  $($_.Key): $($_.Value)" }
```
Assert in your own words afterwards: e.g. "expected >= 1 AcDbLine, saw 1".

## Inspect entities
```powershell
foreach ($e in $doc.ModelSpace) { "{0} layer={1} handle={2}" -f $e.ObjectName, $e.Layer, $e.Handle }
$l = $doc.ModelSpace.Item(0); "start=$($l.StartPoint -join ',') end=$($l.EndPoint -join ',') length=$($l.Length)"
```

## Layers, blocks, layouts
```powershell
$doc.Layers | % { "{0} on={1} frozen={2}" -f $_.Name, $_.LayerOn, $_.Freeze }
$doc.Blocks | % { $_.Name }
$doc.Layouts | % { $_.Name }
```

## System variables (typed on write)
```powershell
$doc.GetVariable('FILEDIA'); $doc.GetVariable('CMDECHO')
$doc.SetVariable('FILEDIA', [int16]0)     # always pass the right type
```

## Drawing things without typing commands
```powershell
$p1 = [double[]](0,0,0); $p2 = [double[]](100,100,0)
$null = $doc.ModelSpace.AddLine($p1, $p2); "added a line"
```
Direct API calls are the fastest way to set up test geometry. Use `SendCommand` when the thing under test is the command.

## Waiting and polling
```powershell
for ($i = 0; $i -lt 30 -and $doc.GetVariable('CMDNAMES'); $i++) { Start-Sleep 1 }   # until the command ends
"CMDNAMES now: '$($doc.GetVariable('CMDNAMES'))'"
```

## Close test drawings, quit
```powershell
foreach ($d in @($acad.Documents)) { $d.Close($false) }    # queries/q-discardall.ps1 (q-closeall.ps1 first checks $d.Saved)
```
In SDI mode (`$doc.GetVariable('SDI')` non-zero) that quits AutoCAD: it keeps one drawing. Replace it instead (only if `$d.Saved`,
else `New` blocks on a "Save changes?" dialog; to discard changes `SaveAs` a temp file first, as q-discardall.ps1 does):
```powershell
[void]$acad.ActiveDocument.New('')    # blank drawing replaces the current one; Documents.Count stays 1
```

## New drawing
```powershell
$acad.Documents.Add()                 # MDI. Throws 0x80210071 in SDI mode: use ActiveDocument.New('') (see above)
```
