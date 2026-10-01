#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a release ZIP of the toolkit plus a SHA-256 checksum file, optionally Authenticode-signing
    the PowerShell scripts first.

.DESCRIPTION
    Follows the usual order for publishing software:
      1. Package exactly one committed version (git archive of tag v<Version>), so local edits and
         git-ignored private modules never ship. Tests and notes for Claude are left out.
      2. Optionally sign every .ps1/.psm1 with a code-signing certificate, timestamped so the
         signatures stay valid after the certificate expires. Fails if any signature isn't Valid.
      3. Zip, then hash the final ZIP into SHA256SUMS.txt (sha256sum format).
    Publish the ZIP and SHA256SUMS.txt together, e.g. as assets of the GitHub release for the tag.
    An existing version is never overwritten: published files must not change.

.PARAMETER Version
    Semantic version, e.g. 1.0.0 or 1.1.0-beta.1. Written into the package as VERSION.

.PARAMETER Ref
    Commit or tag to package. Defaults to the tag v<Version>. Use HEAD only for test builds.

.PARAMETER OutputPath
    Folder for the ZIP and checksum file. Defaults to .\Release (git-ignored).

.PARAMETER CertificateThumbprint
    Thumbprint of a code-signing certificate (with private key) in Cert:\CurrentUser\My.
    Omit to build an unsigned release (checksum only).

.PARAMETER TimestampServer
    RFC 3161 timestamp server used when signing.

.EXAMPLE
    git tag -a v1.0.0 -m "M365 Admin Toolkit 1.0.0"
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
    [string] $TimestampServer = 'http://timestamp.digicert.com'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $root 'Release' }
if (-not $Ref) { $Ref = "v$Version" }
$name = "M365AdminToolkit-$Version"
$zipPath = Join-Path $OutputPath "$name.zip"
$sumsPath = Join-Path $OutputPath "$name.SHA256SUMS.txt"
# In the repository for development only; not part of what users run.
$devOnly = 'Tests', 'CLAUDE.md', '.gitattributes', '.gitignore'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is needed to package a committed version.' }
$commit = git -C $root rev-parse --verify --quiet "$Ref^{commit}"
if ($LASTEXITCODE -or -not $commit) {
    throw "'$Ref' is not a commit or tag. Commit your changes, then tag the release: git tag -a v$Version -m 'M365 Admin Toolkit $Version'"
}
if ((Test-Path -LiteralPath $zipPath) -or (Test-Path -LiteralPath $sumsPath)) {
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

$staging = Join-Path ([IO.Path]::GetTempPath()) "TkRelease_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    # 1. Exactly what is committed at $Ref.
    $archive = "$staging.zip"
    git -C $root archive --format=zip -o $archive $commit
    if ($LASTEXITCODE) { throw "git archive failed for $Ref." }
    $package = Join-Path $staging 'M365AdminToolkit'
    Expand-Archive -LiteralPath $archive -DestinationPath $package
    Remove-Item -LiteralPath $archive -Force
    foreach ($item in $devOnly) {
        $path = Join-Path $package $item
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
    }
    # Older commits may still contain modules that are private now: apply today's .gitignore to them.
    foreach ($module in Get-ChildItem -LiteralPath (Join-Path $package 'Modules') -Directory -ErrorAction SilentlyContinue) {
        git -C $root check-ignore -q --no-index "Modules/$($module.Name)/module.json"
        if (-not $LASTEXITCODE) {
            Write-Warning "Left out Modules\$($module.Name): it is git-ignored (private) now."
            Remove-Item -LiteralPath $module.FullName -Recurse -Force
        }
    }
    [IO.File]::WriteAllText((Join-Path $package 'VERSION'), "$Version`r`n")

    # 2. Sign before zipping: the checksum must cover the signed files.
    $signed = 0
    if ($certificate) {
        foreach ($file in Get-ChildItem -LiteralPath $package -Recurse -File -Include *.ps1, *.psm1) {
            $result = Set-AuthenticodeSignature -LiteralPath $file.FullName -Certificate $certificate -TimestampServer $TimestampServer -HashAlgorithm SHA256
            if ($result.Status -ne 'Valid') {
                throw "Signing $($file.Name) gave status '$($result.Status)': $($result.StatusMessage). Is the certificate's root trusted on this PC?"
            }
            $signed++
        }
        Write-Host "Signed $signed script(s) as '$($certificate.Subject)'."
    }

    # 3. Zip and hash.
    if (-not (Test-Path -LiteralPath $OutputPath)) { [void](New-Item -ItemType Directory -Path $OutputPath -Force) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($package, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    # sha256sum format ("<hash>  <file>"), so `sha256sum -c` works too.
    [IO.File]::WriteAllText($sumsPath, "$hash  $name.zip`n", (New-Object Text.UTF8Encoding $false))
}
finally {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
}

Write-Host "Release $Version from $($commit.Substring(0, 7)):"
Write-Host "  $zipPath"
Write-Host "  SHA-256 $hash"
if (-not $certificate) { Write-Host '  Unsigned: the scripts carry no publisher signature (checksum only).' }
[pscustomobject]@{ Version = $Version; Commit = $commit; Zip = $zipPath; Sha256 = $hash; ChecksumFile = $sumsPath; SignedFiles = $signed }
