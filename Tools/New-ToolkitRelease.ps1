#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the two release ZIPs of the toolkit (Core and Full) plus one SHA-256 checksum file,
    optionally Authenticode-signing the PowerShell scripts first.

.DESCRIPTION
    Follows the usual order for publishing software:
      1. Package exactly one committed version (git archive of tag v<Version>), so local edits and
         git-ignored private modules never ship. Tests and notes for Claude are left out.
         The build stops if a shipped file contains what looks like a real e-mail address or tenant.
      2. Split it into two editions, each with an EDITION file:
           Core - the program with only the sample modules (_Template, Demo.SelfTest)
           Full - the program with every committed module
      3. Optionally sign every .ps1/.psm1 with a code-signing certificate, timestamped so the
         signatures stay valid after the certificate expires. Fails if any signature isn't Valid.
      4. Zip, then hash the final ZIPs into one SHA256SUMS.txt (sha256sum format, a line per ZIP).
    Also writes a copy of the signed Get-AdminToolkit.ps1 next to the ZIPs.
    Publish them with Tools\Publish-ToolkitRelease.ps1 (a GitHub release for the tag).
    An existing version is never overwritten: published files must not change.

.PARAMETER Version
    Semantic version, e.g. 1.0.0 or 1.1.0-beta.1. Written into the package as VERSION.

.PARAMETER Ref
    Commit or tag to package. Defaults to the tag v<Version>. Use HEAD only for test builds.

.PARAMETER OutputPath
    Folder for the ZIPs and checksum file. Defaults to .\Release (git-ignored).

.PARAMETER CertificateThumbprint
    Thumbprint of a code-signing certificate (with private key) in Cert:\CurrentUser\My.
    Omit to build an unsigned release (checksum only).

.PARAMETER TimestampServer
    RFC 3161 timestamp server used when signing.

.PARAMETER LegacyNames
    Builds the one-off bridge release for the old M365AdminToolkit repository: the same toolkit, but
    with the old ZIP names, ZIP root folder and catalog name, so Get-M365AdminToolkit.ps1 copies handed
    out before the rename can still install it (its installer then migrates to Admin Toolkit).
    Every check (tenant-data gate, signing, hashing) is the same.

.EXAMPLE
    git tag -a v1.0.0 -m "Admin Toolkit 1.0.0"
    .\Tools\New-ToolkitRelease.ps1 -Version 1.0.0

.EXAMPLE
    .\Tools\New-ToolkitRelease.ps1 -Version 1.0.0 -CertificateThumbprint 0123456789ABCDEF0123456789ABCDEF01234567
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')] [string] $Version,
    [string] $Ref,
    [string] $OutputPath,
    [string] $CertificateThumbprint,
    [string] $TimestampServer = 'http://timestamp.digicert.com',
    [switch] $LegacyNames
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $root 'Release' }
if (-not $Ref) { $Ref = "v$Version" }
# Package root folder, catalog and ZIP names. -LegacyNames: the pre-rename names that old
# Get-M365AdminToolkit.ps1 copies look for (the bridge release only).
$product = if ($LegacyNames) { 'M365AdminToolkit' } else { 'AdminToolkit' }
$name = "$product-$Version"
# Core keeps the plain ZIP name, so Get-AdminToolkit.ps1 copies from older releases still find it.
$zipPaths = [ordered]@{ Core = Join-Path $OutputPath "$name.zip"; Full = Join-Path $OutputPath "$name-Full.zip" }
$sumsPath = Join-Path $OutputPath "$name.SHA256SUMS.txt"
# The signed download-and-install script, published on its own as Get-AdminToolkit.ps1.
$bootstrapPath = Join-Path $OutputPath "$name.Get-AdminToolkit.ps1"
# In the repository for development only; not part of what users run.
$devOnly = 'Tests', 'CLAUDE.md', '.gitattributes', '.gitignore'
# The only modules in the Core edition. Full has every committed module.
$coreModules = '_Template', 'Demo.SelfTest'
# The tenant-data rule (placeholder addresses only) lives in Core: Find-TkTenantData.
Import-Module (Join-Path $root 'Core\Toolkit.Core.psm1') -Force

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is needed to package a committed version.' }
$commit = git -C $root rev-parse --verify --quiet "$Ref^{commit}"
if ($LASTEXITCODE -or -not $commit) {
    throw "'$Ref' is not a commit or tag. Commit your changes, then tag the release: git tag -a v$Version -m 'Admin Toolkit $Version'"
}
if (@(@($zipPaths.Values) + $sumsPath + $bootstrapPath | Where-Object { Test-Path -LiteralPath $_ }).Count) {
    throw "$name already exists in $OutputPath. Published versions must not change - use a new version number."
}
$certificate = $null
if ($CertificateThumbprint) {
    $certificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object Thumbprint -eq ($CertificateThumbprint -replace '\s', '')
    if (-not $certificate) { throw "No code-signing certificate with thumbprint $CertificateThumbprint in Cert:\CurrentUser\My." }
    if (-not $certificate.HasPrivateKey) { throw 'The certificate has no private key on this PC, so it cannot sign.' }
    if ($certificate.NotAfter -lt (Get-Date)) { throw ('The certificate expired on {0:yyyy-MM-dd}.' -f $certificate.NotAfter) }
}
$dirty = git -C $root status --porcelain --untracked-files=no
if ($dirty -and $Ref -eq 'HEAD') { Write-Warning 'There are uncommitted changes: they are NOT in this build, which packages the last commit.' }

function Assert-NoTenantData([string] $Folder) {
    <# Fails closed: shipped files may only contain placeholder addresses and tenant names. Find-TkTenantData
       (Core) holds the rule, so the export to a USB stick checks exactly the same thing. #>
    $found = @(Find-TkTenantData -Folder $Folder)
    if ($found.Count) { throw "Possible real tenant data in the package - replace it with contoso.example placeholders:`n  $($found -join "`n  ")" }
}

function New-EditionZip([string] $Package, [string] $Edition, [string] $ZipPath) {
    <# Signs (optionally) and zips one edition. Returns the number of signed scripts. #>
    [IO.File]::WriteAllText((Join-Path $Package 'EDITION'), "$Edition`r`n")
    # Sign before zipping: the checksum must cover the signed files.
    $signed = 0
    if ($certificate) {
        # Filtered by extension: -Include is ignored together with -LiteralPath in 5.1.
        foreach ($file in Get-ChildItem -LiteralPath $Package -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' }) {
            $result = Set-AuthenticodeSignature -LiteralPath $file.FullName -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256
            if ($result.Status -ne 'Valid') {
                throw "Signing $($file.Name) gave status '$($result.Status)': $($result.StatusMessage). Is the certificate's root trusted on this PC?"
            }
            $signed++
        }
        # Only scripts can carry a signature. A signed catalog covers every file (XAML, JSON...), so
        # Get-AdminToolkit.ps1 can prove the whole package is untouched, with no files added or missing.
        $catalog = Join-Path $Package "$product.cat"
        [void](New-FileCatalog -Path $Package -CatalogFilePath $catalog -CatalogVersion 2.0)
        $result = Set-AuthenticodeSignature -LiteralPath $catalog -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256
        if ($result.Status -ne 'Valid') { throw "Signing the file catalog gave status '$($result.Status)': $($result.StatusMessage)" }
        Write-Host "$Edition`: signed $signed script(s) and the file catalog as '$($certificate.Subject)'."
    }
    [IO.Compression.ZipFile]::CreateFromDirectory($Package, $ZipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    $signed
}

$staging = Join-Path ([IO.Path]::GetTempPath()) "TkRelease_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    # 1. Exactly what is committed at $Ref.
    $archive = "$staging.zip"
    git -C $root archive --format=zip -o $archive $commit
    if ($LASTEXITCODE) { throw "git archive failed for $Ref." }
    $base = Join-Path $staging 'base'
    Expand-Archive -LiteralPath $archive -DestinationPath $base
    Remove-Item -LiteralPath $archive -Force
    foreach ($item in $devOnly) {
        $path = Join-Path $base $item
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    # Older commits may still contain modules that are private now: apply today's .gitignore to them.
    foreach ($module in Get-ChildItem -LiteralPath (Join-Path $base 'Modules') -Directory -ErrorAction SilentlyContinue) {
        git -C $root check-ignore -q --no-index "Modules/$($module.Name)/module.json"
        if (-not $LASTEXITCODE) {
            Write-Warning "Left out Modules\$($module.Name): it is git-ignored (private) now."
            Remove-Item -LiteralPath $module.FullName -Recurse -Force
        }
    }
    Assert-NoTenantData $base
    [IO.File]::WriteAllText((Join-Path $base 'VERSION'), "$Version`r`n")
    $fullModules = @(Get-ChildItem -LiteralPath (Join-Path $base 'Modules') -Directory -ErrorAction SilentlyContinue | Where-Object Name -notin $coreModules | ForEach-Object Name)
    if (-not $fullModules.Count) { Write-Warning 'No modules beyond the samples are committed: the Full edition is the same as Core.' }

    # 2.-4. One package per edition, each signed and zipped on its own.
    if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath -Force) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $signed = 0
    $hashes = [ordered]@{}
    foreach ($edition in $zipPaths.Keys) {
        $package = Join-Path $staging "$edition\$product"
        [void](New-Item -ItemType Directory -Path (Split-Path $package -Parent))
        Copy-Item -LiteralPath $base -Destination $package -Recurse
        if ($edition -eq 'Core') {
            foreach ($module in Get-ChildItem -LiteralPath (Join-Path $package 'Modules') -Directory -ErrorAction SilentlyContinue | Where-Object Name -notin $coreModules) {
                Remove-Item -LiteralPath $module.FullName -Recurse -Force
            }
            # Same signed copy as in the ZIP: it trusts only toolkit scripts signed by its own signer.
            $corePackage = $package
        }
        $signed += New-EditionZip -Package $package -Edition $edition -ZipPath $zipPaths[$edition]
        $hashes[$edition] = (Get-FileHash -LiteralPath $zipPaths[$edition] -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    # sha256sum format ("<hash>  <file>"), so `sha256sum -c` works too.
    $sums = foreach ($edition in $zipPaths.Keys) { "$($hashes[$edition])  $(Split-Path $zipPaths[$edition] -Leaf)`n" }
    [IO.File]::WriteAllText($sumsPath, (-join $sums), (New-Object Text.UTF8Encoding $false))
    $bootstrap = Join-Path $corePackage 'Get-AdminToolkit.ps1'
    if (Test-Path -LiteralPath $bootstrap) { Copy-Item -LiteralPath $bootstrap -Destination $bootstrapPath }
    else { $bootstrapPath = $null }
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

Write-Host "Release $Version from $($commit.Substring(0, 7)):"
Write-Host "  Core: $($zipPaths.Core)"
Write-Host "        SHA-256 $($hashes.Core)"
Write-Host "  Full: $($zipPaths.Full) ($($fullModules.Count) module(s) beyond the samples)"
Write-Host "        SHA-256 $($hashes.Full)"
if ($bootstrapPath) { Write-Host "  $bootstrapPath" }
if (-not $certificate) { Write-Host '  Unsigned: the scripts carry no publisher signature (checksum only). Get-AdminToolkit.ps1 refuses unsigned builds.' }
[pscustomobject]@{
    Version = $Version; Commit = $commit
    Zip = $zipPaths.Core; Sha256 = $hashes.Core
    FullZip = $zipPaths.Full; FullSha256 = $hashes.Full; FullModules = $fullModules
    ChecksumFile = $sumsPath; Bootstrap = $bootstrapPath; SignedFiles = $signed
}
