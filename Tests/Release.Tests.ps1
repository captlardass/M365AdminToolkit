# Release build test suite: packages HEAD into a temp folder. Signing needs a real certificate, so only its checks run.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$script = "$Root\Tools\New-ToolkitRelease.ps1"
$out = Join-Path ([IO.Path]::GetTempPath()) "TkReleaseTest_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
function Build([hashtable] $Arguments) { & $script @Arguments 6>$null 3>$null }

if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Test-Path "$Root\.git")) {
    Check 'Release build (needs git and a working copy)' $true 'skipped'
}
else {
    try {
        $release = Build @{ Version = '0.0.1-test'; Ref = 'HEAD'; OutputPath = $out }
        Check 'Builds a ZIP and a checksum file' ((Test-Path $release.Zip) -and (Test-Path $release.ChecksumFile)) "$($release.Zip)"
        $actual = (Get-FileHash $release.Zip -Algorithm SHA256).Hash.ToLowerInvariant()
        $line = [IO.File]::ReadAllText($release.ChecksumFile)
        Check 'Checksum file matches the ZIP (sha256sum format)' ($line -eq "$actual  M365AdminToolkit-0.0.1-test.zip`n") $line.Trim()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($release.Zip)
        try { $entries = @($zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' }) } finally { $zip.Dispose() }
        Check 'Package has the toolkit and a VERSION file' (($entries -contains 'M365AdminToolkit/Start-Toolkit.ps1') -and ($entries -contains 'M365AdminToolkit/VERSION') -and ($entries -contains 'M365AdminToolkit/Core/Toolkit.Core.psm1')) ''
        $devFiles = @($entries | Where-Object { $_ -like 'M365AdminToolkit/Tests/*' -or $_ -in 'M365AdminToolkit/CLAUDE.md', 'M365AdminToolkit/.gitignore', 'M365AdminToolkit/.gitattributes' })
        Check 'Tests and development notes are left out' (-not $devFiles.Count) ($devFiles -join ', ')
        $modules = @($entries | Where-Object { $_ -match '^M365AdminToolkit/Modules/([^/]+)/' } | ForEach-Object { $_.Split('/')[2] } | Sort-Object -Unique)
        $private = @($modules | Where-Object { $_ -notin '_Template', 'Demo.SelfTest' })
        Check 'Only the shared sample modules ship' (-not $private.Count -and $modules -contains '_Template') "modules: $($modules -join ', ')"
        Check 'Unsigned build signs nothing' ($release.SignedFiles -eq 0) ''
        git -C $Root cat-file -e 'HEAD:Get-M365AdminToolkit.ps1' 2>$null
        if ($LASTEXITCODE) { Check 'Download script ships next to the ZIP' $true 'skipped: not committed yet' }
        else { Check 'Download script ships next to the ZIP' ($release.Bootstrap -and (Test-Path $release.Bootstrap) -and $entries -contains 'M365AdminToolkit/Get-M365AdminToolkit.ps1') "$($release.Bootstrap)" }

        $threw = $false
        try { Build @{ Version = '0.0.1-test'; Ref = 'HEAD'; OutputPath = $out } | Out-Null } catch { $threw = $true }
        Check 'Refuses to overwrite a built version' $threw ''
        $threw = $false
        try { Build @{ Version = '9.9.9'; OutputPath = $out } | Out-Null } catch { $threw = $_.Exception.Message -like '*git tag*' }
        Check 'Without -Ref, needs the tag v<Version>' $threw ''
        $threw = $false
        try { Build @{ Version = '0.0.2-test'; Ref = 'HEAD'; OutputPath = $out; CertificateThumbprint = '0000000000000000000000000000000000000000' } | Out-Null } catch { $threw = $true }
        Check 'Unknown signing certificate stops the build' ($threw -and -not (Test-Path (Join-Path $out 'M365AdminToolkit-0.0.2-test.zip'))) ''
        $threw = $false
        try { Build @{ Version = '1.0'; Ref = 'HEAD'; OutputPath = $out } | Out-Null } catch { $threw = $true }
        Check 'Version must be semantic (x.y.z)' $threw ''
    }
    catch { Check 'Release build runs without errors' $false $_.Exception.Message }
    finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force } }
}

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors)
Check 'New-ToolkitRelease.ps1 parses' (-not $errors.Count) (@($errors | ForEach-Object Message) -join '; ')

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
