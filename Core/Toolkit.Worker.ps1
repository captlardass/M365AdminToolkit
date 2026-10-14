<#
    Toolkit.Worker - dot-sourced into the background worker runspace at startup.

    The worker owns the Microsoft 365 connections. Because it is one long-lived runspace,
    a Graph or Exchange sign-in done for one module is reused by the next.

    This is deliberately a dot-sourced script rather than a .psm1: Connect-ExchangeOnline
    imports its generated cmdlets into the caller's session state, and we want them in the
    worker's global scope where module scripts can see them.

    $global:TkSettings (Config\settings.json) is set by New-TkWorker.
#>

# Module authors (and these helpers) log with Write-Information; make sure it reaches the GUI log.
$global:InformationPreference = 'Continue'

function Assert-TkInstalled {
    param([Parameter(Mandatory)] [string] $Name)
    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "The PowerShell module '$Name' is not installed. Install it with: Install-Module $Name -Scope CurrentUser"
    }
}

function Get-TkSetting {
    param([Parameter(Mandatory)] [string] $Section)
    if ($global:TkSettings -and $global:TkSettings.PSObject.Properties[$Section]) { $global:TkSettings.$Section }
}

#region Sign-in session policy
<#
    The toolkit works in customer tenants, so a sign-in is trusted only for the toolkit launch
    that made it, and only until the first of:
      * midnight (the calendar day changes),
      * Session.MaxAgeHours after sign-in (settings.json, default 8),
      * Session.IdleMinutes without a module run or connect (default 60),
      * the PC sleeping or hibernating,
      * the system clock going backwards.
    Nothing outlives a launch: Graph signs in with -ContextScope Process (in-memory token cache),
    and WAM - the Windows sign-in broker, which silently hands back an account's tokens even after
    a restart - is bypassed, so the browser asks which account to use. A connection this launch
    did not make (Graph and Exchange keep theirs in process-wide state) is ended before use.

    Every session is pinned to one tenant. A sign-in to a different tenant, or a check that cannot
    tell, signs everything out. All checks fail closed: when in doubt, sign out.
#>

$global:TkSession = $null           # set by Register-TkSignIn, cleared by Disconnect-TkAll
$global:TkSignOutReason = ''        # why the toolkit last ended a session; read once by Get-TkConnectionStatus

if (-not ('TkNative.Clock' -as [type])) {
    # Without it Get-TkAwakeTime returns nothing and every session check fails closed.
    try { Add-Type -Namespace TkNative -Name Clock -ErrorAction Stop -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool QueryUnbiasedInterruptTime(out ulong UnbiasedTime);' }
    catch { }
}

function Get-TkAwakeTime {
    <# 100 ns ticks the PC has been awake since boot (sleep and hibernation excluded), or nothing if unknown. #>
    if (-not ('TkNative.Clock' -as [type])) { return }
    $ticks = [uint64]0
    if ([TkNative.Clock]::QueryUnbiasedInterruptTime([ref]$ticks)) { [long]$ticks }
}

function Get-TkSessionPolicy {
    <# Session limits from settings.json; missing or out-of-range values fall back to the defaults. #>
    $cfg = Get-TkSetting 'Session'
    $maxAge = 8
    $idle = 60
    if ($cfg) {
        $v = $cfg.MaxAgeHours -as [double]
        if ($v -gt 0 -and $v -le 24) { $maxAge = $v }
        $v = $cfg.IdleMinutes -as [double]
        if ($v -gt 0 -and $v -le 1440) { $idle = $v }
    }
    [pscustomobject]@{ MaxAgeHours = $maxAge; IdleMinutes = $idle }
}

function Set-TkSessionLimit {
    <# Applies limits saved from Settings to this worker at once (Get-TkSessionPolicy still validates them). #>
    param([Parameter(Mandatory)] [double] $MaxAgeHours, [Parameter(Mandatory)] [double] $IdleMinutes)
    if (-not $global:TkSettings) { $global:TkSettings = [pscustomobject]@{} }
    $global:TkSettings | Add-Member -NotePropertyName Session -Force -NotePropertyValue ([pscustomobject]@{ MaxAgeHours = $MaxAgeHours; IdleMinutes = $IdleMinutes })
    $p = Get-TkSessionPolicy
    Write-Information "Session limits: sign out $($p.MaxAgeHours) hour(s) after sign-in, or after $($p.IdleMinutes) minute(s) without use."
}

function New-TkSession {
    param([Parameter(Mandatory)] [string] $TenantId, [datetime] $Now = (Get-Date), $AwakeTime = (Get-TkAwakeTime))
    [pscustomobject]@{ TenantId = $TenantId; TenantName = ''; SignedIn = $Now; LastUsed = $Now; AwakeAtSignIn = $AwakeTime }
}

function Get-TkSessionExpiry {
    <#
    .SYNOPSIS
        Why a session may no longer be used, or nothing while it is still valid.
        The clock readings are parameters so tests can move time.
    #>
    param($Session, [datetime] $Now = (Get-Date), $AwakeTime = (Get-TkAwakeTime), $Policy = (Get-TkSessionPolicy))

    if (-not $Session) { return 'the connection was not made by this toolkit session' }
    if ($Now -lt $Session.SignedIn -or $Now -lt $Session.LastUsed) { return 'the system clock went backwards' }
    if ($Now.Date -ne $Session.SignedIn.Date) { return 'a new day has started (sessions end at midnight)' }
    # UTC for durations, so a daylight-saving change is not taken for elapsed time.
    $age = $Now.ToUniversalTime() - $Session.SignedIn.ToUniversalTime()
    if ($age.TotalHours -ge $Policy.MaxAgeHours) { return "it is more than $($Policy.MaxAgeHours) hour(s) since sign-in" }
    if (($Now.ToUniversalTime() - $Session.LastUsed.ToUniversalTime()).TotalMinutes -ge $Policy.IdleMinutes) {
        return "it was idle for more than $($Policy.IdleMinutes) minute(s)"
    }
    if ($null -eq $AwakeTime -or $null -eq $Session.AwakeAtSignIn) { return 'sleep or hibernation since sign-in cannot be ruled out' }
    # Wall-clock time minus awake time = time asleep. Allow drift between the two clocks; a real sleep is longer.
    $asleep = $age - [TimeSpan]::FromTicks([long]$AwakeTime - [long]$Session.AwakeAtSignIn)
    if ($asleep.TotalSeconds -gt 120) { return 'the PC has been asleep or hibernated since sign-in' }
}

function Get-TkSessionEnd {
    <# When the session ends at the latest, if nothing else (idle, sleep) ends it sooner. #>
    param([Parameter(Mandatory)] $Session, $Policy = (Get-TkSessionPolicy))
    $midnight = $Session.SignedIn.Date.AddDays(1)
    $maxAge = $Session.SignedIn.AddHours($Policy.MaxAgeHours)
    if ($maxAge -lt $midnight) { $maxAge } else { $midnight }
}

function Test-TkGraphConnected {
    [bool]((Get-Module Microsoft.Graph.Authentication) -and (Get-MgContext))
}

function Test-TkExchangeConnected {
    if (-not (Get-Module ExchangeOnlineManagement)) { return $false }
    $sessions = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' })
    $sessions.Count -gt 0
}

function Get-TkTenantId {
    <# The tenant ID(s) a service is signed in to. Exchange can hold several connections, so this may return more than one. #>
    param([Parameter(Mandatory)] [ValidateSet('Graph', 'Exchange')] [string] $Service)
    if ($Service -eq 'Graph') {
        if (Test-TkGraphConnected) { [string](Get-MgContext).TenantId }
        return
    }
    if (Test-TkExchangeConnected) {
        Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' } |
            ForEach-Object { [string]$_.TenantID } | Sort-Object -Unique
    }
}

function Get-TkTenantName {
    <#
        The tenant's display name, asked of the tenant itself. Never derived from the account's domain:
        with delegated admin (GDAP) the account belongs to another tenant than the one being managed.
    #>
    if (Test-TkGraphConnected) {
        try {
            $org = (Invoke-MgGraphRequest -Method GET -Uri 'v1.0/organization?$select=id,displayName' -OutputType PSObject -ErrorAction Stop).value | Select-Object -First 1
            if ($org.displayName) { return [string]$org.displayName }
        }
        catch { Write-Verbose "Tenant name from Graph: $($_.Exception.Message)" }
    }
    if ((Test-TkExchangeConnected) -and (Get-Command Get-OrganizationConfig -ErrorAction SilentlyContinue)) {
        try {
            $name = [string](Get-OrganizationConfig -ErrorAction Stop).DisplayName
            if ($name) { return $name }
        }
        catch { Write-Verbose "Tenant name from Exchange: $($_.Exception.Message)" }
    }
    ''
}

function Register-TkSignIn {
    <#
    .SYNOPSIS
        Called after every connect: starts the session on the first sign-in and pins it to that tenant.
        A sign-in to another tenant - or one whose tenant cannot be read - signs everything out.
    #>
    param([Parameter(Mandatory)] [ValidateSet('Graph', 'Exchange')] [string] $Service)

    $ids = @(Get-TkTenantId -Service $Service)
    $pinned = if ($global:TkSession) { $global:TkSession.TenantId } else { '' }
    $problem = if ($ids.Count -ne 1 -or -not ($ids[0] -as [guid])) { "it could not be confirmed which tenant $Service is signed in to" }
        elseif ($pinned -and $ids[0] -ne $pinned) { "$Service signed in to tenant $($ids[0]), but this session is for tenant $pinned" }
    if ($problem) {
        Disconnect-TkAll
        $global:TkSignOutReason = $problem
        throw "Signed out of Microsoft 365 because $problem. Sign in again with an account for the tenant you mean."
    }

    if (-not $global:TkSession) { $global:TkSession = New-TkSession -TenantId $ids[0] }
    $global:TkSession.LastUsed = Get-Date
    if (-not $global:TkSession.TenantName) {
        $global:TkSession.TenantName = Get-TkTenantName
        $shownName = if ($global:TkSession.TenantName) { $global:TkSession.TenantName } else { '(name not available)' }
        Write-Information "Signed in to tenant: $shownName - $($ids[0])"
    }
}

function Confirm-TkSession {
    <# Signs out when the current connection may no longer be trusted (see the region comment). #>
    if (-not ((Test-TkGraphConnected) -or (Test-TkExchangeConnected))) {
        $global:TkSession = $null
        return
    }
    $reason = Get-TkSessionExpiry -Session $global:TkSession
    if (-not $reason) {
        # A script that connected on its own may have moved a service to another tenant.
        $ids = @(@(Get-TkTenantId -Service Graph) + @(Get-TkTenantId -Service Exchange) | Where-Object { $_ })
        if (@($ids | Where-Object { $_ -ne $global:TkSession.TenantId }).Count) { $reason = 'a connection is signed in to another tenant than this session' }
    }
    if (-not $reason) { return }
    Write-Warning "Signed out of Microsoft 365 because $reason. Sign in again and check the tenant shown at the top."
    Disconnect-TkAll
    $global:TkSignOutReason = $reason
}

function Clear-TkInheritedSignIn {
    <#
        Graph and Exchange keep their connection in process-wide state. A toolkit relaunched in the same
        PowerShell process - or started from a prompt that ran Connect-MgGraph - would otherwise inherit
        that sign-in. Runs once when the worker starts; Confirm-TkSession is the backstop.
    #>
    $loaded = @([AppDomain]::CurrentDomain.GetAssemblies() | ForEach-Object { $_.GetName().Name })
    try {
        if ($loaded -contains 'Microsoft.Graph.Authentication') { Import-Module Microsoft.Graph.Authentication -ErrorAction Stop }
        if ($loaded -like 'Microsoft.Exchange.Management.ExoPowershell*') { Import-Module ExchangeOnlineManagement -ErrorAction Stop }
        if ((Test-TkGraphConnected) -or (Test-TkExchangeConnected)) { Disconnect-TkAll }
    }
    catch { }     # must not fail worker start-up; Confirm-TkSession signs out before any use
}

#endregion

function Connect-TkGraph {
    <#
    .SYNOPSIS
        Ensures a Microsoft Graph connection with (at least) the given delegated scopes.
        With an app registration + certificate in settings.json it signs in app-only instead.
    #>
    [CmdletBinding()]
    param([string[]] $Scopes = @())

    Assert-TkInstalled 'Microsoft.Graph.Authentication'
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Confirm-TkSession

    $cfg = Get-TkSetting 'Graph'
    $context = Get-MgContext

    if ($cfg -and $cfg.ClientId -and $cfg.CertificateThumbprint) {
        # App-only: permissions come from the app registration, not from requested scopes.
        if (-not ($context -and $context.AuthType -eq 'AppOnly')) {
            Write-Information 'Connecting to Microsoft Graph (app-only, certificate)...'
            Connect-MgGraph -TenantId $cfg.TenantId -ClientId $cfg.ClientId -CertificateThumbprint $cfg.CertificateThumbprint -ContextScope Process -NoWelcome -ErrorAction Stop
        }
        Register-TkSignIn -Service Graph
        return
    }

    $missing = @($Scopes | Where-Object { -not $context -or $context.Scopes -notcontains $_ })
    if (-not $context -or $missing.Count) {
        # Reconnect with the union of what we already had and what this module needs.
        # User.Read lets the toolkit read the tenant's name (GET /organization).
        $allScopes = @(@($Scopes) + @(if ($context) { $context.Scopes }) + 'User.Read' | Where-Object { $_ } | Sort-Object -Unique)
        $connect = @{ Scopes = $allScopes; ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($cfg -and $cfg.TenantId) { $connect.TenantId = $cfg.TenantId }

        # Bypass WAM for this sign-in so the browser asks which account to use, then put the user's own setting back.
        $wamOption = [bool](Get-Command Set-MgGraphOption -ParameterName DisableLoginByWAM -ErrorAction SilentlyContinue)
        $restoreWam = $wamOption -and -not (Get-MgGraphOption).DisableLoginByWAM
        if ($restoreWam) { Set-MgGraphOption -DisableLoginByWAM $true | Out-Null }
        Write-Information ("Connecting to Microsoft Graph (scopes: {0})..." -f ($allScopes -join ', '))
        try { Connect-MgGraph @connect }
        finally { if ($restoreWam) { Set-MgGraphOption -DisableLoginByWAM $false | Out-Null } }
    }
    Register-TkSignIn -Service Graph
}

function Connect-TkExchange {
    <#
    .SYNOPSIS
        Ensures an Exchange Online connection (interactive, or app-only if configured).
    #>
    [CmdletBinding()]
    param()

    Confirm-TkSession
    if (-not (Test-TkExchangeConnected)) {
        Assert-TkInstalled 'ExchangeOnlineManagement'
        Import-Module ExchangeOnlineManagement -ErrorAction Stop

        $cfg = Get-TkSetting 'ExchangeOnline'
        $connect = @{ ShowBanner = $false; ErrorAction = 'Stop' }
        if ($cfg -and $cfg.AppId -and $cfg.CertificateThumbprint -and $cfg.Organization) {
            $connect.AppId = $cfg.AppId
            $connect.CertificateThumbprint = $cfg.CertificateThumbprint
            $connect.Organization = $cfg.Organization
            Write-Information 'Connecting to Exchange Online (app-only, certificate)...'
        }
        else {
            # Like Graph: no silent sign-in through the Windows broker (ExchangeOnlineManagement 3.7+).
            if ((Get-Command Connect-ExchangeOnline).Parameters.ContainsKey('DisableWAM')) { $connect.DisableWAM = $true }
            Write-Information 'Connecting to Exchange Online...'
        }
        Connect-ExchangeOnline @connect
    }
    Register-TkSignIn -Service Exchange
}

function Get-TkConnectionStatus {
    Confirm-TkSession

    $graph = $null
    if (Get-Module Microsoft.Graph.Authentication) { $graph = Get-MgContext }

    $exchange = $null
    if (Get-Module ExchangeOnlineManagement) {
        $exchange = Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
    }

    $session = $global:TkSession
    $policy = Get-TkSessionPolicy
    $signOutReason = $global:TkSignOutReason
    $global:TkSignOutReason = ''

    [pscustomobject]@{
        GraphConnected    = [bool]$graph
        GraphAccount      = if (-not $graph) { '' } elseif ($graph.Account) { $graph.Account } else { "app $($graph.AppName)" }
        ExchangeConnected = [bool]$exchange
        ExchangeAccount   = if ($exchange) { [string]$exchange.UserPrincipalName } else { '' }
        TenantId          = if ($session) { $session.TenantId } else { '' }
        TenantName        = if ($session) { $session.TenantName } else { '' }
        SignedIn          = if ($session) { $session.SignedIn } else { $null }
        SessionEnd        = if ($session) { Get-TkSessionEnd -Session $session -Policy $policy } else { $null }
        IdleMinutes       = $policy.IdleMinutes
        SignOutReason     = $signOutReason
    }
}

function Disconnect-TkAll {
    $global:TkSession = $null
    if (Test-TkGraphConnected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Information 'Disconnected from Microsoft Graph.'
    }
    if (Test-TkExchangeConnected) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Information 'Disconnected from Exchange Online.'
    }
    # Fail closed: never carry on believing we are signed out when we are not.
    if ((Test-TkGraphConnected) -or (Test-TkExchangeConnected)) {
        throw 'Could not sign out of Microsoft 365. Close the toolkit and its PowerShell window to end the session.'
    }
}

#region Change guard (dry run and read-only enforcement)
<#
    While a guarded run is active, a PreCommandLookupAction hook sees every command before
    PowerShell resolves it and swaps in a replacement where needed:

      * Commands from Microsoft 365 modules (or with M365 noun prefixes) whose verb changes
        state -> a stub that records the call and does nothing.
      * Invoke-MgGraphRequest / Invoke-RestMethod / Invoke-WebRequest -> a proxy that lets reads
        through (GET, known read-only Graph POST actions, and Exchange Online v3 InvokeCommand
        POSTs for Get-* cmdlets) and records everything else.

    This works for scripts that know nothing about WhatIf. Blocked calls are sent to the GUI
    as Information records tagged 'TkBlocked'. Known gaps (reported per module by
    Get-TkDryRunProfile): other processes, .NET web clients, and commands invoked through a
    CommandInfo object (& (Get-Command X)), which skips command lookup.
#>

$global:TkWriteVerbs = @(
    'Add', 'Approve', 'Block', 'Clear', 'Close', 'Complete', 'Copy', 'Delete', 'Deny', 'Disable', 'Dismount', 'Edit',
    'Enable', 'Grant', 'Import', 'Initialize', 'Install', 'Invoke', 'Join', 'Lock', 'Merge', 'Mount', 'Move', 'New',
    'Publish', 'Register', 'Release', 'Remove', 'Rename', 'Repair', 'Reset', 'Restart', 'Restore', 'Resume', 'Revoke',
    'Rotate', 'Save', 'Send', 'Set', 'Start', 'Stop', 'Submit', 'Suspend', 'Sync', 'Unblock', 'Undo', 'Uninstall',
    'Unlock', 'Unpublish', 'Unregister', 'Update', 'Upgrade', 'Write')
$global:TkM365Modules = '^(Microsoft\.Graph(\..+)?|ExchangeOnlineManagement|tmpEXO_.+|tmp_.+|MicrosoftTeams|PnP\.PowerShell|Microsoft\.Online\.SharePoint\.PowerShell|AzureAD(Preview)?|MSOnline|Az(\..+)?)$'
$global:TkM365Nouns = '^(Mg|EXO|PnP|SPO|AzureAD|AzAD|Msol|Cs|Team)'
$global:TkRestCommands = @('Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest')
# Write-verb commands from M365 modules that only change local session settings, never the tenant.
$global:TkLocalOnlyCommands = @('Set-MgRequestContext', 'Set-MgGraphOption', 'Add-MgEnvironment', 'Set-MgEnvironment', 'Remove-MgEnvironment')
$global:TkHttpMethods = '^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS|MERGE|DEFAULT)$'
$global:TkGuard = @{ Mode = 'Off'; Cache = @{}; Busy = $false; Blocked = 0 }

function Format-TkShortValue {
    param($Value)
    if ($null -eq $Value) { return '$null' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        return '@{' + ((@($Value.Keys) | ForEach-Object { "$_=$(Format-TkShortValue $Value[$_])" }) -join '; ') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        # foreach, not @($Value): in PS 5.1, @() around a List[object] throws 'Argument types do not match'.
        $items = foreach ($v in $Value) { Format-TkShortValue $v }
        return $items -join ', '
    }
    foreach ($p in 'Identity', 'UserPrincipalName', 'PrimarySmtpAddress', 'Id', 'DisplayName', 'Name') {
        if ($Value.PSObject.Properties[$p] -and $Value.$p) { return [string]$Value.$p }
    }
    [string]$Value
}

function Get-TkParameterToken {
    <# Returns the parameter name if the $args element is a '-Name' / '-Name:' token. #>
    param($Item)
    if ($Item -is [string] -and $Item -match '^-([A-Za-z][\w]*):?$') { $Matches[1] }
}

function Format-TkArgumentList {
    param([object[]] $Arguments = @())
    $text = (@($Arguments) | ForEach-Object {
        if (Get-TkParameterToken $_) { ([string]$_).TrimEnd(':') } else { "'" + (Format-TkShortValue $_) + "'" }
    }) -join ' '
    if ($text.Length -gt 400) { $text.Substring(0, 400) + '...' } else { $text }
}

function Get-TkCallTarget {
    param([object[]] $Arguments = @(), $InputObject)
    $preferred = 'Identity', 'UserId', 'GroupId', 'ObjectId', 'Id', 'Mailbox', 'UserPrincipalName', 'Uri', 'DisplayName', 'Name'
    for ($i = 0; $i -lt $Arguments.Count - 1; $i++) {
        $name = Get-TkParameterToken $Arguments[$i]
        if ($name -and $preferred -contains $name) { return Format-TkShortValue $Arguments[$i + 1] }
    }
    if ($null -ne $InputObject) { return Format-TkShortValue $InputObject }
    ''
}

function Write-TkBlockedCall {
    param([string] $Command, [object[]] $Arguments = @(), $InputObject, [string] $Target)
    $global:TkGuard.Blocked++
    if (-not $Target) { $Target = Get-TkCallTarget -Arguments $Arguments -InputObject $InputObject }
    $entry = [pscustomobject]@{
        Mode      = $global:TkGuard.Mode
        Command   = $Command
        Target    = $Target
        Arguments = Format-TkArgumentList $Arguments
    }
    Write-Information -MessageData $entry -Tags 'TkBlocked' -InformationAction Continue
}

function Write-TkReadiness {
    <#
        Reports a tenant-readiness figure for this run: how many of the items the module evaluated
        meet its security-posture rule (e.g. 146 of 200 users have a passkey). The GUI shows it next
        to the result count; it is not a grid row and not in the CSV.
        Count the whole population the module checked, not just the rows it outputs. Items that
        could not be evaluated go in -NotEvaluated, never in -Ready or -Total.
        An impossible figure is not reported (fail closed) - a warning says why.
    #>
    param(
        [Parameter(Mandatory)] [int] $Ready,
        [Parameter(Mandatory)] [int] $Total,
        [Parameter(Mandatory)] [string] $Label,
        [int] $NotEvaluated = 0
    )
    if ($Total -le 0 -or $Ready -lt 0 -or $Ready -gt $Total -or $NotEvaluated -lt 0) {
        Write-Warning "Readiness not reported: '$Ready of $Total' (not evaluated: $NotEvaluated) is not a valid figure."
        return
    }
    $report = [pscustomobject]@{ Ready = $Ready; Total = $Total; Label = $Label; NotEvaluated = $NotEvaluated }
    Write-Information -MessageData $report -Tags 'TkReadiness' -InformationAction Continue
}

function Resolve-TkParameter {
    param($Parameters, [string] $Name)
    if ($Parameters.ContainsKey($Name)) { return $Parameters[$Name] }
    $hits = @($Parameters.Values | Where-Object { $_.Name -like "$Name*" -or $_.Aliases -contains $Name })
    if ($hits.Count -eq 1) { $hits[0] }
}

function ConvertTo-TkCallArgument {
    <#
    .SYNOPSIS
        Splits a proxied call's $args into named and positional arguments using the real command's
        parameter metadata. Needed because re-splatting @args loses '-Switch:$false' and similar.
    #>
    param([Parameter(Mandatory)] $Command, [object[]] $Arguments = @())
    $named = @{}
    $positional = New-Object System.Collections.Generic.List[object]
    $i = 0
    while ($i -lt $Arguments.Count) {
        $item = $Arguments[$i]
        $name = Get-TkParameterToken $item
        $meta = if ($name) { Resolve-TkParameter -Parameters $Command.Parameters -Name $name } else { $null }
        if ($meta) {
            $hasColon = ([string]$item).EndsWith(':')
            if (-not $hasColon -and $meta.SwitchParameter) { $named[$meta.Name] = $true; $i++ }
            # Plain assignment, not '= if (...)': an if-expression unrolls arrays (byte[] body -> object[]).
            elseif ($i + 1 -lt $Arguments.Count) { $named[$meta.Name] = $Arguments[$i + 1]; $i += 2 }
            else { $named[$meta.Name] = $null; $i += 2 }
            continue
        }
        $positional.Add($item)
        $i++
    }
    [pscustomobject]@{ Named = $named; Positional = $positional.ToArray() }
}

function ConvertFrom-TkRequestBody {
    <# A request body as an object: UTF-8 bytes are decoded and JSON strings parsed. $null if it can't be read. #>
    param($Body)
    if ($Body -is [byte[]]) { try { $Body = [System.Text.Encoding]::UTF8.GetString($Body) } catch { return $null } }
    if ($Body -is [string]) { try { return $Body | ConvertFrom-Json } catch { return $null } }
    $Body
}

function Get-TkMember {
    <# A key of a hashtable or a property of an object (both case-insensitive); $null if absent. #>
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value }
}

function Test-TkExoReadCommand {
    <#
        True if a POST is an Exchange Online v3 cmdlet call (.../adminapi/<version>/<tenant>/InvokeCommand)
        for a Get-* cmdlet. EXO v3 sends every classic cmdlet, reads included, this way. The cmdlet name
        must be in both the body and the X-CmdletName header, and they must agree; anything else is a write.
    #>
    param([string] $Uri, $Body, $Headers)
    $path = ([string]$Uri -replace '[?#].*$', '').TrimEnd('/')
    if ($path -notmatch '/adminapi/[^/]+/[^/]+/InvokeCommand$') { return $false }
    $bodyCmdlet = [string](Get-TkMember (Get-TkMember (ConvertFrom-TkRequestBody $Body) 'CmdletInput') 'CmdletName')
    $headerCmdlet = [string](Get-TkMember $Headers 'X-CmdletName')
    if (-not $bodyCmdlet -or $bodyCmdlet -ne $headerCmdlet) { return $false }
    $bodyCmdlet -match '^Get-[A-Za-z]+$'
}

function Test-TkReadRequest {
    <# True if an HTTP request only reads: GET/HEAD/OPTIONS, a known read-only Graph POST action, or an EXO Get-* cmdlet. #>
    param([string] $Method, [string] $Uri, $Body, $Headers)
    $m = if ($Method) { $Method.ToUpperInvariant() } else { 'GET' }
    if ($m -eq 'DEFAULT') { $m = if ($null -ne $Body) { 'POST' } else { 'GET' } }
    if ('GET', 'HEAD', 'OPTIONS' -contains $m) { return $true }
    if ($m -ne 'POST') { return $false }

    $path = ([string]$Uri -replace '[?#].*$', '').TrimEnd('/')
    if ($path -match '/(getByIds|getMemberGroups|getMemberObjects|checkMemberGroups|checkMemberObjects|runHuntingQuery|validateProperties|getAvailableExtensionProperties)$' -or
        $path -match '/search/query$') { return $true }
    if (Test-TkExoReadCommand -Uri $Uri -Body $Body -Headers $Headers) { return $true }

    if ($path -match '/\$batch$') {
        # A batch is a read only if every request inside it is (Graph GETs, or EXO Get-* cmdlet calls).
        $parsed = ConvertFrom-TkRequestBody $Body
        $requests = @(Get-TkMember $parsed 'requests')
        if (-not $requests) { return $false }
        foreach ($r in $requests) {
            $rm = ([string](Get-TkMember $r 'method')).ToUpperInvariant()
            if ('GET', 'HEAD' -contains $rm) { continue }
            if ($rm -eq 'POST' -and (Test-TkExoReadCommand -Uri (Get-TkMember $r 'url') -Body (Get-TkMember $r 'body') -Headers (Get-TkMember $r 'headers'))) { continue }
            return $false
        }
        return $true
    }
    $false
}

function New-TkBlockStub {
    param([string] $DisplayName)
    $quoted = $DisplayName -replace "'", "''"
    # process{} so piped input is recorded once per item, like the real command would receive it.
    [scriptblock]::Create("process { Write-TkBlockedCall -Command '$quoted' -Arguments `$args -InputObject `$_ }")
}

function New-TkRestProxy {
    param([Parameter(Mandatory)] $Real)
    $display = $Real.Name
    {
        $call = ConvertTo-TkCallArgument -Command $Real -Arguments $args
        $method = if ($call.Named.ContainsKey('Method')) { [string]$call.Named['Method'] }
                  else { @($call.Positional | Where-Object { $_ -is [string] -and $_ -match $global:TkHttpMethods }) | Select-Object -First 1 }
        $uri = if ($call.Named.ContainsKey('Uri')) { [string]$call.Named['Uri'] }
               else { @($call.Positional | Where-Object { $_ -isnot [string] -or $_ -notmatch $global:TkHttpMethods }) | Select-Object -First 1 }
        # Indexing, not '= if (...)': an if-expression would unroll a byte[] body into object[].
        $body = $call.Named['Body']
        $headers = $call.Named['Headers']

        if (Test-TkReadRequest -Method $method -Uri $uri -Body $body -Headers $headers) {
            $positional = @($call.Positional)
            $named = $call.Named
            & $Real @positional @named
        }
        else {
            $verb = if ($method) { $method.ToUpperInvariant() } else { 'GET' }
            Write-TkBlockedCall -Command $display -Arguments $args -Target "$verb $uri"
        }
    }.GetNewClosure()
}

function Get-TkGuardReplacement {
    <# Decides what a command name should resolve to during a guarded run: $null = the real command. #>
    param([string] $Name)
    $short = ($Name -split '\\')[-1]
    # Fast path: verb-noun names with a harmless verb never need a lookup.
    if ($short -match '^([A-Za-z]+)-' -and $global:TkWriteVerbs -notcontains $Matches[1]) { return $null }

    try {
        $types = if ($short -notmatch '-') { 'Alias' } else { 'Alias, Function, Cmdlet' }
        $cmd = $ExecutionContext.InvokeCommand.GetCommand($Name, [System.Management.Automation.CommandTypes]$types)
        if ($cmd -and $cmd.CommandType -eq 'Alias') { $cmd = $cmd.ResolvedCommand }
        $commandName = if ($cmd) { $cmd.Name } else { $short }

        if ($global:TkRestCommands -contains $commandName) {
            if ($cmd -and $cmd.CommandType -eq 'Cmdlet') { return New-TkRestProxy -Real $cmd }
            return New-TkBlockStub $commandName          # can't find the real cmdlet: fail closed
        }
        if ($commandName -notmatch '^([A-Za-z]+)-(.+)$') { return $null }
        $verb = $Matches[1]
        $noun = $Matches[2]
        if ($global:TkWriteVerbs -notcontains $verb) { return $null }
        if ($global:TkLocalOnlyCommands -contains $commandName) { return $null }
        $module = if ($cmd) { [string]$cmd.ModuleName } else { '' }
        if ($module -match $global:TkM365Modules -or $noun -match $global:TkM365Nouns) { return New-TkBlockStub $commandName }
        $null
    }
    catch {
        # Fail closed: if we can't decide, a write-verb command is blocked rather than allowed.
        if ($short -match '^([A-Za-z]+)-' -and $global:TkWriteVerbs -contains $Matches[1]) { return New-TkBlockStub $short }
        $null
    }
}

$global:TkLookupHook = {
    param([string] $CommandName, [System.Management.Automation.CommandLookupEventArgs] $LookupArgs)
    $guard = $global:TkGuard
    if ($guard.Mode -eq 'Off' -or $guard.Busy) { return }
    $guard.Busy = $true            # our own lookups below must not re-enter the hook
    try {
        $replacement = $guard.Cache[$CommandName]
        if ($null -eq $replacement) {
            $replacement = Get-TkGuardReplacement $CommandName
            if ($null -eq $replacement) { $replacement = $false }
            $guard.Cache[$CommandName] = $replacement
        }
        if ($replacement) {
            $LookupArgs.CommandScriptBlock = $replacement
            $LookupArgs.StopSearch = $true
        }
    }
    finally { $guard.Busy = $false }
}

function Enable-TkGuard {
    param([Parameter(Mandatory)] [ValidateSet('DryRun', 'ReadOnly')] [string] $Mode)
    $global:TkGuard.Mode = $Mode
    $global:TkGuard.Cache = @{}         # modules may have changed since the last run (e.g. EXO reconnect)
    $global:TkGuard.Blocked = 0
    $global:TkGuard.Busy = $false
    $ExecutionContext.InvokeCommand.PreCommandLookupAction = $global:TkLookupHook
}

function Disable-TkGuard {
    $ExecutionContext.InvokeCommand.PreCommandLookupAction = $null
    $global:TkGuard.Mode = 'Off'
}

#endregion

function Invoke-TkModule {
    <#
    .SYNOPSIS
        Runs one module: satisfy its declared connections, then call its entry script,
        optionally under the change guard.

    .PARAMETER Guard
        Off      - normal run.
        DryRun   - Microsoft 365 changes are blocked and reported (native WhatIf scripts also get -WhatIf).
        ReadOnly - a real run of a read-only module; any attempted change is blocked and reported.
    #>
    param(
        [Parameter(Mandatory)] [string] $EntryPath,
        [Parameter(Mandatory)] $Requires,
        [hashtable] $Parameters = @{},
        [ValidateSet('Off', 'DryRun', 'ReadOnly')] [string] $Guard = 'Off'
    )

    # Even modules that declare no connection: the script must not pick up a stale one.
    Confirm-TkSession
    # Connect before the guard is on, so sign-in is never mistaken for a change.
    if ($Requires.GraphScopes.Count) { Connect-TkGraph -Scopes $Requires.GraphScopes }
    if ($Requires.ExchangeOnline) { Connect-TkExchange }
    if ($global:TkSession) {
        $global:TkSession.LastUsed = Get-Date
        $shownName = if ($global:TkSession.TenantName) { $global:TkSession.TenantName } else { '(name not available)' }
        Write-Information "Tenant: $shownName - $($global:TkSession.TenantId)"
    }

    if ($Guard -eq 'Off') {
        & $EntryPath @Parameters
        return
    }

    # Deliberately NOT setting $WhatIfPreference: that would also silence Set-Alias, Set-Variable,
    # New-Item... and change how the script behaves. The guard targets Microsoft 365 changes only;
    # local files (e.g. CSV reports) are still written. Risky local actions are flagged statically.
    Enable-TkGuard -Mode $Guard
    try { & $EntryPath @Parameters }
    finally { Disable-TkGuard }      # also runs on errors and on Cancel (pipeline stop)
}

Clear-TkInheritedSignIn
