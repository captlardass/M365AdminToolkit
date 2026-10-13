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

    $cfg = Get-TkSetting 'Graph'
    $context = Get-MgContext

    if ($cfg -and $cfg.ClientId -and $cfg.CertificateThumbprint) {
        # App-only: permissions come from the app registration, not from requested scopes.
        if ($context -and $context.AuthType -eq 'AppOnly') { return }
        Write-Information 'Connecting to Microsoft Graph (app-only, certificate)...'
        Connect-MgGraph -TenantId $cfg.TenantId -ClientId $cfg.ClientId -CertificateThumbprint $cfg.CertificateThumbprint -NoWelcome -ErrorAction Stop
        return
    }

    $missing = @($Scopes | Where-Object { -not $context -or $context.Scopes -notcontains $_ })
    if ($context -and $missing.Count -eq 0) { return }

    # Reconnect with the union of what we already had and what this module needs.
    $allScopes = @(@($Scopes) + @(if ($context) { $context.Scopes }) | Where-Object { $_ } | Sort-Object -Unique)
    $connect = @{ NoWelcome = $true; ErrorAction = 'Stop' }
    if ($allScopes.Count) { $connect.Scopes = $allScopes }
    if ($cfg -and $cfg.TenantId) { $connect.TenantId = $cfg.TenantId }

    Write-Information ("Connecting to Microsoft Graph (scopes: {0})..." -f $(if ($allScopes) { $allScopes -join ', ' } else { 'default' }))
    Connect-MgGraph @connect
}

function Test-TkExchangeConnected {
    if (-not (Get-Module ExchangeOnlineManagement)) { return $false }
    $sessions = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Connected' })
    $sessions.Count -gt 0
}

function Connect-TkExchange {
    <#
    .SYNOPSIS
        Ensures an Exchange Online connection (interactive, or app-only if configured).
    #>
    [CmdletBinding()]
    param()

    if (Test-TkExchangeConnected) { return }
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
        Write-Information 'Connecting to Exchange Online...'
    }
    Connect-ExchangeOnline @connect
}

function Get-TkConnectionStatus {
    $graph = $null
    if (Get-Module Microsoft.Graph.Authentication) { $graph = Get-MgContext }

    $exchange = $null
    if (Get-Module ExchangeOnlineManagement) {
        $exchange = Get-ConnectionInformation -ErrorAction SilentlyContinue |
            Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
    }

    [pscustomobject]@{
        GraphConnected    = [bool]$graph
        GraphAccount      = if (-not $graph) { '' } elseif ($graph.Account) { $graph.Account } else { "app $($graph.AppName)" }
        ExchangeConnected = [bool]$exchange
        ExchangeAccount   = if ($exchange) { [string]$exchange.UserPrincipalName } else { '' }
    }
}

function Disconnect-TkAll {
    if ((Get-Module Microsoft.Graph.Authentication) -and (Get-MgContext)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Information 'Disconnected from Microsoft Graph.'
    }
    if (Test-TkExchangeConnected) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Information 'Disconnected from Exchange Online.'
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

    # Connect before the guard is on, so sign-in is never mistaken for a change.
    if ($Requires.GraphScopes.Count) { Connect-TkGraph -Scopes $Requires.GraphScopes }
    if ($Requires.ExchangeOnline) { Connect-TkExchange }

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
