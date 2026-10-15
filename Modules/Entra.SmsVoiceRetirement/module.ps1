<#
.SYNOPSIS
    Shows the SMS and Voice authentication method policy scope and the retirement status of
    Microsoft-provided SMS/Voice delivery for the tenant.

.DESCRIPTION
    Based on microsoft/entra-sms-voice-usage-analyzer (Get-SmsVoicePolicyUsers.ps1, MIT licence).

    Returns one row per finding:
      Tenant  Authentication methods migration state and registration campaign state
      SMS     Policy state and every include/exclude target (all users, groups, users)
      Voice   Same as SMS
      Summary Impact assessment and retirement guidance

    This is a policy scope scanner, not a user inventory or usage report. It does not expand group
    membership, count effective users, inspect registered methods or read sign-in activity. Only a
    migration state of migrationComplete proves that legacy MFA/SSPR settings are ignored; otherwise the
    assessment is reported as incomplete. The temporary opt-out setting and customer-managed telecom
    providers are not inspected.

    Read-only: only GET requests are made.

    GraphScopes: Policy.Read.All, Group.Read.All
    Minimum Entra role: Global Reader, Security Reader or Authentication Policy Administrator.

.PARAMETER IncludeDisabledTargets
    Also list targets kept on a disabled SMS or Voice method. They are not active scope and are marked as such.
#>
[CmdletBinding()]
param(
    [bool] $IncludeDisabledTargets = $false
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.

$retirementUrl = 'https://learn.microsoft.com/entra/identity/authentication/concept-sms-voice-retirement'
$passkeyGuide  = 'https://aka.ms/passkeydeploymentguide'

function Get-Value($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $Object.$Name
}

function ConvertTo-ResultRow([string] $Area, [string] $Item, [string] $Value, [string] $Status, [string] $Detail, [string] $Id) {
    [pscustomobject]@{
        Area   = $Area
        Item   = $Item
        Value  = $Value
        Status = $Status
        Detail = $Detail
        Id     = $Id
    }
}

$groupNames = @{}
function Resolve-GroupName([string] $GroupId) {
    if (-not $groupNames.ContainsKey($GroupId)) {
        try {
            $group = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$GroupId`?`$select=displayName" -ErrorAction Stop
            $groupNames[$GroupId] = Get-Value $group 'displayName'
        }
        catch {
            Write-Warning "Could not resolve group $GroupId`: $($_.Exception.Message)"
            $groupNames[$GroupId] = $GroupId
        }
    }
    $groupNames[$GroupId]
}

# 1. Tenant-wide policy
Write-Information 'Reading the authentication methods policy...'
try {
    $authPolicy = Invoke-MgGraphRequest -Method GET -Uri 'v1.0/policies/authenticationMethodsPolicy' -ErrorAction Stop
}
catch {
    if ("$($_.Exception.Message) $($_.ErrorDetails.Message)" -match 'Authorization_RequestDenied|Forbidden|403') {
        throw ('Access denied reading the authentication methods policy. The module needs the Graph scope Policy.Read.All ' +
            'and a role such as Global Reader, Security Reader or Authentication Policy Administrator. ' +
            "Graph said: $($_.Exception.Message)")
    }
    throw
}

$rows = New-Object System.Collections.Generic.List[object]

$migrationState = Get-Value $authPolicy 'policyMigrationState'
if (-not $migrationState) { $migrationState = 'unknown' }
$migrationComplete = $migrationState -eq 'migrationComplete'
$rows.Add((ConvertTo-ResultRow 'Tenant' 'Migration state' $migrationState $(if ($migrationComplete) { 'OK' } else { 'Warning' }) `
    $(if ($migrationComplete) { 'Legacy MFA/SSPR authentication method settings are ignored.' }
      else { 'Legacy MFA/SSPR settings may still allow SMS/Voice and are not read by this module. Verify them in the Entra admin center and complete the migration.' }) ''))

$campaign = Get-Value (Get-Value $authPolicy 'registrationEnforcement') 'authenticationMethodsRegistrationCampaign'
$campaignState = Get-Value $campaign 'state'
if (-not $campaignState) { $campaignState = 'unknown' }
$campaignText = if ($campaignState -eq 'default') { 'Microsoft managed' } else { $campaignState }
$campaignStatus = switch ($campaignState) { 'enabled' { 'OK' } 'default' { 'Info' } default { 'Warning' } }
$rows.Add((ConvertTo-ResultRow 'Tenant' 'Registration campaign' $campaignText $campaignStatus 'Nudges users to register a stronger method after MFA.' ''))

# 2. SMS and Voice method configurations
$scopes = @{}
$states = @{}
foreach ($method in @('SMS', 'Voice')) {
    Write-Information "Reading the $method method configuration..."
    $config = Invoke-MgGraphRequest -Method GET -ErrorAction Stop `
        -Uri "v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/$($method.ToLower())"

    $state = Get-Value $config 'state'
    if (-not $state) { $state = 'unknown' }
    $states[$method] = $state
    $enabled = $state -eq 'enabled'
    $rows.Add((ConvertTo-ResultRow $method 'Method state' $state $(switch ($state) { 'enabled' { 'Action' } 'disabled' { 'OK' } default { 'Warning' } }) `
        $(if ($enabled) { 'Microsoft-provided delivery retires on 1 Feb 2027.' } else { '' }) ''))

    $scope = [pscustomobject]@{ HasIncludes = $false; Known = $true }
    $scopes[$method] = $scope
    if (-not $enabled -and -not $IncludeDisabledTargets) { continue }

    # Targets are a relationship on some method types; if Graph leaves them out, say so instead of guessing.
    if ($config -is [System.Collections.IDictionary] -and -not $config.Contains('includeTargets')) {
        $scope.Known = $false
        $rows.Add((ConvertTo-ResultRow $method 'Targets' 'unknown' 'Warning' 'Graph did not return the include targets for this method.' ''))
        continue
    }

    $suffix = if ($enabled) { '' } else { ' (method disabled - not active)' }
    foreach ($kind in @('Include', 'Exclude')) {
        foreach ($target in @(Get-Value $config "$($kind.ToLower())Targets")) {
            if ($null -eq $target) { continue }
            $type = Get-Value $target 'targetType'
            $id   = Get-Value $target 'id'
            if ($kind -eq 'Include' -and $enabled) { $scope.HasIncludes = $true }

            $item, $name = if ($type -eq 'group' -and $id -eq 'all_users') { "$kind all users", 'All users' }
                           elseif ($type -eq 'group') { "$kind group", (Resolve-GroupName $id) }
                           else { "$kind $type", '' }
            $status = if (-not $enabled) { 'Info' } elseif ($kind -eq 'Include') { 'Action' } else { 'Info' }
            $detail = if ($kind -eq 'Include' -and $enabled) { 'Policy target - not a user count or proof of actual use.' } else { '' }
            $rows.Add((ConvertTo-ResultRow $method $item $name $status ($detail + $suffix).Trim() $id))
        }
    }
}

# 3. Impact summary
$hasTargets = $scopes['SMS'].HasIncludes -or $scopes['Voice'].HasIncludes
$statesKnown = ($states['SMS'] -in @('enabled', 'disabled')) -and ($states['Voice'] -in @('enabled', 'disabled')) -and
               $scopes['SMS'].Known -and $scopes['Voice'].Known
$complete = $migrationComplete -and $statesKnown

if ($hasTargets) {
    $rows.Add((ConvertTo-ResultRow 'Summary' 'Assessment' 'SMS/Voice targets found' 'Action' `
        'Move these users to phishing-resistant methods (passkeys), or configure a customer-managed telecom provider before 1 Feb 2027.' ''))
}
elseif ($complete) {
    $rows.Add((ConvertTo-ResultRow 'Summary' 'Assessment' 'No enabled SMS/Voice targets' 'OK' `
        'Applies to the authentication methods policy only - not a general certification of migration readiness.' ''))
}
if (-not $complete) {
    $rows.Add((ConvertTo-ResultRow 'Summary' 'Assessment' 'Incomplete' 'Warning' `
        'Migration is not complete or a policy state/scope is unknown, so SMS/Voice may still be available to users.' ''))
}
if ($hasTargets -or -not $complete) {
    $rows.Add((ConvertTo-ResultRow 'Summary' 'From 1 Sep 2026' 'Automatic passkey enablement' 'Info' `
        'Users enabled for SMS/Voice (policy or legacy MFA) are enabled for passkeys and nudged after MFA, unless the tenant used the temporary opt-out.' $passkeyGuide))
    $rows.Add((ConvertTo-ResultRow 'Summary' '1 Feb 2027' 'Microsoft-provided SMS/Voice retires' 'Action' `
        'No opt-out. Users whose only MFA method is SMS/Voice must register a passkey at sign-in unless moved to a customer-managed provider.' $retirementUrl))
}

$actions = @($rows | Where-Object { $_.Status -eq 'Action' }).Count
$warnings = @($rows | Where-Object { $_.Status -eq 'Warning' }).Count
Write-Information "Done. SMS: $($states['SMS']), Voice: $($states['Voice']), migration: $migrationState. $actions action item(s), $warnings warning(s)."
if (-not $migrationComplete) { Write-Warning 'Authentication methods migration is not complete - legacy MFA/SSPR settings were not checked.' }

$rows
