#Requires -Version 5.1
<#
.SYNOPSIS
    Runs every headless test suite: module contract validation, the dry-run change guard and
    the script viewer. Exits 1 on any failure, so it can gate changes.

.DESCRIPTION
    Nothing here touches a tenant: the guard suite uses fake Graph and Exchange modules from
    Tests\Fixtures and a probe file to prove that blocked changes never execute.

.EXAMPLE
    .\Tools\Invoke-ToolkitTests.ps1
#>
[CmdletBinding()]
param()

$root = Split-Path $PSScriptRoot -Parent
$global:TkTestFailures = 0

Write-Host '== Module contract' -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'Test-ToolkitModules.ps1') -IncludeTemplate
if ($LASTEXITCODE) { $global:TkTestFailures++ }

foreach ($suite in 'Guard', 'Viewer', 'Inventory') {
    Write-Host "== $suite suite" -ForegroundColor Cyan
    # Each suite in its own process: the guard hooks command lookup and must start from a clean runspace.
    powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File (Join-Path $root "Tests\$suite.Tests.ps1") -Root $root |
        Out-String -Stream | Where-Object { $_.Trim() } | ForEach-Object {
            if ($_ -match '^\s*FAIL') { Write-Host $_ -ForegroundColor Red; $global:TkTestFailures++ }
            elseif ($_ -match 'passed, (\d+) failed') { Write-Host $_ -ForegroundColor $(if ($Matches[1] -eq '0') { 'Green' } else { 'Red' }) }
            elseif ($_ -match '^\s*PASS') { Write-Verbose $_ }
        }
}

if ($global:TkTestFailures) {
    Write-Host "$($global:TkTestFailures) failure(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'All suites passed.' -ForegroundColor Green
