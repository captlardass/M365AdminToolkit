[CmdletBinding()]
param(
    [bool] $ResolveReferencedGroups = $true,
    [bool] $IncludeAllDynamic = $false
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.
# membershipRule can't be filtered server-side, so fetch every dynamic group and match here.
$filter = [uri]::EscapeDataString("groupTypes/any(c:c eq 'DynamicMembership')")
$select = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled,membershipRule,membershipRuleProcessingState'
$uri = "v1.0/groups?`$filter=$filter&`$select=$select&`$count=true&`$top=999"
$headers = @{ ConsistencyLevel = 'eventual' }

# Matches e.g.  user.memberof -any (group.objectId -in ['<guid>', '<guid>'])
$memberOfPattern = '(?i)\b(user|device)\.memberof\b'
$clausePattern = '(?i)\.memberof\s+-any\s*\(\s*group\.objectId\s+-in\s*\[([^\]]*)\]'
$guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$context = Get-MgContext
$tenantId = if ($context) { $context.TenantId } else { $null }

Write-Information 'Reading dynamic membership groups...'
$entries = New-Object System.Collections.Generic.List[object]
$scanned = 0

while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -Headers $headers -ErrorAction Stop
    foreach ($group in $page.value) {
        $scanned++
        $rule = [string]$group.membershipRule
        if ($rule -match $memberOfPattern) {
            $ids = foreach ($clause in [regex]::Matches($rule, $clausePattern)) {
                [regex]::Matches($clause.Groups[1].Value, $guidPattern) | ForEach-Object { $_.Value.ToLowerInvariant() }
            }
            $entries.Add([pscustomobject]@{ Group = $group; UsesMemberOf = $true; ReferencedIds = @($ids | Select-Object -Unique) })
        }
        elseif ($IncludeAllDynamic) {
            $entries.Add([pscustomobject]@{ Group = $group; UsesMemberOf = $false; ReferencedIds = @() })
        }
    }
    $uri = $page.'@odata.nextLink'
    Write-Information "Scanned $scanned dynamic group(s)..."
}

# Resolve referenced group ids to names in batches (getByIds takes up to 1000 ids per call).
$names = @{}
$allIds = @($entries | ForEach-Object { $_.ReferencedIds } | Select-Object -Unique)
if ($ResolveReferencedGroups -and $allIds.Count -gt 0) {
    Write-Information "Resolving $($allIds.Count) referenced group(s)..."
    for ($i = 0; $i -lt $allIds.Count; $i += 1000) {
        $batch = $allIds[$i..([Math]::Min($i + 999, $allIds.Count - 1))]
        $body = @{ ids = @($batch); types = @('group') } | ConvertTo-Json -Depth 3
        $result = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/directoryObjects/getByIds' -Body $body -ContentType 'application/json' -ErrorAction Stop
        foreach ($obj in $result.value) { $names[([string]$obj.id).ToLowerInvariant()] = $obj.displayName }
    }
}

function Get-GroupKind($Group) {
    if ($Group.groupTypes -contains 'Unified') { 'Microsoft 365' }
    elseif ($Group.securityEnabled) { 'Security' }
    else { 'Distribution' }
}

# Iterate the List directly: in PS 5.1, @($list) + @($list) throws 'Argument types do not match'.
foreach ($entry in $entries) {
    $group = $entry.Group
    $ids = $entry.ReferencedIds
    $usesMemberOf = $entry.UsesMemberOf

    $referenced = $null
    $missing = $null
    if ($ResolveReferencedGroups -and $ids.Count -gt 0) {
        $referenced = ($ids | ForEach-Object { if ($names.ContainsKey($_)) { $names[$_] } else { "<not found: $_>" } }) -join '; '
        $missing = @($ids | Where-Object { -not $names.ContainsKey($_) }).Count
    }
    if ($usesMemberOf -and $ids.Count -eq 0) {
        Write-Warning "'$($group.displayName)' uses memberOf but no group ids could be parsed from its rule - check it manually."
    }

    [pscustomobject]@{
        DisplayName            = $group.displayName
        UsesMemberOf           = $usesMemberOf
        GroupType              = Get-GroupKind $group
        ProcessingState        = $group.membershipRuleProcessingState
        ReferencedGroupCount   = $ids.Count
        ReferencedGroups       = $referenced
        MissingReferencedCount = $missing
        ReferencedGroupIds     = $ids -join '; '
        MembershipRule         = $group.membershipRule
        Mail                   = $group.mail
        Id                     = $group.id
        TenantId               = $tenantId
    }
}

$memberOfCount = @($entries | Where-Object { $_.UsesMemberOf }).Count
Write-Information "Done. $memberOfCount of $scanned dynamic group(s) use memberOf."
