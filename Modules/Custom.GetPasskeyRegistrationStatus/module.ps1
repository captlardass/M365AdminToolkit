<#
.SYNOPSIS
    Lists which users have registered a passkey (FIDO2) as an authentication method, and which have not.

.DESCRIPTION
    Returns one row per user with a PasskeyStatus of Registered, Not registered or Unknown.
    Passkeys cover device-bound passkeys in Microsoft Authenticator and FIDO2 security keys
    such as YubiKey. Windows Hello for Business is a separate method and is not counted.

    Two lookup modes:

      Live   (default) Reads /users/{id}/authentication/fido2Methods for every user. Always up
             to date, includes passkey name/model and registration dates, and needs no
             Entra ID P1/P2 license. One request per user, so large tenants take a while.

      Report Reads /reports/authenticationMethods/userRegistrationDetails. Fast for large
             tenants, but requires Entra ID P1/P2, the data can be a few hours old and only
             method types are returned (no per-key details).

    Read-only: only GET requests are made.

    Graph scopes (enter in the toolkit): User.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All
    AuditLog.Read.All is only used by Report mode. The signed-in admin also needs an Entra role that can
    read other users' authentication methods, e.g. Authentication Administrator or Global Reader.

.PARAMETER Mode
    Live reads each user's passkeys directly. Report uses the registration report (needs Entra ID P1/P2).

.PARAMETER Show
    Which users to return: All, Registered or NotRegistered. Users that could not be checked are always returned.

.PARAMETER IncludeGuests
    Include guest (B2B) accounts. By default only member accounts are checked.

.PARAMETER IncludeDisabled
    Include disabled accounts. By default only enabled accounts are checked.
#>
[CmdletBinding()]
param(
    [ValidateSet('Live', 'Report')]
    [string] $Mode = 'Live',

    [ValidateSet('All', 'Registered', 'NotRegistered')]
    [string] $Show = 'All',

    [bool] $IncludeGuests = $false,

    [bool] $IncludeDisabled = $false
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.

function Get-GraphPaged {
    param([string] $Uri)
    $items = New-Object System.Collections.Generic.List[object]
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        foreach ($item in $page.value) { $items.Add($item) }
        $Uri = $page.'@odata.nextLink'
    }
    , $items
}

function Test-PermissionError($ErrorRecord) {
    "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails.Message)" -match
        'Authentication_MSGraphPermissionMissing|Authorization_RequestDenied|Forbidden|403'
}

function ConvertTo-UtcDate($Value) {
    if (-not $Value) { return $null }
    ([datetime]$Value).ToUniversalTime()
}

# 1. Users in scope
Write-Information 'Retrieving users...'
$users = Get-GraphPaged -Uri 'v1.0/users?$select=id,displayName,userPrincipalName,userType,accountEnabled&$top=999'
$users = @($users | Where-Object {
    ($IncludeGuests -or $_.userType -ne 'Guest') -and
    ($IncludeDisabled -or $_.accountEnabled -eq $true)
})
Write-Information "Users in scope: $($users.Count)"
if ($users.Count -eq 0) {
    Write-Warning 'No users matched the filter.'
    return
}

# 2. Passkey lookup
$rows = New-Object System.Collections.Generic.List[object]

if ($Mode -eq 'Live') {
    $checked = 0
    foreach ($u in $users) {
        $checked++
        $methods = @()
        $lookupError = $null
        try {
            # The Graph SDK retries throttled (429) requests automatically.
            $response = Invoke-MgGraphRequest -Method GET -Uri "v1.0/users/$($u.id)/authentication/fido2Methods" -ErrorAction Stop
            $methods = @($response.value | Where-Object { $_ })
        }
        catch {
            # A missing scope or role fails for every user alike - stop instead of warning 1000 times.
            if ($checked -eq 1 -and (Test-PermissionError $_)) {
                throw ('Access denied reading authentication methods. Make sure the module requires the Graph scope ' +
                    'UserAuthenticationMethod.Read.All and that you have a role such as Authentication Administrator ' +
                    "or Global Reader. Graph said: $($_.Exception.Message)")
            }
            $lookupError = $_.Exception.Message
            Write-Warning "Could not read authentication methods for $($u.userPrincipalName): $lookupError"
        }

        $dates = @($methods | Where-Object { $_.createdDateTime } | ForEach-Object { ConvertTo-UtcDate $_.createdDateTime } | Sort-Object)
        $status = if ($lookupError) { 'Unknown' } elseif ($methods.Count) { 'Registered' } else { 'Not registered' }

        $rows.Add([pscustomobject]@{
            DisplayName        = $u.displayName
            UserPrincipalName  = $u.userPrincipalName
            PasskeyStatus      = $status
            PasskeyCount       = $methods.Count
            PasskeyDetails     = (@($methods | ForEach-Object {
                                    if ($_.model) { "$($_.displayName) [$($_.model)]" } else { $_.displayName }
                                 }) -join '; ')
            FirstRegisteredUtc = if ($dates.Count) { $dates[0] } else { $null }
            LastRegisteredUtc  = if ($dates.Count) { $dates[-1] } else { $null }
            UserType           = $u.userType
            AccountEnabled     = $u.accountEnabled
            LookupError        = $lookupError
            Id                 = $u.id
        })

        if ($checked % 50 -eq 0) { Write-Information "Checked $checked of $($users.Count) user(s)..." }
    }
}
else {
    Write-Information 'Retrieving authentication methods registration report...'
    try {
        $report = Get-GraphPaged -Uri 'v1.0/reports/authenticationMethods/userRegistrationDetails?$top=999'
    }
    catch {
        if (Test-PermissionError $_) {
            throw ('Access denied to the registration report. Report mode needs the Graph scopes AuditLog.Read.All and ' +
                'UserAuthenticationMethod.Read.All, a role such as Reports Reader, Security Reader or Global Reader, ' +
                'and an Entra ID P1/P2 license. Use Mode = Live if the tenant has no P1/P2.')
        }
        if ("$($_.Exception.Message) $($_.ErrorDetails.Message)" -match 'NonPremium') {
            throw 'Report mode needs an Entra ID P1/P2 license in the tenant. Use Mode = Live instead.'
        }
        throw
    }
    $reportById = @{}
    foreach ($entry in $report) { $reportById[$entry.id] = $entry }

    foreach ($u in $users) {
        $entry = $reportById[$u.id]
        # 'fido2' plus the newer 'passKeyDeviceBound*' values
        $passkeyTypes = @()
        if ($entry) { $passkeyTypes = @($entry.methodsRegistered | Where-Object { $_ -match '^(fido2|passKey)' }) }
        $status = if (-not $entry) { 'Unknown' } elseif ($passkeyTypes.Count) { 'Registered' } else { 'Not registered' }

        $rows.Add([pscustomobject]@{
            DisplayName        = $u.displayName
            UserPrincipalName  = $u.userPrincipalName
            PasskeyStatus      = $status
            PasskeyCount       = $null
            PasskeyDetails     = $passkeyTypes -join '; '
            FirstRegisteredUtc = $null
            LastRegisteredUtc  = $null
            UserType           = $u.userType
            AccountEnabled     = $u.accountEnabled
            LookupError        = if (-not $entry) { 'User not in the registration report yet' } else { $null }
            Id                 = $u.id
        })
    }
}

# 3. Summary and output (registered first, then not registered, then unknown)
$registered    = @($rows | Where-Object { $_.PasskeyStatus -eq 'Registered' })
$notRegistered = @($rows | Where-Object { $_.PasskeyStatus -eq 'Not registered' })
$unknown       = @($rows | Where-Object { $_.PasskeyStatus -eq 'Unknown' })
$pct = [Math]::Round(($registered.Count / $rows.Count) * 100, 1)

Write-Information "Done. Checked $($rows.Count) user(s): $($registered.Count) with passkey ($pct %), $($notRegistered.Count) without."
if ($unknown.Count) { Write-Warning "$($unknown.Count) user(s) could not be checked - see the LookupError column." }

$output = switch ($Show) {
    'Registered'    { @($registered) + @($unknown) }
    'NotRegistered' { @($notRegistered) + @($unknown) }
    default         { @($registered) + @($notRegistered) + @($unknown) }
}

$output | Sort-Object @{ Expression = { @('Registered', 'Not registered', 'Unknown').IndexOf($_.PasskeyStatus) } }, DisplayName
