<#
    ExportDialog - the "Export scripts" window: modules to a folder or .tar.gz, e.g. on a USB stick, to run
    on another machine. Dot-sourced by Start-Toolkit.ps1. The work is in Toolkit.Core (Export-TkModule).
#>

function Show-TkExportDialog {
    <#
    .SYNOPSIS
        Shows the export dialog. -Selected modules start ticked; "All shown" ticks -Shown (the ones the
        module list currently shows). Returns the Export-TkModule result, or $null if cancelled.
    #>
    param(
        [Parameter(Mandatory)] [System.Windows.Window] $Owner,
        [object[]] $Modules = @(),
        [string[]] $Selected = @(),
        [string[]] $Shown = @()
    )

    $d = Import-TkXaml -Path (Join-Path $PSScriptRoot 'ExportWindow.xaml')
    $d.Window.Owner = $Owner
    $dlg = @{ Result = $null; Boxes = New-Object System.Collections.Generic.List[object] }

    function Update-ExportSummary {
        $chosen = @($dlg.Boxes | Where-Object IsChecked | ForEach-Object { $_.Tag })
        $byRuntime = @($chosen | Group-Object Runtime | Sort-Object Name | ForEach-Object { "$($_.Name) $($_.Count)" })
        $d.SelectionSummary.Text = if ($chosen.Count) { "$($chosen.Count) selected ($($byRuntime -join ', '))" } else { 'Tick the modules to export.' }
        $d.ExportButton.IsEnabled = [bool]$chosen.Count
    }

    foreach ($m in @($Modules | Where-Object IsValid | Sort-Object Category, Name)) {
        $box = New-Object System.Windows.Controls.CheckBox
        $box.Content = '{0}   ({1}, {2})' -f $m.Name, $m.Runtime, $m.Category
        $box.Tag = $m
        $box.Margin = '2,3,2,3'
        $box.IsChecked = $Selected -contains $m.Id
        $box.Add_Checked({ Update-ExportSummary })
        $box.Add_Unchecked({ Update-ExportSummary })
        [void]$d.ModuleList.Items.Add($box)
        $dlg.Boxes.Add($box)
    }
    $d.SelectAllButton.Add_Click({ foreach ($b in $dlg.Boxes) { if ($Shown -contains $b.Tag.Id) { $b.IsChecked = $true } } })
    $d.SelectNoneButton.Add_Click({ foreach ($b in $dlg.Boxes) { $b.IsChecked = $false } })

    # Scripts for Linux or macOS default to the archive, which keeps the executable bit.
    $unix = @($dlg.Boxes | Where-Object IsChecked | Where-Object { $_.Tag.Runtime -in 'Bash', 'Zsh', 'Python' }).Count
    $d.FormatBox.SelectedIndex = if ($unix) { 0 } else { 1 }

    $drives = @(Get-TkRemovableDrive)
    foreach ($drive in $drives) {
        $button = New-Object System.Windows.Controls.Button
        $button.Content = "$($drive.Label)$(if ($drive.FileSystem) { " - $($drive.FileSystem)" })"
        $button.Tag = $drive.Root
        $button.Margin = '0,0,6,0'
        $button.Add_Click({ $d.DestinationBox.Text = $this.Tag })
        [void]$d.DrivePanel.Children.Add($button)
    }
    if (-not $drives.Count) { $d.DrivesHint.Text = 'No USB drive found - plug one in, or pick any folder.' }
    $d.DestinationBox.Text = if ($drives.Count) { $drives[0].Root } else { [Environment]::GetFolderPath('Desktop') }

    $d.BrowseDestinationButton.Add_Click({
        Add-Type -AssemblyName System.Windows.Forms
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        try {
            $picker.Description = 'Choose where to export the scripts (e.g. a USB stick)'
            if ($d.DestinationBox.Text -and (Test-Path -LiteralPath $d.DestinationBox.Text)) { $picker.SelectedPath = $d.DestinationBox.Text }
            if ($picker.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $d.DestinationBox.Text = $picker.SelectedPath }
        }
        finally { $picker.Dispose() }
    })

    $d.ExportButton.Add_Click({
        $d.ExportStatus.Text = ''
        $chosen = @($dlg.Boxes | Where-Object IsChecked | ForEach-Object { $_.Tag })
        $destination = $d.DestinationBox.Text.Trim().Trim('"')
        if (-not $chosen.Count) { $d.ExportStatus.Text = 'Tick at least one module.'; return }
        if (-not $destination -or -not (Test-Path -LiteralPath $destination -PathType Container)) { $d.ExportStatus.Text = 'Choose an existing destination folder.'; return }
        try {
            $plan = Get-TkExportPlan -Module $chosen
            $allow = $false
            if ($plan.TenantData.Count) {
                # Fails closed: only exported when the admin has seen the lines and says yes.
                $shownLines = @($plan.TenantData | Select-Object -First 10)
                $more = if ($plan.TenantData.Count -gt 10) { "`n  ... and $($plan.TenantData.Count - 10) more" } else { '' }
                $answer = [System.Windows.MessageBox]::Show(
                    "These lines look like real addresses or tenant names. Anyone who gets the USB stick can read them:`n`n  $($shownLines -join "`n  ")$more`n`nExport anyway?",
                    'Possible tenant data', 'YesNo', 'Warning')
                if ($answer -ne 'Yes') { $d.ExportStatus.Text = 'Not exported. Replace the addresses with placeholders, or untick those modules.'; return }
                $allow = $true
            }
            $format = [string]$d.FormatBox.SelectedItem.Tag
            $dlg.Result = Export-TkModule -Module $chosen -Destination $destination -Format $format -AllowTenantData:$allow
        }
        catch { $d.ExportStatus.Text = $_.Exception.Message; return }

        $text = "Exported $($dlg.Result.Modules) module(s) to:`n$($dlg.Result.Path)"
        if ($dlg.Result.LeftOut.Count) { $text += "`n`nLeft out (result files): $($dlg.Result.LeftOut.Count)" }
        if ($dlg.Result.Warnings.Count) { $text += "`n`n" + (@($dlg.Result.Warnings | ForEach-Object { "! $_" }) -join "`n") }
        $text += "`n`nShow it in Explorer?"
        if ([System.Windows.MessageBox]::Show($text, 'Export done', 'YesNo', 'Information') -eq 'Yes') {
            Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList "/select,`"$($dlg.Result.Path)`""
        }
        $d.Window.DialogResult = $true
    })

    Update-ExportSummary
    [void]$d.Window.ShowDialog()
    $dlg.Result
}
