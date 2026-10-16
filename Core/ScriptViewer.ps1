<#
    ScriptViewer - read-only, syntax-coloured view of a module's script (and module.json).
    Dot-sourced by Start-Toolkit.ps1. Tokenising is done by ConvertTo-TkCodeLine in Toolkit.Core;
    nothing here ever executes the script.

    Event handlers look up their viewer via the window's Tag, so they work both for the
    non-modal viewer owned by the main window and the modal one opened from Add module.
#>

# Colours are theme resources (Tk.Code.<kind> in Core\Themes), so the code recolours with the theme.
function Add-TkCodeLines {
    <# Fills a ListBox with one row per line: line number + coloured code. Row.Tag = plain text. #>
    param([System.Windows.Controls.ListBox] $List, [object[]] $Lines)
    $List.Items.Clear()
    $width = [Math]::Max(3, ([string]$Lines.Count).Length) * 8 + 10
    foreach ($line in $Lines) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Tag = $line.Text
        $number = New-Object System.Windows.Controls.TextBlock
        $number.Text = [string]$line.Number
        $number.Width = $width
        $number.TextAlignment = 'Right'
        $number.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Tk.Code.LineNumber')
        $number.Margin = New-Object System.Windows.Thickness 0, 0, 14, 0
        [void]$row.Children.Add($number)

        $code = New-Object System.Windows.Controls.TextBlock
        foreach ($part in $line.Parts) {
            $kind = $part[0]
            $run = New-Object System.Windows.Documents.Run $part[1]
            if ($kind) {
                $run.SetResourceReference([System.Windows.Documents.TextElement]::ForegroundProperty, "Tk.Code.$kind")
                if ($kind -eq 'Keyword') { $run.FontWeight = [System.Windows.FontWeights]::SemiBold }
                if ($kind -eq 'Comment') { $run.FontStyle = [System.Windows.FontStyles]::Italic }
            }
            [void]$code.Inlines.Add($run)
        }
        [void]$row.Children.Add($code)
        [void]$List.Items.Add($row)
    }
}

function Get-TkViewerList {
    param($Viewer)
    if ($Viewer.Ui.ViewerTabs.SelectedItem -eq $Viewer.Ui.ManifestTab) { $Viewer.Ui.ManifestList } else { $Viewer.Ui.CodeList }
}

function Update-TkViewerFind {
    <# Highlights every line containing the search text and reports the count. #>
    param($Viewer)
    $needle = $Viewer.Ui.FindBox.Text
    $list = Get-TkViewerList $Viewer
    $hits = 0      # not $matches - that's an automatic variable
    foreach ($row in $list.Items) {
        $hit = $needle -and ([string]$row.Tag).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if ($hit) { $row.SetResourceReference([System.Windows.Controls.Panel]::BackgroundProperty, 'Tk.Code.Match'); $hits++ } else { $row.ClearValue([System.Windows.Controls.Panel]::BackgroundProperty) }
    }
    $Viewer.Ui.FindStatus.Text = if (-not $needle) { '' } elseif ($hits) { "$hits matching line(s)" } else { 'No matches' }
}

function Select-TkViewerMatch {
    param($Viewer, [switch] $Previous)
    $needle = $Viewer.Ui.FindBox.Text
    if (-not $needle) { return }
    $list = Get-TkViewerList $Viewer
    $count = $list.Items.Count
    if (-not $count) { return }
    $start = $list.SelectedIndex
    for ($step = 1; $step -le $count; $step++) {
        $index = if ($Previous) { ($start - $step + $count * 2) % $count } else { ($start + $step + $count) % $count }
        if (([string]$list.Items[$index].Tag).IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $list.SelectedIndex = $index
            $list.ScrollIntoView($list.Items[$index])
            return
        }
    }
}

function Copy-TkViewerLines {
    param($Viewer, [switch] $All)
    $list = Get-TkViewerList $Viewer
    $rows = if ($All -or $list.SelectedItems.Count -eq 0) { @($list.Items) }
            else { @($list.SelectedItems) | Sort-Object { $list.Items.IndexOf($_) } }
    $text = (@($rows | ForEach-Object { [string]$_.Tag })) -join [Environment]::NewLine
    if (-not $text) { return }
    # The clipboard can be held open by another program (clipboard managers, RDP): retry briefly.
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            [System.Windows.Clipboard]::SetDataObject($text, $true)
            $Viewer.Ui.FindStatus.Text = "Copied $(@($rows).Count) line(s)"
            return
        }
        catch { Start-Sleep -Milliseconds 50 }
    }
    $Viewer.Ui.FindStatus.Text = 'The clipboard is busy (another program is using it) - try again.'
}

function Set-TkScriptViewerContent {
    <# Loads (or reloads) a script and optional manifest into an open viewer. #>
    param(
        [Parameter(Mandatory)] $Viewer,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Title,
        [string] $ManifestPath
    )
    $Viewer.Path = $Path
    $Viewer.ManifestPath = $ManifestPath
    $ui = $Viewer.Ui
    $ui.Window.Title = "Script - $Title"
    $ui.ViewerTitle.Text = $Title
    try {
        $summary = Get-TkFileSummary -Path $Path
        $ui.ViewerPath.Text = $summary.Path
        $ui.ViewerMeta.Text = '{0} lines   |   {1} KB   |   last changed {2:yyyy-MM-dd HH:mm}' -f $summary.Lines, $summary.SizeKB, $summary.Modified
        $ui.ViewerHash.Text = "SHA-256  $($summary.Sha256)"
        # PowerShell highlighting only for PowerShell: other languages (bash, Python, cmd) are shown as plain text.
        $runtime = Get-TkRuntimeForFile $Path
        $language = if ($runtime) { (Get-TkRuntimeDefinition $runtime).Language } else { 'Plain' }
        Add-TkCodeLines -List $ui.CodeList -Lines @(ConvertTo-TkCodeLine -Text $summary.Text -Language $language)
    }
    catch {
        $ui.ViewerMeta.Text = "Could not read the script: $($_.Exception.Message)"
        $ui.ViewerHash.Text = ''
        $ui.CodeList.Items.Clear()
    }

    if ($ManifestPath -and (Test-Path -LiteralPath $ManifestPath)) {
        $ui.ManifestTab.Visibility = 'Visible'
        Add-TkCodeLines -List $ui.ManifestList -Lines @(ConvertTo-TkCodeLine -Text ([System.IO.File]::ReadAllText($ManifestPath)) -Language Plain)
    }
    else {
        $ui.ManifestTab.Visibility = 'Collapsed'
        $ui.ManifestList.Items.Clear()
        $ui.ViewerTabs.SelectedItem = $ui.ScriptTab
    }
    Update-TkViewerFind $Viewer
    if ($ui.CodeList.Items.Count) { $ui.CodeList.ScrollIntoView($ui.CodeList.Items[0]) }
}

function Open-TkScriptViewer {
    <#
    .SYNOPSIS
        Creates a viewer window for a script. Non-modal by default (returns the viewer);
        -Modal blocks until it is closed.
    #>
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [Parameter(Mandatory)] [string] $Path,
        [string] $Title = (Split-Path -Leaf $Path),
        [string] $ManifestPath,
        [switch] $Modal
    )

    $ui = Import-TkXaml -Path (Join-Path $PSScriptRoot 'ScriptViewerWindow.xaml')
    $viewer = @{ Ui = $ui; Path = $Path; ManifestPath = $ManifestPath }
    $ui.Window.Owner = $Owner
    $ui.Window.Tag = $viewer
    [System.Windows.Automation.AutomationProperties]::SetName($ui.CodeList, 'Script lines')

    $ui.FindBox.Add_TextChanged({ Update-TkViewerFind ([System.Windows.Window]::GetWindow($this).Tag) })
    $ui.FindBox.Add_KeyDown({
        if ($_.Key -eq 'Return') {
            $shift = [System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift
            Select-TkViewerMatch ([System.Windows.Window]::GetWindow($this).Tag) -Previous:([bool]$shift)
            $_.Handled = $true
        }
    })
    $ui.FindNextButton.Add_Click({ Select-TkViewerMatch ([System.Windows.Window]::GetWindow($this).Tag) })
    $ui.CopyAllButton.Add_Click({ Copy-TkViewerLines ([System.Windows.Window]::GetWindow($this).Tag) -All })
    $ui.RefreshViewerButton.Add_Click({
        $v = [System.Windows.Window]::GetWindow($this).Tag
        Set-TkScriptViewerContent -Viewer $v -Path $v.Path -Title $v.Ui.ViewerTitle.Text -ManifestPath $v.ManifestPath
    })
    $ui.OpenEditorButton.Add_Click({
        $v = [System.Windows.Window]::GetWindow($this).Tag
        $file = if ($v.Ui.ViewerTabs.SelectedItem -eq $v.Ui.ManifestTab) { $v.ManifestPath } else { $v.Path }
        Start-Process -FilePath notepad.exe -ArgumentList "`"$file`""
    })
    $ui.ViewerTabs.Add_SelectionChanged({
        if ($_.OriginalSource -eq $this) { Update-TkViewerFind ([System.Windows.Window]::GetWindow($this).Tag) }
    })

    # Ctrl+C copies the selected lines (whole lines, without line numbers).
    foreach ($list in $ui.CodeList, $ui.ManifestList) {
        $binding = New-Object System.Windows.Input.CommandBinding (
            [System.Windows.Input.ApplicationCommands]::Copy,
            [System.Windows.Input.ExecutedRoutedEventHandler] { Copy-TkViewerLines ([System.Windows.Window]::GetWindow($this).Tag) })
        [void]$list.CommandBindings.Add($binding)
    }

    Set-TkScriptViewerContent -Viewer $viewer -Path $Path -Title $Title -ManifestPath $ManifestPath
    if ($Modal) { [void]$ui.Window.ShowDialog(); return }
    $ui.Window.Show()
    $viewer
}
