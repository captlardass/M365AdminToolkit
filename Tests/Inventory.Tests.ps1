# Installed-modules inventory test suite. Offline: fake module lists and a fake gallery feed.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$userBase = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
$allBase = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
function Fake([string] $Name, [string] $Version, [string] $Base = $userBase) {
    [pscustomobject]@{ Name = $Name; Version = [version]$Version; ModuleBase = Join-Path $Base "$Name\$Version" }
}
function Row($Rows, [string] $Name) { @($Rows | Where-Object Module -eq $Name)[0] }

$installed = @(
    Fake 'Microsoft.Graph.Authentication' '2.30.0'
    Fake 'Microsoft.Graph.Authentication' '2.25.0' $allBase
    Fake 'Microsoft.Graph.Users' '2.30.0'
    Fake 'Microsoft.Graph.Groups' '2.25.0' $allBase
    Fake 'Microsoft.Graph.Beta.Users' '2.28.0'
    Fake 'MicrosoftTeams' '7.0.0'
    Fake 'AzureAD' '2.0.2.182' $allBase
    Fake 'Pester' '5.5.0'
)
$latest = @{ 'Microsoft.Graph.Authentication' = [version]'2.30.0'; 'MicrosoftTeams' = [version]'8.0.0' }
$rows = @(Get-TkModuleInventory -Installed $installed -Latest $latest)

$exo = Row $rows 'ExchangeOnlineManagement'
Check 'Required module not installed is Missing' ($exo.Status -eq 'Missing' -and $exo.Action -like 'Install-Module ExchangeOnlineManagement*') "$($exo.Status) / $($exo.Action)"
Check 'Optional module not installed is Not installed' ((Row $rows 'PnP.PowerShell').Status -eq 'Not installed') ''
$auth = Row $rows 'Microsoft.Graph.Authentication'
Check 'Highest installed version wins' ($auth.Installed -eq '2.30.0' -and $auth.OtherVersions -eq '2.25.0') "$($auth.Installed) / $($auth.OtherVersions)"
Check 'Same as gallery is Up to date' ($auth.Status -eq 'Up to date' -and $auth.Latest -eq '2.30.0') $auth.Status
Check 'Scope CurrentUser from Documents path' ($auth.Scope -eq 'CurrentUser') $auth.Scope
Check 'Scope AllUsers from Program Files path' ((Row $rows 'AzureAD').Scope -eq 'AllUsers') ''
$teams = Row $rows 'MicrosoftTeams'
Check 'Older than gallery is Update available' ($teams.Status -eq 'Update available' -and $teams.Action -eq 'Update-Module MicrosoftTeams') "$($teams.Status) / $($teams.Action)"
Check 'Retired module installed is flagged' ((Row $rows 'AzureAD').Status -eq 'Retired') ''
Check 'Retired module not installed is left out' (-not (Row $rows 'MSOnline')) ''
Check 'Graph sub-module on another version is Version mismatch' ((Row $rows 'Microsoft.Graph.Groups').Status -eq 'Version mismatch') (Row $rows 'Microsoft.Graph.Groups').Status
Check 'Graph sub-module on same version, no gallery data, is Installed' ((Row $rows 'Microsoft.Graph.Users').Status -eq 'Installed') (Row $rows 'Microsoft.Graph.Users').Status
Check 'Beta sub-modules are not compared with Authentication' ((Row $rows 'Microsoft.Graph.Beta.Users').Status -eq 'Installed') (Row $rows 'Microsoft.Graph.Beta.Users').Status
Check 'Unrelated modules are not listed' (-not (Row $rows 'Pester')) ''
Check 'Required modules come first' ((@($rows | Select-Object -First 2 | ForEach-Object Role) -join ',') -eq 'Required,Required') ''
Check 'Retired modules come last' ($rows[-1].Role -eq 'Retired') $rows[-1].Module
Check 'No internal sort column leaks out' (-not ($rows[0].PSObject.Properties.Name -contains 'SortKey')) ''
Check 'No module paths leak out (they contain the user name)' (-not @($rows | Where-Object { ($_.PSObject.Properties.Value -join ' ') -like '*\*' }).Count) ''

$none = @(Get-TkModuleInventory -Installed @())
Check 'Nothing installed: required are Missing, no Installed rows' (@($none | Where-Object Status -eq 'Missing').Count -eq 2 -and -not @($none | Where-Object Installed).Count) ''

# Gallery lookup with a fake feed: a global function shadows the cmdlet inside the module.
function global:Invoke-RestMethod {
    param($Uri, $TimeoutSec, $ErrorAction)
    $global:TkFakeUris += , $Uri
    @(
        [pscustomobject]@{ properties = [pscustomobject]@{ Id = 'MicrosoftTeams'; Version = '8.1.0' } }
        [pscustomobject]@{ properties = [pscustomobject]@{ Id = 'Microsoft.Graph.Authentication'; Version = '2.31.0' } }
        [pscustomobject]@{ properties = $null }
    )
}
$global:TkFakeUris = @()
$names = @(1..20 | ForEach-Object { "Microsoft.Graph.Fake$_" }) + 'MicrosoftTeams', "bad'name"
$gallery = Get-TkGalleryVersion -Name $names
Check 'Gallery versions parsed' ($gallery['MicrosoftTeams'] -eq [version]'8.1.0' -and $gallery['Microsoft.Graph.Authentication'] -eq [version]'2.31.0') ($gallery.Keys -join ',')
Check 'Gallery queried in chunks of 15' ($global:TkFakeUris.Count -eq 2) "$($global:TkFakeUris.Count) request(s)"
Check 'Names with quotes are never sent' (-not @($global:TkFakeUris | Where-Object { [uri]::UnescapeDataString($_) -like "*bad'name*" }).Count) ''
$checked = @(Get-TkModuleInventory -Installed $installed -CheckGallery)
Check 'CheckGallery flags an update' ((Row $checked 'Microsoft.Graph.Authentication').Status -eq 'Update available') (Row $checked 'Microsoft.Graph.Authentication').Status

function global:Invoke-RestMethod { throw 'No network (test)' }
$warnings = $null
$offline = @(Get-TkModuleInventory -Installed $installed -CheckGallery -WarningVariable warnings -WarningAction SilentlyContinue)
Check 'Gallery offline: warning, rows still returned' ($offline.Count -eq $rows.Count -and @($warnings).Count -eq 1) "rows=$($offline.Count) warnings=$(@($warnings).Count)"
Remove-Item Function:\Invoke-RestMethod

# Update plan: which installs fix the rows, in which scope.
function InvRow([string] $Module, [string] $Status, [string] $Installed, [string] $Latest, [string] $Scope = 'CurrentUser') {
    [pscustomobject]@{ Module = $Module; Status = $Status; Installed = $Installed; Latest = $Latest; Scope = $Scope }
}
$inv = @(
    InvRow 'ExchangeOnlineManagement' 'Update available' '3.9.0' '3.10.1' 'AllUsers'
    InvRow 'Microsoft.Graph.Authentication' 'Update available' '2.33.0' '2.41.0'
    InvRow 'Microsoft.Graph' 'Update available' '2.29.1' '2.41.0' 'AllUsers'
    InvRow 'Microsoft.Graph.Users' 'Version mismatch' '2.29.1' '2.41.0' 'AllUsers'
    InvRow 'Microsoft.Graph.Beta.Users' 'Update available' '2.30.0' '2.41.0'
    InvRow 'MicrosoftTeams' 'Up to date' '8.0.0' '8.0.0'
    InvRow 'AzureAD' 'Retired' '2.0.2.182' '' 'AllUsers'
    InvRow 'PnP.PowerShell' 'Not installed' '' '3.4.1'
    InvRow 'Microsoft.Graph.Missing' 'Missing' '' ''
)
$plan = @(Get-TkModuleUpdatePlan -Inventory $inv -Elevated $false)
$planNames = @($plan | ForEach-Object Module)
Check 'Plan: Authentication goes first' ($planNames[0] -eq 'Microsoft.Graph.Authentication') ($planNames -join ',')
Check 'Plan: updates and missing are included' (@('ExchangeOnlineManagement', 'Microsoft.Graph', 'Microsoft.Graph.Beta.Users', 'Microsoft.Graph.Missing' | Where-Object { $planNames -notcontains $_ }).Count -eq 0) ($planNames -join ',')
Check 'Plan: sub-modules covered by the Graph bundle are left out' ($planNames -notcontains 'Microsoft.Graph.Users') ($planNames -join ',')
Check 'Plan: Beta sub-modules are not covered by the Graph bundle' ($planNames -contains 'Microsoft.Graph.Beta.Users') ''
Check 'Plan: up to date, retired and optional not installed are left out' (@('MicrosoftTeams', 'AzureAD', 'PnP.PowerShell' | Where-Object { $planNames -contains $_ }).Count -eq 0) ($planNames -join ',')
$exoPlan = Row $plan 'ExchangeOnlineManagement'
Check 'Plan: AllUsers without admin goes to CurrentUser with a note' ($exoPlan.Scope -eq 'CurrentUser' -and $exoPlan.Note -and $exoPlan.To -eq '3.10.1') "$($exoPlan.Scope) / $($exoPlan.Note)"
Check 'Plan: AllUsers stays AllUsers as admin' ((Row (Get-TkModuleUpdatePlan -Inventory $inv -Elevated $true) 'ExchangeOnlineManagement').Scope -eq 'AllUsers') ''
Check 'Plan: missing with unknown latest installs latest' ((Row $plan 'Microsoft.Graph.Missing').To -eq 'latest') (Row $plan 'Microsoft.Graph.Missing').To
$mismatchOnly = @(Get-TkModuleUpdatePlan -Inventory $inv -Name 'Microsoft.Graph.Users' -Elevated $false | ForEach-Object Module)
Check 'Plan: selected version mismatch brings Authentication along' (($mismatchOnly -join ',') -eq 'Microsoft.Graph.Authentication,Microsoft.Graph.Users') ($mismatchOnly -join ',')
Check 'Plan: selecting only up-to-date rows plans nothing' (-not @(Get-TkModuleUpdatePlan -Inventory $inv -Name 'MicrosoftTeams', 'AzureAD' -Elevated $false).Count) ''
Check 'Plan: no gallery data plans no updates' (-not @(Get-TkModuleUpdatePlan -Inventory @(InvRow 'MicrosoftTeams' 'Installed' '7.0.0' '') -Elevated $false).Count) ''

# Installing: fake PowerShellGet so nothing touches the real machine or network.
function global:Get-PackageProvider { param([switch] $ListAvailable, $ErrorAction) [pscustomobject]@{ Name = 'NuGet'; Version = [version]'2.8.5.208' } }
function global:Install-PackageProvider { $global:TkFakeProvider = $true }
function global:Install-Module {
    param($Name, $Scope, $Repository, [switch] $Force, $RequiredVersion, [switch] $AcceptLicense)
    if ($Name -eq 'Broken.Module') { throw 'Simulated install failure' }
    $global:TkFakeInstalls += , ([pscustomobject]@{ Name = $Name; Scope = $Scope; RequiredVersion = $RequiredVersion; Force = [bool]$Force })
}
$global:TkFakeInstalls = @()
$global:TkFakeProvider = $false
$testPlan = @(
    [pscustomobject]@{ Module = 'MicrosoftTeams'; From = '7.0.0'; To = '8.0.0'; Scope = 'CurrentUser'; Note = '' }
    [pscustomobject]@{ Module = 'Broken.Module'; From = '1.0.0'; To = '2.0.0'; Scope = 'CurrentUser'; Note = '' }
    [pscustomobject]@{ Module = 'ExchangeOnlineManagement'; From = ''; To = 'latest'; Scope = 'CurrentUser'; Note = '' }
)
$whatIf = @(Update-TkInstalledModule -Plan $testPlan -WhatIf)
Check 'Update -WhatIf installs nothing and reports WhatIf' (-not $global:TkFakeInstalls.Count -and @($whatIf | Where-Object Status -eq 'WhatIf').Count -eq 3) "$($global:TkFakeInstalls.Count) install(s)"
$warnings = $null
$updated = @(Update-TkInstalledModule -Plan $testPlan -WarningVariable warnings -WarningAction SilentlyContinue)
Check 'Update installs the planned version with -Force' (@($global:TkFakeInstalls | Where-Object { $_.Name -eq 'MicrosoftTeams' -and $_.RequiredVersion -eq '8.0.0' -and $_.Force -and $_.Scope -eq 'CurrentUser' }).Count -eq 1) ''
Check 'Update of a missing module installs latest (no RequiredVersion)' (@($global:TkFakeInstalls | Where-Object { $_.Name -eq 'ExchangeOnlineManagement' -and -not $_.RequiredVersion }).Count -eq 1) ''
Check 'Update reports Updated / Failed / Installed' ((@($updated | ForEach-Object Status) -join ',') -eq 'Updated,Failed,Installed') (@($updated | ForEach-Object Status) -join ',')
Check 'A failed install warns and does not stop the rest' (@($warnings).Count -eq 1 -and (Row $updated 'Broken.Module').Message -like '*Simulated*') "warnings=$(@($warnings).Count)"
Check 'NuGet provider present: not reinstalled' (-not $global:TkFakeProvider) ''
Remove-Item Function:\Install-Module, Function:\Get-PackageProvider, Function:\Install-PackageProvider

# The main window still loads, with the new tab's controls.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
try {
    Import-TkStyle -Path "$Root\Core\Styles.xaml"
    $ui = Import-TkXaml -Path "$Root\Core\MainWindow.xaml"
    $missing = @('InventoryTab', 'InventoryGrid', 'InventorySummary', 'CheckUpdatesButton', 'RescanModulesButton', 'ShowGraphSubCheck', 'UpdateModulesButton' | Where-Object { -not $ui[$_] })
    Check 'MainWindow.xaml loads with inventory controls' (-not $missing.Count) ($missing -join ',')
}
catch { Check 'MainWindow.xaml loads with inventory controls' $false $_.Exception.Message }

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("$Root\Start-Toolkit.ps1", [ref]$null, [ref]$errors)
Check 'Start-Toolkit.ps1 parses' (-not $errors.Count) (@($errors | ForEach-Object Message) -join '; ')
# Without a BOM, Windows PowerShell 5.1 reads a file as ANSI, so non-ASCII bytes there get garbled.
$scripts = @(Get-ChildItem "$Root\Core", "$Root\Tests", "$Root\Tools" -Include *.ps1, *.psm1 -Recurse) + @(Get-Item "$Root\Start-Toolkit.ps1")
$nonAscii = @($scripts | Where-Object {
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    $hasBom = $bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    -not $hasBom -and @($bytes -gt 127).Count
} | ForEach-Object Name)
Check 'Scripts without a BOM are ASCII-only' (-not $nonAscii.Count) ($nonAscii -join ',')

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
