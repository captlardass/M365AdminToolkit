[CmdletBinding()]
param(
    [ValidateSet('Privileged', 'All')] [string] $RoleFilter = 'Privileged',
    [bool] $IncludeEligible = $true,
    [bool] $ExpandGroups = $true
)

# GraphScopes: RoleManagement.Read.Directory, User.Read.All, GroupMember.Read.All, Organization.Read.All
# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.
# Reports licensed users that hold (privileged) Entra ID directory roles - one row per user and role assignment.

# Fallback for tenants where roleDefinitions does not return isPrivileged: template ids of well-known privileged roles.
$knownPrivilegedTemplates = @(
    '62e90394-69f5-4237-9190-012177145e10' # Global Administrator
    'e8611ab8-c189-46e8-94e1-60213ab1f814' # Privileged Role Administrator
    '7be44c8a-adaf-4e2a-84d6-ab2649e08a13' # Privileged Authentication Administrator
    '194ae4cb-b126-40b2-bd5b-6091b380977d' # Security Administrator
    'b1be1c3e-b65d-4f19-8427-f6fa0d97feb9' # Conditional Access Administrator
    'c4e39bd9-1100-46d3-8c65-fb160da0071f' # Authentication Administrator
    '9b895d92-2cd3-44c7-9d02-a6ac2d5ea5c3' # Application Administrator
    '158c047a-c907-4556-b7ef-446551a6b5f7' # Cloud Application Administrator
    '8ac3fc64-6eca-42ea-9e69-59f4c7b60eb2' # Hybrid Identity Administrator
    'fe930be7-5e62-47db-91af-98c3a49a38b1' # User Administrator
    '729827e3-9c14-49f7-bb1b-9608f156bbb8' # Helpdesk Administrator
    '29232cdf-9323-42fd-ade2-1d097af3e4de' # Exchange Administrator
    'f28a1f50-f6e7-4571-818b-6a12f2af6b6c' # SharePoint Administrator
    '3a2c62db-5318-420d-8d74-23affee5d9d5' # Intune Administrator
)

function Get-TkGraphPages([string] $Uri) {
    while ($Uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $Uri -ErrorAction Stop
        foreach ($item in $page.value) { $item }
        $Uri = $page.'@odata.nextLink'
    }
}

# --- Role definitions ---------------------------------------------------------------------------
# isPrivileged is exposed on the beta endpoint; fall back to the built-in list when it is missing.
Write-Information 'Reading role definitions...'
$roles = @{}
foreach ($def in Get-TkGraphPages 'beta/roleManagement/directory/roleDefinitions?$select=id,templateId,displayName,isPrivileged,isBuiltIn') {
    $privileged = if ($null -ne $def.isPrivileged) { [bool]$def.isPrivileged } else { $knownPrivilegedTemplates -contains $def.templateId }
    $info = [pscustomobject]@{ Name = $def.displayName; IsPrivileged = $privileged; IsBuiltIn = $def.isBuiltIn }
    $roles[$def.id] = $info
    if ($def.templateId) { $roles[$def.templateId] = $info }
}

# --- License names ------------------------------------------------------------------------------
$skuNames = @{}
try {
    foreach ($sku in Get-TkGraphPages 'v1.0/subscribedSkus?$select=skuId,skuPartNumber') { $skuNames[$sku.skuId] = $sku.skuPartNumber }
}
catch { Write-Warning "Could not read subscribed SKUs, licenses will be shown as SKU ids: $($_.Exception.Message)" }

# --- Role assignments ---------------------------------------------------------------------------
$assignments = New-Object System.Collections.Generic.List[object]

Write-Information 'Reading active role assignments...'
foreach ($a in Get-TkGraphPages 'v1.0/roleManagement/directory/roleAssignments?$expand=principal') {
    $assignments.Add([pscustomobject]@{ Assignment = $a; Type = 'Active' })
}

if ($IncludeEligible) {
    Write-Information 'Reading PIM eligible role assignments...'
    try {
        foreach ($a in Get-TkGraphPages 'v1.0/roleManagement/directory/roleEligibilitySchedules?$expand=principal') {
            $assignments.Add([pscustomobject]@{ Assignment = $a; Type = 'Eligible' })
        }
    }
    catch { Write-Warning "Could not read PIM eligible assignments (needs Entra ID P2): $($_.Exception.Message)" }
}
Write-Information "Found $($assignments.Count) role assignment(s)."

# --- Resolve principals to users ----------------------------------------------------------------
$groupMembers = @{}
$userCache = @{}
$userSelect = 'id,displayName,userPrincipalName,accountEnabled,userType,assignedLicenses'

function Get-TkUser([string] $Id) {
    if (-not $userCache.ContainsKey($Id)) {
        try { $userCache[$Id] = Invoke-MgGraphRequest -Method GET -Uri "v1.0/users/$Id`?`$select=$userSelect" -ErrorAction Stop }
        catch { Write-Warning "Could not read user $Id`: $($_.Exception.Message)"; $userCache[$Id] = $null }
    }
    $userCache[$Id]
}

$reported = 0
$reportedUsers = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($entry in $assignments) {
    $a = $entry.Assignment
    $role = $roles[$a.roleDefinitionId]
    if (-not $role) { $role = [pscustomobject]@{ Name = $a.roleDefinitionId; IsPrivileged = $knownPrivilegedTemplates -contains $a.roleDefinitionId; IsBuiltIn = $null } }
    if ($RoleFilter -eq 'Privileged' -and -not $role.IsPrivileged) { continue }

    $principal = $a.principal
    $principalType = if ($principal) { ([string]$principal.'@odata.type') -replace '^#microsoft\.graph\.', '' } else { '' }

    # Work out which users hold the role, and how. Service principals are skipped.
    $holders = @()
    if ($principalType -eq 'user') {
        $holders = @([pscustomobject]@{ Id = $a.principalId; Via = 'Direct' })
    }
    elseif ($principalType -eq 'group' -and $ExpandGroups) {
        if (-not $groupMembers.ContainsKey($a.principalId)) {
            $groupMembers[$a.principalId] = @(Get-TkGraphPages "v1.0/groups/$($a.principalId)/transitiveMembers/microsoft.graph.user?`$select=id" | ForEach-Object { $_.id })
        }
        $holders = @($groupMembers[$a.principalId] | ForEach-Object { [pscustomobject]@{ Id = $_; Via = "Group: $($principal.displayName)" } })
    }

    $scope = if ($a.directoryScopeId -eq '/') { 'Tenant' } else { $a.directoryScopeId }

    foreach ($holder in $holders) {
        $user = Get-TkUser $holder.Id
        if (-not $user) { continue }
        $licenses = @($user.assignedLicenses)
        if ($licenses.Count -eq 0) { continue }

        $reported++
        [void]$reportedUsers.Add($user.id)
        [pscustomobject]@{
            DisplayName       = $user.displayName
            UserPrincipalName = $user.userPrincipalName
            UserType          = $user.userType
            AccountEnabled    = $user.accountEnabled
            Role              = $role.Name
            RoleIsPrivileged  = $role.IsPrivileged
            AssignmentType    = $entry.Type
            AssignedVia       = $holder.Via
            Scope             = $scope
            Licenses          = (@($licenses | ForEach-Object { if ($skuNames.ContainsKey($_.skuId)) { $skuNames[$_.skuId] } else { $_.skuId } }) -join '; ')
            UserId            = $user.id
        }
    }
}

Write-Information "Done. $reported role assignment(s) held by $($reportedUsers.Count) licensed user(s)."
