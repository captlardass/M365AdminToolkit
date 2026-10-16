<#
    AddModuleDialog - the "Add module" window. Dot-sourced by Start-Toolkit.ps1.

    All real work (script analysis, manifest generation, validation) is in Toolkit.Core;
    this file only wires the form to it.
#>

function Show-TkAddModuleDialog {
    <#
    .SYNOPSIS
        Shows the Add module dialog. Returns the created module, or $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $ModulesPath,
        [object[]] $Modules = @()
    )

    $d = Import-TkXaml -Path (Join-Path $PSScriptRoot 'AddModuleWindow.xaml')
    $d.Window.Owner = $Owner

    # Mutable dialog state (handlers run in child scopes - see Start-Toolkit.ps1).
    $dlg = @{
        Analysis     = $null
        AnalysedPath = $null
        Created      = $null
        AutoName     = $true      # name/id follow the script and category until the user types their own
        AutoId       = $true
        Updating     = $false
    }
    $existingIds = @($Modules | ForEach-Object { $_.Id })

    foreach ($category in @($Modules | Where-Object IsValid | ForEach-Object { $_.Category } | Sort-Object -Unique)) {
        [void]$d.CategoryBox.Items.Add($category)
    }
    $d.CategoryBox.Text = 'Custom'
    foreach ($runtime in Get-TkRuntimeName) { [void]$d.RuntimeBox.Items.Add($runtime) }
    $d.RuntimeBox.SelectedIndex = 0

    function Set-RuntimeView([string] $Runtime) {
        <# Other languages can't use the toolkit's sign-in or be read-only: grey those out and say why. #>
        $external = $Runtime -and $Runtime -ne 'PowerShell'
        foreach ($control in $d.ExchangeCheck, $d.GraphScopesBox, $d.ReadOnlyCheck) { $control.IsEnabled = -not $external }
        if ($external) { $d.ExchangeCheck.IsChecked = $false; $d.ReadOnlyCheck.IsChecked = $false; $d.GraphScopesBox.Text = '' }
        $d.ConnectionsNote.Visibility = if ($external) { 'Visible' } else { 'Collapsed' }
    }
    $d.RuntimeBox.Add_SelectionChanged({ if (-not $d.ScriptPathBox.Text.Trim()) { Set-RuntimeView ([string]$d.RuntimeBox.SelectedItem) } })

    function Set-QuietText($Box, [string] $Text) {
        $dlg.Updating = $true
        $Box.Text = $Text
        $dlg.Updating = $false
    }

    function Update-SuggestedId {
        if ($dlg.AutoId) { Set-QuietText $d.IdBox (Get-TkSuggestedId -Category $d.CategoryBox.Text -Name $d.NameBox.Text) }
    }

    function Update-TagChips {
        $chosen = @(Split-TkList $d.TagsBox.Text)
        foreach ($chip in $d.ExistingTagsPanel.Children) { $chip.IsChecked = $chosen -contains $chip.Tag }
    }

    function Update-Analysis {
        $path = $d.ScriptPathBox.Text.Trim().Trim('"')
        if ($path -eq $dlg.AnalysedPath) { return }
        $dlg.AnalysedPath = $path
        $dlg.Analysis = $null
        $d.ParamGrid.ItemsSource = $null
        $d.ParamGrid.Visibility = 'Collapsed'
        $d.ViewSourceButton.IsEnabled = $false
        $d.WarningText.Text = ''
        $d.DialogStatus.Text = ''

        if (-not $path) {
            $d.RuntimeBox.IsEnabled = $true
            Set-RuntimeView ([string]$d.RuntimeBox.SelectedItem)
            $d.AnalysisSummary.Text = 'No script selected: the module will be created from the blank template for the language above, ready for you to edit.'
            return
        }
        $runtime = Get-TkRuntimeForFile $path
        if (-not $runtime -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $d.AnalysisSummary.Text = 'Choose an existing .ps1, .cmd, .bat, .sh, .zsh or .py file.'
            return
        }
        # The file type decides the language.
        $d.RuntimeBox.SelectedItem = $runtime
        $d.RuntimeBox.IsEnabled = $false
        Set-RuntimeView $runtime
        # Even a script with syntax errors can be read - let people look before they decide.
        $d.ViewSourceButton.IsEnabled = $true
        try { $analysis = Get-TkScriptAnalysis -Path $path }
        catch { $d.AnalysisSummary.Text = $_.Exception.Message; return }

        $dlg.Analysis = $analysis
        if ($analysis.Runtime -ne 'PowerShell') {
            $status = Get-TkRuntimeStatus -Name $analysis.Runtime -Settings $settings    # $settings: Start-Toolkit.ps1
            $dryRun = if ($analysis.DryRunArgument) { "dry run: the script's own $($analysis.DryRunArgument) switch" } else { 'no dry run (add a # tk-dryrun: line if the script has a dry-run switch)' }
            $runsWith = if ($status.Available) { "runs through $($status.Label)" } else { "no interpreter on this PC, so export only ($($status.Reason))" }
            $d.AnalysisSummary.Text = "$($analysis.Runtime) script, $runsWith. Found $($analysis.Parameters.Count) input(s) in tk-param lines; $dryRun. Unguarded: every run asks first."
        }
        else {
            $dryRun = if ($analysis.SupportsWhatIf) { 'dry run: native WhatIf (the script reports its changes)' } else { 'dry run: enforced by the toolkit (changes are blocked and listed)' }
            $d.AnalysisSummary.Text = "Found $($analysis.Parameters.Count) input(s); $dryRun."
            $d.ReadOnlyCheck.IsChecked = $analysis.LooksReadOnly
        }
        if ($analysis.Parameters.Count) {
            $rows = @($analysis.Parameters | ForEach-Object {
                [pscustomobject]@{
                    Input    = $_.Label
                    Control  = $_.Type
                    Required = $_.Required
                    Default  = $_.Default
                    Options  = $_.Options -join ', '
                    Parameter = $_.Name
                }
            })
            $d.ParamGrid.ItemsSource = (ConvertTo-TkDataTable -FlatObject @(ConvertTo-TkFlatObject $rows)).DefaultView
            $d.ParamGrid.Visibility = 'Visible'
        }
        if ($analysis.Warnings) { $d.WarningText.Text = (@($analysis.Warnings | ForEach-Object { "!  $_" }) -join "`n") }

        if ($dlg.AutoName -or -not $d.NameBox.Text) { Set-QuietText $d.NameBox $analysis.SuggestedName; $dlg.AutoName = $true }
        if (-not $d.DescriptionBox.Text -and $analysis.SuggestedDescription) { $d.DescriptionBox.Text = $analysis.SuggestedDescription }
        if ($analysis.Runtime -eq 'PowerShell') { $d.ExchangeCheck.IsChecked = $analysis.UsesExchange }
        if ($analysis.GraphScopes) { $d.GraphScopesBox.Text = $analysis.GraphScopes -join ', ' }
        Update-SuggestedId
    }

    # Existing tags as toggle chips, so people reuse tags instead of inventing near-duplicates.
    foreach ($tag in @($Modules | ForEach-Object { $_.Tags } | Sort-Object -Unique)) {
        $chip = New-Object System.Windows.Controls.Primitives.ToggleButton
        $chip.Style = $d.Window.FindResource('TagChip')
        $chip.Content = $tag
        $chip.Tag = $tag
        $chip.Add_Click({
            $chosen = @(Split-TkList $d.TagsBox.Text)
            $chosen = if ($chosen -contains $this.Tag) { @($chosen | Where-Object { $_ -ne $this.Tag }) } else { $chosen + $this.Tag }
            $d.TagsBox.Text = $chosen -join ', '
        })
        [void]$d.ExistingTagsPanel.Children.Add($chip)
    }
    if ($d.ExistingTagsPanel.Children.Count -eq 0) {
        $none = New-Object System.Windows.Controls.TextBlock
        $none.Text = '(no tags in use yet)'
        $none.Style = $d.Window.FindResource('Hint')
        [void]$d.ExistingTagsPanel.Children.Add($none)
    }

    $d.BrowseButton.Add_Click({
        $open = New-Object Microsoft.Win32.OpenFileDialog
        $open.Filter = 'Scripts (*.ps1;*.cmd;*.bat;*.sh;*.zsh;*.py)|*.ps1;*.cmd;*.bat;*.sh;*.zsh;*.py|PowerShell (*.ps1)|*.ps1|cmd (*.cmd;*.bat)|*.cmd;*.bat|bash / zsh (*.sh;*.zsh)|*.sh;*.zsh|Python (*.py)|*.py'
        $open.Title = 'Choose the script to turn into a module'
        if ($open.ShowDialog($d.Window)) {
            $d.ScriptPathBox.Text = $open.FileName
            Update-Analysis
        }
    })
    $d.ScriptPathBox.Add_LostFocus({ Update-Analysis })
    $d.ViewSourceButton.Add_Click({
        $path = $d.ScriptPathBox.Text.Trim().Trim('"')
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Open-TkScriptViewer -Owner $d.Window -Path $path -Title (Split-Path -Leaf $path) -Modal
        }
    })
    $d.TagsBox.Add_TextChanged({ Update-TagChips })
    $d.NameBox.Add_TextChanged({
        if (-not $dlg.Updating) { $dlg.AutoName = -not $d.NameBox.Text }
        Update-SuggestedId
    })
    $d.IdBox.Add_TextChanged({
        if (-not $dlg.Updating) { $dlg.AutoId = -not $d.IdBox.Text }
    })
    $d.CategoryBox.AddHandler(
        [System.Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent,
        [System.Windows.Controls.TextChangedEventHandler] { Update-SuggestedId })

    $d.CreateButton.Add_Click({
        Update-Analysis
        $id = $d.IdBox.Text.Trim()
        $name = $d.NameBox.Text.Trim()
        $category = $d.CategoryBox.Text.Trim()
        $path = $d.ScriptPathBox.Text.Trim().Trim('"')

        $problems = @()
        if (-not $name) { $problems += 'Enter a name.' }
        if (-not $category) { $problems += 'Enter a category.' }
        if ($id -notmatch '^[A-Za-z][A-Za-z0-9]*(\.[A-Za-z][A-Za-z0-9]*)+$') { $problems += "The Id must look like 'Area.TaskName'." }
        elseif ($existingIds -contains $id) { $problems += "The Id '$id' is already used by another module." }
        if ($path -and -not $dlg.Analysis) { $problems += 'The selected script could not be read - see the message above.' }
        # Without scopes the toolkit never connects to Graph, so every Graph call in the script would fail.
        if ($dlg.Analysis -and $dlg.Analysis.UsesGraph -and -not @(Split-TkList $d.GraphScopesBox.Text -Separator '[,\s]+').Count) {
            $problems += 'The script uses Microsoft Graph - enter the scopes it needs under Connections.'
        }
        if ($problems) { $d.DialogStatus.Text = $problems -join ' '; return }

        $request = @{
            ModulesPath    = $ModulesPath
            Id             = $id
            Name           = $name
            Category       = $category
            Description    = $d.DescriptionBox.Text.Trim()
            Tags           = [string[]]@(Split-TkList $d.TagsBox.Text)
            ExchangeOnline = [bool]$d.ExchangeCheck.IsChecked
            ReadOnly       = [bool]$d.ReadOnlyCheck.IsChecked
            GraphScopes    = [string[]]@(Split-TkList $d.GraphScopesBox.Text -Separator '[,\s]+')
        }
        if ($path) { $request.ScriptPath = $path }
        else { $request.Runtime = [string]$d.RuntimeBox.SelectedItem }
        try {
            $dlg.Created = New-TkModule @request
            $d.Window.DialogResult = $true
        }
        catch { $d.DialogStatus.Text = $_.Exception.Message }
    })

    Update-Analysis
    [void]$d.ScriptPathBox.Focus()
    [void]$d.Window.ShowDialog()
    $dlg.Created
}
