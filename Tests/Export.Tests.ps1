# Export suite: how result rows become Excel cells for 'Open in Excel' (column types, text safety).
# Opening Excel itself (COM) is not run here, so the suite works on machines without Excel.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

# Rows as the toolkit holds them: flattened, every value a string (dummy contoso.example data).
$raw = @(
    [pscustomobject]@{ Name = 'PC-001'; Serial = '0042'; Count = 3; Size = 237.5; Enrolled = [datetime]'2024-04-25'; LastSync = [datetime]'2026-09-03 21:02'; Os = '10.0.26200.8457'; Note = '=HYPERLINK("http://contoso.example")'; Empty = $null; Big = '12345678901234567890' }
    [pscustomobject]@{ Name = 'PC-002'; Serial = '7'; Count = 0; Size = -1; Enrolled = $null; LastSync = [datetime]'2026-10-14 07:31'; Os = '10.0.22621.4317'; Note = ''; Empty = $null; Big = '1' }
)
$rows = @(ConvertTo-TkFlatObject -InputObject $raw)
$d = ConvertTo-TkExcelData -Rows $rows
$kind = @{}
for ($i = 0; $i -lt $d.Names.Count; $i++) { $kind[$d.Names[$i]] = $d.Kinds[$i] }
function Cell([int] $Row, [string] $Name) { $d.Cells[$Row, [array]::IndexOf($d.Names, $Name)] }

Check 'Header row holds the column names' ((Cell 0 'Name') -eq 'Name' -and (Cell 0 'LastSync') -eq 'LastSync' -and $d.RowCount -eq 3) ''
Check 'Whole and decimal numbers become a Number column' ($kind.Count -eq 'Number' -and $kind.Size -eq 'Number' -and (Cell 1 'Size') -eq 237.5 -and (Cell 2 'Size') -eq -1) "$($kind.Count) $($kind.Size)"
Check 'Numbers are real numbers, not text' ((Cell 1 'Count') -is [double]) ''
Check 'A leading zero keeps the column as text (serial 0042)' ($kind.Serial -eq 'Text' -and (Cell 1 'Serial') -eq '0042') $kind.Serial
Check 'Version strings stay text' ($kind.Os -eq 'Text' -and (Cell 1 'Os') -eq '10.0.26200.8457') $kind.Os
Check 'Long digit strings (IDs) stay text, not rounded' ($kind.Big -eq 'Text' -and (Cell 1 'Big') -eq '12345678901234567890') $kind.Big
Check 'Date-only values (always midnight) become a Date column, blanks allowed' ($kind.Enrolled -eq 'Date' -and (Cell 1 'Enrolled') -eq ([datetime]'2024-04-25').ToOADate() -and $null -eq (Cell 2 'Enrolled')) "$($kind.Enrolled) $(Cell 1 'Enrolled')"
Check 'Date and time values become a DateTime column' ($kind.LastSync -eq 'DateTime' -and (Cell 1 'LastSync') -eq ([datetime]'2026-09-03 21:02').ToOADate()) "$($kind.LastSync) $(Cell 1 'LastSync')"
Check 'A value that looks like a formula stays text' ($kind.Note -eq 'Text' -and (Cell 1 'Note') -eq '=HYPERLINK("http://contoso.example")') $kind.Note
Check 'Empty values are empty cells' ($kind.Empty -eq 'Text' -and $null -eq (Cell 1 'Empty') -and $null -eq (Cell 2 'Note')) ''

$mixed = @([pscustomobject]@{ When = '2026-02-30' }, [pscustomobject]@{ When = '2026-03-01' })
$m = ConvertTo-TkExcelData -Rows $mixed
Check 'An impossible date is kept as text, not dropped' ($m.Cells[1, 0] -eq '2026-02-30' -and $m.Cells[2, 0] -eq ([datetime]'2026-03-01').ToOADate()) "$($m.Cells[1, 0])"
Check 'No rows: nothing to open' ($null -eq (ConvertTo-TkExcelData -Rows @())) ''

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
