# Script-viewer and manifest test suite (tokeniser round-trips, colouring, file summary, profiles).
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$Proto = Join-Path ([IO.Path]::GetTempPath()) ('tk-viewer-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $Proto -Force | Out-Null
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

# Tricky source: here-strings, block comment, tabs, nested expandable strings, CRLF + LF mix, no trailing newline.
$tricky = "<#`r`n  block comment`r`n#>`r`nparam([string]`$Name = 'x')`r`n`$h = @`"`r`nHello `$(`$Name.ToUpper())`r`n  line two`r`n`"@`n`tGet-Item -Path `$h # trailing comment`r`nif (`$true) { 42 }"
Set-Content -LiteralPath "$Proto\tricky.ps1" -Value $tricky -NoNewline

$files = @(Get-ChildItem "$Root\Modules" -Recurse -Filter *.ps1) + @(Get-Item "$Proto\tricky.ps1") + @(Get-ChildItem "$Root\Core" -Filter *.ps*1)
foreach ($f in $files) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $lines = @(ConvertTo-TkCodeLine -Text $text)
    $expected = @(($text -replace "`t", '    ') -split "\r\n|\n|\r")
    if ($expected.Count -gt 1 -and $expected[-1] -eq '') { $expected = $expected[0..($expected.Count - 2)] }
    $bad = @(for ($i = 0; $i -lt $lines.Count; $i++) { if ((($lines[$i].Parts | ForEach-Object { $_[1] }) -join '') -ne $lines[$i].Text -or $lines[$i].Text -ne $expected[$i]) { $i + 1 } })
    Check "Round-trip $($f.Name)" ($bad.Count -eq 0 -and $lines.Count -eq $expected.Count) "lines=$($lines.Count)/$($expected.Count) bad=$($bad -join ',')"
}

$t = @(ConvertTo-TkCodeLine -Text $tricky)
function KindOf($line, $text) { @($t[$line - 1].Parts | Where-Object { $_[1] -like "*$text*" } | Select-Object -First 1)[0][0] }
Check 'Block comment spans lines 1-3 as Comment' ((KindOf 1 '<#') -eq 'Comment' -and (KindOf 2 'block') -eq 'Comment' -and (KindOf 3 '#>') -eq 'Comment') ''
Check 'Keyword param' ((KindOf 4 'param') -eq 'Keyword') (KindOf 4 'param')
Check 'Type [string]' ((KindOf 4 'string') -eq 'Type') (KindOf 4 'string')
Check 'Variable $Name' ((KindOf 4 '$Name') -eq 'Variable') ''
Check 'Here-string spans lines 5-8 as String' ((KindOf 6 'Hello') -eq 'String' -and (KindOf 7 'line two') -eq 'String' -and (KindOf 8 '"@') -eq 'String') ''
Check 'Tab expanded, command + parameter coloured' ($t[8].Text.StartsWith('    Get-Item') -and (KindOf 9 'Get-Item') -eq 'Command' -and (KindOf 9 '-Path') -eq 'Parameter') $t[8].Text
Check 'Trailing comment' ((KindOf 9 'trailing') -eq 'Comment') ''
Check 'Number' ((KindOf 10 '42') -eq 'Number') ''
Check 'Empty text gives one empty line' (@(ConvertTo-TkCodeLine -Text '').Count -eq 1) ''
Check 'Plain mode has no kinds' (@(ConvertTo-TkCodeLine -Text '{"a": 1}' -Language Plain | ForEach-Object { $_.Parts } | Where-Object { $_[0] }).Count -eq 0) ''

# File summary
$demo = "$Root\Modules\Demo.SelfTest\module.ps1"
$s = Get-TkFileSummary -Path $demo
Check 'Summary hash matches Get-FileHash' ($s.Sha256 -eq (Get-FileHash $demo -Algorithm SHA256).Hash) $s.Sha256
Check 'Summary line count matches viewer' ($s.Lines -eq @(ConvertTo-TkCodeLine -Text $s.Text).Count) "$($s.Lines)"
$s2 = Get-TkFileSummary -Path "$Proto\tricky.ps1"
Check 'Line count without trailing newline' ($s2.Lines -eq 10) "$($s2.Lines)"

# Performance: a 3000-line script
$big = (1..3000 | ForEach-Object { "Get-MgUser -UserId 'u$_' | Select-Object Id, DisplayName # row $_" }) -join "`r`n"
$sw = [Diagnostics.Stopwatch]::StartNew(); $bl = @(ConvertTo-TkCodeLine -Text $big); $sw.Stop()
Check 'Tokenise 3000 lines under 5 s' ($bl.Count -eq 3000 -and $sw.ElapsedMilliseconds -lt 5000) "$($sw.ElapsedMilliseconds) ms"

# Module profiles + manifest checks
$mods = @(Get-TkModule -Path "$Root\Modules")
foreach ($m in $mods) { Check "Profile $($m.Id)" ($m.IsValid -and $m.DryRun) "mode=$($m.DryRun.Mode) readonly=$($m.ReadOnly) caveats=$(@($m.DryRun.Caveats).Count)" }
$bad = [pscustomobject]@{ Id = 'A.B'; Name = 'n'; Category = 'c'; Description = 'd'; Version = '1.0'; EntryPoint = 'module.ps1'; ReadOnly = 'yes' }
Check 'ReadOnly must be boolean' (@(Test-TkManifest -Manifest $bad -ModuleDirectory "$Root\Modules\Demo.SelfTest") -match 'ReadOnly').Count ''

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }




