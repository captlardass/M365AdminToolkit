[CmdletBinding()]
param(
    [bool] $IncludeInherited = $true,
    [string[]] $LimitToGroups = @()
)

# Uses Invoke-MgGraphRequest so only Microsoft.Graph.Authentication is required.
# Graph has no "groups that are members of a group" filter, so: read every group, then ask each one
# for its direct group members (20 per $batch call) and build the child -> parent map in memory.
$select = 'id,displayName,mail,groupTypes,securityEnabled,mailEnabled,onPremisesSyncEnabled'
$uri = "v1.0/groups?`$select=$select&`$top=999"

$context = Get-MgContext
$tenantId = if ($context) { $context.TenantId } else { $null }

Write-Information 'Reading groups...'
$groups = @{}
while ($uri) {
    $page = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
    foreach ($group in $page.value) { $groups[([string]$group.id).ToLowerInvariant()] = $group }
    $uri = $page.'@odata.nextLink'
    Write-Information "Read $($groups.Count) group(s)..."
}

# Microsoft 365 groups can't contain groups, so skip asking them.
$toCheck = @($groups.Values | Where-Object { $_.groupTypes -notcontains 'Unified' } | ForEach-Object { ([string]$_.id).ToLowerInvariant() })

# parent id -> list of direct child group ids, and child id -> list of direct parent ids
$parentsOf = @{}
$failed = New-Object System.Collections.Generic.List[string]

function Add-Edge([string] $Parent, [string] $Child) {
    $Child = $Child.ToLowerInvariant()
    if (-not $parentsOf.ContainsKey($Child)) { $parentsOf[$Child] = New-Object System.Collections.Generic.List[string] }
    if (-not $parentsOf[$Child].Contains($Parent)) { $parentsOf[$Child].Add($Parent) }
}

function Read-NextPages([string] $Parent, $NextLink) {
    while ($NextLink) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $NextLink -ErrorAction Stop
        foreach ($m in $page.value) { Add-Edge $Parent ([string]$m.id) }
        $NextLink = $page.'@odata.nextLink'
    }
}

Write-Information "Checking $($toCheck.Count) group(s) for nested group members..."
$done = 0
for ($i = 0; $i -lt $toCheck.Count; $i += 20) {
    $pending = @($toCheck[$i..([Math]::Min($i + 19, $toCheck.Count - 1))])
    $attempt = 0
    while ($pending.Count -gt 0) {
        $attempt++
        $requests = @(for ($n = 0; $n -lt $pending.Count; $n++) {
            @{ id = [string]$n; method = 'GET'; url = "/groups/$($pending[$n])/members/microsoft.graph.group?`$select=id&`$top=999" }
        })
        $body = @{ requests = $requests } | ConvertTo-Json -Depth 4
        $result = Invoke-MgGraphRequest -Method POST -Uri 'v1.0/$batch' -Body $body -ContentType 'application/json' -ErrorAction Stop

        $retry = New-Object System.Collections.Generic.List[string]
        $wait = 0
        foreach ($response in $result.responses) {
            $parent = $pending[[int]$response.id]
            $status = [int]$response.status
            if ($status -eq 200) {
                foreach ($m in $response.body.value) { Add-Edge $parent ([string]$m.id) }
                try { Read-NextPages $parent $response.body.'@odata.nextLink' }
                catch { Write-Warning "Could not read all members of '$($groups[$parent].displayName)': $($_.Exception.Message)"; $failed.Add($parent) }
            }
            elseif ($status -eq 404) {
                Write-Information "Group '$($groups[$parent].displayName)' was deleted during the run - skipped."
            }
            elseif (($status -eq 429 -or $status -ge 500) -and $attempt -lt 5) {
                $retry.Add($parent)
                $after = 0
                if ($response.headers -and [int]::TryParse([string]$response.headers.'Retry-After', [ref]$after)) { $wait = [Math]::Max($wait, $after) }
            }
            else {
                $message = if ($response.body.error) { $response.body.error.message } else { "HTTP $status" }
                Write-Warning "Could not read members of '$($groups[$parent].displayName)': $message"
                $failed.Add($parent)
            }
        }
        $pending = $retry.ToArray()
        if ($pending.Count -gt 0) {
            if ($wait -le 0) { $wait = [Math]::Min(30, [Math]::Pow(2, $attempt)) }
            Write-Information "Throttled - retrying $($pending.Count) group(s) in $wait s..."
            Start-Sleep -Seconds $wait
        }
    }
    $done = [Math]::Min($i + 20, $toCheck.Count)
    if ($done % 500 -lt 20 -or $done -eq $toCheck.Count) { Write-Information "Checked $done of $($toCheck.Count) group(s)..." }
}

function Get-GroupKind($Group) {
    if ($null -eq $Group) { 'Unknown' }
    elseif ($Group.groupTypes -contains 'Unified') { 'Microsoft 365' }
    elseif ($Group.securityEnabled -and $Group.mailEnabled) { 'Mail-enabled security' }
    elseif ($Group.securityEnabled) { 'Security' }
    else { 'Distribution' }
}

function Get-GroupName([string] $Id) {
    if ($groups.ContainsKey($Id)) { $groups[$Id].displayName } else { "<unknown: $Id>" }
}

# Optional filter on the member (child) group: by object id or display name.
$children = @($parentsOf.Keys)
$wanted = @($LimitToGroups | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
if ($wanted.Count -gt 0) {
    $children = @($children | Where-Object { $wanted -contains $_ -or $wanted -contains (Get-GroupName $_) })
    foreach ($w in $wanted) {
        $known = $groups.ContainsKey($w.ToLowerInvariant()) -or @($groups.Values | Where-Object { $_.displayName -eq $w }).Count -gt 0
        if (-not $known) { Write-Warning "No group found matching '$w'." }
    }
}

$rows = 0
foreach ($child in ($children | Sort-Object { Get-GroupName $_ })) {
    # Breadth-first walk up the parent chain: first hit is the shortest path; the visited set stops loops.
    $paths = @{ $child = @($child) }
    $queue = New-Object System.Collections.Generic.Queue[string]
    $queue.Enqueue($child)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        if (-not $parentsOf.ContainsKey($current)) { continue }
        if (-not $IncludeInherited -and $current -ne $child) { continue }
        foreach ($parent in $parentsOf[$current]) {
            if ($paths.ContainsKey($parent)) { continue }
            $paths[$parent] = @($paths[$current]) + $parent
            $queue.Enqueue($parent)

            $chain = $paths[$parent]
            $direct = $chain.Count -eq 2
            $childGroup = $groups[$child]
            $parentGroup = $groups[$parent]
            $rows++
            [pscustomobject]@{
                Group           = Get-GroupName $child
                GroupType       = Get-GroupKind $childGroup
                MemberOf        = Get-GroupName $parent
                MemberOfType    = Get-GroupKind $parentGroup
                Membership      = if ($direct) { 'Direct' } else { 'Inherited' }
                Path            = ($chain | ForEach-Object { Get-GroupName $_ }) -join ' > '
                GroupSource     = if ($childGroup -and $childGroup.onPremisesSyncEnabled) { 'On-premises' } else { 'Cloud' }
                MemberOfSource  = if ($parentGroup -and $parentGroup.onPremisesSyncEnabled) { 'On-premises' } else { 'Cloud' }
                GroupId         = $child
                MemberOfId      = $parent
                TenantId        = $tenantId
            }
        }
    }
}

if ($failed.Count -gt 0) {
    Write-Warning "$($failed.Count) group(s) could not be checked, so the report may be incomplete."
}
Write-Information "Done. $($children.Count) group(s) are members of other groups; $rows row(s)."
