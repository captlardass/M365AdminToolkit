# Fake stand-in for a Microsoft Graph module (name matters: guard matches on module name).
function Get-MgFakeUser { param([string] $UserId = 'all') 1..2 | ForEach-Object { [pscustomobject]@{ Id = "user$_"; UserPrincipalName = "user$_@contoso.example" } } }
function Update-MgFakeUser {
    [CmdletBinding()]
    param([Parameter(ValueFromPipelineByPropertyName)] [string] $Id, [string] $Department, [hashtable] $BodyParameter)
    process { Add-Content -LiteralPath $env:TK_PROBE_LOG -Value "EXECUTED Update-MgFakeUser $Id $Department" }
}
function New-MgFakeUser { param([string] $DisplayName) Add-Content -LiteralPath $env:TK_PROBE_LOG -Value "EXECUTED New-MgFakeUser $DisplayName"; [pscustomobject]@{ Id = 'new' } }
Export-ModuleMember -Function Get-MgFakeUser, Update-MgFakeUser, New-MgFakeUser
