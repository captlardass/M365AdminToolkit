#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Admin Toolkit for the current user, with Start menu (and desktop) shortcuts.

.DESCRIPTION
    Copies the toolkit to %LOCALAPPDATA%\Programs\AdminToolkit (no admin rights needed),
    unblocks the files, creates shortcuts that open the GUI and adds an uninstall entry under
    Settings > Apps. Run it again from a newer copy to upgrade in place:
      - Core, Tools and the launchers are replaced.
      - Modules: new modules are added. A module file is only overwritten when the copy being
        installed is newer, so modules you create or edit in the installed copy are kept.
      - Config\settings.json and Logs are never touched.
    An install from before the rename (M365 Admin Toolkit) is found and moved: its settings, logs and
    modules are copied into the new folder, its program files, shortcuts and uninstall entry removed.

.PARAMETER Destination
    Install folder. Defaults to %LOCALAPPDATA%\Programs\AdminToolkit. With -ShowSummary and no
    -Destination, a folder picker opens.
    The folder must be private to you: system folders, network paths and folders that other users can
    write to are refused, because anyone who can change the files could run code as you. A new folder
    is created with access for you, SYSTEM and Administrators only.

.PARAMETER MigrateFrom
    An M365 Admin Toolkit install to move into this one. Without it, a normal install looks for one
    itself (its Settings > Apps entry, then %LOCALAPPDATA%\Programs\M365AdminToolkit); -Portable only
    migrates when this is given. Its Config\settings.json, Logs and Modules are copied (newer files win)
    and its program files removed, so only the new copy starts. The old folder keeps your data until
    you delete it.

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
    [Parameter(ParameterSetName = 'Install')] [string] $MigrateFrom,
    [Parameter(ParameterSetName = 'Install')] [switch] $DesktopShortcut,
    [Parameter(ParameterSetName = 'Install')] [switch] $Portable,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)] [switch] $Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')] [switch] $RemoveUserData,
    [switch] $ShowSummary
)

$ErrorActionPreference = 'Stop'
$appName = 'Admin Toolkit'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AdminToolkit'
# The names before the rename to Admin Toolkit: found and cleaned up on install and uninstall.
$legacy = @{
    Name = 'M365 Admin Toolkit'
    Key  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\M365AdminToolkit'
    Folder = Join-Path $env:LOCALAPPDATA 'Programs\M365AdminToolkit'
}
# The toolkit targets Windows PowerShell 5.1, even if this installer runs under PowerShell 7.
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# What belongs to the program: replaced on upgrade, removed on uninstall. Everything else is user data.
$programItems = 'Core', 'Tools', 'Start-Toolkit.ps1', 'Start-Toolkit.cmd', 'Install-Toolkit.ps1', 'Install-Toolkit.cmd',
    'Get-AdminToolkit.ps1', 'README.md', 'VERSION', 'EDITION', 'Config\settings.example.json',
    'Get-M365AdminToolkit.ps1'    # the bootstrap script's name before the rename: removed on upgrade
$defaultDestination = Join-Path $env:LOCALAPPDATA 'Programs\AdminToolkit'

function Select-ToolkitFolder([string] $Default) {
    <# Folder picker for interactive installs. Returns $null when cancelled. #>
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = "Choose where to install $appName. An AdminToolkit folder is created inside the folder you pick."
        $dialog.SelectedPath = Split-Path $Default -Parent
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        $picked = $dialog.SelectedPath
    }
    finally { $dialog.Dispose() }
    # Picking an existing install (or a folder already named for it) upgrades it in place.
    if ((Split-Path $picked -Leaf) -in 'AdminToolkit', 'M365AdminToolkit' -or (Test-Path -LiteralPath (Join-Path $picked 'Start-Toolkit.ps1'))) { $picked }
    else { Join-Path $picked 'AdminToolkit' }
}

if (-not $Destination -and -not $Uninstall -and $ShowSummary) {
    $Destination = Select-ToolkitFolder $defaultDestination
    if (-not $Destination) { Write-Host 'Setup cancelled.'; return }
}
if (-not $Destination) { $Destination = $defaultDestination }
$Destination = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($Destination).TrimEnd('\')
$shortcuts = @{
    StartMenu = Join-Path ([Environment]::GetFolderPath('Programs')) "$appName.lnk"
    Desktop   = Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"
}
$legacyShortcuts = @(
    Join-Path ([Environment]::GetFolderPath('Programs')) "$($legacy.Name).lnk"
    Join-Path ([Environment]::GetFolderPath('Desktop')) "$($legacy.Name).lnk"
)

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
        $link.Description = 'Run admin modules and scripts from one window'
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

function Find-LegacyToolkit([string] $Source) {
    <# The M365 Admin Toolkit install to move into this one: -MigrateFrom, else (not -Portable) the one
       registered in Settings > Apps, else the old default folder. $null when there is none. Never the
       folder the installer runs from: migrating removes the old program files. #>
    $candidates = if ($MigrateFrom) { , $PSCmdlet.GetUnresolvedProviderPathFromPSPath($MigrateFrom).TrimEnd('\') }
    elseif (-not $Portable) {
        (Get-ItemProperty -Path $legacy.Key -ErrorAction SilentlyContinue).InstallLocation
        $legacy.Folder
    }
    foreach ($folder in $candidates) {
        if (-not $folder -or $folder -eq $Source -or $Source.StartsWith("$folder\", [StringComparison]::OrdinalIgnoreCase)) { continue }
        if ((Test-Path -LiteralPath (Join-Path $folder 'Start-Toolkit.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $folder '.git'))) { return $folder }
    }
    if ($MigrateFrom) { throw "No M365 Admin Toolkit installation to move in $MigrateFrom (missing, a git working copy, or the folder setup runs from)." }
    $null
}

function Move-LegacyToolkit([string] $From) {
    <# Copies settings, logs and modules from an M365 Admin Toolkit install into $Destination, then removes
       its program files, shortcuts and uninstall entry so only the new copy starts. User data stays in $From. #>
    if ($From -ne $Destination) {
        Write-Host "Moving M365 Admin Toolkit from $From ..."
        $settings = Join-Path $From 'Config\settings.json'
        $target = Join-Path $Destination 'Config\settings.json'
        if ((Test-Path -LiteralPath $settings) -and -not (Test-Path -LiteralPath $target)) {
            [void](New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force)
            Copy-Item -LiteralPath $settings -Destination $target
        }
        foreach ($folder in 'Logs', 'Modules') { [void](Copy-NewerFile (Join-Path $From $folder) (Join-Path $Destination $folder)) }
        foreach ($item in $programItems) {
            $path = Join-Path $From $item
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
    }
    if (-not $Portable) {
        foreach ($path in $legacyShortcuts | Where-Object { Test-ToolkitShortcut -Path $_ -Folder $From }) { Remove-Item -LiteralPath $path -Force }
        if ((Get-ItemProperty -Path $legacy.Key -ErrorAction SilentlyContinue).InstallLocation -eq $From) { Remove-Item -Path $legacy.Key -Recurse -Force }
    }
}

# Accounts that may change the install folder: you, SYSTEM, Administrators, and the CREATOR OWNER /
# OWNER RIGHTS / TrustedInstaller placeholders. Anyone else with write access could plant code you run.
$trustedSids = @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544', 'S-1-3-0', 'S-1-3-4',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
)
# WriteData, AppendData, DeleteSubdirectoriesAndFiles, Delete, ChangePermissions, TakeOwnership, GENERIC_WRITE, GENERIC_ALL
$writeMask = 0x2 -bor 0x4 -bor 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x40000000 -bor 0x10000000
# On the folders above it, only what lets someone delete, rename or re-permission the install folder counts.
$replaceMask = 0x40 -bor 0x10000 -bor 0x40000 -bor 0x80000 -bor 0x10000000

function Get-OtherWriter([string] $Path, [long] $Mask, [switch] $IncludeInheritOnly) {
    <# Who besides the trusted accounts holds any of $Mask on $Path (or owns it). Unreadable = refuse. #>
    try { $acl = Get-Acl -LiteralPath $Path }
    catch { return "(could not read the permissions: $($_.Exception.Message))" }
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $trustedSids) { "owner $(Resolve-SidName $owner)" }
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne 'Allow' -or $rule.IdentityReference.Value -in $trustedSids) { continue }
        if (-not $IncludeInheritOnly -and ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
        if ([long]$rule.FileSystemRights -band $Mask) { "$(Resolve-SidName $rule.IdentityReference.Value) ($($rule.FileSystemRights))" }
    }
}

function Resolve-SidName([string] $Sid) {
    try { (New-Object Security.Principal.SecurityIdentifier $Sid).Translate([Security.Principal.NTAccount]).Value } catch { $Sid }
}

function Assert-SafeDestination([string] $Folder) {
    <# Refuses folders where the toolkit would be shared, system-owned or changeable by other users. Fails closed. #>
    if ($Folder.StartsWith('\\')) { throw "Network paths can't be used: $Folder. Choose a folder on this PC." }
    $root = [IO.Path]::GetPathRoot($Folder)
    if (-not $root -or $Folder.TrimEnd('\') -eq $root.TrimEnd('\')) { throw "Choose a folder, not the root of a drive: $Folder" }
    $drive = New-Object IO.DriveInfo $root
    if ($drive.DriveType -eq 'Network') { throw "$root is a network drive. Choose a folder on this PC." }
    $system = 'Windows', 'ProgramFiles', 'ProgramFilesX86', 'CommonApplicationData' |
        ForEach-Object { [Environment]::GetFolderPath($_) } | Where-Object { $_ }
    foreach ($dir in $system) {
        if ($Folder -eq $dir -or $Folder.StartsWith("$($dir.TrimEnd('\'))\", [StringComparison]::OrdinalIgnoreCase)) {
            throw "$dir is a machine-wide folder. The toolkit installs per user: choose a folder in your own profile, e.g. $defaultDestination."
        }
    }
    if ($drive.DriveType -eq 'Removable' -and $Portable) {
        Write-Warning "$root is a removable drive: anyone who gets hold of it can change the scripts. Only run a copy you trust."
        return
    }

    $problems = @()
    if (Test-Path -LiteralPath $Folder) {
        $problems += @(Get-OtherWriter -Path $Folder -Mask $writeMask -IncludeInheritOnly | ForEach-Object { "$Folder`: $_" })
    }
    $parent = Split-Path $Folder -Parent
    while ($parent) {
        if (Test-Path -LiteralPath $parent) { $problems += @(Get-OtherWriter -Path $parent -Mask $replaceMask | ForEach-Object { "$parent`: $_" }) }
        $parent = Split-Path $parent -Parent
    }
    if ($problems.Count) {
        throw ("Other accounts can change $Folder or a folder above it, so they could change the toolkit's scripts and run code as you:`n  " +
            ($problems -join "`n  ") + "`nChoose a folder only you can write to, e.g. $defaultDestination.")
    }
}

function New-PrivateFolder([string] $Folder) {
    <# Creates the install folder - and any missing folder above it - with access for you, SYSTEM and
       Administrators only (nothing inherited): a new D:\Tools would otherwise inherit "Users can modify". #>
    $missing = @()
    for ($dir = $Folder; $dir -and -not (Test-Path -LiteralPath $dir); $dir = Split-Path $dir -Parent) { $missing = , $dir + $missing }
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $trustedSids[0..2]) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule (
            (New-Object Security.Principal.SecurityIdentifier $sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    foreach ($dir in $missing) {
        [void](New-Item -ItemType Directory -Path $dir)
        Set-Acl -LiteralPath $dir -AclObject $acl
    }
}

function Install-Toolkit {
    $source = $PSScriptRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $source 'Core\Toolkit.Core.psm1'))) { throw "No toolkit files found next to the installer in $source." }
    if ($Destination -eq $source) { throw "This copy already runs from $Destination. Run the installer from the downloaded or cloned folder instead." }
    if ($Destination.StartsWith("$source\", [StringComparison]::OrdinalIgnoreCase)) { throw 'The install folder cannot be inside the folder you install from.' }
    Assert-NotWorkingCopy $Destination
    Assert-SafeDestination $Destination
    if ((New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrator')) {
        Write-Warning 'Running as administrator: the toolkit is installed for the account running this window. Run it without elevation to install it for yourself.'
    }

    $migrateFrom = Find-LegacyToolkit $source
    $upgrade = Test-Path -LiteralPath (Join-Path $Destination 'Start-Toolkit.ps1')
    Write-Host "$(if ($upgrade) { 'Upgrading' } else { 'Installing' }) $appName in $Destination ..."
    if (-not (Test-Path -LiteralPath $Destination)) {
        if ($Portable -and (New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Destination))).DriveType -eq 'Removable') {
            [void](New-Item -ItemType Directory -Path $Destination -Force)    # removable drives often have no permissions to set
        }
        else { New-PrivateFolder $Destination }
    }
    # Before the new modules: a module edited in the old copy is newer and is kept.
    if ($migrateFrom) { Move-LegacyToolkit $migrateFrom }

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
        # Release ZIPs carry a VERSION file (Tools\New-ToolkitRelease.ps1); a git clone doesn't.
        $versionFile = Join-Path $Destination 'VERSION'
        if (Test-Path -LiteralPath $versionFile) { $values.DisplayVersion = (Get-Content -LiteralPath $versionFile -TotalCount 1).Trim() }
        else { Remove-ItemProperty -Path $uninstallKey -Name DisplayVersion -ErrorAction SilentlyContinue }
        foreach ($name in $values.Keys) { [void](New-ItemProperty -Path $uninstallKey -Name $name -Value $values[$name] -PropertyType String -Force) }
        foreach ($name in 'NoModify', 'NoRepair') { [void](New-ItemProperty -Path $uninstallKey -Name $name -Value 1 -PropertyType DWord -Force) }
        [void](New-ItemProperty -Path $uninstallKey -Name EstimatedSize -Value $sizeKb -PropertyType DWord -Force)
    }

    if ($migrateFrom -and $migrateFrom -ne $Destination) { Write-Host "  Moved settings, logs and modules from $migrateFrom. That folder still holds them - delete it once you have checked the new copy." }
    Write-Host "Done. $(if ($Portable) { "Start it with $Destination\Start-Toolkit.cmd" } else { "Start '$appName' from the Start menu." })"
    [pscustomobject]@{ Action = if ($upgrade) { 'Upgraded' } else { 'Installed' }; Destination = $Destination; Shortcuts = $created; KeptModuleFiles = $kept; MigratedFrom = $migrateFrom }
}

function Uninstall-Toolkit {
    Assert-NotWorkingCopy $Destination
    $registered = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    $registeredLegacy = (Get-ItemProperty -Path $legacy.Key -ErrorAction SilentlyContinue).InstallLocation
    if (-not (Test-Path -LiteralPath (Join-Path $Destination 'Start-Toolkit.ps1')) -and $Destination -notin $registered, $registeredLegacy) {
        throw "No $appName installation found in $Destination."
    }
    Write-Host "Uninstalling $appName from $Destination ..."
    # Can't delete a folder this window is standing in.
    if ((Get-Location).ProviderPath -like "$Destination*") { Set-Location -LiteralPath $env:TEMP }

    # Shortcuts and the Settings > Apps entry from before the rename count too, when they point here.
    $removed = @(@($shortcuts.Values) + $legacyShortcuts | Where-Object { Test-ToolkitShortcut -Path $_ -Folder $Destination })
    foreach ($path in $removed) { Remove-Item -LiteralPath $path -Force }
    if ($registered -eq $Destination) { Remove-Item -Path $uninstallKey -Recurse -Force }
    if ((Get-ItemProperty -Path $legacy.Key -ErrorAction SilentlyContinue).InstallLocation -eq $Destination) { Remove-Item -Path $legacy.Key -Recurse -Force }

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
        if ($summary.MigratedFrom -and $summary.MigratedFrom -ne $Destination) { $text += "`n`nYour settings, logs and modules were copied from the M365 Admin Toolkit in:`n$($summary.MigratedFrom)`nDelete that folder once you have checked the new copy." }
        if ($summary.KeptModuleFiles.Count) { $text += "`n`n$($summary.KeptModuleFiles.Count) module file(s) were kept because the installed copy is newer." }
        $text += "`n`nStart it now?"
        if ([System.Windows.MessageBox]::Show($text, $appName, 'YesNo', 'Information') -eq 'Yes') {
            Start-Process -FilePath $powershell -ArgumentList (Get-LaunchArgument $Destination) -WorkingDirectory $Destination
        }
    }
}
$summary
