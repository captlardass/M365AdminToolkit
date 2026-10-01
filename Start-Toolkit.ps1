#Requires -Version 5.1
<#
.SYNOPSIS
    M365 Admin Toolkit - a modular WPF front-end for Microsoft 365 PowerShell tasks.

.DESCRIPTION
    Discovers modules under .\Modules, renders a form for the selected one from its
    module.json, and runs it in a background worker runspace that keeps the Graph and
    Exchange Online connections alive between runs.

.PARAMETER ModulesPath
    Folder to load modules from. Defaults to .\Modules next to this script.

.EXAMPLE
    .\Start-Toolkit.ps1
#>
[CmdletBinding()]
param(
    [string] $ModulesPath
)

$ErrorActionPreference = 'Stop'
if (-not $ModulesPath) { $ModulesPath = Join-Path $PSScriptRoot 'Modules' }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'WPF needs a single-threaded apartment. Start with: powershell.exe -STA -File .\Start-Toolkit.ps1'
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Import-Module (Join-Path $PSScriptRoot 'Core\Toolkit.Core.psm1') -Force
. (Join-Path $PSScriptRoot 'Core\AddModuleDialog.ps1')
. (Join-Path $PSScriptRoot 'Core\ScriptViewer.ps1')

$settingsPath = Join-Path $PSScriptRoot 'Config\settings.json'
$settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }

$preferences = Get-TkPreference
Import-TkStyle -Path (Join-Path $PSScriptRoot 'Core\Styles.xaml') -Theme (Resolve-TkTheme $preferences.Theme)
$ui = Import-TkXaml -Path (Join-Path $PSScriptRoot 'Core\MainWindow.xaml')

# Leading comma: without it PowerShell would unroll the (empty) set into $null on return.
function New-TkStringSet { , [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase) }

# All mutable GUI state lives here: event handlers run in child scopes, so they can
# change members of this hashtable but not reassign script variables.
$State = @{
    Modules       = @()
    Current       = $null
    ParamControls = $null
    Job           = $null
    Worker        = $null
    Results       = @()
    ResultsFrom   = ''
    LogFile       = Join-Path $PSScriptRoot ('Logs\toolkit-{0:yyyyMMdd}.log' -f (Get-Date))
    Favorites     = New-TkStringSet
    SelectedTags  = New-TkStringSet       # tag filter: a module must carry all of these
    Collapsed     = New-TkStringSet       # tree groups the user folded away
    GroupBy       = $preferences.GroupBy
    Theme         = $preferences.Theme     # System (follow Windows), Light or Dark
    Viewer        = $null                 # the open script viewer, if any
    Inventory     = @()                   # rows for the Installed modules tab
    InventoryJob  = $null                 # scan running in its own runspace, apart from the worker
    InventoryChecked = $false             # whether the last scan compared with the PowerShell Gallery
    Elevated      = Test-TkElevated        # AllUsers modules can only be updated in place as administrator
}
foreach ($id in $preferences.Favorites) { [void]$State.Favorites.Add($id) }

$Star = @{ On = [string][char]0x2605; Off = [string][char]0x2606 }

#region Helpers

function Write-UiLog {
    param([string] $Level, [string] $Message, [switch] $NoFile)
    $ui.LogBox.AppendText(('{0:HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message) + [Environment]::NewLine)
    $ui.LogBox.ScrollToEnd()
    # Module chatter stays on screen; toolkit events and errors also go to the log file.
    if (-not $NoFile) { Write-TkLogFile -Path $State.LogFile -Level $Level -Message $Message }
}

function Update-Buttons {
    $busy = [bool]$State.Job
    $ui.RunButton.IsEnabled = (-not $busy) -and [bool]$State.Current -and [bool]$State.Current.IsValid
    $ui.CancelButton.IsEnabled = $busy -and [bool]$State.Job.Cancellable
    foreach ($name in 'ConnectGraphButton', 'ConnectExoButton', 'DisconnectButton', 'ReloadButton', 'AddModuleButton', 'SaveTagsButton') {
        $ui[$name].IsEnabled = -not $busy
    }
    # A module update runs apart from the worker but takes minutes, so it shows the busy bar too.
    $showBusy = $busy -or ($State.InventoryJob -and $State.InventoryJob.Kind -eq 'Update')
    $ui.BusyBar.Visibility = if ($showBusy) { 'Visible' } else { 'Collapsed' }
    $ui.BusyBar.IsIndeterminate = $showBusy
}

function Start-UiJob {
    <# Runs a script in the worker. Only one job at a time - the worker is a single runspace. #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [hashtable] $Parameters = @{},
        [scriptblock] $OnComplete,
        [hashtable] $Data = @{},
        [switch] $Cancellable,
        [switch] $Quiet
    )
    if ($State.Job) { Write-UiLog 'WARN' "Busy with '$($State.Job.Name)' - try again when it finishes."; return }

    $job = Start-TkJob -Runspace $State.Worker -Name $Name -ScriptBlock $ScriptBlock -Parameters $Parameters
    $job | Add-Member -NotePropertyMembers @{ OnComplete = $OnComplete; Cancellable = [bool]$Cancellable; Quiet = [bool]$Quiet; Data = $Data }
    $State.Job = $job
    if (-not $Quiet) {
        Write-UiLog 'INFO' "Started: $Name"
        $ui.StatusText.Text = "Running: $Name ..."
    }
    Update-Buttons
}

function Set-ConnectionIndicator {
    param($Dot, $Label, [string] $Service, [bool] $Connected, [string] $Account)
    $Dot.SetResourceReference([System.Windows.Shapes.Shape]::FillProperty, $(if ($Connected) { 'Tk.Connected' } else { 'Tk.Disconnected' }))
    $Label.Text = if ($Connected) { "${Service}: $Account" } else { "${Service}: not connected" }
}

function Update-ConnectionStatus {
    Start-UiJob -Name 'Connection status' -Quiet -ScriptBlock { Get-TkConnectionStatus } -OnComplete {
        param($Done, $Output)
        $status = $Output | Select-Object -First 1
        if (-not $status) { return }
        Set-ConnectionIndicator $ui.GraphDot $ui.GraphStatus 'Graph' $status.GraphConnected $status.GraphAccount
        Set-ConnectionIndicator $ui.ExoDot $ui.ExoStatus 'Exchange' $status.ExchangeConnected $status.ExchangeAccount
    }
}

function Save-Preferences {
    try {
        Save-TkPreference -Preference ([pscustomobject]@{
            Favorites = [string[]]@($State.Favorites | Sort-Object)
            GroupBy   = $State.GroupBy
            Theme     = $State.Theme
        })
    }
    catch { Write-UiLog 'WARN' "Could not save preferences: $($_.Exception.Message)" }
}

function Sync-Theme {
    <# Shows the preferred theme. 'System' rereads the Windows app mode, so calling this on Activated follows changes. #>
    $theme = Resolve-TkTheme $State.Theme
    if ($theme -ne (Get-TkTheme)) { Set-TkTheme -Theme $theme }
}

function Set-StarState {
    param($Button, [bool] $IsFavorite, [string] $ModuleName)
    $Button.Content = if ($IsFavorite) { $Star.On } else { $Star.Off }
    # Local gold while set; otherwise clear it so the style's grey + gold-on-hover applies.
    if ($IsFavorite) { $Button.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Tk.Gold') } else { $Button.ClearValue([System.Windows.Controls.Control]::ForegroundProperty) }
    $Button.ToolTip = if ($IsFavorite) { 'Remove from favourites' } else { 'Add to favourites' }
    [System.Windows.Automation.AutomationProperties]::SetName($Button, "Favourite: $ModuleName")
}

function Switch-Favorite {
    param([string] $Id)
    if (-not $State.Favorites.Remove($Id)) { [void]$State.Favorites.Add($Id) }
    Save-Preferences
    Update-ModuleTree
    if ($State.Current -and $State.Current.Id -eq $Id) { Update-ModuleHeader $State.Current }
}

function Set-TagFilter {
    param([string] $Tag, [bool] $On)
    if ($On) { [void]$State.SelectedTags.Add($Tag) } else { [void]$State.SelectedTags.Remove($Tag) }
    Update-TagPanel
    Update-ModuleTree
    if ($State.Current) { Update-ModuleHeader $State.Current }
}

function New-TagChip {
    param([string] $Tag, [string] $Text = $Tag)
    $chip = New-Object System.Windows.Controls.Primitives.ToggleButton
    $chip.Style = $ui.Window.FindResource('TagChip')
    $chip.Content = $Text
    $chip.Tag = $Tag
    $chip.IsChecked = $State.SelectedTags.Contains($Tag)
    $chip.ToolTip = if ($chip.IsChecked) { "Stop filtering on '$Tag'" } else { "Show only modules tagged '$Tag'" }
    # Checked/Unchecked rather than Click, so keyboard and screen-reader toggling work too.
    # (Handlers are attached after IsChecked is set above, so building a chip fires nothing.)
    $chip.Add_Checked({ Set-TagFilter $this.Tag $true })
    $chip.Add_Unchecked({ Set-TagFilter $this.Tag $false })
    $chip
}

function Update-TagPanel {
    $ui.TagPanel.Children.Clear()
    $counts = @{}      # PowerShell hashtables are case-insensitive, like tags
    foreach ($m in $State.Modules | Where-Object IsValid) {
        foreach ($t in $m.Tags) { $counts[$t] = 1 + [int]$counts[$t] }
    }
    # Forget selected tags that no longer exist (e.g. after editing tags).
    foreach ($t in @($State.SelectedTags | ForEach-Object { $_ })) { if (-not $counts.ContainsKey($t)) { [void]$State.SelectedTags.Remove($t) } }

    foreach ($t in $counts.Keys | Sort-Object) {
        [void]$ui.TagPanel.Children.Add((New-TagChip -Tag $t -Text "$t  $($counts[$t])"))
    }
    if ($State.SelectedTags.Count) {
        $clear = New-Object System.Windows.Controls.Button
        $clear.Style = $ui.Window.FindResource('LinkButton')
        $clear.Content = 'Clear filter'
        $clear.Add_Click({ $State.SelectedTags.Clear(); Update-TagPanel; Update-ModuleTree; if ($State.Current) { Update-ModuleHeader $State.Current } })
        [void]$ui.TagPanel.Children.Add($clear)
    }
    if (-not $counts.Count) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Style = $ui.Window.FindResource('Hint')
        $none.Text = "No tags yet - select a module and use 'Edit tags'."
        [void]$ui.TagPanel.Children.Add($none)
    }
}

function Test-ModuleVisible {
    param($Module)
    $filter = $ui.SearchBox.Text.Trim()
    if ($filter) {
        $pattern = '*' + [System.Management.Automation.WildcardPattern]::Escape($filter) + '*'
        $hit = $Module.Name -like $pattern -or $Module.Category -like $pattern -or $Module.Id -like $pattern -or
            $Module.Description -like $pattern -or @($Module.Tags | Where-Object { $_ -like $pattern }).Count
        if (-not $hit) { return $false }
    }
    foreach ($t in $State.SelectedTags) { if ($Module.Tags -notcontains $t) { return $false } }
    $true
}

function New-ModuleTreeItem {
    param($Module)
    $item = New-Object System.Windows.Controls.TreeViewItem
    $item.Tag = $Module
    $item.FontWeight = [System.Windows.FontWeights]::Normal

    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $star = New-Object System.Windows.Controls.Button
    $star.Style = $ui.Window.FindResource('StarButton')
    $star.Tag = $Module.Id
    Set-StarState $star $State.Favorites.Contains($Module.Id) $Module.Name
    $star.Add_Click({ Switch-Favorite $this.Tag })
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Module.Name
    $label.VerticalAlignment = 'Center'
    if (-not $Module.IsValid) { $label.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.Error') }
    [void]$row.Children.Add($star)
    [void]$row.Children.Add($label)
    $item.Header = $row
    # The header is a panel now, so give the row a name for screen readers and UI automation.
    [System.Windows.Automation.AutomationProperties]::SetName($item, $Module.Name)

    $tip =if ($Module.IsValid) { $Module.Description } else { $Module.Errors -join "`n" }
    if ($Module.Tags.Count) { $tip += "`n`nTags: " + ($Module.Tags -join ', ') }
    $item.ToolTip = $tip
    $item
}

function New-GroupTreeItem {
    param([string] $Key, [string] $Title, [object[]] $Modules)
    $group = New-Object System.Windows.Controls.TreeViewItem
    $group.Header = '{0} ({1})' -f $Title, $Modules.Count
    $group.FontWeight = [System.Windows.FontWeights]::SemiBold
    $group.DataContext = $Key
    $group.IsExpanded = -not $State.Collapsed.Contains($Key)
    # Remember folding across rebuilds. Expanded/Collapsed bubble up, so ignore events from children.
    $group.Add_Expanded({ if ($_.OriginalSource -eq $this) { [void]$State.Collapsed.Remove($this.DataContext) } })
    $group.Add_Collapsed({ if ($_.OriginalSource -eq $this) { [void]$State.Collapsed.Add($this.DataContext) } })
    foreach ($m in $Modules | Sort-Object Name) { [void]$group.Items.Add((New-ModuleTreeItem $m)) }
    [void]$ui.ModuleTree.Items.Add($group)
}

function Update-ModuleTree {
    $ui.ModuleTree.Items.Clear()
    $visible = @($State.Modules | Where-Object { Test-ModuleVisible $_ })
    $valid = @($visible | Where-Object IsValid)

    $favorites = @($visible | Where-Object { $State.Favorites.Contains($_.Id) })
    if ($favorites) { New-GroupTreeItem -Key 'fav' -Title "$($Star.On) Favourites" -Modules $favorites }

    switch ($State.GroupBy) {
        'Tag' {
            foreach ($t in @($valid | ForEach-Object { $_.Tags } | Sort-Object -Unique)) {
                New-GroupTreeItem -Key "tag:$t" -Title $t -Modules @($valid | Where-Object { $_.Tags -contains $t })
            }
            $untagged = @($valid | Where-Object { $_.Tags.Count -eq 0 })
            if ($untagged) { New-GroupTreeItem -Key 'tag:' -Title '(untagged)' -Modules $untagged }
        }
        'Name' {
            foreach ($m in $valid | Sort-Object Name) { [void]$ui.ModuleTree.Items.Add((New-ModuleTreeItem $m)) }
        }
        default {
            foreach ($g in $valid | Group-Object Category | Sort-Object Name) {
                New-GroupTreeItem -Key "cat:$($g.Name)" -Title $g.Name -Modules @($g.Group)
            }
        }
    }
    $invalid = @($visible | Where-Object { -not $_.IsValid })
    if ($invalid) { New-GroupTreeItem -Key 'invalid' -Title '[!] Invalid modules' -Modules $invalid }

    if ($ui.ModuleTree.Items.Count -eq 0) {
        $empty = New-Object System.Windows.Controls.TreeViewItem
        $empty.Header = 'No modules match the search or tag filter.'
        $empty.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Tk.SubtleText')
        $empty.Focusable = $false
        [void]$ui.ModuleTree.Items.Add($empty)
    }
    if ($State.Current) { Select-ModuleInTree $State.Current.Id }
}

function Select-ModuleInTree {
    <# Selects the module's row. Only looks in expanded groups unless -Reveal is given. #>
    param([string] $Id, [switch] $Reveal)
    foreach ($top in $ui.ModuleTree.Items) {
        if ($top.Tag -and $top.Tag.Id -eq $Id) { $top.IsSelected = $true; return }
        if (-not $top.IsExpanded -and -not $Reveal) { continue }
        foreach ($child in $top.Items) {
            if ($child.Tag -and $child.Tag.Id -eq $Id) {
                $top.IsExpanded = $true
                $child.IsSelected = $true
                $child.BringIntoView()
                return
            }
        }
    }
}

function Import-Modules {
    <# Rescans the Modules folder. -KeepForm keeps typed input when the selected module still exists. #>
    param([switch] $KeepForm)
    $currentId = if ($State.Current) { $State.Current.Id } else { $null }
    $State.Modules = @(Get-TkModule -Path $ModulesPath)
    $valid = @($State.Modules | Where-Object IsValid).Count
    $invalid = $State.Modules.Count - $valid
    Write-UiLog 'INFO' "Loaded $valid module(s) from $ModulesPath."
    foreach ($m in $State.Modules | Where-Object { -not $_.IsValid }) {
        Write-UiLog 'WARN' "Module '$($m.Id)' is invalid: $($m.Errors -join ' | ')"
    }
    $ui.SubTitle.Text = if ($invalid) { "$valid modules loaded, $invalid invalid" } else { "$valid modules loaded" }

    $fresh = if ($currentId) { $State.Modules | Where-Object { $_.Id -eq $currentId } | Select-Object -First 1 } else { $null }
    if ($fresh -and $KeepForm) { $State.Current = $fresh; Update-ModuleHeader $fresh }
    elseif ($fresh) { Show-Module $fresh }
    elseif ($currentId) { Clear-ModuleView }

    Update-TagPanel
    Update-ModuleTree
}

function Clear-ModuleView {
    $State.Current = $null
    $State.ParamControls = $null
    $ui.ModuleTitle.Text = 'Select a module'
    $ui.ModuleMeta.Text = ''
    $ui.ModuleDescription.Text = 'Pick a task from the list on the left.'
    $ui.ParamPanel.Children.Clear()
    $ui.HeaderTagPanel.Children.Clear()
    foreach ($name in 'FavoriteButton', 'EditTagsButton', 'OpenFolderButton', 'ViewScriptButton', 'TagEditPanel', 'WhatIfCheck', 'DryRunInfo') {
        $ui[$name].Visibility = 'Collapsed'
    }
    if ($State.Viewer) { $State.Viewer.Ui.Window.Close() }
    Update-Buttons
}

function Sync-ScriptViewer {
    <# Keeps an open script viewer on the selected module. #>
    $viewer = $State.Viewer
    if (-not $viewer) { return }
    $module = $State.Current
    if (-not $module -or -not $module.EntryPath -or -not (Test-Path -LiteralPath $module.EntryPath)) {
        $viewer.Ui.Window.Close()
        return
    }
    if ($viewer.Path -ne $module.EntryPath) {
        Set-TkScriptViewerContent -Viewer $viewer -Path $module.EntryPath -Title $module.Name -ManifestPath $module.ManifestPath
    }
}

function Update-DryRunOption {
    <# Every valid module gets the dry-run option; the hint explains how it works for this script. #>
    param($Module)
    if (-not $Module.IsValid -or -not $Module.DryRun) {
        $ui.WhatIfCheck.Visibility = 'Collapsed'
        $ui.DryRunInfo.Visibility = 'Collapsed'
        return
    }
    $ui.WhatIfCheck.Visibility = 'Visible'
    $ui.DryRunInfo.Visibility = 'Visible'
    # Safe by default: modules start in dry-run mode. Read-only ones don't need it - they're guarded on every run.
    $ui.WhatIfCheck.IsChecked = -not $Module.ReadOnly

    $how = if ($Module.DryRun.Mode -eq 'Native') {
        'The script supports WhatIf and reports what it would change. As a safety net the toolkit also blocks any Microsoft 365 change.'
    }
    else {
        'Enforced by the toolkit: every Microsoft 365 change the script attempts is blocked and listed under Blocked changes.'
    }
    if ($Module.ReadOnly) { $how = 'Read-only module: Microsoft 365 changes are blocked on every run, dry run or not. ' + $how }
    $how += ' Local files (e.g. CSV reports) are still written.'
    $caveats = @($Module.DryRun.Caveats)
    if ($caveats) {
        $how += "`nNot covered: " + ($caveats -join ' ')
        $ui.DryRunInfo.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.DryRunWarning')
    }
    else { $ui.DryRunInfo.ClearValue([System.Windows.Controls.TextBlock]::ForegroundProperty) }
    $ui.DryRunInfo.Text = $how
}

function Show-Blocked {
    <# Fills the Blocked changes tab after a guarded run. #>
    param([object[]] $Entries = @(), [string] $Guard = 'Off', [bool] $Native, [string] $ModuleName)
    $rows = @($Entries | Where-Object { $_ } | ForEach-Object {
        [pscustomobject]@{ Command = $_.Command; Target = $_.Target; Arguments = $_.Arguments }
    })
    $ui.BlockedGrid.ItemsSource = if ($rows.Count) { (ConvertTo-TkDataTable -FlatObject @(ConvertTo-TkFlatObject -InputObject $rows)).DefaultView } else { $null }
    $ui.BlockedTab.Header = if ($rows.Count) { "Blocked changes ($($rows.Count))" } else { 'Blocked changes' }
    $ui.BlockedSummary.Text = switch ($Guard) {
        'DryRun' {
            if ($rows.Count) { "Dry run: $($rows.Count) change(s) were blocked - nothing was changed in Microsoft 365. This is what the script would have done:" }
            elseif ($Native) { 'Dry run: nothing needed blocking. The script reported its intended changes itself - see Results (rows marked WhatIf).' }
            else { 'Dry run: the script did not attempt any Microsoft 365 change.' }
        }
        'ReadOnly' {
            if ($rows.Count) { "This read-only module tried to make $($rows.Count) change(s). All were blocked. Review its script - it should not do this." }
            else { 'Read-only run: no changes were attempted.' }
        }
        default { 'Real run - the dry-run guard was off, so nothing was blocked.' }
    }
    # The tab keeps showing the last run while you browse other modules - say which one it was.
    if ($ModuleName) { $ui.BlockedSummary.Text += "   [last run: $ModuleName]" }
}

function Update-ModuleHeader {
    <# Everything above the form: title, star, meta line, tag chips, description. #>
    param($Module)
    $ui.ModuleTitle.Text = $Module.Name
    Set-StarState $ui.FavoriteButton $State.Favorites.Contains($Module.Id) $Module.Name
    foreach ($name in 'FavoriteButton', 'EditTagsButton', 'OpenFolderButton') { $ui[$name].Visibility = 'Visible' }
    # The script can be read even when the module is invalid - that is often how you find out why.
    $hasScript = $Module.EntryPath -and (Test-Path -LiteralPath $Module.EntryPath)
    $ui.ViewScriptButton.Visibility = if ($hasScript) { 'Visible' } else { 'Collapsed' }
    Sync-ScriptViewer

    $requires = @()
    if ($Module.Requires.ExchangeOnline) { $requires += 'Exchange Online' }
    if ($Module.Requires.GraphScopes.Count) { $requires += "Graph ($($Module.Requires.GraphScopes -join ', '))" }
    if (-not $requires) { $requires = @('nothing') }
    $mode = if (-not $Module.DryRun) { '' } elseif ($Module.ReadOnly) { '   |   Read-only' } elseif ($Module.DryRun.Mode -eq 'Native') { '   |   WhatIf: native' } else { '   |   WhatIf: enforced by toolkit' }
    $ui.ModuleMeta.Text = '{0}   |   v{1}   |   {2}   |   Requires: {3}{4}' -f $Module.Category, $Module.Version, $Module.Id, ($requires -join ' + '), $mode

    $ui.HeaderTagPanel.Children.Clear()
    foreach ($t in $Module.Tags) { [void]$ui.HeaderTagPanel.Children.Add((New-TagChip -Tag $t)) }

    if ($Module.IsValid) { $ui.ModuleDescription.Text = $Module.Description }
    else { $ui.ModuleDescription.Text = "This module failed validation and cannot run:`n  - " + ($Module.Errors -join "`n  - ") }
}

function Show-Module {
    param($Module)
    $State.Current = $Module
    $ui.TagEditPanel.Visibility = 'Collapsed'
    Update-ModuleHeader $Module

    if ($Module.IsValid) {
        $State.ParamControls = New-TkParameterForm -Panel $ui.ParamPanel -Module $Module
    }
    else {
        $ui.ParamPanel.Children.Clear()
        $State.ParamControls = $null
    }
    Update-DryRunOption $Module
    Update-Buttons
}

function Show-Results {
    param([object[]] $Objects, [string] $From)
    $State.Results = @(ConvertTo-TkFlatObject -InputObject $Objects)
    $State.ResultsFrom = $From
    $ui.ResultGrid.ItemsSource = (ConvertTo-TkDataTable -FlatObject $State.Results).DefaultView
    $ui.ResultCount.Text = '{0} result(s) from {1}' -f $State.Results.Count, $From
    $ui.ExportButton.IsEnabled = $State.Results.Count -gt 0
}

function Test-GraphSubModule {
    param($Row)
    $Row.Module -like 'Microsoft.Graph.*' -and $Row.Module -notin 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Beta'
}

function Start-InventoryScan {
    <#
        Lists the installed M365 PowerShell modules in a throwaway runspace, so the scan (and the
        gallery lookup) never waits for a module run in the worker and never holds one up.
    #>
    param([switch] $CheckGallery)
    if ($State.InventoryJob) { return }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $job = Start-TkJob -Runspace $runspace -Name 'Installed modules' -Parameters @{
        CorePath     = Join-Path $PSScriptRoot 'Core\Toolkit.Core.psm1'
        CheckGallery = [bool]$CheckGallery
    } -ScriptBlock {
        param($CorePath, $CheckGallery)
        Import-Module $CorePath
        Get-TkModuleInventory -CheckGallery:$CheckGallery
    }
    $job | Add-Member -NotePropertyMembers @{ Runspace = $runspace; CheckGallery = [bool]$CheckGallery; Kind = 'Scan' }
    $State.InventoryJob = $job
    $ui.InventorySummary.Text = if ($CheckGallery) { 'Checking the PowerShell Gallery for newer versions...' } else { 'Scanning installed PowerShell modules...' }
    Update-InventoryButtons
    $inventoryTimer.Start()
}

function Update-InventoryButtons {
    <# Scan and update share one runspace slot: while either runs, the inventory buttons are off. #>
    $idle = -not $State.InventoryJob
    $ui.CheckUpdatesButton.IsEnabled = $idle
    $ui.RescanModulesButton.IsEnabled = $idle
    $button = $ui.UpdateModulesButton
    $selected = @(Get-SelectedInventoryModule)
    $plan = @(Get-ModuleUpdatePlan)
    $button.Content = if ($selected.Count) { 'Update selected' } else { 'Update all' }
    if ($plan.Count) { $button.Content = "$($button.Content) ($($plan.Count))" }
    $button.IsEnabled = $idle -and $State.InventoryChecked -and $plan.Count -gt 0
    $button.ToolTip = if (-not $idle) { 'Busy - wait for the current scan or update to finish' }
        elseif (-not $State.InventoryChecked) { "Click 'Check for updates' first" }
        elseif (-not $plan.Count -and $selected.Count) { 'The selected modules need no update. Clear the selection to update everything.' }
        elseif (-not $plan.Count) { 'Everything is up to date' }
        else { "Install from the PowerShell Gallery: $(@($plan | ForEach-Object { "$($_.Module) $($_.To)" }) -join ', ')" }
}

function Get-SelectedInventoryModule {
    $ui.InventoryGrid.SelectedItems | ForEach-Object { [string]$_.Row['Module'] } | Where-Object { $_ }
}

function Get-ModuleUpdatePlan {
    <# What the update button would install: the selected rows, or every row when none is selected. #>
    if (-not $State.Inventory -or -not $State.InventoryChecked) { return }
    $selected = @(Get-SelectedInventoryModule)
    if ($selected.Count) { Get-TkModuleUpdatePlan -Inventory $State.Inventory -Name $selected -Elevated $State.Elevated }
    else { Get-TkModuleUpdatePlan -Inventory $State.Inventory -Elevated $State.Elevated }
}

function Start-ModuleUpdate {
    <# Asks first, then installs the planned versions in a throwaway runspace (not the worker, which has modules loaded). #>
    if ($State.InventoryJob) { return }
    $plan = @(Get-ModuleUpdatePlan)
    if (-not $plan.Count) { return }
    $lines = @($plan | Select-Object -First 12 | ForEach-Object {
        $from = if ($_.From) { $_.From } else { 'not installed' }
        "  $($_.Module): $from -> $($_.To) ($($_.Scope))"
    })
    if ($plan.Count -gt 12) { $lines += "  ...and $($plan.Count - 12) more" }
    $notes = @($plan | Where-Object Note | ForEach-Object Note | Select-Object -Unique)
    $text = "Install these PowerShell modules from the PowerShell Gallery?`n`n$($lines -join "`n")"
    if ($notes) { $text += "`n`n$($notes -join "`n")" }
    $text += "`n`nThis can take several minutes (the Microsoft.Graph bundle is large). Older versions are kept. Restart the toolkit afterwards to use the new versions."
    if ([System.Windows.MessageBox]::Show($text, 'Update modules', 'YesNo', 'Question') -ne 'Yes') { return }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $job = Start-TkJob -Runspace $runspace -Name 'Update modules' -Parameters @{
        CorePath = Join-Path $PSScriptRoot 'Core\Toolkit.Core.psm1'
        Plan     = $plan
    } -ScriptBlock {
        param($CorePath, $Plan)
        Import-Module $CorePath
        Update-TkInstalledModule -Plan $Plan
    }
    $job | Add-Member -NotePropertyMembers @{ Runspace = $runspace; Kind = 'Update' }
    $State.InventoryJob = $job
    Write-UiLog 'INFO' "Updating $($plan.Count) PowerShell module(s): $(@($plan | ForEach-Object { "$($_.Module) $($_.To)" }) -join ', ')"
    $ui.InventorySummary.Text = "Installing $($plan.Count) module(s) from the PowerShell Gallery - progress is on the Log tab..."
    Update-Buttons
    Update-InventoryButtons
    $inventoryTimer.Start()
}

function Complete-ModuleUpdate {
    $job = $State.InventoryJob
    $received = Receive-TkJob -Job $job
    $done = Complete-TkJob -Job $job
    $job.Runspace.Dispose()
    $State.InventoryJob = $null
    Update-Buttons     # restores the busy bar to the worker's state
    foreach ($entry in $received.Log) { Write-UiLog $entry.Level $entry.Message }

    $rows = $job.Collected.ToArray()
    $ok = @($rows | Where-Object { $_.Status -in 'Updated', 'Installed' })
    $failed = @($rows | Where-Object Status -eq 'Failed')
    $summary = if ($done.Failure) { "Module update failed: $($done.Failure)" }
        else { "Module update: $($ok.Count) installed, $($failed.Count) failed." }
    Write-UiLog $(if ($done.Failure -or $failed.Count) { 'WARN' } else { 'INFO' }) $summary
    $ui.StatusText.Text = $summary
    $message = $summary
    if ($failed.Count) { $message += "`n`nFailed:`n$(@($failed | ForEach-Object { "  $($_.Module): $($_.Message)" }) -join "`n")" }
    if ($failed.Count -and -not $State.Elevated) { $message += "`n`nTip: some failures need the toolkit to run as administrator." }
    if ($ok.Count) { $message += "`n`nRestart the toolkit to load the new versions - this session keeps using the old ones." }
    $icon = if ($done.Failure -or $failed.Count) { 'Warning' } else { 'Information' }
    [void][System.Windows.MessageBox]::Show($message, 'Update modules', 'OK', $icon)
    Start-InventoryScan -CheckGallery
}

function Complete-InventoryScan {
    $job = $State.InventoryJob
    $received = Receive-TkJob -Job $job
    $done = Complete-TkJob -Job $job
    $job.Runspace.Dispose()
    $State.InventoryJob = $null
    Update-InventoryButtons
    foreach ($entry in $received.Log) { Write-UiLog $entry.Level $entry.Message }

    if ($done.Failure) {
        $ui.InventorySummary.Text = "Could not list installed modules: $($done.Failure)"
        Write-UiLog 'ERROR' "Installed modules scan failed: $($done.Failure)"
        return
    }
    $State.Inventory = $job.Collected.ToArray()
    $State.InventoryChecked = $job.CheckGallery
    foreach ($row in $State.Inventory | Where-Object Status -eq 'Missing') {
        Write-UiLog 'WARN' "Required PowerShell module '$($row.Module)' is not installed - see the Installed modules tab."
    }
    Update-InventoryView
}

function Update-InventoryView {
    $rows = $State.Inventory
    $showSub = [bool]$ui.ShowGraphSubCheck.IsChecked
    $shown = @($rows | Where-Object { $showSub -or -not (Test-GraphSubModule $_) })
    $ui.InventoryGrid.ItemsSource = if ($shown.Count) { (ConvertTo-TkDataTable -FlatObject @(ConvertTo-TkFlatObject -InputObject $shown)).DefaultView } else { $null }

    $attention = @($rows | Where-Object { $_.Status -in 'Missing', 'Update available', 'Version mismatch', 'Retired' })
    $parts = foreach ($s in 'Missing', 'Update available', 'Version mismatch', 'Retired') {
        $n = @($attention | Where-Object Status -eq $s).Count
        if ($n) { '{0} {1}' -f $n, $s.ToLower() }
    }
    $installed = @($rows | Where-Object Installed).Count
    $text = if ($parts) { "$installed installed. Needs attention: $(@($parts) -join ', ')." } else { "$installed installed, nothing needs attention." }
    if (-not $State.InventoryChecked) { $text += " Click 'Check for updates' to compare with the PowerShell Gallery." }
    $hidden = @($rows | Where-Object { Test-GraphSubModule $_ })
    if ($hidden.Count -and -not $showSub) {
        $hiddenIssues = @($hidden | Where-Object { $_.Status -in 'Update available', 'Version mismatch' }).Count
        $text += " $($hidden.Count) Graph sub-module(s) hidden" + $(if ($hiddenIssues) { ", $hiddenIssues of them need attention." } else { '.' })
    }
    $ui.InventorySummary.Text = $text
    # Count only visible rows: one Graph update fixes dozens of hidden sub-module rows at once.
    $visibleIssues = @($attention | Where-Object { $showSub -or -not (Test-GraphSubModule $_) }).Count
    $ui.InventoryTab.Header = if ($visibleIssues) { "Installed modules ($visibleIssues to fix)" } else { 'Installed modules' }
    Update-InventoryButtons
}

#endregion

#region Event handlers

# The heartbeat: drain the running job's streams on the UI thread (no cross-thread calls).
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $job = $State.Job
    if (-not $job) { return }
    try {
        $finished = $job.Handle.IsCompleted     # check first so the final drain below catches everything
        $received = Receive-TkJob -Job $job
        foreach ($entry in $received.Log) { Write-UiLog $entry.Level $entry.Message -NoFile:($entry.Level -ne 'ERROR') }
        # Blocked calls may name users or mailboxes: on screen only, never in the log file.
        foreach ($b in $received.Blocked) { Write-UiLog 'BLOCKED' "$($b.Command) $($b.Arguments)" -NoFile }
        if (-not $job.Quiet -and $received.Output.Count) { $ui.ResultCount.Text = "$($job.Collected.Count) result(s) so far..." }
        if (-not $finished) { return }

        $done = Complete-TkJob -Job $job
        $State.Job = $null
        if (-not $job.Quiet) {
            $seconds = [math]::Round($done.Duration.TotalSeconds, 1)
            if ($done.Failure) { Write-UiLog 'ERROR' "$($job.Name) failed: $($done.Failure)" }
            Write-UiLog 'INFO' "Finished: $($job.Name) - $($done.State), $($job.Collected.Count) result(s), ${seconds}s"
            $ui.StatusText.Text = "Last run: $($job.Name) - $($done.State) in ${seconds}s"
        }
        Update-Buttons
        if ($job.OnComplete) { & $job.OnComplete $done $job.Collected.ToArray() $job.Blocked.ToArray() $job }
    }
    catch {
        $State.Job = $null
        Update-Buttons
        Write-UiLog 'ERROR' "Toolkit error while processing job: $($_.Exception.Message)"
    }
})

# Separate, short-lived heartbeat for the Installed modules scan or update; stops itself when it is done.
$inventoryTimer = New-Object System.Windows.Threading.DispatcherTimer
$inventoryTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$inventoryTimer.Add_Tick({
    $job = $State.InventoryJob
    if (-not $job) { $inventoryTimer.Stop(); return }
    if (-not $job.Handle.IsCompleted) {
        # An update takes minutes: show its progress as it happens.
        if ($job.Kind -eq 'Update') { foreach ($entry in (Receive-TkJob -Job $job).Log) { Write-UiLog $entry.Level $entry.Message } }
        return
    }
    $inventoryTimer.Stop()
    try {
        if ($job.Kind -eq 'Update') { Complete-ModuleUpdate } else { Complete-InventoryScan }
    }
    catch {
        $State.InventoryJob = $null
        Update-Buttons
        Update-InventoryButtons
        Write-UiLog 'ERROR' "Toolkit error while handling installed modules: $($_.Exception.Message)"
    }
})

$ui.RescanModulesButton.Add_Click({ Start-InventoryScan -CheckGallery:$State.InventoryChecked })
$ui.CheckUpdatesButton.Add_Click({ Start-InventoryScan -CheckGallery })
$ui.UpdateModulesButton.Add_Click({ Start-ModuleUpdate })
$ui.InventoryGrid.Add_SelectionChanged({ Update-InventoryButtons })
$ui.ShowGraphSubCheck.Add_Checked({ Update-InventoryView })
$ui.ShowGraphSubCheck.Add_Unchecked({ Update-InventoryView })

$ui.ModuleTree.Add_SelectedItemChanged({
    $item = $ui.ModuleTree.SelectedItem
    if (-not $item -or -not $item.Tag) { return }
    # The tree is rebuilt on every filter/star change; re-selecting the same module must not wipe the form.
    if ($State.Current -and $State.Current.Id -eq $item.Tag.Id) { return }
    Show-Module $item.Tag
})

$ui.SearchBox.Add_TextChanged({ Update-ModuleTree })
$ui.ReloadButton.Add_Click({ Import-Modules })

$ui.GroupByBox.SelectedIndex = [math]::Max(0, [array]::IndexOf(@('Category', 'Tag', 'Name'), $State.GroupBy))
$ui.GroupByBox.Add_SelectionChanged({
    $State.GroupBy = [string]$ui.GroupByBox.SelectedItem.Tag
    Save-Preferences
    Update-ModuleTree
})

$ui.FavoriteButton.Add_Click({ if ($State.Current) { Switch-Favorite $State.Current.Id } })

# View script: a toggle that opens a read-only viewer window, which then follows the selected module.
$ui.ViewScriptButton.Add_Checked({
    $module = $State.Current
    if (-not $module -or -not $module.EntryPath -or -not (Test-Path -LiteralPath $module.EntryPath)) {
        $ui.ViewScriptButton.IsChecked = $false
        return
    }
    if ($State.Viewer) { Sync-ScriptViewer; [void]$State.Viewer.Ui.Window.Activate(); return }
    try {
        $viewer = Open-TkScriptViewer -Owner $ui.Window -Path $module.EntryPath -Title $module.Name -ManifestPath $module.ManifestPath
        $viewer.Ui.Window.Add_Closed({
            $State.Viewer = $null
            $ui.ViewScriptButton.IsChecked = $false
        })
        $State.Viewer = $viewer
    }
    catch {
        $ui.ViewScriptButton.IsChecked = $false
        Write-UiLog 'ERROR' "Could not open the script viewer: $($_.Exception.Message)"
    }
})
$ui.ViewScriptButton.Add_Unchecked({ if ($State.Viewer) { $State.Viewer.Ui.Window.Close() } })

$ui.OpenFolderButton.Add_Click({
    if ($State.Current) { Start-Process -FilePath explorer.exe -ArgumentList "`"$($State.Current.Directory)`"" }
})

$ui.EditTagsButton.Add_Click({
    if (-not $State.Current) { return }
    $ui.TagEditBox.Text = $State.Current.Tags -join ', '
    $inUse = @($State.Modules | ForEach-Object { $_.Tags } | Sort-Object -Unique)
    $ui.TagEditBox.ToolTip = if ($inUse) { "Comma-separated. Tags in use: $($inUse -join ', ')" } else { 'Comma-separated, e.g. Calendar, Permissions' }
    $ui.TagEditPanel.Visibility = 'Visible'
    [void]$ui.TagEditBox.Focus()
    $ui.TagEditBox.SelectAll()
})

function Save-EditedTags {
    $module = $State.Current
    if (-not $module) { return }
    $tags = [string[]]@(Split-TkList $ui.TagEditBox.Text)
    try {
        Set-TkModuleTag -ModuleDirectory $module.Directory -Tags $tags
        Write-UiLog 'INFO' "Tags for '$($module.Id)' set to: $(if ($tags) { $tags -join ', ' } else { '(none)' })"
        $ui.TagEditPanel.Visibility = 'Collapsed'
        Import-Modules -KeepForm
    }
    catch {
        [void][System.Windows.MessageBox]::Show("Could not save tags: $($_.Exception.Message)", 'Edit tags', 'OK', 'Error')
    }
}
$ui.SaveTagsButton.Add_Click({ Save-EditedTags })
$ui.CancelTagsButton.Add_Click({ $ui.TagEditPanel.Visibility = 'Collapsed' })
$ui.TagEditBox.Add_KeyDown({
    if ($_.Key -eq 'Return') { Save-EditedTags; $_.Handled = $true }
    elseif ($_.Key -eq 'Escape') { $ui.TagEditPanel.Visibility = 'Collapsed'; $_.Handled = $true }
})

$ui.AddModuleButton.Add_Click({
    try {
        $created = Show-TkAddModuleDialog -Owner $ui.Window -ModulesPath $ModulesPath -Modules $State.Modules
    }
    catch {
        Write-UiLog 'ERROR' "Add module failed: $($_.Exception.Message)"
        return
    }
    if (-not $created) { return }
    Write-UiLog 'INFO' "Added module '$($created.Id)' in $($created.Directory)"
    Import-Modules
    Show-Module $created
    Select-ModuleInTree $created.Id -Reveal
    $ui.StatusText.Text = "Added '$($created.Name)'. Use 'Open folder' to fine-tune module.json or the script."
})

$ui.RunButton.Add_Click({
    $module = $State.Current
    if (-not $module -or -not $module.IsValid) { return }

    $form = Get-TkParameterValue -Controls $State.ParamControls
    if ($form.Problems.Count) {
        [void][System.Windows.MessageBox]::Show(($form.Problems -join "`n"), 'Check your input', 'OK', 'Warning')
        return
    }
    $parameters = $form.Values
    $dryRun = [bool]$ui.WhatIfCheck.IsChecked
    # Only scripts that declare SupportsShouldProcess accept -WhatIf; the guard covers all of them.
    if ($module.SupportsWhatIf) { $parameters['WhatIf'] = $dryRun }
    $guard = if ($dryRun) { 'DryRun' } elseif ($module.ReadOnly) { 'ReadOnly' } else { 'Off' }
    if ($guard -eq 'Off') {
        $answer = [System.Windows.MessageBox]::Show(
            "'$($module.Name)' will run for real and can make changes in your tenant.`n`nTip: read it with 'View script' or do a dry run first.`n`nContinue?",
            'Confirm changes', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    $ui.ResultGrid.ItemsSource = $null
    $ui.ExportButton.IsEnabled = $false
    $ui.ResultCount.Text = 'Running...'
    Show-Blocked -Entries @() -Guard $guard
    $modeText = switch ($guard) { 'DryRun' { 'DRY RUN - Microsoft 365 changes are blocked' } 'ReadOnly' { 'read-only run - changes are blocked' } default { 'REAL RUN - changes will be made' } }
    Write-UiLog 'INFO' "Mode: $modeText"
    # Log which inputs were supplied, never their values - they may identify people.
    $suppliedNames = if ($parameters.Count) { ($parameters.Keys | Sort-Object) -join ', ' } else { 'none' }
    Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message "Run $($module.Id) v$($module.Version) mode=$guard with inputs: $suppliedNames"

    $jobName = if ($guard -eq 'DryRun') { "$($module.Name) (dry run)" } else { $module.Name }
    Start-UiJob -Name $jobName -Cancellable -Data @{ Guard = $guard; Native = $module.SupportsWhatIf; ModuleName = $module.Name } -Parameters @{
        EntryPath  = $module.EntryPath
        Requires   = $module.Requires
        Parameters = $parameters
        Guard      = $guard
    } -ScriptBlock {
        param($EntryPath, $Requires, $Parameters, $Guard)
        Invoke-TkModule -EntryPath $EntryPath -Requires $Requires -Parameters $Parameters -Guard $Guard
    } -OnComplete {
        param($Done, $Output, $Blocked, $Job)
        Show-Results -Objects $Output -From $Job.Data.ModuleName
        Show-Blocked -Entries $Blocked -Guard $Job.Data.Guard -Native $Job.Data.Native -ModuleName $Job.Data.ModuleName
        if ($Job.Data.Guard -ne 'Off') {
            # Counts only - the entries themselves stay on screen.
            Write-UiLog 'INFO' "$($Job.Data.Guard): $($Blocked.Count) Microsoft 365 change(s) blocked."
        }
        $ui.OutputTabs.SelectedItem = if ($Blocked.Count) { $ui.BlockedTab } elseif ($Output.Count) { $ui.ResultsTab } else { $ui.LogTab }
        Update-ConnectionStatus
    }
})

$ui.CancelButton.Add_Click({
    if ($State.Job) {
        Write-UiLog 'WARN' "Cancelling: $($State.Job.Name)"
        Stop-TkJob -Job $State.Job
    }
})

$ui.ConnectGraphButton.Add_Click({
    Start-UiJob -Name 'Connect Microsoft Graph' -ScriptBlock { Connect-TkGraph } -OnComplete { Update-ConnectionStatus }
})
$ui.ConnectExoButton.Add_Click({
    Start-UiJob -Name 'Connect Exchange Online' -ScriptBlock { Connect-TkExchange } -OnComplete { Update-ConnectionStatus }
})
$ui.DisconnectButton.Add_Click({
    Start-UiJob -Name 'Disconnect' -ScriptBlock { Disconnect-TkAll } -OnComplete { Update-ConnectionStatus }
})

$ui.ExportButton.Add_Click({
    if (-not $State.Results.Count) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'CSV file (*.csv)|*.csv'
    $safeName = ($State.ResultsFrom -replace '[^\w\-]+', '_').Trim('_')
    $dialog.FileName = '{0}_{1:yyyyMMdd-HHmm}.csv' -f $safeName, (Get-Date)
    if ($dialog.ShowDialog($ui.Window)) {
        # -UseCulture picks the list separator Excel expects on this machine (';' in NO/SE).
        $State.Results | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8 -UseCulture
        Write-UiLog 'INFO' "Exported $($State.Results.Count) row(s) to $($dialog.FileName)"
    }
})

$ui.Window.Add_ContentRendered({ Update-ConnectionStatus; Start-InventoryScan })

# Theme: set the box before hooking it up, so loading the preference doesn't save it straight back.
$ui.ThemeBox.SelectedIndex = [math]::Max(0, [array]::IndexOf(@('System', 'Light', 'Dark'), $State.Theme))
$ui.ThemeBox.Add_SelectionChanged({
    $State.Theme = [string]$ui.ThemeBox.SelectedItem.Tag
    Save-Preferences
    Sync-Theme
})
# Coming back to the toolkit after changing Windows' light/dark mode picks up the new mode.
$ui.Window.Add_Activated({ if ($State.Theme -eq 'System') { Sync-Theme } })

# Safety net: an exception escaping any event handler would otherwise terminate the whole app.
$ui.Window.Dispatcher.Add_UnhandledException({
    $_.Handled = $true
    try { Write-UiLog 'ERROR' "Unexpected error (the toolkit kept running): $($_.Exception.Message)" } catch { }
})

$ui.Window.Add_Closing({
    # Stopping Install-Module halfway can leave a broken module folder behind.
    if ($State.InventoryJob -and $State.InventoryJob.Kind -eq 'Update') {
        $answer = [System.Windows.MessageBox]::Show(
            "PowerShell modules are still being installed. Closing now can leave a module half installed.`n`nClose anyway?",
            'Update in progress', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $_.Cancel = $true; return }
    }
    $timer.Stop()
    $inventoryTimer.Stop()
    if ($State.Job) { Stop-TkJob -Job $State.Job }
    if ($State.InventoryJob) { Stop-TkJob -Job $State.InventoryJob }
    Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message 'Toolkit closed.'
})

#endregion

Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message "Toolkit started (PowerShell $($PSVersionTable.PSVersion))."
Import-Modules
$State.Worker = New-TkWorker -HelperScript (Join-Path $PSScriptRoot 'Core\Toolkit.Worker.ps1') -Settings $settings
$timer.Start()

[void]$ui.Window.ShowDialog()

if ($State.Worker) { $State.Worker.Dispose() }
