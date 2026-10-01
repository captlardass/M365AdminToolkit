# Installer test suite. Portable installs into a temp folder: no shortcuts, no uninstall entry.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$installer = "$Root\Install-Toolkit.ps1"
$dest = Join-Path ([IO.Path]::GetTempPath()) ("TkInstallTest_{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\M365AdminToolkit'
$registeredBefore = (Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
function Run([hashtable] $Arguments) { & $installer @Arguments 6>$null | Select-Object -Last 1 }

try {
    $first = Run @{ Destination = $dest; Portable = $true }
    Check 'Fresh install reports Installed' ($first.Action -eq 'Installed') $first.Action
    $expected = 'Core\Toolkit.Core.psm1', 'Core\Toolkit.Worker.ps1', 'Tools\Test-ToolkitModules.ps1', 'Start-Toolkit.ps1', 'Start-Toolkit.cmd',
        'Install-Toolkit.ps1', 'Install-Toolkit.cmd', 'Config\settings.example.json', 'Modules\_Template\module.json', 'Modules\Demo.SelfTest\module.ps1'
    $missing = @($expected | Where-Object { -not (Test-Path (Join-Path $dest $_)) })
    Check 'Program files and modules are copied' (-not $missing.Count) ($missing -join ', ')
    $unwanted = @('Tests', '.git', 'CLAUDE.md', 'Logs' | Where-Object { Test-Path (Join-Path $dest $_) })
    Check 'Tests, git data and notes are not copied' (-not $unwanted.Count) ($unwanted -join ', ')
    Check 'Portable install adds no shortcuts' (-not @($first.Shortcuts).Count) ''
    Check 'Portable install leaves the uninstall entry alone' ((Get-ItemProperty -Path $uninstallKey -ErrorAction SilentlyContinue).InstallLocation -eq $registeredBefore) ''

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
finally { if (Test-Path $dest) { Remove-Item $dest -Recurse -Force } }

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$errors)
Check 'Install-Toolkit.ps1 parses' (-not $errors.Count) (@($errors | ForEach-Object Message) -join '; ')

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
