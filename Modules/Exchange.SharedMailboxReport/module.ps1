# Read-only report: Sent Items settings and who has which permissions on shared mailboxes.
# Groups are expanded (recursively) to their members, so every count is "distinct effective users".
[CmdletBinding()]
param(
    [string[]] $Mailboxes = @(),
    [bool] $AllSharedMailboxes = $false,
    [bool] $IncludeFolderPermissions = $true,
    [bool] $Detail = $false
)

$extraProperties = 'MessageCopyForSentAsEnabled', 'MessageCopyForSendOnBehalfEnabled', 'GrantSendOnBehalfTo'
# Trustees that are listed in the detail rows but never counted as users.
$uncountedTypes = 'Default', 'Anonymous', 'OrphanedSid', 'EmptyGroup'
$recipientCache = @{}
$groupCache = @{}

function ConvertTo-TkTrustee {
    <# Turns an Exchange recipient (or member) object into the trustee shape used by this report. #>
    param($Recipient, [string] $Fallback)
    $address = [string]$Recipient.PrimarySmtpAddress
    $name = [string]$Recipient.DisplayName
    if (-not $name) { $name = [string]$Recipient.Name }
    if (-not $name) { $name = $Fallback }
    $type = [string]$Recipient.RecipientTypeDetails
    $key = if ($address) { $address } elseif ($Recipient.ExternalDirectoryObjectId) { [string]$Recipient.ExternalDirectoryObjectId } else { $name }
    [pscustomobject]@{
        Name     = $name
        Address  = $address
        Type     = $type
        Key      = $key.ToLowerInvariant()
        IsGroup  = $type -match 'Group'
        Identity = if ($address) { $address } else { $name }
    }
}

function Resolve-TkTrustee {
    <# Looks up a permission's user/trustee string once per run. Never throws. #>
    param([string] $Identity)
    if ($recipientCache.ContainsKey($Identity)) { return $recipientCache[$Identity] }

    $trustee = [pscustomobject]@{
        Name = $Identity; Address = ''; Type = 'Unresolved'; Key = $Identity.ToLowerInvariant(); IsGroup = $false; Identity = $Identity
    }
    if ($Identity -match '^S-1-5-21-') {
        # Permission left behind by a deleted user or group.
        $trustee.Type = 'OrphanedSid'
    }
    else {
        try {
            $recipient = Get-EXORecipient -Identity $Identity -ErrorAction Stop | Select-Object -First 1
            if ($recipient) { $trustee = ConvertTo-TkTrustee -Recipient $recipient -Fallback $Identity }
        }
        catch { Write-Warning "Could not resolve '$Identity': $($_.Exception.Message)" }
    }
    $recipientCache[$Identity] = $trustee
    $trustee
}

function Get-TkGroupMember {
    <# Members of a group as trustees, nested groups expanded. Falls back to the group itself on failure. #>
    param($Group, [System.Collections.Generic.HashSet[string]] $Visited)
    if ($groupCache.ContainsKey($Group.Key)) { return $groupCache[$Group.Key] }
    if (-not $Visited) { $Visited = New-Object 'System.Collections.Generic.HashSet[string]' }
    if (-not $Visited.Add($Group.Key)) { return }    # circular nesting

    $result = New-Object 'System.Collections.Generic.List[object]'
    try {
        $members = if ($Group.Type -eq 'GroupMailbox') {
            Get-UnifiedGroupLinks -Identity $Group.Identity -LinkType Members -ResultSize Unlimited -ErrorAction Stop
        }
        else {
            Get-DistributionGroupMember -Identity $Group.Identity -ResultSize Unlimited -ErrorAction Stop
        }
        foreach ($member in $members) {
            $trustee = ConvertTo-TkTrustee -Recipient $member -Fallback ([string]$member.Name)
            if ($trustee.IsGroup) {
                foreach ($nested in Get-TkGroupMember -Group $trustee -Visited $Visited) { $result.Add($nested) }
            }
            else { $result.Add($trustee) }
        }
        if ($result.Count -eq 0) { Write-Warning "Group '$($Group.Name)' has no members - listed as EmptyGroup, not counted." }
    }
    catch {
        Write-Warning "Could not expand group '$($Group.Name)', counting it as one: $($_.Exception.Message)"
        $result.Add($Group)
    }
    $members = $result.ToArray()
    $groupCache[$Group.Key] = $members
    $members
}

function Get-TkGrant {
    <# One grant per effective user: the trustee itself, or each member if it is a group. #>
    param([string] $Type, [string] $Rights, $Trustee)
    if ($Trustee.IsGroup) {
        $members = @(Get-TkGroupMember -Group $Trustee)
        foreach ($member in $members) {
            [pscustomobject]@{ Type = $Type; Rights = $Rights; Trustee = $member; Via = $Trustee.Name }
        }
        if ($members.Count -eq 0) {
            # Keep the grant visible in the detail view instead of silently dropping it.
            $empty = [pscustomobject]@{ Name = $Trustee.Name; Address = $Trustee.Address; Type = 'EmptyGroup'; Key = $Trustee.Key; IsGroup = $false; Identity = $Trustee.Identity }
            [pscustomobject]@{ Type = $Type; Rights = $Rights; Trustee = $empty; Via = 'Direct' }
        }
    }
    else {
        [pscustomobject]@{ Type = $Type; Rights = $Rights; Trustee = $Trustee; Via = 'Direct' }
    }
}

function Measure-TkUser {
    <# Distinct counted users among the grants of one type ('*' = all types). #>
    param($Grants, [string] $Type)
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($grant in $Grants) {
        if (($Type -eq '*' -or $grant.Type -eq $Type) -and $uncountedTypes -notcontains $grant.Trustee.Type) {
            [void]$set.Add($grant.Trustee.Key)
        }
    }
    $set.Count
}

function Format-TkRightsBreakdown {
    <# 'Editor: 2, Reviewer: 3' - distinct counted users per access right on one folder. #>
    param($Grants, [string] $Type)
    $byRights = @{}
    foreach ($grant in $Grants) {
        if ($grant.Type -ne $Type -or $uncountedTypes -contains $grant.Trustee.Type) { continue }
        if (-not $byRights.ContainsKey($grant.Rights)) { $byRights[$grant.Rights] = New-Object 'System.Collections.Generic.HashSet[string]' }
        [void]$byRights[$grant.Rights].Add($grant.Trustee.Key)
    }
    ($byRights.Keys | Sort-Object | ForEach-Object { '{0}: {1}' -f $_, $byRights[$_].Count }) -join ', '
}

# --- Which mailboxes ---------------------------------------------------------------------------
$targets = New-Object 'System.Collections.Generic.List[object]'
if ($AllSharedMailboxes) {
    Write-Information 'Fetching all shared mailboxes...'
    foreach ($mbx in Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize Unlimited -Properties $extraProperties -ErrorAction Stop) {
        $targets.Add([pscustomobject]@{ Input = [string]$mbx.PrimarySmtpAddress; Mailbox = $mbx; Error = '' })
    }
}
else {
    $Mailboxes = @($Mailboxes | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if (-not $Mailboxes) { throw "Enter at least one mailbox, or tick 'All shared mailboxes'." }
    foreach ($identity in $Mailboxes) {
        try {
            $mbx = Get-EXOMailbox -Identity $identity -Properties $extraProperties -ErrorAction Stop
            if ($mbx.RecipientTypeDetails -ne 'SharedMailbox') {
                Write-Warning "$identity is a $($mbx.RecipientTypeDetails), not a shared mailbox - reporting it anyway."
            }
            $targets.Add([pscustomobject]@{ Input = $identity; Mailbox = $mbx; Error = '' })
        }
        catch {
            $targets.Add([pscustomobject]@{ Input = $identity; Mailbox = $null; Error = $_.Exception.Message })
        }
    }
}
if ($targets.Count -eq 0) { Write-Warning 'No shared mailboxes found.'; return }

Write-Information "Checking $($targets.Count) mailbox(es)$(if ($IncludeFolderPermissions) { ' including Inbox/Calendar folder permissions' })..."
$done = 0

# --- Per mailbox -------------------------------------------------------------------------------
foreach ($target in $targets) {
    $done++
    $mbx = $target.Mailbox
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $grants = New-Object 'System.Collections.Generic.List[object]'
    $calendarDefault = ''

    if (-not $mbx) {
        $errors.Add("Mailbox not found: $($target.Error)")
        Write-Warning "Mailbox $done of $($targets.Count) ('$($target.Input)') not found: $($target.Error)"
    }
    else {
        $address = [string]$mbx.PrimarySmtpAddress

        try {
            $entries = Get-EXOMailboxPermission -Identity $address -ErrorAction Stop | Where-Object {
                [string]$_.User -notlike 'NT AUTHORITY\*' -and [string]$_.Deny -ne 'True' -and
                [string]$_.IsInherited -ne 'True' -and ($_.AccessRights -join ',') -match 'FullAccess'
            }
            foreach ($entry in $entries) {
                foreach ($grant in Get-TkGrant -Type 'FullAccess' -Rights 'FullAccess' -Trustee (Resolve-TkTrustee ([string]$entry.User))) { $grants.Add($grant) }
            }
        }
        catch { $errors.Add("Full Access: $($_.Exception.Message)") }

        try {
            $entries = Get-EXORecipientPermission -Identity $address -AccessRights SendAs -ResultSize Unlimited -ErrorAction Stop | Where-Object {
                [string]$_.Trustee -notlike 'NT AUTHORITY\*' -and [string]$_.AccessControlType -eq 'Allow'
            }
            foreach ($entry in $entries) {
                foreach ($grant in Get-TkGrant -Type 'SendAs' -Rights 'SendAs' -Trustee (Resolve-TkTrustee ([string]$entry.Trustee))) { $grants.Add($grant) }
            }
        }
        catch { $errors.Add("Send As: $($_.Exception.Message)") }

        foreach ($delegate in $mbx.GrantSendOnBehalfTo) {
            if (-not [string]$delegate) { continue }
            foreach ($grant in Get-TkGrant -Type 'SendOnBehalf' -Rights 'SendOnBehalf' -Trustee (Resolve-TkTrustee ([string]$delegate))) { $grants.Add($grant) }
        }

        if ($IncludeFolderPermissions) {
            foreach ($scope in 'Inbox', 'Calendar') {
                try {
                    # The folder name is localised ('Innboks', 'Kalender', ...); the folder type is not.
                    $folder = Get-MailboxFolderStatistics -Identity $address -FolderScope $scope -ErrorAction Stop |
                        Where-Object { $_.FolderType -eq $scope } | Select-Object -First 1
                    if (-not $folder) { throw "No $scope folder found." }
                    $folderIdentity = '{0}:\{1}' -f $address, $folder.Name

                    foreach ($entry in Get-MailboxFolderPermission -Identity $folderIdentity -ErrorAction Stop) {
                        $rights = $entry.AccessRights -join ','
                        $userName = if ($entry.User.DisplayName) { [string]$entry.User.DisplayName } else { [string]$entry.User }
                        $userType = [string]$entry.User.UserType
                        if (-not $userType -and ('Default', 'Anonymous') -contains $userName) { $userType = $userName }

                        if (('Default', 'Anonymous') -contains $userType) {
                            if ($scope -eq 'Calendar' -and $userType -eq 'Default') { $calendarDefault = $rights }
                            if ($rights -ne 'None') {
                                $special = [pscustomobject]@{ Name = $userType; Address = ''; Type = $userType; Key = $userType.ToLowerInvariant(); IsGroup = $false; Identity = $userType }
                                $grants.Add([pscustomobject]@{ Type = "$scope folder"; Rights = $rights; Trustee = $special; Via = 'Direct' })
                            }
                            continue
                        }
                        if ($rights -eq 'None') { continue }

                        $principalAddress = [string]$entry.User.RecipientPrincipal.PrimarySmtpAddress
                        $trustee = if ($userType -eq 'External') {
                            [pscustomobject]@{ Name = $userName; Address = ''; Type = 'External'; Key = $userName.ToLowerInvariant(); IsGroup = $false; Identity = $userName }
                        }
                        elseif ($principalAddress) { Resolve-TkTrustee $principalAddress }
                        else { Resolve-TkTrustee $userName }
                        foreach ($grant in Get-TkGrant -Type "$scope folder" -Rights $rights -Trustee $trustee) { $grants.Add($grant) }
                    }
                }
                catch { $errors.Add("$scope folder: $($_.Exception.Message)") }
            }
        }

        if ($errors.Count) { Write-Warning "Mailbox $done of $($targets.Count) ($address): $($errors -join '; ')" }
    }

    $status = if (-not $mbx) { 'Failed' } elseif ($errors.Count) { 'Partial' } else { 'OK' }
    $common = [ordered]@{
        Mailbox                     = if ($mbx) { [string]$mbx.DisplayName } else { $target.Input }
        PrimarySmtpAddress          = if ($mbx) { [string]$mbx.PrimarySmtpAddress } else { '' }
        RecipientType               = if ($mbx) { [string]$mbx.RecipientTypeDetails } else { '' }
        SentAsCopyToSentItems       = if ($mbx) { [string]$mbx.MessageCopyForSentAsEnabled } else { '' }
        SendOnBehalfCopyToSentItems = if ($mbx) { [string]$mbx.MessageCopyForSendOnBehalfEnabled } else { '' }
    }

    if ($Detail) {
        $rows = 0
        foreach ($grant in $grants) {
            $row = [ordered]@{}
            foreach ($key in $common.Keys) { $row[$key] = $common[$key] }
            $row.PermissionType = $grant.Type
            $row.AccessRights = $grant.Rights
            $row.User = $grant.Trustee.Name
            $row.UserAddress = $grant.Trustee.Address
            $row.UserType = $grant.Trustee.Type
            $row.GrantedVia = $grant.Via
            $row.Status = $status
            $row.Error = $errors -join '; '
            [pscustomobject]$row
            $rows++
        }
        if ($rows -eq 0) {
            # Keep mailboxes without any permissions visible in the detail view too.
            $row = [ordered]@{}
            foreach ($key in $common.Keys) { $row[$key] = $common[$key] }
            $row.PermissionType = '(none)'
            $row.AccessRights = ''; $row.User = ''; $row.UserAddress = ''; $row.UserType = ''; $row.GrantedVia = ''
            $row.Status = $status
            $row.Error = $errors -join '; '
            [pscustomobject]$row
        }
    }
    else {
        $row = $common
        $row.FullAccessUsers = Measure-TkUser -Grants $grants -Type 'FullAccess'
        $row.SendAsUsers = Measure-TkUser -Grants $grants -Type 'SendAs'
        $row.SendOnBehalfUsers = Measure-TkUser -Grants $grants -Type 'SendOnBehalf'
        if ($IncludeFolderPermissions -and $mbx) {
            $row.InboxFolderUsers = Measure-TkUser -Grants $grants -Type 'Inbox folder'
            $row.InboxFolderRights = Format-TkRightsBreakdown -Grants $grants -Type 'Inbox folder'
            $row.CalendarFolderUsers = Measure-TkUser -Grants $grants -Type 'Calendar folder'
            $row.CalendarFolderRights = Format-TkRightsBreakdown -Grants $grants -Type 'Calendar folder'
        }
        else {
            $row.InboxFolderUsers = ''; $row.InboxFolderRights = ''; $row.CalendarFolderUsers = ''; $row.CalendarFolderRights = ''
        }
        $row.CalendarDefault = $calendarDefault
        $row.UsersWithAnyAccess = Measure-TkUser -Grants $grants -Type '*'
        $row.Status = $status
        $row.Error = $errors -join '; '
        [pscustomobject]$row
    }

    if ($done % 10 -eq 0) { Write-Information "$done / $($targets.Count) mailboxes checked..." }
}
