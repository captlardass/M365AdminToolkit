#Requires -Version 5.1
<#
.SYNOPSIS
    Creates a new toolkit module - from an existing script, or from Modules\_Template.
    Same engine as the GUI's "+ Add module" button.

.EXAMPLE
    .\Tools\New-ToolkitModule.ps1 -Id Exchange.SharedSentItems -Name 'Shared mailbox sent items' -Category 'Exchange Online' -FromScript C:\Scripts\Set-SentItems.ps1 -ExchangeOnline -Tags 'Shared mailbox', 'Bulk change'

.EXAMPLE
    .\Tools\New-ToolkitModule.ps1 -Id Entra.LicenseReport -Name 'License report' -Category 'Entra ID' -GraphScopes User.Read.All, Organization.Read.All -Tags Licensing, Report
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $Id,
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Category,
    [string] $Description,
    [string[]] $Tags = @(),
    [string] $FromScript,
    [switch] $ExchangeOnline,
    [string[]] $GraphScopes = @(),
    [switch] $ReadOnly
)

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'Core\Toolkit.Core.psm1') -Force

if ($FromScript) {
    $analysis = Get-TkScriptAnalysis -Path $FromScript
    foreach ($warning in $analysis.Warnings) { Write-Warning $warning }
    if ($analysis.UsesExchange -and -not $ExchangeOnline) { Write-Warning 'The script looks like it uses Exchange Online - did you mean to pass -ExchangeOnline?' }
    if ($analysis.GraphScopes -and -not $GraphScopes) {
        Write-Host "Using Graph scopes found in the script: $($analysis.GraphScopes -join ', ')"
        $GraphScopes = $analysis.GraphScopes
    }
}

# -WhatIf must be passed on explicitly: preference variables don't flow from a script into module functions.
$module = New-TkModule -ModulesPath (Join-Path $root 'Modules') -Id $Id -Name $Name -Category $Category `
    -Description $Description -Tags $Tags -ScriptPath $FromScript -ExchangeOnline:$ExchangeOnline -GraphScopes $GraphScopes `
    -ReadOnly:$ReadOnly `
    -WhatIf:$WhatIfPreference

if ($module) {
    Write-Host "Created $($module.Directory) with $($module.Parameters.Count) input(s)." -ForegroundColor Green
    Write-Host 'Review module.json (labels, help texts) and module.ps1, then run .\Tools\Test-ToolkitModules.ps1'
}
