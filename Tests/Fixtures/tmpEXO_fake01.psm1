# Fake stand-in for the Exchange Online temp module (EXO v3 names it tmpEXO_xxxx).
function New-InternalContext { @{ Session = 'ok' } }     # private helper with a 'write' verb - reads must still work
function Get-Mailbox { param([string] $Identity) $ctx = New-InternalContext; [pscustomobject]@{ Identity = $Identity; Ctx = $ctx.Session } }
function Set-Mailbox {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(ValueFromPipelineByPropertyName)] [string] $Identity, [bool] $MessageCopyForSentAsEnabled)
    process { Add-Content -LiteralPath $env:TK_PROBE_LOG -Value "EXECUTED Set-Mailbox $Identity" }
}
Export-ModuleMember -Function Get-Mailbox, Set-Mailbox
