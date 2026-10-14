#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes a release built by New-ToolkitRelease.ps1 as a GitHub release (needs the GitHub CLI, gh).

.DESCRIPTION
    Uploads three assets to a new release for the tag v<Version>:
      M365AdminToolkit-<Version>.zip, M365AdminToolkit-<Version>.SHA256SUMS.txt and Get-M365AdminToolkit.ps1.
    Before uploading it checks that the ZIP still matches its checksum and that the scripts are
    validly signed (Get-M365AdminToolkit.ps1 refuses unsigned packages anyway).
    The release is created as a draft, the assets are attached, then it is published, so with
    GitHub's immutable releases turned on nothing can be added or swapped afterwards.
    An existing release is never changed: published versions must not change.

.PARAMETER Version
    The version that was built, e.g. 1.2.0. Versions with a suffix (1.2.0-beta.1) become prereleases.

.PARAMETER OutputPath
    Folder with the built files. Defaults to .\Release.

.PARAMETER AllowUnsigned
    Publish an unsigned build anyway (users then have to verify it by hand).

.EXAMPLE
    .\Tools\Publish-ToolkitRelease.ps1 -Version 1.2.0 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')] [string] $Version,
    [string] $OutputPath,
    [switch] $AllowUnsigned
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $root 'Release' }
$repository = 'captlardass/M365AdminToolkit'
$tag = "v$Version"
$name = "M365AdminToolkit-$Version"
$zip = Join-Path $OutputPath "$name.zip"
$sums = Join-Path $OutputPath "$name.SHA256SUMS.txt"
$bootstrap = Join-Path $OutputPath "$name.Get-M365AdminToolkit.ps1"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is needed: https://cli.github.com, then run gh auth login.' }
foreach ($file in $zip, $sums, $bootstrap) {
    if (-not (Test-Path -LiteralPath $file)) { throw "$file is missing. Build it first: .\Tools\New-ToolkitRelease.ps1 -Version $Version" }
}

# The files must be exactly what was built and hashed.
$expected = ([IO.File]::ReadAllText($sums) -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "$name.zip no longer matches its checksum file. Don't publish it." }

$signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
if ($signature.Status -ne 'Valid') {
    if (-not $AllowUnsigned) { throw "Get-M365AdminToolkit.ps1 is not validly signed ($($signature.Status)). Build with -CertificateThumbprint, or pass -AllowUnsigned." }
    Write-Warning 'Publishing an UNSIGNED build: Get-M365AdminToolkit.ps1 will refuse to install it without -AllowUnsigned.'
}

gh release view $tag --repo $repository *> $null
if (-not $LASTEXITCODE) { throw "Release $tag already exists on GitHub. Published versions must not change - use a new version number." }

# Upload under the stable name, so .../releases/latest/download/Get-M365AdminToolkit.ps1 always works.
$upload = Join-Path ([IO.Path]::GetTempPath()) "TkPublish_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
[void](New-Item -ItemType Directory -Path $upload)
try {
    $bootstrapAsset = Join-Path $upload 'Get-M365AdminToolkit.ps1'
    Copy-Item -LiteralPath $bootstrap -Destination $bootstrapAsset
    $notes = "SHA-256 of $name.zip: ``$actual```n`nInstall: download **Get-M365AdminToolkit.ps1** and run it. It verifies the checksum and the publisher signature before installing for your user account."
    $arguments = @('release', 'create', $tag, $zip, $sums, $bootstrapAsset, '--repo', $repository, '--verify-tag', '--draft',
        '--title', "M365 Admin Toolkit $Version", '--notes', $notes)
    if ($Version -like '*-*') { $arguments += '--prerelease' }

    if ($PSCmdlet.ShouldProcess("$repository $tag", 'Create GitHub release and upload 3 assets')) {
        # --verify-tag: the tag must already be pushed, so the release points at the commit that was built.
        & gh @arguments
        if ($LASTEXITCODE) { throw "gh release create failed. A draft may be left on GitHub: check https://github.com/$repository/releases" }
        & gh release edit $tag --repo $repository --draft=false
        if ($LASTEXITCODE) { throw "Uploaded, but publishing the draft failed. Publish it on https://github.com/$repository/releases" }
        Write-Host "Published ${tag}: https://github.com/$repository/releases/tag/$tag"
    }
}
finally { Remove-Item -LiteralPath $upload -Recurse -Force -ErrorAction SilentlyContinue }
