#Requires -Version 5.1
<#
.SYNOPSIS
    Admin Toolkit - a modular WPF front-end for admin tasks: Microsoft 365 modules and local scripts.

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
# Release builds carry a VERSION file (Tools\New-ToolkitRelease.ps1); a git clone doesn't.
$versionFile = Join-Path $PSScriptRoot 'VERSION'
$toolkitVersion = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() } else { 'dev' }
$editionFile = Join-Path $PSScriptRoot 'EDITION'
$toolkitEdition = if (Test-Path -LiteralPath $editionFile) { (Get-Content -LiteralPath $editionFile -TotalCount 1).Trim() } else { $null }
$ui.VersionText.Text = $toolkitVersion
$ui.VersionText.ToolTip = if ($toolkitVersion -eq 'dev') { 'Development copy (no VERSION file): not installed from a release' }
    elseif ($toolkitEdition) { "Toolkit version $toolkitVersion, $toolkitEdition edition" }
    else { "Toolkit version $toolkitVersion" }
$ui.Window.Title = "$($ui.Window.Title) $toolkitVersion"
$baseTitle = $ui.Window.Title      # Show-Tenant appends the tenant, so it shows in the taskbar too
$ui.MainTabs.SelectedItem = $ui.ModulesTab     # always open on the Modules page

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
    ReadinessView = $preferences.ReadinessView   # Percent (with counts) or Rating (Pass/Warn/Fail)
    ReadinessByModule = @{}               # module Id -> last run's readiness (Get-TkReadiness + Finished); this session only
    Viewer        = $null                 # the open script viewer, if any
    Inventory     = @()                   # rows for Settings > Installed PowerShell modules
    InventoryJob  = $null                 # scan running in its own runspace, apart from the worker
    InventoryChecked = $false             # whether the last scan compared with the PowerShell Gallery
    Elevated      = Test-TkElevated        # AllUsers modules can only be updated in place as administrator
    SignOutNotice = ''                    # why the worker last ended the sign-in; shown in the header until the next one
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
    # A script whose interpreter isn't on this PC can still be read and exported, not run.
    $runnable = [bool]$State.Current -and [bool]$State.Current.IsValid -and
        (-not $State.Current.External -or (Get-TkRuntimeStatus -Name $State.Current.Runtime -Settings $settings).Available)
    $ui.RunButton.IsEnabled = (-not $busy) -and $runnable
    $ui.CancelButton.IsEnabled = $busy -and [bool]$State.Job.Cancellable
    # SaveSessionButton: new limits are applied in the worker, which can't take a second job.
    foreach ($name in 'ConnectGraphButton', 'ConnectExoButton', 'DisconnectButton', 'ReloadButton', 'AddModuleButton', 'SaveTagsButton', 'SaveSessionButton') {
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
        Show-Tenant $status
    }
}

function Show-Tenant {
    <# The tenant block in the header (and the window title). Fails closed: no session, no tenant shown. #>
    param($Status)
    $connected = ($Status.GraphConnected -or $Status.ExchangeConnected) -and $Status.TenantId
    if ($Status.SignOutReason) {
        $State.SignOutNotice = $Status.SignOutReason
        $ui.StatusText.Text = "Signed out of Microsoft 365 because $($Status.SignOutReason)."
        # The worker's warning is on screen; the file gets the reason (no tenant or account details).
        Write-TkLogFile -Path $State.LogFile -Level 'WARN' -Message "Signed out: $($Status.SignOutReason)"
    }
    if ($connected) {
        $State.SignOutNotice = ''
        $name = if ($Status.TenantName) { $Status.TenantName } else { 'Tenant name not available' }
        $ui.TenantName.Text = $name
        $ui.TenantIdText.Text = "Tenant ID: $($Status.TenantId)"
        $ui.TenantIdText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.HeaderSubtle')
        $ui.TenantBox.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Tk.Connected')
        $ui.TenantBox.ToolTip = "Every module runs in this tenant.`nSigned in at {0:HH:mm}. The session ends at {1:HH:mm}, after {2} minutes without use, or when the PC sleeps - whichever comes first." -f $Status.SignedIn, $Status.SessionEnd, $Status.IdleMinutes
        $ui.Window.Title = "$baseTitle - $name ($($Status.TenantId))"
        [System.Windows.Automation.AutomationProperties]::SetName($ui.TenantBox, "Current tenant: $name, ID $($Status.TenantId)")
    }
    else {
        $ui.TenantName.Text = 'No tenant - not signed in'
        $ui.TenantIdText.Text = 'Tenant ID: -'
        $ui.TenantIdText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.HeaderSubtle')
        $ui.TenantBox.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Tk.Disconnected')
        $ui.TenantBox.ToolTip = 'Not signed in. The toolkit signs in when a module needs it, and asks which account to use.'
        $ui.Window.Title = $baseTitle
        [System.Windows.Automation.AutomationProperties]::SetName($ui.TenantBox, 'Current tenant: not signed in')
        # Stays until the next sign-in, so coming back to the PC you can see why you were signed out.
        if ($State.SignOutNotice) {
            $ui.TenantIdText.Text = "Signed out: $($State.SignOutNotice)"
            $ui.TenantIdText.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.HeaderWarning')
            $ui.TenantBox.SetResourceReference([System.Windows.Controls.Border]::BorderBrushProperty, 'Tk.HeaderWarning')
            $ui.TenantBox.ToolTip = "Signed out because $($State.SignOutNotice). The next module run or Connect asks you to sign in again."
        }
    }
}

function Save-Preferences {
    try {
        Save-TkPreference -Preference ([pscustomobject]@{
            Favorites = [string[]]@($State.Favorites | Sort-Object)
            GroupBy   = $State.GroupBy
            Theme     = $State.Theme
            ReadinessView = $State.ReadinessView
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
            $Module.Description -like $pattern -or $Module.Runtime -like $pattern -or @($Module.Tags | Where-Object { $_ -like $pattern }).Count
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
        'Runtime' {
            # In the runtime table's order: PowerShell first, then cmd, bash, zsh, Python.
            foreach ($r in Get-TkRuntimeName) {
                $group = @($valid | Where-Object Runtime -eq $r)
                if ($group) { New-GroupTreeItem -Key "rt:$r" -Title $r -Modules $group }
            }
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
    Show-Readiness
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
    # Only the guard can promise "nothing is changed": another language's dry run is the script's own word.
    $ui.WhatIfCheck.Content = if ($Module.DryRun.Mode -eq 'External') { "Dry run ($($Module.DryRunArgument)) - the script's own, not checked by the toolkit" }
        else { 'Dry run (WhatIf) - nothing is changed in Microsoft 365' }

    if ($Module.DryRun.Mode -eq 'External') {
        # Another language: the guard can't see it. Only offer a dry run the script implements itself.
        $runtime = Get-TkRuntimeStatus -Name $Module.Runtime -Settings $settings
        $ui.WhatIfCheck.Visibility = if ($Module.SupportsWhatIf) { 'Visible' } else { 'Collapsed' }
        $ui.WhatIfCheck.IsChecked = [bool]$Module.SupportsWhatIf
        $how = if ($Module.SupportsWhatIf) { "Dry run: the toolkit runs the script with $($Module.DryRunArgument) and the script decides what that means." }
        else { 'No dry run: this script has no dry-run switch. The toolkit asks before every run.' }
        $how += "`nUnguarded: " + (@($Module.DryRun.Caveats) -join ' ')
        if (-not $runtime.Available) { $how += "`nExport only on this PC - no interpreter found ($($runtime.Reason)). Install one, or set Runtimes.$($Module.Runtime).Path in Config\settings.json." }
        $ui.DryRunInfo.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.DryRunWarning')
        $ui.DryRunInfo.Text = $how
        return
    }

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
    param([object[]] $Entries = @(), [string] $Guard = 'Off', [bool] $Native, [string] $ModuleName, [bool] $External, [bool] $DryRun)
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
        default {
            if ($External -and $DryRun) { "Unguarded script, run with its own dry-run switch: the toolkit can't see or block what it does. Check its output in Results and Log." }
            elseif ($External) { "Unguarded script (not PowerShell): the toolkit can't see or block what it does." }
            else { 'Real run - the dry-run guard was off, so nothing was blocked.' }
        }
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
    $mode = if (-not $Module.DryRun) { '' } elseif ($Module.External) { '   |   UNGUARDED' } elseif ($Module.ReadOnly) { '   |   Read-only' } elseif ($Module.DryRun.Mode -eq 'Native') { '   |   WhatIf: native' } else { '   |   WhatIf: enforced by toolkit' }
    if ($Module.External) {
        $runtime = Get-TkRuntimeStatus -Name $Module.Runtime -Settings $settings
        $mode = "   |   $(if ($runtime.Available) { $runtime.Label } else { "$($Module.Runtime) - export only" })$mode"
        if ($Module.Platforms.Count) { $mode += "   |   For: $($Module.Platforms -join ', ')" }
    }
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
    Show-Readiness
    Update-Buttons
}

function Show-Results {
    param([object[]] $Objects, [string] $From)
    $State.Results = @(ConvertTo-TkFlatObject -InputObject $Objects)
    $State.ResultsFrom = $From
    $ui.ResultGrid.ItemsSource = (ConvertTo-TkDataTable -FlatObject $State.Results).DefaultView
    $ui.ResultCount.Text = '{0} result(s) from {1}' -f $State.Results.Count, $From
    $ui.ExportButton.IsEnabled = $State.Results.Count -gt 0
    $ui.OpenExcelButton.IsEnabled = $State.Results.Count -gt 0
}

function Show-Readiness {
    <#
        The Tenant readiness box beside the inputs, for the selected module's last run in this session.
        Hidden (inputs take the full width) when that module has no figure.
    #>
    $r = if ($State.Current) { $State.ReadinessByModule[$State.Current.Id] }
    if (-not $r) {
        $ui.ReadinessCard.Visibility = 'Collapsed'
        $ui.ReadinessColumn.Width = New-Object System.Windows.GridLength 0
        return
    }

    # Ring: an ellipse stroke dashed to the share, in stroke-thickness units, around the ellipse's centre line.
    $ring = $ui.ReadinessRing
    $circumference = [math]::PI * ($ui.ReadinessGauge.Width - $ring.StrokeThickness)
    $dash = $circumference * $r.Percent / 100 / $ring.StrokeThickness
    $ring.StrokeDashArray = New-Object System.Windows.Media.DoubleCollection (, [double[]]@($dash, 1000))
    $brush = switch ($r.Rating) { 'Pass' { 'Tk.ReadinessPass' } 'Warn' { 'Tk.ReadinessWarn' } default { 'Tk.ReadinessFail' } }
    $ring.SetResourceReference([System.Windows.Shapes.Shape]::StrokeProperty, $brush)

    $percent = '{0}%' -f $r.Percent
    $rating = $r.Rating.ToUpperInvariant()
    $big, $small = if ($State.ReadinessView -eq 'Rating') { $rating, $percent } else { $percent, $rating }
    $ui.ReadinessBig.Text = $big
    $ui.ReadinessSmall.Text = $small
    $ui.ReadinessSmall.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brush)
    [System.Windows.Automation.AutomationProperties]::SetName($ui.ReadinessGauge, "Readiness $($r.Percent) percent, $($r.Rating)")

    $ui.ReadinessLabel.Text = '{0} of {1} {2}' -f $r.Ready, $r.Total, $r.Label
    $ui.ReadinessNotEvaluated.Text = "$($r.NotEvaluated) not evaluated"
    $ui.ReadinessNotEvaluated.Visibility = if ($r.NotEvaluated) { 'Visible' } else { 'Collapsed' }
    $ui.ReadinessThresholds.Text = 'Pass: {0}%+     Warn: {1}%+     Fail: below {1}%' -f $r.Pass, $r.Warn
    $ui.ReadinessSource.Text = 'Last run {0:HH:mm}' -f $r.Finished

    $ui.ReadinessColumn.Width = New-Object System.Windows.GridLength 1, ([System.Windows.GridUnitType]::Star)
    $ui.ReadinessCard.Visibility = 'Visible'
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

    $remove = $ui.UninstallModulesButton
    $removable = @(Get-UninstallCandidate)
    $remove.Content = if ($removable.Count) { "Uninstall ($($removable.Count))" } else { 'Uninstall' }
    $remove.IsEnabled = $idle -and $removable.Count -gt 0
    $remove.ToolTip = if (-not $idle) { 'Busy - wait for the current scan or update to finish' }
        elseif (-not $removable.Count) { 'Select the installed modules to remove first' }
        else { "Remove every installed version of: $(@($removable | ForEach-Object Module) -join ', ')" }
}

function Get-UninstallCandidate {
    <# The selected rows that are actually installed. #>
    $selected = @(Get-SelectedInventoryModule)
    if (-not $selected.Count) { return }
    $State.Inventory | Where-Object { $_.Installed -and $selected -contains $_.Module }
}

function Show-ModuleFolders {
    <#
        Lists the folders PowerShell loads modules from (and where the selected modules are), then offers
        to open one in Explorer. On screen only: the paths contain the user name, so they are never logged.
    #>
    $folders = @(Get-TkModuleFolder)
    $selected = @(Get-SelectedInventoryModule)
    $copies = if ($selected.Count) { @(Get-TkModuleLocation -Name $selected) } else { @() }

    $lines = @('PowerShell looks for modules in these folders, in this order:', '')
    $lines += @($folders | ForEach-Object { "  $($_.Scope): $($_.Path)$(if (-not $_.Exists) { '  (does not exist yet)' })" })
    if ($copies.Count) {
        $lines += '', 'Selected modules:'
        $lines += @($copies | ForEach-Object { "  $($_.Module) $($_.Version): $($_.Path)" })
    }
    elseif ($selected.Count) { $lines += '', 'The selected modules are not installed.' }

    # Open the selected module's own folder (the one holding its version folders), else the user's module folder.
    $open = $null
    if ($copies.Count) {
        $newest = @($copies | Where-Object Module -eq $copies[0].Module)[-1].Path
        $open = if ($null -ne (ConvertTo-ModuleFolderVersion (Split-Path $newest -Leaf))) { Split-Path $newest -Parent } else { $newest }
    }
    else { $open = @($folders | Where-Object { $_.Exists -and $_.Scope -eq 'CurrentUser' }) + @($folders | Where-Object Exists) | Select-Object -First 1 -ExpandProperty Path }

    $lines += '', 'Ctrl+C copies this text.'
    if (-not $open -or -not (Test-Path -LiteralPath $open)) {
        [void][System.Windows.MessageBox]::Show(($lines -join "`n"), 'Module folders', 'OK', 'Information')
        return
    }
    $lines += '', "Open this folder in Explorer?`n  $open"
    if ([System.Windows.MessageBox]::Show(($lines -join "`n"), 'Module folders', 'YesNo', 'Information') -eq 'Yes') {
        Start-Process -FilePath explorer.exe -ArgumentList "`"$open`""
    }
}

function ConvertTo-ModuleFolderVersion {
    param([string] $Text)
    $v = $null
    if ([version]::TryParse($Text, [ref]$v)) { $v } else { $null }
}

function Start-ModuleUninstall {
    <# Asks first, then removes every installed version of the selected modules in a throwaway runspace. #>
    if ($State.InventoryJob) { return }
    $rows = @(Get-UninstallCandidate)
    if (-not $rows.Count) { return }
    $lines = @($rows | Select-Object -First 12 | ForEach-Object {
        $versions = @($_.Installed) + @(([string]$_.OtherVersions -split ',\s*') | Where-Object { $_ })
        "  $($_.Module) $($versions -join ', ') ($($_.Scope))"
    })
    if ($rows.Count -gt 12) { $lines += "  ...and $($rows.Count - 12) more" }

    $notes = @()
    $required = @($rows | Where-Object Role -eq 'Required' | ForEach-Object Module)
    if ($required.Count) { $notes += "$($required -join ' and ') $(if ($required.Count -gt 1) { 'are' } else { 'is' }) required by the toolkit: modules that need it stop working until you install it again." }
    $names = @($rows | ForEach-Object Module)
    foreach ($bundle in 'Microsoft.Graph', 'Microsoft.Graph.Beta') {
        if ($names -notcontains $bundle) { continue }
        $subs = @($State.Inventory | Where-Object { $_.Installed -and $_.Module -like "$bundle.*" -and $names -notcontains $_.Module -and
            -not ($bundle -eq 'Microsoft.Graph' -and $_.Module -like 'Microsoft.Graph.Beta*') -and $_.Module -ne 'Microsoft.Graph.Authentication' })
        if ($subs.Count) { $notes += "Removing the $bundle bundle leaves its $($subs.Count) sub-module(s) installed. Tick 'Show Graph sub-modules' to select them too." }
    }
    if (-not $State.Elevated -and @($rows | Where-Object Scope -eq 'AllUsers').Count) { $notes += 'Modules installed for all users can only be removed when the toolkit runs as administrator.' }
    $notes += "Modules the toolkit has loaded (for example after Connect Graph) are skipped. To remove those, restart the toolkit and uninstall before connecting."

    $text = "Uninstall every installed version of these PowerShell modules?`n`n$($lines -join "`n")`n`n$($notes -join "`n`n")"
    if ([System.Windows.MessageBox]::Show($text, 'Uninstall modules', 'YesNo', 'Warning', 'No') -ne 'Yes') { return }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $job = Start-TkJob -Runspace $runspace -Name 'Uninstall modules' -Parameters @{
        CorePath = Join-Path $PSScriptRoot 'Core\Toolkit.Core.psm1'
        Name     = [string[]]$names
    } -ScriptBlock {
        param($CorePath, $Name)
        Import-Module $CorePath
        Uninstall-TkInstalledModule -Name $Name
    }
    $job | Add-Member -NotePropertyMembers @{ Runspace = $runspace; Kind = 'Uninstall' }
    $State.InventoryJob = $job
    Write-UiLog 'INFO' "Uninstalling $($names.Count) PowerShell module(s): $($names -join ', ')"
    $ui.InventorySummary.Text = "Uninstalling $($names.Count) module(s) - progress is on the Log tab..."
    Update-Buttons
    Update-InventoryButtons
    $inventoryTimer.Start()
}

function Complete-ModuleUninstall {
    $job = $State.InventoryJob
    $received = Receive-TkJob -Job $job
    $done = Complete-TkJob -Job $job
    $job.Runspace.Dispose()
    $State.InventoryJob = $null
    Update-Buttons
    foreach ($entry in $received.Log) { Write-UiLog $entry.Level $entry.Message }

    $rows = $job.Collected.ToArray()
    $removed = @($rows | Where-Object Status -eq 'Removed')
    $notDone = @($rows | Where-Object Status -in 'Failed', 'Skipped')
    $summary = if ($done.Failure) { "Module uninstall failed: $($done.Failure)" }
        else { "Module uninstall: $($removed.Count) version(s) removed, $($notDone.Count) not removed." }
    Write-UiLog $(if ($done.Failure -or $notDone.Count) { 'WARN' } else { 'INFO' }) $summary
    $ui.StatusText.Text = $summary
    $message = $summary
    if ($notDone.Count) { $message += "`n`nNot removed:`n$(@($notDone | ForEach-Object { "  $($_.Module) $($_.Version): $($_.Message)" }) -join "`n")" }
    if ($removed.Count) { $message += "`n`nThis session keeps any version it already loaded until the toolkit restarts." }
    $icon = if ($done.Failure -or $notDone.Count) { 'Warning' } else { 'Information' }
    [void][System.Windows.MessageBox]::Show($message, 'Uninstall modules', 'OK', $icon)
    Start-InventoryScan -CheckGallery:$State.InventoryChecked
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
        Write-UiLog 'WARN' "Required PowerShell module '$($row.Module)' is not installed - see Settings > Installed PowerShell modules."
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
    # Shown on the Settings tab, so it's visible from the Modules page.
    $ui.SettingsTabHeader.Text = if ($visibleIssues) { "Settings ($visibleIssues to fix)" } else { 'Settings' }
    [System.Windows.Automation.AutomationProperties]::SetName($ui.SettingsTab, $ui.SettingsTabHeader.Text)
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
        # An update or uninstall takes minutes: show its progress as it happens.
        if ($job.Kind -ne 'Scan') { foreach ($entry in (Receive-TkJob -Job $job).Log) { Write-UiLog $entry.Level $entry.Message } }
        return
    }
    $inventoryTimer.Stop()
    try {
        switch ($job.Kind) {
            'Update' { Complete-ModuleUpdate }
            'Uninstall' { Complete-ModuleUninstall }
            default { Complete-InventoryScan }
        }
    }
    catch {
        $State.InventoryJob = $null
        Update-Buttons
        Update-InventoryButtons
        Write-UiLog 'ERROR' "Toolkit error while handling installed modules: $($_.Exception.Message)"
    }
})

# Session check: the worker ends a stale sign-in (midnight, idle, sleep...) before every use anyway;
# this makes it happen - and the header show it - while the toolkit just sits open.
$sessionTimer = New-Object System.Windows.Threading.DispatcherTimer
$sessionTimer.Interval = [TimeSpan]::FromSeconds(60)
$sessionTimer.Add_Tick({ if (-not $State.Job -and $State.Worker) { Update-ConnectionStatus } })

$ui.RescanModulesButton.Add_Click({ Start-InventoryScan -CheckGallery:$State.InventoryChecked })
$ui.CheckUpdatesButton.Add_Click({ Start-InventoryScan -CheckGallery })
$ui.UpdateModulesButton.Add_Click({ Start-ModuleUpdate })
$ui.UninstallModulesButton.Add_Click({ Start-ModuleUninstall })
$ui.ModuleFoldersButton.Add_Click({ Show-ModuleFolders })
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

$ui.GroupByBox.SelectedIndex = [math]::Max(0, [array]::IndexOf(@('Category', 'Tag', 'Name', 'Runtime'), $State.GroupBy))
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
    $dryRun = [bool]$ui.WhatIfCheck.IsChecked -and $ui.WhatIfCheck.Visibility -eq 'Visible'
    $runtime = $null
    if ($module.External) {
        # Another language runs as its own process: the guard can't see it, so it is always Off and always confirmed.
        $runtime = Get-TkRuntimeStatus -Name $module.Runtime -Settings $settings
        if (-not $runtime.Available) {
            [void][System.Windows.MessageBox]::Show("No interpreter for $($module.Runtime) was found on this PC: $($runtime.Reason)", 'Cannot run', 'OK', 'Warning')
            return
        }
        $guard = 'Off'
        $what = if ($dryRun) { "with its own dry-run switch ($($module.DryRunArgument)). The toolkit can't check that the script honours it." }
        else { 'for real.' }
        $answer = [System.Windows.MessageBox]::Show(
            "'$($module.Name)' is a $($module.Runtime) script and runs through $($runtime.Label) $what`n`nUNGUARDED: it runs with your rights and can change anything you can - files, settings, other systems. The dry-run guard only sees PowerShell.`n`nTip: read it with 'View script' first.`n`nContinue?",
            'Confirm unguarded run', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }
    else {
        # Only scripts that declare SupportsShouldProcess accept -WhatIf; the guard covers all of them.
        if ($module.SupportsWhatIf) { $parameters['WhatIf'] = $dryRun }
        $guard = if ($dryRun) { 'DryRun' } elseif ($module.ReadOnly) { 'ReadOnly' } else { 'Off' }
        if ($guard -eq 'Off') {
            $answer = [System.Windows.MessageBox]::Show(
                "'$($module.Name)' will run for real and can make changes in your tenant.`n`nTip: read it with 'View script' or do a dry run first.`n`nContinue?",
                'Confirm changes', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { return }
        }
    }

    $ui.ResultGrid.ItemsSource = $null
    $ui.ExportButton.IsEnabled = $false
    $ui.OpenExcelButton.IsEnabled = $false
    $ui.ResultCount.Text = 'Running...'
    # Never show an old figure next to a run in progress.
    $State.ReadinessByModule.Remove($module.Id)
    Show-Readiness
    Show-Blocked -Entries @() -Guard $guard -External $module.External -DryRun $dryRun
    $modeText = if ($module.External) {
        if ($dryRun) { "UNGUARDED $($module.Runtime) script, its own dry run ($($module.DryRunArgument))" } else { "UNGUARDED $($module.Runtime) script - REAL RUN" }
    }
    else { switch ($guard) { 'DryRun' { 'DRY RUN - Microsoft 365 changes are blocked' } 'ReadOnly' { 'read-only run - changes are blocked' } default { 'REAL RUN - changes will be made' } } }
    Write-UiLog 'INFO' "Mode: $modeText"
    # Log which inputs were supplied, never their values - they may identify people.
    $suppliedNames = if ($parameters.Count) { ($parameters.Keys | Sort-Object) -join ', ' } else { 'none' }
    $logMode = if ($module.External) { "unguarded-$($module.Runtime)$(if ($dryRun) { '-dryrun' })" } else { $guard }
    Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message "Run $($module.Id) v$($module.Version) mode=$logMode with inputs: $suppliedNames"

    $jobName = if ($dryRun) { "$($module.Name) (dry run)" } else { $module.Name }
    Start-UiJob -Name $jobName -Cancellable -Data @{ Guard = $guard; Native = $module.SupportsWhatIf; ModuleName = $module.Name; ModuleId = $module.Id; Readiness = $module.Readiness; External = $module.External; DryRun = $dryRun } -Parameters @{
        EntryPath      = $module.EntryPath
        Requires       = $module.Requires
        Parameters     = $parameters
        Guard          = $guard
        Runtime        = $runtime
        DryRunArgument = $module.DryRunArgument
        DryRun         = $dryRun
    } -ScriptBlock {
        param($EntryPath, $Requires, $Parameters, $Guard, $Runtime, $DryRunArgument, $DryRun)
        Invoke-TkModule -EntryPath $EntryPath -Requires $Requires -Parameters $Parameters -Guard $Guard -Runtime $Runtime -DryRunArgument $DryRunArgument -DryRun $DryRun
    } -OnComplete {
        param($Done, $Output, $Blocked, $Job)
        Show-Results -Objects $Output -From $Job.Data.ModuleName
        # A failed or cancelled run may have counted only part of the tenant: show no score rather than a wrong one.
        $complete = $Done.State -eq 'Completed' -and -not $Done.Failure
        $readiness = if ($complete) { Get-TkReadiness -Report $Job.Readiness -Threshold $Job.Data.Readiness }
        if ($readiness) {
            $readiness | Add-Member -NotePropertyName Finished -NotePropertyValue (Get-Date)
            $State.ReadinessByModule[$Job.Data.ModuleId] = $readiness
            Write-UiLog 'INFO' "Readiness: $($readiness.Percent)% ($($readiness.Rating))"
        }
        else { $State.ReadinessByModule.Remove($Job.Data.ModuleId) }
        # Only redraw if the module that ran is still the one on screen.
        if ($State.Current -and $State.Current.Id -eq $Job.Data.ModuleId) { Show-Readiness }
        Show-Blocked -Entries $Blocked -Guard $Job.Data.Guard -Native $Job.Data.Native -ModuleName $Job.Data.ModuleName -External $Job.Data.External -DryRun $Job.Data.DryRun
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

$ui.OpenExcelButton.Add_Click({
    if (-not $State.Results.Count) { return }
    $ui.StatusText.Text = 'Opening the results in Excel...'
    $ui.Window.Cursor = [System.Windows.Input.Cursors]::Wait
    try {
        Open-TkExcelTable -Rows $State.Results -SheetName $State.ResultsFrom
        Write-UiLog 'INFO' "Opened $($State.Results.Count) row(s) in Excel (unsaved workbook)."
        $ui.StatusText.Text = 'Opened in Excel. The workbook is not saved until you save it.'
    }
    catch {
        $ui.StatusText.Text = 'Could not open Excel.'
        [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Open in Excel', 'OK', 'Warning')
    }
    finally { $ui.Window.ClearValue([System.Windows.FrameworkElement]::CursorProperty) }
})

# Settings > Sign-in sessions starts with the limits in effect (settings.json, or the defaults).
$startLimit = Get-TkSessionLimit -Settings $settings
$ui.MaxAgeHoursBox.Text = [string]$startLimit.MaxAgeHours
$ui.IdleMinutesBox.Text = [string]$startLimit.IdleMinutes

function Save-SessionLimit {
    $check = Test-TkSessionLimit -MaxAgeHours $ui.MaxAgeHoursBox.Text -IdleMinutes $ui.IdleMinutesBox.Text
    if ($check.Problems.Count) {
        [void][System.Windows.MessageBox]::Show(($check.Problems -join "`n"), 'Sign-in sessions', 'OK', 'Warning')
        return
    }
    try { Save-TkSessionLimit -Path $settingsPath -MaxAgeHours $check.MaxAgeHours -IdleMinutes $check.IdleMinutes }
    catch {
        [void][System.Windows.MessageBox]::Show("Could not save: $($_.Exception.Message)", 'Sign-in sessions', 'OK', 'Error')
        return
    }
    Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message "Session limits set: $($check.MaxAgeHours) h after sign-in, $($check.IdleMinutes) min idle."
    # Apply now: shorter limits may end the current session straight away (the status check does that).
    Start-UiJob -Name 'Apply session limits' -Quiet -Parameters @{ H = $check.MaxAgeHours; M = $check.IdleMinutes } -ScriptBlock {
        param($H, $M) Set-TkSessionLimit -MaxAgeHours $H -IdleMinutes $M
    } -OnComplete { Update-ConnectionStatus }
    $ui.MaxAgeHoursBox.Text = [string]$check.MaxAgeHours
    $ui.IdleMinutesBox.Text = [string]$check.IdleMinutes
    $ui.StatusText.Text = "Session limits saved: $($check.MaxAgeHours) hour(s) after sign-in, $($check.IdleMinutes) minute(s) without use."
}
$ui.SaveSessionButton.Add_Click({ Save-SessionLimit })
foreach ($box in $ui.MaxAgeHoursBox, $ui.IdleMinutesBox) {
    $box.Add_KeyDown({ if ($_.Key -eq 'Return') { Save-SessionLimit; $_.Handled = $true } })
}

$ui.ExportLogButton.Add_Click({
    $text = $ui.LogBox.Text
    if (-not $text.Trim()) { Write-UiLog 'INFO' 'The log is empty - nothing to export.'; return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = 'AdminToolkit-log_{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)
    if (-not $dialog.ShowDialog($ui.Window)) { return }
    try {
        $header = 'Admin Toolkit {0} - log exported {1:yyyy-MM-dd HH:mm:ss}' -f $toolkitVersion, (Get-Date)
        # The on-screen log, as shown (it can name users or mailboxes, unlike the file in Logs\).
        [System.IO.File]::WriteAllText($dialog.FileName, $header + [Environment]::NewLine + [Environment]::NewLine + $text, [System.Text.UTF8Encoding]::new($true))
        Write-UiLog 'INFO' "Exported the log to $($dialog.FileName)"
    }
    catch {
        [void][System.Windows.MessageBox]::Show("Could not export the log: $($_.Exception.Message)", 'Export log', 'OK', 'Error')
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
# Readiness view: set before hooking up, like the theme box. Checked/Unchecked so keyboard and UI Automation work.
$ui.ReadinessViewButton.IsChecked = $State.ReadinessView -eq 'Rating'
$ui.ReadinessViewButton.Add_Checked({ $State.ReadinessView = 'Rating'; Save-Preferences; Show-Readiness })
$ui.ReadinessViewButton.Add_Unchecked({ $State.ReadinessView = 'Percent'; Save-Preferences; Show-Readiness })
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
    $sessionTimer.Stop()
    if ($State.Job) { Stop-TkJob -Job $State.Job }
    if ($State.InventoryJob) { Stop-TkJob -Job $State.InventoryJob }
    Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message 'Toolkit closed.'
})

#endregion

Write-TkLogFile -Path $State.LogFile -Level 'INFO' -Message "Toolkit started (PowerShell $($PSVersionTable.PSVersion))."
Import-Modules
$State.Worker = New-TkWorker -HelperScript (Join-Path $PSScriptRoot 'Core\Toolkit.Worker.ps1') -Settings $settings
$timer.Start()
$sessionTimer.Start()

[void]$ui.Window.ShowDialog()

if ($State.Worker) {
    # Sign out with the window: Graph and Exchange keep connections process-wide, so a relaunch from this
    # PowerShell window would otherwise inherit them. (The next worker also clears any it finds.)
    if ($State.Job) { [void]$State.Job.Handle.AsyncWaitHandle.WaitOne(5000) }    # let a cancelled run stop
    if (-not (Invoke-TkWorkerCommand -Runspace $State.Worker -Script 'Disconnect-TkAll' -TimeoutSeconds 15)) {
        Write-TkLogFile -Path $State.LogFile -Level 'WARN' -Message 'Could not confirm sign-out on close; the next launch ends any leftover session.'
    }
    $State.Worker.Dispose()
}
