#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the M365 Admin Toolkit from its GitHub releases, verifies it and installs it for the
    current user.

.DESCRIPTION
    Download this script from the Releases page and run it. It:
      1. Asks the GitHub API for the release (latest stable unless -Version or -IncludePrerelease).
      2. Downloads the ZIP and its SHA256SUMS.txt into a new, empty temp folder and checks the hash.
      3. Checks the Authenticode signature of every .ps1/.psm1 in the ZIP and of the file catalog
         that covers every other file. All must be Valid and signed by the same certificate that
         signed this script (or -ExpectedSigner).
      4. Extracts the ZIP, refusing any entry that would land outside the extract folder.
      5. Runs the included Install-Toolkit.ps1 for the current user, then deletes the temp folder.
    Anything unexpected stops the install: it fails closed. It refuses to run elevated, so the
    toolkit is always installed for the signed-in user, never machine-wide.

.PARAMETER Destination
    Install folder. Without it, a folder picker opens (or the default
    %LOCALAPPDATA%\Programs\M365AdminToolkit is used with -NoGui).

.PARAMETER Version
    Install this version (e.g. 1.2.0) instead of the latest release.

.PARAMETER IncludePrerelease
    Take the newest release even if it is a prerelease.

.PARAMETER Portable
    Only copy the files: no shortcuts and no uninstall entry.

.PARAMETER DesktopShortcut
    Also put a shortcut on the desktop.

.PARAMETER NoGui
    No folder picker and no message boxes, e.g. for scripted installs.

.PARAMETER ExpectedSigner
    Thumbprint of the certificate the toolkit scripts must be signed with. Defaults to the
    certificate that signed this script.

.PARAMETER AllowUnsigned
    Development builds only: skip the signature check (the SHA-256 check still runs).

.PARAMETER SourceZip
    Install from a local release ZIP instead of downloading (needs -ChecksumFile). Every check still runs.

.PARAMETER ChecksumFile
    The SHA256SUMS.txt that belongs to -SourceZip.

.EXAMPLE
    .\Get-M365AdminToolkit.ps1

.EXAMPLE
    .\Get-M365AdminToolkit.ps1 -Destination D:\Tools\M365AdminToolkit -NoGui
#>
[CmdletBinding(DefaultParameterSetName = 'Download')]
param(
    [string] $Destination,
    [Parameter(ParameterSetName = 'Download')] [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')] [string] $Version,
    [Parameter(ParameterSetName = 'Download')] [switch] $IncludePrerelease,
    [switch] $Portable,
    [switch] $DesktopShortcut,
    [switch] $NoGui,
    [ValidatePattern('^[0-9A-Fa-f]{40}$')] [string] $ExpectedSigner,
    [switch] $AllowUnsigned,
    [Parameter(ParameterSetName = 'Local', Mandatory)] [string] $SourceZip,
    [Parameter(ParameterSetName = 'Local', Mandatory)] [string] $ChecksumFile
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'    # Invoke-WebRequest is very slow in 5.1 with the progress bar
$appName = 'M365 Admin Toolkit'
# Hard-coded on purpose: the script only ever trusts this repository.
$repository = 'captlardass/M365AdminToolkit'
$apiBase = "https://api.github.com/repos/$repository/releases"
$downloadBase = "https://github.com/$repository/releases/download/"
$packageRoot = 'M365AdminToolkit'

function Test-Elevated {
    (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ToolkitRelease {
    <# Returns the release (tag, ZIP and checksum asset URLs) to install. #>
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'M365AdminToolkit-Installer' }
    $release = if ($Version) { Invoke-RestMethod -Uri "$apiBase/tags/v$Version" -Headers $headers -UseBasicParsing }
    elseif ($IncludePrerelease) {
        # Assigned first: 5.1 writes a JSON array as one object, so piping the call directly wouldn't enumerate it.
        $list = Invoke-RestMethod -Uri "$apiBase`?per_page=20" -Headers $headers -UseBasicParsing
        $list | Where-Object { -not $_.draft } | Select-Object -First 1
    }
    else { Invoke-RestMethod -Uri "$apiBase/latest" -Headers $headers -UseBasicParsing }
    if (-not $release -or $release.draft) { throw "No published release found in $repository." }
    if ($release.tag_name -notmatch '^v(\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?)$') { throw "Unexpected release tag '$($release.tag_name)'." }
    $found = $Matches[1]
    $name = "M365AdminToolkit-$found"
    $urls = @{}
    foreach ($file in "$name.zip", "$name.SHA256SUMS.txt") {
        $asset = @($release.assets | Where-Object name -eq $file)
        if ($asset.Count -ne 1) { throw "Release $($release.tag_name) has no single asset named $file." }
        $url = [string]$asset[0].browser_download_url
        # Only release downloads from this repository, over HTTPS.
        if (-not $url.StartsWith("$downloadBase$($release.tag_name)/", [StringComparison]::Ordinal)) { throw "Unexpected download URL for $file`: $url" }
        $urls[$file] = $url
    }
    [pscustomobject]@{ Version = $found; Name = $name; ZipUrl = $urls["$name.zip"]; SumsUrl = $urls["$name.SHA256SUMS.txt"] }
}

function Assert-Checksum([string] $Zip, [string] $Sums) {
    <# The ZIP's SHA-256 must match its line in the checksum file (sha256sum format). #>
    $zipName = Split-Path $Zip -Leaf
    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($Sums)) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$' -and $Matches[2].Trim() -eq $zipName) { $expected = $Matches[1].ToLowerInvariant() }
    }
    if (-not $expected) { throw "The checksum file has no SHA-256 for $zipName." }
    $actual = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "SHA-256 mismatch for $zipName (expected $expected, got $actual). The download is damaged or was changed - nothing was installed." }
    $actual
}

function Expand-ToolkitZip([string] $Zip, [string] $Target) {
    <# Extracts entry by entry. Every entry must stay under <Target>\M365AdminToolkit (no zip slip). #>
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $root = [IO.Path]::GetFullPath((Join-Path $Target $packageRoot)).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            $path = [IO.Path]::GetFullPath((Join-Path $Target $entry.FullName))
            if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "The ZIP contains an entry outside the $packageRoot folder: '$($entry.FullName)'. Nothing was installed." }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { [void](New-Item -ItemType Directory -Path $path -Force); continue }
            $dir = Split-Path $path -Parent
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $path, $false)
        }
    }
    finally { $archive.Dispose() }
    $root.TrimEnd('\')
}

function Assert-Signature([string] $Folder, [string] $Signer) {
    <# Every script must carry a Valid signature from the expected certificate. #>
    # Filtered by extension: -Include is ignored together with -LiteralPath in 5.1.
    $scripts = @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' })
    if (-not $scripts.Count) { throw 'The package contains no scripts.' }
    $bad = foreach ($file in $scripts) {
        $signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
        if ($signature.Status -ne 'Valid') { "$($file.Name): $($signature.Status)" }
        elseif ($signature.SignerCertificate.Thumbprint -ne $Signer) { "$($file.Name): signed by $($signature.SignerCertificate.Subject)" }
    }
    if ($bad) { throw "Signature check failed - nothing was installed:`n  $(@($bad) -join "`n  ")" }

    # The signed catalog covers the other files too (XAML, JSON...) and catches added or missing files.
    $catalog = Join-Path $Folder 'M365AdminToolkit.cat'
    if (-not (Test-Path -LiteralPath $catalog)) { throw 'The package has no signed file catalog (M365AdminToolkit.cat) - nothing was installed.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $catalog
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $Signer) {
        throw "The file catalog is not validly signed by the expected publisher ($($signature.Status)) - nothing was installed."
    }
    $check = Test-FileCatalog -Path $Folder -CatalogFilePath $catalog -FilesToSkip 'M365AdminToolkit.cat' -Detailed
    if ($check.Status -ne 'Valid') { throw 'Files in the package differ from the signed catalog (changed, added or missing) - nothing was installed.' }
    $scripts.Count
}

function Install-FromRelease {
    if (Test-Elevated) {
        throw 'Run this without "Run as administrator": the toolkit is installed for your own account only, and an elevated window would install it for the admin account instead.'
    }

    # Who must have signed the toolkit: -ExpectedSigner, else whoever signed this script.
    $signer = $null
    if (-not $AllowUnsigned) {
        if ($ExpectedSigner) { $signer = $ExpectedSigner.ToUpperInvariant() }
        else {
            $own = if ($PSCommandPath) { Get-AuthenticodeSignature -LiteralPath $PSCommandPath }
            if (-not $own -or $own.Status -ne 'Valid') {
                throw 'This installer script is not validly signed, so it cannot tell which publisher to trust. Download Get-M365AdminToolkit.ps1 again from the Releases page, or pass -ExpectedSigner <thumbprint>.'
            }
            $signer = $own.SignerCertificate.Thumbprint
        }
    }
    else { Write-Warning '-AllowUnsigned: the publisher signature is NOT checked. Use this only for your own development builds.' }

    # A new, empty folder of our own for everything downloaded.
    $work = Join-Path ([IO.Path]::GetTempPath()) "TkSetup_$([guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $work)
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Local') {
            $zip = Join-Path $work (Split-Path $SourceZip -Leaf)
            $sums = Join-Path $work 'SHA256SUMS.txt'
            Copy-Item -LiteralPath $SourceZip -Destination $zip
            Copy-Item -LiteralPath $ChecksumFile -Destination $sums
            $label = Split-Path $SourceZip -Leaf
        }
        else {
            # Windows PowerShell 5.1 may still default to TLS 1.0; GitHub needs 1.2 or later.
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $release = Get-ToolkitRelease
            Write-Host "Downloading $appName $($release.Version) from github.com/$repository ..."
            $zip = Join-Path $work "$($release.Name).zip"
            $sums = Join-Path $work "$($release.Name).SHA256SUMS.txt"
            Invoke-WebRequest -Uri $release.ZipUrl -OutFile $zip -UseBasicParsing
            Invoke-WebRequest -Uri $release.SumsUrl -OutFile $sums -UseBasicParsing
            $label = "$appName $($release.Version)"
        }

        $hash = Assert-Checksum -Zip $zip -Sums $sums
        Write-Host "SHA-256 OK ($hash)."
        $package = Expand-ToolkitZip -Zip $zip -Target (Join-Path $work 'x')
        $installer = Join-Path $package 'Install-Toolkit.ps1'
        if (-not (Test-Path -LiteralPath $installer)) { throw "The package has no Install-Toolkit.ps1." }
        if ($signer) {
            $count = Assert-Signature -Folder $package -Signer $signer
            Write-Host "Signatures OK ($count scripts, signer $signer)."
        }

        $arguments = @{}
        if ($Destination) { $arguments.Destination = $Destination }
        if ($Portable) { $arguments.Portable = $true }
        if ($DesktopShortcut) { $arguments.DesktopShortcut = $true }
        if (-not $NoGui) { $arguments.ShowSummary = $true }
        Write-Host "Installing $label ..."
        $State.HandedOff = $true    # from here on the installer reports its own errors
        & $installer @arguments
    }
    finally {
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$State = @{ HandedOff = $false }
try { Install-FromRelease }
catch {
    if (-not $NoGui -and -not $State.HandedOff) {
        Add-Type -AssemblyName PresentationFramework
        [void][System.Windows.MessageBox]::Show("Setup stopped: $($_.Exception.Message)", $appName, 'OK', 'Error')
    }
    throw
}
