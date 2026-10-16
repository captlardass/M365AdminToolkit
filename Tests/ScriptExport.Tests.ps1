# Script export suite: modules to a folder or .tar.gz for another machine (e.g. on a USB stick).
# Everything is written to temp folders. The WSL case runs an extracted script on Linux when WSL is there.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }
function Skip([string] $Case, [string] $Why) { $results.Add([pscustomobject]@{ Result = 'PASS'; Case = $Case; Detail = "skipped: $Why" }) }

Import-Module "$Root\Core\Toolkit.Core.psm1" -Force
$work = Join-Path ([IO.Path]::GetTempPath()) ('TkExportTest_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$modules = Join-Path $work 'Modules'
$out = Join-Path $work 'out'
[void](New-Item -ItemType Directory -Path $modules, $out)

function New-FixtureModule([string] $Id, [string] $Runtime, [string] $File, [byte[]] $Bytes, [hashtable] $Extra = @{}) {
    $dir = Join-Path $modules $Id
    [void](New-Item -ItemType Directory -Path $dir)
    [IO.File]::WriteAllBytes((Join-Path $dir $File), $Bytes)
    $manifest = [ordered]@{ Id = $Id; Name = "Test $Runtime"; Category = 'Local'; Description = 'Fixture'; Version = '1.0.0'; EntryPoint = $File; Runtime = $Runtime
        Parameters = @(@{ Name = 'Path'; Label = 'Path'; Type = 'String'; Required = $true; HelpText = 'Folder' }) }
    foreach ($k in $Extra.Keys) { $manifest[$k] = $Extra[$k] }
    [IO.File]::WriteAllText((Join-Path $dir 'module.json'), ([pscustomobject]$manifest | ConvertTo-Json -Depth 5))
    $dir
}
$ascii = [Text.Encoding]::ASCII
function Get-Sha([byte[]] $Bytes) { $s = [Security.Cryptography.SHA256]::Create(); try { -join ($s.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $s.Dispose() } }

try {
    # A bash script saved on Windows: UTF-8 BOM and CRLF, which would break it on Linux.
    $bom = [byte[]](0xEF, 0xBB, 0xBF)
    $bashDir = New-FixtureModule 'Local.ExportBash' 'Bash' 'module.sh' ($bom + $ascii.GetBytes("#!/usr/bin/env bash`r`necho `"##tk:row {\`"Ok\`":true}`"`r`necho from-linux`r`n")) @{ DryRunArgument = '--dry-run'; SupportsWhatIf = $true; Platforms = @('Linux') }
    Set-Content (Join-Path $bashDir 'results.csv') 'Name,Value'
    Set-Content (Join-Path $bashDir 'run.log') 'log'
    [void](New-Item -ItemType Directory (Join-Path $bashDir 'lib'))
    [IO.File]::WriteAllBytes((Join-Path $bashDir 'lib\helper.sh'), $ascii.GetBytes("#!/bin/sh`r`necho helper`r`n"))
    [void](New-FixtureModule 'Local.ExportCmd' 'Cmd' 'module.cmd' ($ascii.GetBytes("@echo off`necho hi`n")))
    [void](New-FixtureModule 'Local.ExportPython' 'Python' 'module.py' ($ascii.GetBytes("print('hi')`r`n")))
    Copy-Item -Recurse "$Root\Modules\Demo.SelfTest" $modules
    $all = @(Get-TkModule -Path $modules)
    Check 'Fixture modules are valid' (@($all | Where-Object { -not $_.IsValid }).Count -eq 0) (@($all | Where-Object { -not $_.IsValid } | ForEach-Object { "$($_.Id): $($_.Errors)" }) -join ' | ')

    # --- Folder export ---
    $r = Export-TkModule -Module $all -Destination $out -Format Folder
    $x = $r.Path
    Check 'Folder export writes one folder per module, a README each and SHA256SUMS' ($r.Modules -eq 4 -and (Test-Path "$x\Local.ExportBash\module.sh") -and (Test-Path "$x\Demo.SelfTest\module.ps1") -and (Test-Path "$x\Local.ExportCmd\README.txt") -and (Test-Path "$x\README.txt") -and (Test-Path "$x\SHA256SUMS.txt")) $x
    $sh = [IO.File]::ReadAllBytes("$x\Local.ExportBash\module.sh")
    Check 'Bash script: LF line endings and no BOM (the #! line comes first)' ($sh -notcontains 13 -and $sh[0] -eq [byte][char]'#') "first byte $($sh[0])"
    Check 'Helper scripts in subfolders get the same treatment' (([IO.File]::ReadAllBytes("$x\Local.ExportBash\lib\helper.sh")) -notcontains 13) ''
    $cmd = [IO.File]::ReadAllText("$x\Local.ExportCmd\module.cmd")
    Check 'cmd script: CRLF line endings' ($cmd -eq "@echo off`r`necho hi`r`n") ($cmd -replace "`r", '\r' -replace "`n", '\n')
    Check 'Result files a script left in its folder (*.csv, *.log) stay behind' (-not (Test-Path "$x\Local.ExportBash\results.csv") -and -not (Test-Path "$x\Local.ExportBash\run.log") -and @($r.LeftOut).Count -eq 2) ($r.LeftOut -join ', ')
    $leaked = @(Get-ChildItem $x -Recurse | Where-Object { $_.Name -in 'Logs', 'Config', 'preferences.json', 'settings.json' })
    Check 'No logs, settings or preferences are exported' (-not $leaked.Count) ($leaked.FullName -join ', ')
    $bad = foreach ($line in [IO.File]::ReadAllLines("$x\SHA256SUMS.txt")) {
        $hash, $rel = $line -split '  ', 2
        if ((Get-Sha ([IO.File]::ReadAllBytes((Join-Path $x ($rel -replace '/', '\'))))) -ne $hash) { $rel }
    }
    $listed = @([IO.File]::ReadAllLines("$x\SHA256SUMS.txt")).Count
    $onDisk = @(Get-ChildItem $x -Recurse -File | Where-Object Name -ne 'SHA256SUMS.txt').Count
    Check 'SHA256SUMS.txt matches every exported file' (-not $bad -and $listed -eq $onDisk) "mismatch: $($bad -join ', '); listed $listed, on disk $onDisk"
    $readme = [IO.File]::ReadAllText("$x\Local.ExportBash\README.txt")
    Check 'README says how to run it on its own' ($readme -like '*./module.sh --Path "<Path>"*' -and $readme -like '*--dry-run*' -and $readme -like '*chmod +x*' -and $readme -like '*Runs on: Linux*') ''
    $again = Export-TkModule -Module $all -Destination $out -Format Folder
    Check 'A second export never overwrites the first' ($again.Path -ne $x -and (Test-Path $x) -and (Test-Path $again.Path)) "$($again.Path)"

    # --- .tar.gz export ---
    $t = Export-TkModule -Module $all -Destination $out -Format TarGz
    Check 'TarGz export writes one .tar.gz' ($t.Path -like '*.tar.gz' -and (Test-Path $t.Path)) $t.Path
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
        $listing = & $tar -tvzf $t.Path 2>&1 | Out-String
        $shLine = ($listing -split "`r?`n" | Where-Object { $_ -match 'Local\.ExportBash/module\.sh$' }) -join ''
        $readmeLine = ($listing -split "`r?`n" | Where-Object { $_ -match 'Local\.ExportBash/README\.txt$' }) -join ''
        Check 'tar sees the bash and Python scripts as executable (0755), other files 0644' ($shLine -like '-rwxr-xr-x*' -and ($listing -split "`r?`n" | Where-Object { $_ -match 'module\.py$' }) -like '-rwxr-xr-x*' -and $readmeLine -like '-rw-r--r--*') "$shLine | $readmeLine"
        $unpacked = Join-Path $work 'unpacked'
        [void](New-Item -ItemType Directory $unpacked)
        & $tar -xzf $t.Path -C $unpacked 2>&1 | Out-Null
        $top = Get-ChildItem $unpacked -Directory | Select-Object -First 1
        $same = (Get-Sha ([IO.File]::ReadAllBytes("$($top.FullName)\Local.ExportBash\module.sh"))) -eq (Get-Sha $sh)
        Check 'The archive unpacks to the same files as the folder export' ($same -and (Test-Path "$($top.FullName)\SHA256SUMS.txt")) $top.FullName
    }
    else { Skip 'tar listing' 'tar.exe not found' }

    $wsl = Get-TkRuntimeStatus Bash
    if ($wsl.Available -and $wsl.Wsl) {
        # On Linux: unpack, verify the checksums and run the script straight away - no chmod needed.
        $linuxOut = & $wsl.Interpreter --cd (Split-Path $t.Path) -e sh -c "d=`$(mktemp -d) && tar -xzf '$(Split-Path $t.Path -Leaf)' -C `"`$d`" && cd `"`$d`"/* && sha256sum -c --quiet SHA256SUMS.txt && ./Local.ExportBash/module.sh && echo CHECKS-OK; rm -rf `"`$d`"" 2>&1 | Out-String
        Check 'On Linux the unpacked script verifies with sha256sum -c and runs without chmod' ($linuxOut -like '*from-linux*' -and $linuxOut -like '*CHECKS-OK*') $linuxOut.Trim()
    }
    else { Skip 'Run the unpacked archive on Linux' 'no WSL' }

    # --- Tenant data: fails closed ---
    $leakDir = New-FixtureModule 'Local.ExportLeak' 'Bash' 'module.sh' ($ascii.GetBytes("#!/bin/sh`n# contact: it-ops@" + "northwind-traders.no`n# example: user@contoso.example`n"))
    $leak = Get-TkModule -Path $modules | Where-Object Id -eq 'Local.ExportLeak'
    $before = @(Get-ChildItem $out).Count
    $threw = $null
    try { Export-TkModule -Module $leak -Destination $out | Out-Null } catch { $threw = $_.Exception.Message }
    Check 'An address that is not a placeholder stops the export, and nothing is written' ($threw -like '*Possible real tenant data*' -and $threw -like '*northwind-traders.no*' -and $threw -notlike '*contoso.example*' -and @(Get-ChildItem $out).Count -eq $before) "$threw"
    $forced = Export-TkModule -Module $leak -Destination $out -AllowTenantData
    Check '-AllowTenantData exports anyway and reports the lines' ((Test-Path $forced.Path) -and @($forced.TenantData).Count -eq 1) ($forced.TenantData -join ' | ')
    $hits = @(Find-TkTenantData -Folder $leakDir)
    Check 'Find-TkTenantData flags real-looking addresses and tenants, not placeholders' ($hits.Count -eq 1 -and $hits[0] -like 'module.sh:2:*') ($hits -join ' | ')

    $broken = [pscustomobject]@{ Id = 'Local.Broken'; Name = 'Broken'; IsValid = $false; Errors = @('bad'); Directory = $leakDir }
    $threw = $false
    try { Export-TkModule -Module $broken -Destination $out | Out-Null } catch { $threw = $_.Exception.Message -like '*not a valid module*' }
    Check 'An invalid module is refused' $threw ''
}
catch { Check 'Export suite runs without errors' $false "$($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)" }
finally { if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } }

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
