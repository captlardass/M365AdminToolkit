# Download-installer test suite: offline, against a release built from HEAD (-SourceZip). Portable installs into temp folders.
param([string] $Root)
# Resolved here, not in param(): $PSScriptRoot is empty in param defaults on PS 5.1.
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$results = New-Object System.Collections.Generic.List[object]
function Check([string] $Case, [bool] $Ok, [string] $Detail = '') { $results.Add([pscustomobject]@{ Result = if ($Ok) { 'PASS' } else { 'FAIL' }; Case = $Case; Detail = $Detail }) }

$script = "$Root\Get-M365AdminToolkit.ps1"
$work = Join-Path ([IO.Path]::GetTempPath()) "TkBootstrapTest_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
function Setup([hashtable] $Arguments) { & $script @Arguments -NoGui 6>$null 3>$null | Select-Object -Last 1 }
function Refusal([hashtable] $Arguments) {
    <# The error message, or $null if the run did not fail. #>
    try { Setup $Arguments | Out-Null; $null } catch { $_.Exception.Message }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue) -or -not (Test-Path "$Root\.git")) {
    Check 'Download installer (needs git and a working copy to build a release)' $true 'skipped'
}
else {
    try {
        [void](New-Item -ItemType Directory -Path $work)
        $release = & "$Root\Tools\New-ToolkitRelease.ps1" -Version '0.0.1-test' -Ref HEAD -OutputPath "$work\out" 6>$null 3>$null
        $local = @{ SourceZip = $release.Zip; ChecksumFile = $release.ChecksumFile; Portable = $true }

        $dest = "$work\good"
        $done = Setup ($local + @{ Destination = $dest; AllowUnsigned = $true })
        Check 'Verified release installs' ($done.Action -eq 'Installed' -and (Test-Path "$dest\Start-Toolkit.ps1") -and (Test-Path "$dest\VERSION")) "$($done.Action)"
        Check 'Temp download folder is cleaned up' (-not @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'TkSetup_*' | Where-Object LastWriteTime -gt (Get-Date).AddMinutes(-5)).Count) ''

        $bytes = [IO.File]::ReadAllBytes($release.Zip)
        $bytes[[int]($bytes.Length / 2)] = $bytes[[int]($bytes.Length / 2)] -bxor 0xFF
        $tampered = "$work\tampered\$(Split-Path $release.Zip -Leaf)"
        [void](New-Item -ItemType Directory -Path (Split-Path $tampered))
        [IO.File]::WriteAllBytes($tampered, $bytes)
        $message = Refusal @{ SourceZip = $tampered; ChecksumFile = $release.ChecksumFile; Destination = "$work\tampered-dest"; AllowUnsigned = $true; Portable = $true }
        Check 'A changed byte fails the SHA-256 check and installs nothing' ($message -like '*SHA-256 mismatch*' -and -not (Test-Path "$work\tampered-dest")) $message

        $message = Refusal ($local + @{ Destination = "$work\unsigned-dest" })
        Check 'Refuses when it cannot tell which publisher to trust (unsigned installer)' ($message -like '*not validly signed*' -and -not (Test-Path "$work\unsigned-dest")) $message
        $message = Refusal ($local + @{ Destination = "$work\signer-dest"; ExpectedSigner = '0' * 40 })
        Check 'Refuses unsigned or wrongly signed toolkit scripts' ($message -like '*Signature check failed*' -and $message -like '*Install-Toolkit.ps1*' -and $message -notlike '*README.md*' -and -not (Test-Path "$work\signer-dest")) $message

        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $evilZip = "$work\evil\M365AdminToolkit-0.0.2-test.zip"
        [void](New-Item -ItemType Directory -Path (Split-Path $evilZip))
        $archive = [IO.Compression.ZipFile]::Open($evilZip, 'Create')
        try {
            foreach ($entryName in 'M365AdminToolkit/Install-Toolkit.ps1', 'M365AdminToolkit/../../evil.txt') {
                $writer = New-Object IO.StreamWriter ($archive.CreateEntry($entryName).Open())
                try { $writer.Write('# test') } finally { $writer.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        $evilSums = "$work\evil\SHA256SUMS.txt"
        [IO.File]::WriteAllText($evilSums, "$((Get-FileHash $evilZip -Algorithm SHA256).Hash.ToLowerInvariant())  $(Split-Path $evilZip -Leaf)`n")
        $message = Refusal @{ SourceZip = $evilZip; ChecksumFile = $evilSums; Destination = "$work\evil-dest"; AllowUnsigned = $true; Portable = $true }
        Check 'Refuses a ZIP entry outside the package folder (zip slip)' ($message -like '*outside the M365AdminToolkit folder*' -and -not (Test-Path "$work\evil-dest")) $message

        $elevated = (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($elevated) {
            $message = Refusal ($local + @{ Destination = "$work\admin-dest"; AllowUnsigned = $true })
            Check 'Refuses to run elevated' ($message -like '*Run as administrator*' -and -not (Test-Path "$work\admin-dest")) $message
        }
        else { Check 'Refuses to run elevated' $true 'skipped: this window is not elevated' }
    }
    catch { Check 'Download installer runs without errors' $false $_.Exception.Message }
    finally { if (Test-Path $work) { Remove-Item $work -Recurse -Force } }
}

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors)
Check 'Get-M365AdminToolkit.ps1 parses' (-not $errors.Count) (@($errors | ForEach-Object Message) -join '; ')

$results | Format-Table -AutoSize -Wrap | Out-String -Width 200
"{0} passed, {1} failed" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -eq 'FAIL').Count
$results.ToArray() | Where-Object Result -eq 'FAIL' | ForEach-Object { $global:TkTestFailures++ }
