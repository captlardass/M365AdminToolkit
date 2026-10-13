# Module contract (checked by Tools\Test-ToolkitModules.ps1 and at GUI start):
#   * Every parameter in module.json exists in this param() block, with the same name.
#   * SupportsWhatIf in module.json  <=>  [CmdletBinding(SupportsShouldProcess)] here,
#     and every change is wrapped in $PSCmdlet.ShouldProcess(...).
#   * Connections listed under "Requires" are made for you before this script runs.
#   * Emit one object per result; they become the grid rows and CSV export.
#   * Log with Write-Information / Write-Warning. Throw to fail the whole run.
#   * Never prompt (Read-Host, Get-Credential) - the script runs without a console.
#   * If the script can prove a security-posture factor ("X of Y are OK"), report it once at the end:
#       if (Test-Path Function:\Write-TkReadiness) { Write-TkReadiness -Ready $ok -Total $checked -Label 'users are compliant' }
#     Count everything checked, not only the rows you output; items you couldn't check go in -NotEvaluated.
#     Optional thresholds in module.json: "Readiness": { "Pass": 90, "Warn": 70 }.
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string[]] $Identities,
    [ValidateSet('Report', 'Fix')] [string] $Mode = 'Report'
)

foreach ($identity in $Identities) {
    $status = 'Checked'
    if ($Mode -eq 'Fix') {
        if ($PSCmdlet.ShouldProcess($identity, 'Apply fix')) {
            # Make the change here.
            $status = 'Fixed'
        }
        else {
            $status = 'WhatIf'
        }
    }
    [pscustomobject]@{ Identity = $identity; Mode = $Mode; Status = $status }
}
