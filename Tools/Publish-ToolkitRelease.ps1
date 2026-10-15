#Requires -Version 5.1
<#
.SYNOPSIS
    Publishes a release built by New-ToolkitRelease.ps1 as a GitHub release (needs the GitHub CLI, gh).

.DESCRIPTION
    Uploads four assets to a new release for the tag v<Version>:
      M365AdminToolkit-<Version>.zip       Core edition: the program with only the sample modules
      M365AdminToolkit-<Version>-Full.zip  Full edition: the program with every bundled module
      M365AdminToolkit-<Version>.SHA256SUMS.txt and Get-M365AdminToolkit.ps1.
    The release notes explain which edition to pick and list the Full modules, read from the
    module.json files inside the Full ZIP, so they always match what ships.
    Before uploading it checks that both ZIPs still match their checksums and that the scripts are
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
$fullZip = Join-Path $OutputPath "$name-Full.zip"
$sums = Join-Path $OutputPath "$name.SHA256SUMS.txt"
$bootstrap = Join-Path $OutputPath "$name.Get-M365AdminToolkit.ps1"
$coreModules = '_Template', 'Demo.SelfTest'

function Get-ZipModule([string] $Path, [string[]] $Exclude) {
    <# The module.json of every module in a release ZIP except the folders in -Exclude, sorted by category and name. #>
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $manifests = foreach ($entry in $archive.Entries) {
            if (($entry.FullName -replace '\\', '/') -notmatch '^M365AdminToolkit/Modules/([^/]+)/module\.json$' -or $Matches[1] -in $Exclude) { continue }
            $reader = New-Object IO.StreamReader ($entry.Open())
            try { $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        }
    }
    finally { $archive.Dispose() }
    $manifests | Sort-Object Category, Name
}

function Format-Cell([string] $Text) { ($Text -replace '\r?\n', ' ' -replace '\|', '\|').Trim() }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is needed: https://cli.github.com, then run gh auth login.' }
foreach ($file in $zip, $fullZip, $sums, $bootstrap) {
    if (-not (Test-Path -LiteralPath $file)) { throw "$file is missing. Build it first: .\Tools\New-ToolkitRelease.ps1 -Version $Version" }
}

# The files must be exactly what was built and hashed.
$hashes = @{}
foreach ($file in $zip, $fullZip) {
    $leaf = Split-Path $file -Leaf
    $expected = $null
    foreach ($line in [IO.File]::ReadAllLines($sums)) {
        if ($line -match '^([0-9a-fA-F]{64}) [ *](.+)$' -and $Matches[2].Trim() -eq $leaf) { $expected = $Matches[1].ToLowerInvariant() }
    }
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "$leaf no longer matches its checksum file. Don't publish it." }
    $hashes[$leaf] = $actual
}

$signature = Get-AuthenticodeSignature -LiteralPath $bootstrap
if ($signature.Status -ne 'Valid') {
    if (-not $AllowUnsigned) { throw "Get-M365AdminToolkit.ps1 is not validly signed ($($signature.Status)). Build with -CertificateThumbprint, or pass -AllowUnsigned." }
    Write-Warning 'Publishing an UNSIGNED build: Get-M365AdminToolkit.ps1 will refuse to install it without -AllowUnsigned.'
}

gh release view $tag --repo $repository *> $null
if (-not $LASTEXITCODE) { throw "Release $tag already exists on GitHub. Published versions must not change - use a new version number." }

# Upload under the stable name, so .../releases/latest/download/Get-M365AdminToolkit.ps1 always works.
$upload = Join-Path ([IO.Path]::GetTempPath()) "TkPublish_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
# -WhatIf:$false: a local scratch folder, needed to preview the notes under -WhatIf too.
[void](New-Item -ItemType Directory -Path $upload -WhatIf:$false)
try {
    $bootstrapAsset = Join-Path $upload 'Get-M365AdminToolkit.ps1'
    Copy-Item -LiteralPath $bootstrap -Destination $bootstrapAsset -WhatIf:$false
    $modules = @(Get-ZipModule $fullZip -Exclude $coreModules)
    $lines = @(
        '## Which download?', '',
        '| Edition | File | What you get |', '|---|---|---|',
        "| **Full** | ``$name-Full.zip`` | The toolkit with $($modules.Count) ready-made modules (listed below). Pick this to start using it straight away. |",
        "| **Core** | ``$name.zip`` | The toolkit with only the module template and a self-test. Pick this to build your own modules from scratch. |",
        '',
        'Both editions have the same program; only the modules differ. Modules you add yourself are kept when you upgrade, whichever edition you install.',
        '', '## Install', '',
        'Download **Get-M365AdminToolkit.ps1** and run it in a normal (not elevated) PowerShell window. It asks which edition you want, then checks the SHA-256 and the publisher signature before installing for your user account. For scripted installs: `Get-M365AdminToolkit.ps1 -Edition Full -NoGui` (or `-Edition Core`).',
        '', "## Modules in the Full edition", '',
        '| Module | Category | Type | What it does |', '|---|---|---|---|')
    $lines += foreach ($module in $modules) {
        $type = if ($module.ReadOnly) { 'Read-only' } elseif ($module.SupportsWhatIf) { 'Changes (dry run first)' } else { 'Changes' }
        '| {0} | {1} | {2} | {3} |' -f (Format-Cell $module.Name), (Format-Cell $module.Category), $type, (Format-Cell $module.Description)
    }
    if (-not $modules.Count) { $lines += '| - | - | - | No modules beyond the samples in this release. |' }
    $lines += '', '## SHA-256', '', '```'
    $lines += foreach ($leaf in $hashes.Keys | Sort-Object) { "$($hashes[$leaf])  $leaf" }
    $lines += '```'
    $notes = ($lines -join "`n") + "`n"
    if ($WhatIfPreference) { Write-Host "Release notes:`n$notes" }
    # A file, not --notes: Windows PowerShell 5.1 mangles double quotes in arguments to native programs.
    $notesFile = Join-Path $upload 'notes.md'
    [IO.File]::WriteAllText($notesFile, $notes, (New-Object Text.UTF8Encoding $false))
    $arguments = @('release', 'create', $tag, $zip, $fullZip, $sums, $bootstrapAsset, '--repo', $repository, '--verify-tag', '--draft',
        '--title', "M365 Admin Toolkit $Version", '--notes-file', $notesFile)
    if ($Version -like '*-*') { $arguments += '--prerelease' }

    if ($PSCmdlet.ShouldProcess("$repository $tag", 'Create GitHub release and upload 4 assets (Core and Full)')) {
        # --verify-tag: the tag must already be pushed, so the release points at the commit that was built.
        & gh @arguments
        if ($LASTEXITCODE) { throw "gh release create failed. A draft may be left on GitHub: check https://github.com/$repository/releases" }
        & gh release edit $tag --repo $repository --draft=false
        if ($LASTEXITCODE) { throw "Uploaded, but publishing the draft failed. Publish it on https://github.com/$repository/releases" }
        Write-Host "Published ${tag}: https://github.com/$repository/releases/tag/$tag"
    }
}
finally { Remove-Item -LiteralPath $upload -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false }
