# Theme test suite: palettes, resource names, and every window laid out in light and dark.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

function Get-PaletteKey([string] $Theme) {
    try { $palette = [System.Windows.Markup.XamlReader]::Parse((Get-Content "$Root\Core\Themes\$Theme.xaml" -Raw -Encoding UTF8)) }
    catch { Check "$Theme.xaml parses" $false $_.Exception.InnerException.Message; return , @() }
    Check "$Theme.xaml parses" $true ''
    , @($palette.Keys | Where-Object { $_ -is [string] } | Sort-Object)
}
$light = Get-PaletteKey 'Light'
$dark = Get-PaletteKey 'Dark'
$diff = @(Compare-Object $light $dark | ForEach-Object { "$($_.InputObject) ($(if ($_.SideIndicator -eq '<=') { 'only Light' } else { 'only Dark' }))" })
Check 'Light and Dark define the same Tk.* names' (-not $diff.Count) ($diff -join ', ')

# Every theme name used in XAML ({DynamicResource Tk.X}) or code ('Tk.X') must exist, or it silently shows nothing.
$files = @(Get-ChildItem "$Root\Core" -Include *.xaml, *.ps1, *.psm1 -Recurse | Where-Object { $_.DirectoryName -notlike '*\Themes' }) + @(Get-Item "$Root\Start-Toolkit.ps1")
$used = @($files | ForEach-Object {
    [regex]::Matches([IO.File]::ReadAllText($_.FullName), '(?:DynamicResource |[''"])(Tk(?:\.[A-Za-z]+)+)(?=[''"}])') | ForEach-Object { $_.Groups[1].Value }
} | Sort-Object -Unique)
$unknown = @($used | Where-Object { $light -notcontains $_ })
Check 'Every Tk.* name used exists in the palettes' ($used.Count -gt 20 -and -not $unknown.Count) "$($used.Count) used; unknown: $($unknown -join ', ')"
$kinds = @(ConvertTo-TkCodeLine -Text "# c`n`$x = Get-Item -Path 'a' 42 [int] if" -Language PowerShell | ForEach-Object { $_.Parts } | ForEach-Object { $_[0] } | Where-Object { $_ } | Sort-Object -Unique)
$missingKinds = @($kinds | Where-Object { $light -notcontains "Tk.Code.$_" })
Check 'Every syntax colour kind has a Tk.Code.* brush' ($kinds.Count -ge 5 -and -not $missingKinds.Count) "kinds: $($kinds -join ', '); missing: $($missingKinds -join ', ')"

# Following Windows
$registry = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
$expected = if ($registry -eq 0) { 'Dark' } else { 'Light' }
Check 'Get-TkSystemTheme matches the Windows app mode' ((Get-TkSystemTheme) -eq $expected) "$(Get-TkSystemTheme), registry=$registry"
Check 'Preference Light/Dark overrides Windows' ((Resolve-TkTheme 'Light') -eq 'Light' -and (Resolve-TkTheme 'Dark') -eq 'Dark') ''
Check 'Preference System follows Windows' ((Resolve-TkTheme 'System') -eq $expected -and (Resolve-TkTheme '') -eq $expected) ''

$prefFile = Join-Path ([IO.Path]::GetTempPath()) "TkPrefTest_$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
try {
    Check 'No preferences file: theme is System' ((Get-TkPreference -Path $prefFile).Theme -eq 'System') ''
    Set-Content $prefFile '{ "Theme": "Dark" }'
    Check 'Saved theme is read back' ((Get-TkPreference -Path $prefFile).Theme -eq 'Dark') ''
    Set-Content $prefFile '{ "Theme": "Purple" }'
    Check 'Unknown saved theme falls back to System' ((Get-TkPreference -Path $prefFile).Theme -eq 'System') ''
}
finally { Remove-Item $prefFile -ErrorAction SilentlyContinue }

# Every window loads and lays out in both themes, and recolours when the theme changes.
try {
    Import-TkStyle -Path "$Root\Core\Styles.xaml" -Theme Dark
    $merged = [System.Windows.Application]::Current.Resources.MergedDictionaries
    $countBefore = $merged.Count
    $main = Import-TkXaml -Path "$Root\Core\MainWindow.xaml"
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add('Module'); [void]$table.Columns.Add('Status')
    [void]$table.Rows.Add('Contoso.Example', 'Missing'); [void]$table.Rows.Add('Contoso.Other', 'Up to date')
    $main.ResultGrid.ItemsSource = $table.DefaultView
    $main.InventoryGrid.ItemsSource = $table.DefaultView
    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Header = 'Group'; [void]$item.Items.Add('Child'); $item.IsExpanded = $true
    [void]$main.ModuleTree.Items.Add($item)
    # The Tenant readiness box, filled the way Show-Readiness does, so it is laid out in both themes too.
    $main.ReadinessColumn.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $main.ReadinessCard.Visibility = 'Visible'
    $main.ReadinessRing.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@(20.5, 1000))
    $main.ReadinessRing.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, 'Tk.ReadinessWarn')
    $main.ReadinessBig.Text = '73%'; $main.ReadinessSmall.Text = 'WARN'
    $main.ReadinessLabel.Text = '146 of 200 users have a passkey'; $main.ReadinessNotEvaluated.Text = '3 not evaluated'
    $windows = @($main.Window, (Import-TkXaml -Path "$Root\Core\AddModuleWindow.xaml").Window, (Import-TkXaml -Path "$Root\Core\ScriptViewerWindow.xaml").Window, (Import-TkXaml -Path "$Root\Core\ExportWindow.xaml").Window)

    foreach ($theme in 'Dark', 'Light', 'Dark') {
        Set-TkTheme -Theme $theme
        $problems = @(foreach ($w in $windows) {
            try { $w.Content.Measure((New-Object System.Windows.Size 1260, 800)); $w.Content.Arrange((New-Object System.Windows.Rect 0, 0, 1260, 800)); $w.Content.UpdateLayout() }
            catch { "$($w.Title): $($_.Exception.Message)" }
        })
        Check "All windows lay out in $theme" (-not $problems.Count) ($problems -join '; ')
    }
    Check 'Switching themes replaces the palette instead of stacking them' ($merged.Count -eq $countBefore) "$countBefore -> $($merged.Count)"
    Set-TkTheme -Theme Dark
    $darkBackground = [string]$main.Window.Background
    Set-TkTheme -Theme Light
    $lightBackground = [string]$main.Window.Background
    Check 'Open windows recolour live' ($darkBackground -eq '#FF16181D' -and $lightBackground -eq '#FFF3F4F6') "dark=$darkBackground light=$lightBackground"
    Check 'Get-TkTheme reports the current theme' ((Get-TkTheme) -eq 'Light') (Get-TkTheme)
    Check 'Readiness box takes space beside the inputs' ($main.ReadinessCard.ActualWidth -gt 300 -and $main.ReadinessRing.ActualWidth -eq 150) "card=$($main.ReadinessCard.ActualWidth) ring=$($main.ReadinessRing.ActualWidth)"
    $ringLight = [string]$main.ReadinessRing.Stroke
    Set-TkTheme -Theme Dark
    Check 'Readiness ring recolours with the theme' ($ringLight -ne [string]$main.ReadinessRing.Stroke) "light=$ringLight dark=$($main.ReadinessRing.Stroke)"
    Set-TkTheme -Theme Light

    # Title bar: needs a window handle. EnsureHandle creates one without showing anything.
    [void](New-Object System.Windows.Interop.WindowInteropHelper $main.Window).EnsureHandle()
    Set-TkTheme -Theme Dark
    Check 'Dark title bar support compiles' ([bool]('TkNative.Dwm' -as [type])) ''
    Set-TkTheme -Theme Light
}
catch { Check 'Theme rendering runs without errors' $false $_.Exception.Message }

# A second launch in the same PowerShell session (VS Code, ISE, a terminal): the WPF Application and its
# dictionaries survive, the module is re-imported. The old palette must not outrank the new one.
try {
    $merged = [System.Windows.Application]::Current.Resources.MergedDictionaries
    Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
    Import-TkStyle -Path "$Root\Core\Styles.xaml" -Theme Dark
    $again = Import-TkXaml -Path "$Root\Core\MainWindow.xaml"
    Set-TkTheme -Theme Light
    $palettes = @($merged | Where-Object { $_.Contains('Tk.WindowBackground') }).Count
    $styles = @($merged | Where-Object { $_.Contains('Card') }).Count
    Check 'Second launch in the same session: one palette and one style set, no stacking' ($palettes -eq 1 -and $styles -eq 1) "palettes=$palettes styles=$styles"
    Check 'Second launch in the same session: the theme still switches the whole window' ([string]$again.Window.Background -eq '#FFF3F4F6') ([string]$again.Window.Background)
}
catch { Check 'Second launch in the same session runs without errors' $false $_.Exception.Message }

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
