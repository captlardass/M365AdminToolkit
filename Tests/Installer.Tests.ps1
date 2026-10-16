# Installer test suite. Portable installs into a temp folder: no shortcuts, no uninstall entry.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$installer = "$Root\Install-Toolkit.ps1"
$dest = Join-Path ([IO.Path]::GetTempPath()) ("TkInstallTest_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\AdminToolkit'
$registeredBefore = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
function Run([hashtable] $Arguments) { & $installer @Arguments 6>$null | Select-Object -Last 1 }

try {
    $first = Run @{ Destination = $dest; Portable = $true }
    Check 'Fresh install reports Installed' ($first.Action -eq 'Installed') $first.Action
    $expected = 'Core\Toolkit.Core.psm1', 'Core\Toolkit.Worker.ps1', 'Tools\Test-ToolkitModules.ps1', 'Start-Toolkit.ps1', 'Start-Toolkit.cmd',
        'Install-Toolkit.ps1', 'Install-Toolkit.cmd', 'Get-AdminToolkit.ps1', 'Config\settings.example.json', 'Modules\_Template\module.json', 'Modules\Demo.SelfTest\module.ps1'
    $missing = @($expected | Where-Object { -not (Test-Path (Join-Path $dest $_)) })
    Check 'Program files and modules are copied' (-not $missing.Count) ($missing -join ', ')
    $unwanted = @('Tests', '.git', 'CLAUDE.md', 'Logs' | Where-Object { Test-Path (Join-Path $dest $_) })
    Check 'Tests, git data and notes are not copied' (-not $unwanted.Count) ($unwanted -join ', ')
    Check 'Portable install adds no shortcuts' (-not @($first.Shortcuts).Count) ''
    Check 'Portable install leaves the uninstall entry alone' ((Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation -eq $registeredBefore) ''
    $acl = Get-Acl -LiteralPath $dest
    $mine = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sids = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    $others = @($sids | Where-Object { $_ -notin $mine, 'S-1-5-18', 'S-1-5-32-544' })
    Check 'New install folder is private (no inherited access, only you, SYSTEM, Administrators)' ($acl.AreAccessRulesProtected -and -not $others.Count -and $sids -contains $mine) ($others -join ', ')

    # User data in the installed copy, then upgrade.
    New-Item -ItemType Directory "$dest\Logs", "$dest\Modules\My.Own" -Force | Out-Null
    Set-Content "$dest\Config\settings.json" 'keep-me'
    Set-Content "$dest\Logs\toolkit.log" 'log'
    Set-Content "$dest\Modules\My.Own\module.json" '{}'
    Set-Content "$dest\Core\Stale.ps1" '# from an older version'
    Add-Content "$dest\Modules\Demo.SelfTest\module.ps1" '# edited in the installed copy'
    (Get-Item "$dest\Modules\Demo.SelfTest\module.ps1").LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(1)
    Set-Content "$dest\Modules\_Template\module.json" 'old'
    (Get-Item "$dest\Modules\_Template\module.json").LastWriteTimeUtc = [datetime]'2000-01-01'

    $second = Run @{ Destination = $dest; Portable = $true }
    Check 'Second run reports Upgraded' ($second.Action -eq 'Upgraded') $second.Action
    Check 'Upgrade keeps settings.json' ((Get-Content "$dest\Config\settings.json") -eq 'keep-me') ''
    Check 'Upgrade keeps logs and own modules' ((Test-Path "$dest\Logs\toolkit.log") -and (Test-Path "$dest\Modules\My.Own\module.json")) ''
    Check 'Upgrade removes stale program files' (-not (Test-Path "$dest\Core\Stale.ps1")) ''
    Check 'Upgrade keeps a module file that is newer in the installed copy' ((Get-Content "$dest\Modules\Demo.SelfTest\module.ps1" -Raw) -like '*edited in the installed copy*' -and @($second.KeptModuleFiles) -contains 'Demo.SelfTest\module.ps1') (@($second.KeptModuleFiles) -join ', ')
    Check 'Upgrade replaces a module file that is older in the installed copy' ((Get-Content "$dest\Modules\_Template\module.json" -Raw) -eq (Get-Content "$Root\Modules\_Template\module.json" -Raw)) ''

    $threw = $false
    try { Run @{ Destination = $Root; Portable = $true } } catch { $threw = $true }
    Check 'Refuses to install over the folder it runs from' $threw ''
    if (Test-Path "$Root\.git") {
        $threw = $false
        try { Run @{ Destination = $Root; Uninstall = $true } } catch { $threw = $true }
        Check 'Refuses to uninstall a git working copy' ($threw -and (Test-Path "$Root\Core\Toolkit.Core.psm1")) ''
    }

    # Unsafe destinations: refused before anything is copied.
    foreach ($case in @(
            @{ Name = 'a machine-wide folder (Program Files)'; Path = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'AdminToolkit' },
            @{ Name = 'a network path'; Path = '\\fileserver.contoso.example\share\AdminToolkit' },
            @{ Name = 'the root of a drive'; Path = [IO.Path]::GetPathRoot($dest) })) {
        $threw = $false
        try { Run @{ Destination = $case.Path; Portable = $true } | Out-Null } catch { $threw = $true }
        Check "Refuses $($case.Name)" ($threw -and -not (Test-Path (Join-Path $case.Path 'Start-Toolkit.ps1'))) $case.Path
    }
    $shared = "$dest-shared"
    New-Item -ItemType Directory $shared | Out-Null
    $sharedAcl = Get-Acl -LiteralPath $shared
    $sharedAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule (
                (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'), 'Modify', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    Set-Acl -LiteralPath $shared -AclObject $sharedAcl
    $threw = $false
    try { Run @{ Destination = $shared; Portable = $true } | Out-Null } catch { $threw = $_.Exception.Message -like '*Other accounts can change*' }
    Check 'Refuses a folder that other users can write to' ($threw -and -not (Test-Path "$shared\Start-Toolkit.ps1")) ''
    $threw = $false
    try { Run @{ Destination = "$shared\Sub"; Portable = $true } | Out-Null } catch { $threw = $true }
    Check 'Refuses a new folder inside one that other users can change' ($threw -and -not (Test-Path "$shared\Sub")) ''
    Remove-Item $shared -Recurse -Force
    $nested = Run @{ Destination = "$dest-nested\Tools\AdminToolkit"; Portable = $true }
    $open = @("$dest-nested", "$dest-nested\Tools" | Where-Object { -not (Get-Acl -LiteralPath $_).AreAccessRulesProtected })
    Check 'Missing parent folders are created private too' ($nested.Action -eq 'Installed' -and -not $open.Count) ($open -join ', ')
    Remove-Item "$dest-nested" -Recurse -Force

    # Moving an install from before the rename (M365 Admin Toolkit). -MigrateFrom, so HKCU is never read or touched.
    $old = "$dest-legacy"
    Run @{ Destination = $old; Portable = $true } | Out-Null
    New-Item -ItemType Directory "$old\Logs", "$old\Modules\My.Legacy" -Force | Out-Null
    Set-Content "$old\Get-M365AdminToolkit.ps1" '# the old bootstrap script'
    Set-Content "$old\Config\settings.json" 'legacy-settings'
    Set-Content "$old\Logs\old.log" 'log'
    Set-Content "$old\Modules\My.Legacy\module.json" '{}'
    $moved = Run @{ Destination = "$dest-migrated"; Portable = $true; MigrateFrom = $old }
    Check 'Migration reports where it moved from' ($moved.Action -eq 'Installed' -and $moved.MigratedFrom -eq $old) "$($moved.MigratedFrom)"
    Check 'Migration copies settings, logs and modules' ((Get-Content "$dest-migrated\Config\settings.json") -eq 'legacy-settings' -and (Test-Path "$dest-migrated\Logs\old.log") -and (Test-Path "$dest-migrated\Modules\My.Legacy\module.json")) ''
    $leftProgram = @('Start-Toolkit.ps1', 'Core', 'Get-M365AdminToolkit.ps1', 'Get-AdminToolkit.ps1' | Where-Object { Test-Path (Join-Path $old $_) })
    Check 'Migration removes the old program files, so only the new copy starts' (-not $leftProgram.Count) ($leftProgram -join ', ')
    Check 'Migration leaves the user data in the old folder' ((Test-Path "$old\Modules\My.Legacy\module.json") -and (Test-Path "$old\Config\settings.json")) ''
    Check 'Portable migration leaves the uninstall entry alone' ((Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation -eq $registeredBefore) ''
    New-Item -ItemType Directory "$old-git\.git" -Force | Out-Null
    Set-Content "$old-git\Start-Toolkit.ps1" '# a working copy'
    $threw = $false
    try { Run @{ Destination = "$dest-migrated2"; Portable = $true; MigrateFrom = "$old-git" } | Out-Null } catch { $threw = $_.Exception.Message -like '*No M365 Admin Toolkit installation*' }
    Check 'Refuses to migrate from a git working copy, before copying anything' ($threw -and (Test-Path "$old-git\Start-Toolkit.ps1") -and -not (Test-Path "$dest-migrated2")) ''
    $threw = $false
    try { Run @{ Destination = "$dest-migrated2"; Portable = $true; MigrateFrom = "$old-missing" } | Out-Null } catch { $threw = $true }
    Check 'Refuses to migrate from a folder with no install' ($threw -and -not (Test-Path "$dest-migrated2")) ''

    $gone = Run @{ Destination = $dest; Uninstall = $true }
    $left = @('Core', 'Tools', 'Start-Toolkit.ps1', 'Install-Toolkit.ps1', 'Config\settings.example.json' | Where-Object { Test-Path (Join-Path $dest $_) })
    Check 'Uninstall removes the program files' (-not $left.Count) ($left -join ', ')
    Check 'Uninstall keeps modules, settings and logs' ($gone.KeptUserData -and (Test-Path "$dest\Modules\My.Own") -and (Test-Path "$dest\Config\settings.json") -and (Test-Path "$dest\Logs")) ''

    Run @{ Destination = $dest; Portable = $true } | Out-Null
    Run @{ Destination = $dest; Uninstall = $true; RemoveUserData = $true } | Out-Null
    Check 'Uninstall -RemoveUserData removes the whole folder' (-not (Test-Path $dest)) ''
    Check 'Uninstalling a portable copy leaves the uninstall entry alone' ((Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation -eq $registeredBefore) ''
}
catch { Check 'Installer runs without errors' $false $_.Exception.Message }
finally { foreach ($dir in $dest, "$dest-shared", "$dest-nested", "$dest-legacy", "$dest-legacy-git", "$dest-migrated", "$dest-migrated2") { if (Test-Path $dir) { Remove-Item $dir -Recurse -Force } } }

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$errors)
Check 'Install-Toolkit.ps1 parses' (-not $errors.Count) (@($errors | ForEach-Object Message) -join '; ')

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
