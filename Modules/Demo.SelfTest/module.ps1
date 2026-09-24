[CmdletBinding(SupportsShouldProcess)]
param(
    [int] $Count = 8,
    [string] $Prefix = 'demo',
    [ValidateSet('IT', 'Finance', 'Sales')] [string] $Department = 'IT',
    [bool] $EmitWarning = $true,
    [bool] $Fail = $false
)

Write-Information "Generating $Count sample row(s) for department $Department..."

for ($i = 1; $i -le $Count; $i++) {
    # Dummy identities only - contoso.example is a reserved, non-routable domain.
    $upn = '{0}-user{1:D2}@contoso.example' -f $Prefix, $i

    $action = if ($PSCmdlet.ShouldProcess($upn, 'Pretend to update department')) { 'Updated' } else { 'WhatIf' }

    [pscustomobject]@{
        Index             = $i
        UserPrincipalName = $upn
        Department        = $Department
        Licensed          = ($i % 2 -eq 0)
        Groups            = @('All Staff', "$Department Team")
        Action            = $action
        Timestamp         = Get-Date
    }
    Start-Sleep -Milliseconds 300
}

if ($EmitWarning) { Write-Warning 'This is what a warning looks like in the log.' }
if ($Fail) { throw 'Failure requested - this is how a terminating error surfaces.' }

Write-Information 'Self-test complete.'
