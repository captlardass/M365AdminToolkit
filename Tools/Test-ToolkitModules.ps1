#Requires -Version 5.1
<#
.SYNOPSIS
    Validates every module against the toolkit contract, without starting the GUI.

.DESCRIPTION
    Same checks the GUI runs at start-up: manifest fields, parameter types, and that
    module.json matches the entry script's param() block. Exits 1 if anything is invalid,
    so it can gate a pull request.

.EXAMPLE
    .\Tools\Test-ToolkitModules.ps1
#>
[CmdletBinding()]
param(
    [string] $ModulesPath,
    [switch] $IncludeTemplate
)

if (-not $ModulesPath) { $ModulesPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'Modules' }
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'Core\Toolkit.Core.psm1') -Force

$modules = @(Get-TkModule -Path $ModulesPath)

if ($IncludeTemplate) {
    $templateDir = Join-Path $ModulesPath '_Template'
    $manifest = Get-Content (Join-Path $templateDir 'module.json') -Raw | ConvertFrom-Json
    $problems = @(Test-TkManifest -Manifest $manifest -ModuleDirectory $templateDir)
    $modules += [pscustomobject]@{ Id = '_Template'; Version = $manifest.Version; IsValid = $problems.Count -eq 0; Errors = $problems }
}

$modules | Sort-Object Id | Format-Table Id, Version, IsValid, @{ Name = 'Problems'; Expression = { $_.Errors -join ' | ' } } -AutoSize -Wrap

$invalid = @($modules | Where-Object { -not $_.IsValid })
if ($invalid) {
    Write-Host "$($invalid.Count) of $($modules.Count) module(s) are invalid." -ForegroundColor Red
    exit 1
}
Write-Host "All $($modules.Count) module(s) are valid." -ForegroundColor Green
