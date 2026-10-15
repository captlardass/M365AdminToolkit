<#
.SYNOPSIS
    Shows which MFA method every user is actually prompted with (their primary method), how strong it is,
    and who still depends on SMS or voice calls.

.DESCRIPTION
    Returns one row per user with:
      PrimaryMethod   The method Entra ID prompts with first. With system-preferred MFA enabled (the
                      Microsoft-managed default) this is the strongest registered method; otherwise it is
                      the method the user picked as preferred.
      Strength        Phishing-resistant (passkey/FIDO2, certificate, platform credential),
                      Standard (Authenticator, OTP), Weak (SMS, voice call), Temporary (Temporary Access Pass)
                      or None (no MFA method). Unknown if the user could not be read.
      Recommendation  What to do next to move the user to phishing-resistant MFA.

    Windows Hello for Business is phishing-resistant but is not offered as an MFA prompt, so it is listed in
    MethodsRegistered only - not as the primary method and not in PhishingResistantRegistered.

    Two lookup modes:

      Live   (default) Reads every user's registered methods and sign-in preferences. Always up to date and
             needs no Entra ID P1/P2 license. Two requests per user, so large tenants take a while. The
             system-preferred method is worked out from the registered methods using Microsoft's documented order.
             Sign-in preferences come from Graph beta if v1.0 does not offer them.

      Report Reads /reports/authenticationMethods/userRegistrationDetails, where Entra ID itself reports the
             system-preferred and user-preferred methods. Fast, but requires Entra ID P1/P2 and the data can be
             a few hours old.

    Read-only: only GET requests are made.

    GraphScopes: User.Read.All, UserAuthenticationMethod.Read.All, AuditLog.Read.All
    AuditLog.Read.All is only used by Report mode. The signed-in admin also needs a role that can read other
    users' authentication methods, e.g. Authentication Administrator, Global Reader or (Report mode) Reports Reader.

.PARAMETER Mode
    Live reads each user's methods directly. Report uses the registration report (needs Entra ID P1/P2).

.PARAMETER Show
    Which users to return: All, SmsOrVoicePrimary or NotPhishingResistant. Users that could not be checked are always returned.

.PARAMETER IncludeGuests
    Include guest (B2B) accounts. By default only member accounts are checked.

.PARAMETER IncludeDisabled
    Include disabled accounts. By default only enabled accounts are checked.
#>
[CmdletBinding()]
param(
    [ValidateSet('Live', 'Report')]
    [string] $Mode = 'Live',

    [ValidateSet('All', 'SmsOrVoicePrimary', 'NotPhishingResistant')]
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

function Get-ErrorText($ErrorRecord) { "$($ErrorRecord.Exception.Message) $($ErrorRecord.ErrorDetails.Message)" }

function Test-PermissionError($ErrorRecord) {
    (Get-ErrorText $ErrorRecord) -match 'Authentication_MSGraphPermissionMissing|Authorization_RequestDenied|Forbidden|403'
}

# Maps any Graph method name (methodsRegistered, systemPreferred, userPreferred, defaultMfaMethod) to a
# display name, a strength and a rank. Rank follows Microsoft's system-preferred MFA order (lower = preferred);
# methods that are never offered as an MFA prompt have no rank.
function Get-MethodInfo([string] $Raw) {
    $name, $strength, $rank = switch -Regex ($Raw) {
        '^\s*$|^none$'                          { 'None', 'None', $null; break }
        'temporaryAccessPass'                   { 'Temporary Access Pass', 'Temporary', $null; break }
        'windowsHello(ForBusiness)?$'           { 'Windows Hello for Business', 'Phishing-resistant', $null; break }
        'passKeySynced'                         { 'Passkey (synced)', 'Phishing-resistant', 1; break }
        'passKey|fido2'                         { 'Passkey (FIDO2)', 'Phishing-resistant', 1; break }
        'x509|certificate'                      { 'Certificate', 'Phishing-resistant', 2; break }
        'macOsSecureEnclave|platformCredential' { 'Platform credential (macOS)', 'Phishing-resistant', 3; break }
        'passwordless'                          { 'Authenticator passwordless', 'Standard', 4; break }
        'push|microsoftAuthenticator'           { 'Authenticator push', 'Standard', 5; break }
        'external'                              { 'External MFA', 'Standard', 6; break }
        'hardware(OneTimePasscode|Oath)'        { 'Hardware OTP token', 'Standard', 7; break }
        'oath|OneTimePasscode'                  { 'OTP app', 'Standard', 7; break }
        'voice|alternateMobilePhone|officePhone' { 'Voice call', 'Weak', 9; break }
        'sms|^mobilePhone$'                     { 'SMS', 'Weak', 8; break }
        'email'                                 { 'Email (SSPR only)', 'SSPR only', $null; break }
        'securityQuestion'                      { 'Security questions (SSPR only)', 'SSPR only', $null; break }
        'appPassword'                           { 'App password', 'Weak', $null; break }
        default                                 { $Raw, 'Unknown', $null }
    }
    [pscustomobject]@{ Name = $name; Strength = $strength; Rank = $rank }
}

# Live mode: turn a /authentication/methods entry into a methodsRegistered-style name.
function Get-LiveMethodName($Method) {
    $type = ($Method.'@odata.type' -replace '^#microsoft\.graph\.', '') -replace 'AuthenticationMethod$', ''
    switch ($type) {
        'password' { $null }
        'phone' {
            switch ($Method.phoneType) { 'mobile' { 'mobilePhone' } 'alternateMobile' { 'alternateMobilePhone' } default { 'officePhone' } }
        }
        'microsoftAuthenticator' { 'microsoftAuthenticatorPush' }
        'softwareOath'           { 'softwareOneTimePasscode' }
        'hardwareOath'           { 'hardwareOneTimePasscode' }
        'platformCredential'     { 'macOsSecureEnclaveKey' }
        default                  { $type }
    }
}

function Get-BestMethod([string[]] $Names) {
    $ranked = @($Names | ForEach-Object { Get-MethodInfo $_ } | Where-Object { $null -ne $_.Rank } | Sort-Object Rank)
    if ($ranked.Count) { $ranked[0] } else { Get-MethodInfo 'none' }
}

function Get-Recommendation($Primary, [bool] $HasPhishingResistant, [bool] $SystemPreferred) {
    if ($Primary.Strength -eq 'Phishing-resistant') { return '' }
    if ($HasPhishingResistant -and -not $SystemPreferred) {
        return 'Has a phishing-resistant method but prefers a weaker one - enable system-preferred MFA or change the preferred method.'
    }
    if ($HasPhishingResistant) { return 'Has a phishing-resistant method that is not used for MFA prompts - check the method policy scope.' }
    switch ($Primary.Strength) {
        'Weak'      { 'Register a passkey. Microsoft-provided SMS/voice delivery retires on 1 Feb 2027.' }
        'None'      { 'No MFA method registered - register a passkey.' }
        'Temporary' { 'Only a Temporary Access Pass - use it to register a passkey.' }
        default     { 'Register a passkey for phishing-resistant MFA.' }
    }
}

function ConvertTo-UserRow($User, [string[]] $Registered, $Primary, [string] $Source, [string] $UserPreferred,
                           $SystemPreferred, [string] $LookupError) {
    $infos = @($Registered | ForEach-Object { Get-MethodInfo $_ })
    # Only methods that can answer an MFA prompt count - Windows Hello for Business alone does not.
    $hasPr = @($infos | Where-Object { $_.Strength -eq 'Phishing-resistant' -and $null -ne $_.Rank }).Count -gt 0
    $hasWeak = @($infos | Where-Object { $_.Strength -eq 'Weak' -and $_.Name -ne 'App password' }).Count -gt 0
    if ($LookupError) { $Primary = [pscustomobject]@{ Name = 'Unknown'; Strength = 'Unknown'; Rank = $null } }

    [pscustomobject]@{
        DisplayName                 = $User.displayName
        UserPrincipalName           = $User.userPrincipalName
        PrimaryMethod               = $Primary.Name
        Strength                    = $Primary.Strength
        PrimarySource               = $Source
        UserPreferredMethod         = if ($UserPreferred) { (Get-MethodInfo $UserPreferred).Name } else { '' }
        SystemPreferredEnabled      = $SystemPreferred
        SmsOrVoiceRegistered        = $hasWeak
        PhishingResistantRegistered = $hasPr
        MethodsRegistered           = (@($infos | ForEach-Object { $_.Name } | Select-Object -Unique) -join '; ')
        Recommendation              = if ($LookupError) { '' } else { Get-Recommendation $Primary $hasPr ($SystemPreferred -eq $true) }
        UserType                    = $User.userType
        AccountEnabled              = $User.accountEnabled
        LookupError                 = $LookupError
        Id                          = $User.id
    }
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

# 2. Primary method per user
$rows = New-Object System.Collections.Generic.List[object]

if ($Mode -eq 'Live') {
    $prefApi = 'v1.0'
    $checked = 0
    foreach ($u in $users) {
        $checked++
        $names = @()
        $prefs = $null
        $lookupError = $null
        try {
            # The Graph SDK retries throttled (429) requests automatically.
            $response = Invoke-MgGraphRequest -Method GET -Uri "v1.0/users/$($u.id)/authentication/methods" -ErrorAction Stop
            $names = @($response.value | Where-Object { $_ } | ForEach-Object { Get-LiveMethodName $_ } | Where-Object { $_ })

            try {
                $prefs = Invoke-MgGraphRequest -Method GET -Uri "$prefApi/users/$($u.id)/authentication/signInPreferences" -ErrorAction Stop
            }
            catch {
                # signInPreferences may only exist in beta; switch once and keep using it.
                if ($prefApi -eq 'v1.0' -and -not (Test-PermissionError $_)) {
                    $prefApi = 'beta'
                    Write-Information 'Sign-in preferences are not in Graph v1.0 here - using beta.'
                    $prefs = Invoke-MgGraphRequest -Method GET -Uri "beta/users/$($u.id)/authentication/signInPreferences" -ErrorAction Stop
                }
                else { throw }
            }
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

        $systemPreferred = $null
        $userPreferred = ''
        $primary = $null
        $source = ''
        if (-not $lookupError) {
            $systemPreferred = $prefs.isSystemPreferredAuthenticationMethodEnabled
            $userPreferred = "$($prefs.userPreferredMethodForSecondaryAuthentication)"
            if ($systemPreferred -ne $false) {
                $primary = Get-BestMethod $names
                $source = 'System-preferred (worked out)'
            }
            elseif ($userPreferred -and $userPreferred -ne 'none') {
                $primary = Get-MethodInfo $userPreferred
                $source = 'User preferred'
            }
            else {
                $primary = Get-BestMethod $names
                $source = 'No preference set (worked out)'
            }
        }
        $rows.Add((ConvertTo-UserRow $u $names $primary $source $userPreferred $systemPreferred $lookupError))

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
        if ((Get-ErrorText $_) -match 'NonPremium') {
            throw 'Report mode needs an Entra ID P1/P2 license in the tenant. Use Mode = Live instead.'
        }
        throw
    }
    $reportById = @{}
    foreach ($entry in $report) { $reportById[$entry.id] = $entry }

    foreach ($u in $users) {
        $entry = $reportById[$u.id]
        if (-not $entry) {
            $rows.Add((ConvertTo-UserRow $u @() $null '' '' $null 'User not in the registration report yet'))
            continue
        }
        $names = @($entry.methodsRegistered | Where-Object { $_ })
        $systemPreferred = $entry.isSystemPreferredAuthenticationMethodEnabled
        $systemMethods = @($entry.systemPreferredAuthenticationMethods | Where-Object { $_ })
        $userPreferred = "$($entry.userPreferredMethodForSecondaryAuthentication)"

        if ($systemPreferred -and $systemMethods.Count) {
            $primary = Get-MethodInfo $systemMethods[0]
            $source = 'System-preferred'
        }
        elseif ($userPreferred -and $userPreferred -ne 'none') {
            $primary = Get-MethodInfo $userPreferred
            $source = 'User preferred'
        }
        elseif ($entry.defaultMfaMethod -and $entry.defaultMfaMethod -ne 'none') {
            $primary = Get-MethodInfo $entry.defaultMfaMethod
            $source = 'Default MFA method'
        }
        else {
            $primary = Get-MethodInfo 'none'
            $source = 'None'
        }
        $rows.Add((ConvertTo-UserRow $u $names $primary $source $userPreferred $systemPreferred $null))
    }
}

# 3. Summary and output
$evaluatedRows = @($rows | Where-Object { $_.Strength -ne 'Unknown' })
$unknown       = @($rows | Where-Object { $_.Strength -eq 'Unknown' })
$resistant     = @($evaluatedRows | Where-Object { $_.Strength -eq 'Phishing-resistant' })
$weak          = @($evaluatedRows | Where-Object { $_.Strength -eq 'Weak' })

Write-Information 'Primary MFA method distribution:'
$rows | Group-Object PrimaryMethod | Sort-Object Count -Descending | ForEach-Object {
    Write-Information ("  {0,-30} {1,6}" -f $_.Name, $_.Count)
}
Write-Information ("Done. Checked $($rows.Count) user(s): $($resistant.Count) phishing-resistant, " +
    "$($weak.Count) on SMS/voice, $($evaluatedRows.Count - $resistant.Count - $weak.Count) other.")
if ($weak.Count) { Write-Warning "$($weak.Count) user(s) are prompted with SMS or voice first. Microsoft-provided SMS/voice delivery retires on 1 Feb 2027." }
if ($unknown.Count) { Write-Warning "$($unknown.Count) user(s) could not be checked - see the LookupError column." }

# Tenant readiness: every user in scope, whatever Show filters out. Unknown users are not counted either way.
if ($evaluatedRows.Count -gt 0 -and (Test-Path Function:\Write-TkReadiness)) {
    Write-TkReadiness -Ready $resistant.Count -Total $evaluatedRows.Count -NotEvaluated $unknown.Count `
        -Label 'users have a phishing-resistant primary MFA method'
}

$output = switch ($Show) {
    'SmsOrVoicePrimary'    { $rows | Where-Object { $_.Strength -in @('Weak', 'Unknown') } }
    'NotPhishingResistant' { $rows | Where-Object { $_.Strength -ne 'Phishing-resistant' } }
    default                { $rows }
}

# Weakest first, so the users to act on are at the top.
$order = @('Weak', 'None', 'Temporary', 'Standard', 'Phishing-resistant', 'Unknown')
$output | Sort-Object @{ Expression = { $order.IndexOf($_.Strength) } }, PrimaryMethod, DisplayName
