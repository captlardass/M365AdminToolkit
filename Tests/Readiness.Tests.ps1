# Tenant readiness suite: scoring, thresholds in module.json, and the saved view preference.
# The worker channel (Write-TkReadiness -> job) is covered end to end in Guard.Tests.ps1.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }
function New-Report([int] $Ready, [int] $Total, [int] $NotEvaluated = 0, [string] $Label = 'items are ready') {
    [pscustomobject]@{ Ready = $Ready; Total = $Total; NotEvaluated = $NotEvaluated; Label = $Label }
}

# Scoring with the default thresholds (Pass >= 90, Warn >= 70)
$cases = @(
    @{ Ready = 200; Total = 200; Percent = 100; Rating = 'Pass' }
    @{ Ready = 180; Total = 200; Percent = 90;  Rating = 'Pass' }
    @{ Ready = 899; Total = 1000; Percent = 89; Rating = 'Warn' }    # 89.9 is not rounded up to a Pass
    @{ Ready = 146; Total = 200; Percent = 73;  Rating = 'Warn' }
    @{ Ready = 139; Total = 200; Percent = 69;  Rating = 'Fail' }
    @{ Ready = 0;   Total = 5;   Percent = 0;   Rating = 'Fail' }
)
foreach ($c in $cases) {
    $r = Get-TkReadiness -Report (New-Report $c.Ready $c.Total)
    Check "Default thresholds: $($c.Ready)/$($c.Total) = $($c.Percent)% $($c.Rating)" ($r.Percent -eq $c.Percent -and $r.Rating -eq $c.Rating) ($r | ConvertTo-Json -Compress)
}
$r = Get-TkReadiness -Report (New-Report 146 200 3 'users have a passkey')
Check 'Counts, label and thresholds are passed through' ($r.Ready -eq 146 -and $r.Total -eq 200 -and $r.NotEvaluated -eq 3 -and $r.Label -eq 'users have a passkey' -and $r.Pass -eq 90 -and $r.Warn -eq 70) ($r | ConvertTo-Json -Compress)

$strict = [pscustomobject]@{ Pass = 98; Warn = 95 }
$r = Get-TkReadiness -Report (New-Report 190 200) -Threshold $strict
Check 'Module thresholds override the defaults (95% -> Warn at 98/95)' ($r.Rating -eq 'Warn' -and $r.Pass -eq 98) ($r | ConvertTo-Json -Compress)

# Fail closed: anything that isn't a usable figure shows nothing.
$bad = [ordered]@{
    'no report'          = $null
    'Ready > Total'      = New-Report 5 4
    'Total 0'            = New-Report 0 0
    'negative Ready'     = New-Report -1 4
    'negative NotEval'   = New-Report 1 4 -1
    'empty label'        = New-Report 1 4 0 ' '
    'Ready not a number' = [pscustomobject]@{ Ready = 'many'; Total = 4; Label = 'x' }
    'Total missing'      = [pscustomobject]@{ Ready = 1; Label = 'x' }
}
foreach ($name in $bad.Keys) {
    Check "Unusable report is not shown: $name" ($null -eq (Get-TkReadiness -Report $bad[$name])) ''
}
Check 'Unusable thresholds show nothing (Warn above Pass)' ($null -eq (Get-TkReadiness -Report (New-Report 1 2) -Threshold ([pscustomobject]@{ Pass = 50; Warn = 80 }))) ''

# module.json "Readiness" validation
$dir = Join-Path ([IO.Path]::GetTempPath()) ('tk-readiness-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    Set-Content -LiteralPath "$dir\module.ps1" -Value 'param()' -Encoding UTF8
    function Test-Readiness([string] $Json) {
        $manifest = ('{{ "Id": "Contoso.Example", "Name": "n", "Category": "c", "Description": "d", "Version": "1.0.0", "EntryPoint": "module.ps1"{0} }}' -f $Json) | ConvertFrom-Json
        @(Test-TkManifest -Manifest $manifest -ModuleDirectory $dir)
    }
    Check 'No Readiness block is valid' ((Test-Readiness '').Count -eq 0) ((Test-Readiness '') -join ' / ')
    Check 'Valid Readiness block passes' ((Test-Readiness ', "Readiness": { "Pass": 95, "Warn": 80.5 }').Count -eq 0) ((Test-Readiness ', "Readiness": { "Pass": 95, "Warn": 80.5 }') -join ' / ')
    $invalid = [ordered]@{
        'not an object'  = ', "Readiness": 90'
        'Pass missing'   = ', "Readiness": { "Warn": 70 }'
        'Pass over 100'  = ', "Readiness": { "Pass": 120, "Warn": 70 }'
        'Warn negative'  = ', "Readiness": { "Pass": 90, "Warn": -1 }'
        'text value'     = ', "Readiness": { "Pass": "90", "Warn": 70 }'
        'Warn over Pass' = ', "Readiness": { "Pass": 70, "Warn": 90 }'
        'unknown key'    = ', "Readiness": { "Pass": 90, "Warn": 70, "Fail": 10 }'
    }
    foreach ($name in $invalid.Keys) {
        $problems = Test-Readiness $invalid[$name]
        Check "Invalid Readiness block is rejected: $name" ($problems.Count -gt 0 -and ($problems -join ' ') -match 'Readiness') ($problems -join ' / ')
    }

    # The thresholds reach the module object the GUI runs with.
    $modules = Join-Path $dir 'Modules'
    New-Item -ItemType Directory -Path "$modules\Strict", "$modules\Plain" -Force | Out-Null
    Set-Content -LiteralPath "$modules\Strict\module.ps1", "$modules\Plain\module.ps1" -Value 'param()' -Encoding UTF8
    Set-Content -LiteralPath "$modules\Strict\module.json" -Encoding UTF8 -Value '{ "Id": "Contoso.Strict", "Name": "n", "Category": "c", "Description": "d", "Version": "1.0.0", "EntryPoint": "module.ps1", "Readiness": { "Pass": 98, "Warn": 95 } }'
    Set-Content -LiteralPath "$modules\Plain\module.json" -Encoding UTF8 -Value '{ "Id": "Contoso.Plain", "Name": "n", "Category": "c", "Description": "d", "Version": "1.0.0", "EntryPoint": "module.ps1" }'
    $found = @(Get-TkModule -Path $modules)
    $s = $found | Where-Object Id -eq 'Contoso.Strict'
    $p = $found | Where-Object Id -eq 'Contoso.Plain'
    Check 'Get-TkModule carries module thresholds' ($s.IsValid -and $s.Readiness.Pass -eq 98 -and $s.Readiness.Warn -eq 95) ($s.Readiness | ConvertTo-Json -Compress)
    Check 'Get-TkModule falls back to the default thresholds' ($p.IsValid -and $p.Readiness.Pass -eq 90 -and $p.Readiness.Warn -eq 70) ($p.Readiness | ConvertTo-Json -Compress)

    # Preference: Percent (default) or Rating; anything else falls back to Percent.
    $prefFile = "$dir\preferences.json"
    Check 'No preferences file: readiness view is Percent' ((Get-TkPreference -Path $prefFile).ReadinessView -eq 'Percent') ''
    Save-TkPreference -Path $prefFile -Preference ([pscustomobject]@{ Favorites = @(); GroupBy = 'Category'; Theme = 'System'; ReadinessView = 'Rating' })
    Check 'Saved readiness view is read back' ((Get-TkPreference -Path $prefFile).ReadinessView -eq 'Rating') ''
    Set-Content -LiteralPath $prefFile -Value '{ "ReadinessView": "Stars" }'
    Check 'Unknown readiness view falls back to Percent' ((Get-TkPreference -Path $prefFile).ReadinessView -eq 'Percent') ''
}
finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
