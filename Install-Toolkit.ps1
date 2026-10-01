#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the M365 Admin Toolkit for the current user, with Start menu (and desktop) shortcuts.

.DESCRIPTION
    Copies the toolkit to %LOCALAPPDATA%\Programs\M365AdminToolkit (no admin rights needed),
    unblocks the files, creates shortcuts that open the GUI and adds an uninstall entry under
    Settings > Apps. Run it again from a newer copy to upgrade in place:
      - Core, Tools and the launchers are replaced.
      - Modules: new modules are added. A module file is only overwritten when the copy being
        installed is newer, so modules you create or edit in the installed copy are kept.
      - Config\settings.json and Logs are never touched.

.PARAMETER Destination
    Install folder. Defaults to %LOCALAPPDATA%\Programs\M365AdminToolkit.

.PARAMETER DesktopShortcut
    Also put a shortcut on the desktop (the Start menu shortcut is always created).

.PARAMETER Portable
    Only copy the files: no shortcuts and no uninstall entry.

.PARAMETER Uninstall
    Removes the shortcuts, the uninstall entry and the program files. Your modules,
    Config\settings.json and Logs stay unless you add -RemoveUserData.

.PARAMETER RemoveUserData
    With -Uninstall: delete the whole install folder, including your modules and logs.

.PARAMETER ShowSummary
    Show the result in a message box (used by Install-Toolkit.cmd and Settings > Apps).

.EXAMPLE
    .\Install-Toolkit.ps1 -DesktopShortcut

.EXAMPLE
    .\Install-Toolkit.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [string] $Destination,
    [Parameter(ParameterSetName = 'Install')] [switch] $DesktopShortcut,
    [Parameter(ParameterSetName = 'Install')] [switch] $Portable,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $RemoveUserData,
    [switch] $ShowSummary
)

$ErrorActionPreference = 'Stop'
$appName = 'M365 Admin Toolkit'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\M365AdminToolkit'
# The toolkit targets Windows PowerShell 5.1, even if this installer runs under PowerShell 7.
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# What belongs to the program: replaced on upgrade, removed on uninstall. Everything else is user data.
$programItems = 'Core', 'Tools', 'Start-Toolkit.ps1', 'Start-Toolkit.cmd', 'Install-Toolkit.ps1', 'Install-Toolkit.cmd',
    'README.md', 'Config\settings.example.json'
if (-not $Destination) { $Destination = Join-Path $env:LOCALAPPDATA 'Programs\M365AdminToolkit' }
$Destination = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Destination).TrimEnd('\')
$shortcuts = @{
    StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk"
    Desktop   = Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"
}

function Get-LaunchArgument([string] $Folder) {
    # Same switches as Start-Toolkit.cmd: WPF needs STA, RemoteSigned applies to this process only.
    "-NoProfile -STA -ExecutionPolicy RemoteSigned -WindowStyle Minimized -File `"$Folder\Start-Toolkit.ps1`""
}

function New-ToolkitShortcut([string] $Path, [string] $Folder) {
    $shell = New-Object -ComObject WScript.Shell
    try {
        $link = $shell.CreateShortcut($Path)
        $link.TargetPath = $powershell
        $link.Arguments = Get-LaunchArgument $Folder
        $link.WorkingDirectory = $Folder
        $link.Description = 'Run Microsoft 365 admin modules from one window'
        $link.IconLocation = "$powershell,0"
        $link.WindowStyle = 7    # minimized: only the GUI shows, not the console behind it
        $link.Save()
    }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Test-ToolkitShortcut([string] $Path, [string] $Folder) {
    <# Whether a shortcut opens the toolkit in this folder, so uninstalling one copy leaves another alone. #>
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $shell = New-Object -ComObject WScript.Shell
    try { $shell.CreateShortcut($Path).Arguments -like "*`"$Folder\Start-Toolkit.ps1`"*" }
    finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
}

function Copy-NewerFile([string] $Source, [string] $Target) {
    <# Copies files that are missing or older at the target. Returns the ones kept because the target was newer. #>
    if (-not (Test-Path -LiteralPath $Source)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File) {
        $relative = $file.FullName.Substring($Source.Length).TrimStart('\')
        $to = Join-Path $Target $relative
        $existing = Get-Item -LiteralPath $to -ErrorAction SilentlyContinue
        if ($existing -and $existing.LastWriteTimeUtc -gt $file.LastWriteTimeUtc) { $relative; continue }
        $dir = Split-Path $to -Parent
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $file.FullName -Destination $to -Force    # keeps the timestamp
    }
}

function Assert-NotWorkingCopy([string] $Folder) {
    if (Test-Path -LiteralPath (Join-Path $Folder '.git')) {
        throw "$Folder is a git working copy, not an install folder. Choose another -Destination."
    }
}

function Install-Toolkit {
    $source = $PSScriptRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $source 'Core\Toolkit.Core.psm1'))) { throw "No toolkit files found next to the installer in $source." }
    if ($Destination -eq $source) { throw "This copy already runs from $Destination. Run the installer from the downloaded or cloned folder instead." }
    if ($Destination.StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase)) { throw 'The install folder cannot be inside the folder you install from.' }
    Assert-NotWorkingCopy $Destination
    if ((New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrator')) {
        Write-Warning 'Running as administrator: the toolkit is installed for the account running this window. Run it without elevation to install it for yourself.'
    }

    $upgrade = Test-Path -LiteralPath (Join-Path $Destination 'Start-Toolkit.ps1')
    Write-Host "$(if ($upgrade) { 'Upgrading' } else { 'Installing' }) $appName in $Destination ..."
    if (-not (Test-Path -LiteralPath $Destination)) { [void](New-Item -ItemType Directory -Path $Destination -Force) }

    foreach ($item in $programItems) {
        $from = Join-Path $source $item
        if (-not (Test-Path -LiteralPath $from)) { continue }
        $to = Join-Path $Destination $item
        if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }    # no stale files from older versions
        $parent = Split-Path $to -Parent
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        Copy-Item -LiteralPath $from -Destination $to -Recurse -Force
    }
    $kept = @(Copy-NewerFile (Join-Path $source 'Modules') (Join-Path $Destination 'Modules'))
    foreach ($k in $kept) { Write-Host "  Kept Modules\$k (the installed copy is newer)" }
    $settings = Join-Path $Destination 'Config\settings.json'
    if ((Test-Path -LiteralPath (Join-Path $source 'Config\settings.json')) -and -not (Test-Path -LiteralPath $settings)) {
        Copy-Item -LiteralPath (Join-Path $source 'Config\settings.json') -Destination $settings
    }
    # Files from a downloaded ZIP carry the internet mark, which RemoteSigned refuses to run.
    Get-ChildItem -LiteralPath $Destination -Recurse -File | Unblock-File

    $created = @()
    if (-not $Portable) {
        $created += $shortcuts.StartMenu
        if ($DesktopShortcut) { $created += $shortcuts.Desktop }
        foreach ($path in $created) { New-ToolkitShortcut -Path $path -Folder $Destination }

        $previous = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
        if ($previous -and $previous -ne $Destination) { Write-Warning "Another copy in $previous was registered; Settings > Apps now points to this one." }
        if (-not (Test-Path $uninstallKey)) { [void](New-Item -Path $uninstallKey -Force) }
        $sizeKb = [int]((Get-ChildItem -LiteralPath $Destination -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
        $values = [ordered]@{
            DisplayName     = $appName
            InstallLocation = $Destination
            InstallDate     = Get-Date -Format 'yyyyMMdd'
            DisplayIcon     = "$powershell,0"
            UninstallString = "`"$powershell`" -NoProfile -ExecutionPolicy RemoteSigned -File `"$Destination\Install-Toolkit.ps1`" -Uninstall -Destination `"$Destination`" -ShowSummary"
        }
        foreach ($name in $values.Keys) { [void](New-ItemProperty -Path $uninstallKey -Name $name -Value $values[$name] -PropertyType String -Force) }
        foreach ($name in 'NoModify', 'NoRepair') { [void](New-ItemProperty -Path $uninstallKey -Name $name -Value 1 -PropertyType DWord -Force) }
        [void](New-ItemProperty -Path $uninstallKey -Name EstimatedSize -Value $sizeKb -PropertyType DWord -Force)
    }

    Write-Host "Done. $(if ($Portable) { "Start it with $Destination\Start-Toolkit.cmd" } else { "Start '$appName' from the Start menu." })"
    [pscustomobject]@{ Action = if ($upgrade) { 'Upgraded' } else { 'Installed' }; Destination = $Destination; Shortcuts = $created; KeptModuleFiles = $kept }
}

function Uninstall-Toolkit {
    Assert-NotWorkingCopy $Destination
    $registered = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Start-Toolkit.ps1')) -and $registered -ne $Destination) {
        throw "No $appName installation found in $Destination."
    }
    Write-Host "Uninstalling $appName from $Destination ..."
    # Can't delete a folder this window is standing in.
    if ((Get-Location).ProviderPath -like "$Destination*") { Set-Location -LiteralPath $env:TEMP }

    $removed = @($shortcuts.Values | Where-Object { Test-ToolkitShortcut -Path $_ -Folder $Destination })
    foreach ($path in $removed) { Remove-Item -LiteralPath $path -Force }
    if ($registered -eq $Destination) { Remove-Item -Path $uninstallKey -Recurse -Force }

    $keptData = $false
    if (Test-Path -LiteralPath $Destination) {
        if ($RemoveUserData) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        else {
            foreach ($item in $programItems) {
                $path = Join-Path $Destination $item
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
            }
            foreach ($dir in (Join-Path $Destination 'Config'), $Destination) {
                if ((Test-Path -LiteralPath $dir) -and -not @(Get-ChildItem -LiteralPath $dir -Force).Count) { Remove-Item -LiteralPath $dir -Force }
            }
            $keptData = Test-Path -LiteralPath $Destination
        }
    }
    Write-Host "Done.$(if ($keptData) { " Your modules, settings and logs are still in $Destination - delete the folder if you no longer need them." })"
    [pscustomobject]@{ Action = 'Uninstalled'; Destination = $Destination; Shortcuts = $removed; KeptUserData = $keptData }
}

try {
    $summary = if ($Uninstall) { Uninstall-Toolkit } else { Install-Toolkit }
}
catch {
    if ($ShowSummary) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("Setup failed: $($_.Exception.Message)", $appName, 'OK', 'Error')
    }
    throw
}

if ($ShowSummary) {
    Add-Type -AssemblyName PresentationFramework
    if ($Uninstall) {
        $text = "$appName was uninstalled."
        if ($summary.KeptUserData) { $text += "`n`nYour modules, settings and logs are still in:`n$Destination" }
        [void][System.Windows.MessageBox]::Show($text, $appName, 'OK', 'Information')
    }
    else {
        $text = "$appName was $($summary.Action.ToLower()) in:`n$Destination"
        if (-not $Portable) { $text += "`n`nOpen it from the Start menu$(if ($DesktopShortcut) { ' or the desktop shortcut' })." }
        if ($summary.KeptModuleFiles.Count) { $text += "`n`n$($summary.KeptModuleFiles.Count) module file(s) were kept because the installed copy is newer." }
        $text += "`n`nStart it now?"
        if ([System.Windows.MessageBox]::Show($text, $appName, 'YesNo', 'Information') -eq 'Yes') {
            Start-Process -FilePath $powershell -ArgumentList (Get-LaunchArgument $Destination) -WorkingDirectory $Destination
        }
    }
}
$summary
